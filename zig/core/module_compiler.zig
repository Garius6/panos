const std = @import("std");
const ast = @import("ast.zig");
const bytecode = @import("bytecode.zig");
const compiler = @import("compiler.zig");
const diagnostic = @import("diagnostic.zig");
const module_linker = @import("module_linker.zig");
const module_loader = @import("module_loader.zig");
const resolver = @import("resolver.zig");
const symbols = @import("symbols.zig");
const target_policy = @import("target.zig");
const type_checker = @import("type_checker.zig");
const types = @import("types.zig");
const vm = @import("vm.zig");

pub const ModuleCompilation = struct {
    resolution: ?resolver.Resolution = null,
    checked: ?type_checker.CheckResult = null,
    compiled: ?compiler.CompileResult = null,

    fn deinit(self: *ModuleCompilation) void {
        if (self.compiled) |*compiled| compiled.deinit();
        if (self.checked) |*checked| checked.deinit();
        if (self.resolution) |*resolution| resolution.deinit();
        self.* = undefined;
    }
};

pub const GraphCompileResult = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    diagnostics: diagnostic.DiagnosticList = .{},
    program: bytecode.Program,
    modules: []ModuleCompilation = &.{},
    start: ?bytecode.FunctionId = null,
    nominal_identities: std.AutoHashMap(resolver.ImportedSymbolOrigin, u32),
    next_nominal_identity: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) GraphCompileResult {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .program = bytecode.Program.init(allocator),
            .nominal_identities = .init(allocator),
        };
    }

    pub fn deinit(self: *GraphCompileResult) void {
        for (self.modules) |*module| module.deinit();
        if (self.modules.len != 0) self.allocator.free(self.modules);
        self.nominal_identities.deinit();
        self.program.deinit();
        self.diagnostics.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn hasErrors(self: *const GraphCompileResult) bool {
        for (self.diagnostics.items.items) |item| {
            if (item.severity == .err) return true;
        }
        return false;
    }

    fn appendDiagnostics(self: *GraphCompileResult, items: *const diagnostic.DiagnosticList) !void {
        for (items.items.items) |item| {
            _ = try self.diagnostics.appendUnique(self.allocator, .{
                .phase = item.phase,
                .severity = item.severity,
                .span = item.span,
                .message = try self.arena.allocator().dupe(u8, item.message),
            });
        }
    }
};

const ImportContext = struct {
    allocator: std.mem.Allocator,
    imported_types: std.ArrayList(type_checker.ImportedSymbolType) = .empty,
    nominals: std.ArrayList(type_checker.ImportedNominal) = .empty,
    methods: std.ArrayList(type_checker.ImportedMethod) = .empty,
    impls: std.ArrayList(type_checker.ImportedImpl) = .empty,
    functions: std.ArrayList(compiler.ImportedFunction) = .empty,
    constants: std.ArrayList(compiler.ImportedConstant) = .empty,

    fn init(allocator: std.mem.Allocator) ImportContext {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ImportContext) void {
        self.constants.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.impls.deinit(self.allocator);
        for (self.methods.items) |method| if (method.parameter_names.len != 0) self.allocator.free(method.parameter_names);
        self.methods.deinit(self.allocator);
        self.nominals.deinit(self.allocator);
        self.imported_types.deinit(self.allocator);
        self.* = undefined;
    }

    fn collect(
        self: *ImportContext,
        resolution: *resolver.Resolution,
        modules: []const ModuleCompilation,
        nominal_identities: *std.AutoHashMap(resolver.ImportedSymbolOrigin, u32),
        next_nominal_identity: *u32,
        graph: *const module_loader.Graph,
    ) !void {
        // `Результат`/`Опция` are prelude types — EVERY module gets its
        // OWN freshly-minted symbol for them (the embedded prelude source
        // is merged unqualified into each file's own resolution, see
        // `resolver.zig`'s `predeclareUnqualifiedImport`), so an exported
        // function/field type referencing "the source module's Результат"
        // was structurally unrelated to "this module's Результат" as far
        // as `copyImportedType`'s `.nominal` case was concerned — it's
        // not a REAL cross-module import (`resolution.imported_symbols`
        // never contains it), so nothing ever bridged the two. Real gap
        // found auditing panosiki: ANY imported function returning
        // `Результат(T, Ошибка)` (i.e. basically every function that can
        // fail) silently became `poison` on the calling side once
        // `copyImportedType` failed to find it — `.значение()`/`.ошибка()`
        // then failed "у типа нет поля" instead of working normally.
        // Fixed by bridging, ONCE per distinct target module this file
        // actually imports from: that module's own `Результат`/`Опция`
        // symbol → THIS module's own `Результат`/`Опция` symbol, with
        // `identity = 0` so `TypeStore.eql`'s nominal comparison falls
        // back to comparing symbols directly — exactly the same shape a
        // purely LOCAL (never-imported) usage of `Результат` already
        // produces in this same file.
        var bridged_modules: std.AutoHashMap(usize, void) = .init(self.allocator);
        defer bridged_modules.deinit();

        var imported_symbols = resolution.imported_symbols.iterator();
        while (imported_symbols.next()) |entry| {
            const imported_symbol = entry.key_ptr.*;
            const origin = entry.value_ptr.*;
            try bridged_modules.put(origin.module, {});
            const exported = resolution.symbols.get(imported_symbol) orelse continue;
            const target = &modules[origin.module];
            const target_resolution = if (target.resolution) |*value| value else return error.ImportNotCompiled;
            const target_checked = if (target.checked) |*value| value else return error.ImportNotChecked;
            const target_compiled = if (target.compiled) |*value| value else return error.ImportNotCompiled;
            const target_symbol = target_resolution.decl_symbols.get(origin.declaration) orelse continue;

            switch (exported.kind) {
                .type => {
                    const identity = try nominalIdentity(nominal_identities, next_nominal_identity, origin);
                    const enum_definition = target_checked.enum_definitions.get(target_symbol);
                    const generic_struct = target_checked.generic_nominal_fields.get(target_symbol);
                    const interface_definition = target_checked.interface_definitions.get(target_symbol);
                    const generic_parameters: ?[]const type_checker.GenericParameter = if (generic_struct) |value|
                        value.parameters
                    else if (enum_definition) |value|
                        (if (value.parameters.len != 0) value.parameters else null)
                    else if (interface_definition) |value|
                        (if (value.parameters.len != 0) value.parameters else null)
                    else
                        null;
                    const fields = if (generic_struct) |value| value.fields else target_checked.nominal_fields.get(target_symbol);
                    const enum_variants = if (enum_definition) |value| value.variants else null;
                    const interface_methods = if (interface_definition) |value| value.methods else null;
                    try self.nominals.append(self.allocator, .{
                        .store = &target_checked.types,
                        .definition_store = &target_checked.types,
                        .source_symbol = target_symbol,
                        .local_symbol = imported_symbol,
                        .identity = identity,
                        .fields = fields,
                        .enum_variants = enum_variants,
                        .generic_parameters = generic_parameters,
                        .interface_methods = interface_methods,
                    });
                    for (graph.impls.items) |impl_export| {
                        if (impl_export.module != origin.module or impl_export.owner_declaration != origin.declaration) continue;
                        for (target_checked.interface_implementations.items) |implementation| {
                            if (implementation.target != target_symbol) continue;
                            const interface_symbol = target_resolution.symbols.get(implementation.interface) orelse continue;
                            if (!std.mem.eql(u8, interface_symbol.name, impl_export.interface_name)) continue;
                            try self.impls.append(self.allocator, .{
                                .owner = imported_symbol,
                                .interface_name = impl_export.interface_name,
                                .method_symbols = implementation.methods,
                                .target_resolution = target_resolution,
                                .store = &target_checked.types,
                                .argument_type_ids = implementation.arguments,
                            });
                        }
                    }
                },
                .function => {
                    const signature = target_checked.symbol_types.get(target_symbol) orelse continue;
                    const function_id = target_compiled.function_ids.get(target_symbol) orelse continue;
                    try self.imported_types.append(self.allocator, .{
                        .symbol = imported_symbol,
                        .store = &target_checked.types,
                        .type_id = signature,
                        .generic_parameters = target_checked.generic_function_parameters.get(target_symbol),
                    });
                    try self.functions.append(self.allocator, .{
                        .symbol = imported_symbol,
                        .function_id = function_id,
                    });
                },
                .constant => {
                    const signature = target_checked.symbol_types.get(target_symbol) orelse continue;
                    const value = target_compiled.top_level_constants.get(target_symbol) orelse continue;
                    try self.imported_types.append(self.allocator, .{
                        .symbol = imported_symbol,
                        .store = &target_checked.types,
                        .type_id = signature,
                    });
                    try self.constants.append(self.allocator, .{
                        .symbol = imported_symbol,
                        .value = value,
                    });
                },
                else => {},
            }
        }
        for (resolution.imported_methods.items) |binding| {
            try bridged_modules.put(binding.origin.module, {});
            const target = &modules[binding.origin.module];
            const target_resolution = if (target.resolution) |*value| value else return error.ImportNotCompiled;
            const target_checked = if (target.checked) |*value| value else return error.ImportNotChecked;
            const target_compiled = if (target.compiled) |*value| value else return error.ImportNotCompiled;
            const target_symbol = target_resolution.decl_symbols.get(binding.origin.declaration) orelse continue;
            const signature = target_checked.symbol_types.get(target_symbol) orelse continue;
            const function_id = target_compiled.function_ids.get(target_symbol) orelse continue;
            const parameters = target_resolution.function_parameters.get(binding.origin.declaration) orelse &.{};
            const parameter_names: []const []const u8 = if (parameters.len == 0) &.{} else blk: {
                const names = try self.allocator.alloc([]const u8, parameters.len);
                for (parameters, names) |parameter, *name| name.* = target_resolution.symbols.get(parameter).?.name;
                break :blk names;
            };
            try self.methods.append(self.allocator, .{
                .owner = binding.owner,
                .name = binding.name,
                .symbol = binding.symbol,
                .store = &target_checked.types,
                .type_id = signature,
                .parameter_names = parameter_names,
            });
            try self.functions.append(self.allocator, .{
                .symbol = binding.symbol,
                .function_id = function_id,
            });
        }

        // Every module has separately resolved prelude symbols. Re-host all
        // prelude types that can occur in an exported signature or generic
        // bound; otherwise an imported `[T: Сравниваемое]`, for example,
        // silently loses its bound because its source SymbolId cannot be
        // compared with the importer's local SymbolId.
        const prelude_type_names = [_][]const u8{
            "Результат",
            "Опция",
            "Сравниваемое",
            "Итерируемое",
            "Печатаемое",
        };
        var touched = bridged_modules.keyIterator();
        while (touched.next()) |module_index_ptr| {
            const target = &modules[module_index_ptr.*];
            const target_resolution = if (target.resolution) |*value| value else return error.ImportNotCompiled;
            const target_checked = if (target.checked) |*value| value else return error.ImportNotChecked;
            for (prelude_type_names) |name| {
                const source_symbol = findLocalTypeSymbol(target_resolution, name) orelse continue;
                const local_symbol = findLocalTypeSymbol(resolution, name) orelse continue;
                try self.nominals.append(self.allocator, .{
                    .store = &target_checked.types,
                    .definition_store = &target_checked.types,
                    .source_symbol = source_symbol,
                    .local_symbol = local_symbol,
                    .identity = 0,
                });
            }
        }

        // A public signature may contain a nominal from a dependency of the
        // directly imported module.  It has no name in this module's source,
        // but it still needs a LOCAL representative: fields and methods are
        // keyed by SymbolId in the checker, whereas TypeId must never escape
        // its owning TypeStore.  Re-host the complete reachable nominal
        // closure before importSignaturePass copies any signature.
        var nominal_index: usize = 0;
        while (nominal_index < self.nominals.items.len) : (nominal_index += 1) {
            const imported = self.nominals.items[nominal_index];
            if (imported.fields) |fields| {
                for (fields) |field| {
                    try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, imported.definition_store, field.typ);
                }
            }
            if (imported.enum_variants) |variants| {
                for (variants) |variant| {
                    for (variant.fields) |field| {
                        try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, imported.definition_store, field);
                    }
                }
            }
            if (imported.interface_methods) |methods| {
                for (methods) |method| {
                    for (method.parameters) |parameter| {
                        try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, imported.definition_store, parameter);
                    }
                    try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, imported.definition_store, method.return_type);
                }
            }
        }
        var imported_type_index: usize = 0;
        while (imported_type_index < self.imported_types.items.len) : (imported_type_index += 1) {
            const imported = self.imported_types.items[imported_type_index];
            try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, imported.store, imported.type_id);
        }
        // Index-based, re-reading `self.methods.items` fresh each
        // iteration — NOT `for (self.methods.items) |method|`, which
        // captures a fixed slice. A transitively-discovered nominal with
        // its OWN methods (below, the `.nominal` case) appends MORE
        // entries to this exact list from inside this same loop — a
        // captured slice keeps iterating over the OLD backing array after
        // `ArrayList.append` reallocates it, walking freed memory (real,
        // reproducible segfault: any imported function whose signature
        // combines a transitively-imported nominal with a LOCAL struct
        // that has a `реализация` block, e.g. `std/сеть/http.ps`'s
        // `отправить_json(значение: json.Значение) -> Результат(Ответ,
        // Ошибка)` — `Ответ` has methods).
        var method_index: usize = 0;
        while (method_index < self.methods.items.len) : (method_index += 1) {
            const method = self.methods.items[method_index];
            try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, method.store, method.type_id);
        }
    }

    fn collectTransitiveNominals(
        self: *ImportContext,
        resolution: *resolver.Resolution,
        modules: []const ModuleCompilation,
        nominal_identities: *std.AutoHashMap(resolver.ImportedSymbolOrigin, u32),
        next_nominal_identity: *u32,
        external_store: *const types.TypeStore,
        external_type: types.TypeId,
    ) !void {
        const entry = external_store.get(external_type) orelse return error.InvalidImportedType;
        switch (entry.*) {
            .tuple => |elements| for (elements) |element| try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, external_store, element),
            .function => |function| {
                for (function.parameters) |parameter| try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, external_store, parameter);
                try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, external_store, function.return_type);
            },
            .nominal => |nominal| {
                for (nominal.arguments) |argument| try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, external_store, argument);
                for (self.nominals.items) |known| {
                    if (known.store == external_store and known.source_symbol == nominal.symbol) return;
                }
                const reference_module = moduleForTypeStore(modules, external_store) orelse return error.UnsupportedImportedType;
                const target = &modules[reference_module];
                const target_resolution = if (target.resolution) |*value| value else return error.ImportNotCompiled;
                const origin: resolver.ImportedSymbolOrigin = target_resolution.imported_symbols.get(nominal.symbol) orelse blk: {
                    const declaration = declarationForSymbol(target_resolution, nominal.symbol);
                    if (declaration) |value| break :blk .{ .module = reference_module, .declaration = value };
                    // Resolver-installed builtin types have no AST
                    // declaration and exist independently in every module.
                    // Re-host them by name, just like prelude types; their
                    // operations are recognised by the local checker.
                    const source_symbol = target_resolution.symbols.get(nominal.symbol) orelse return error.UnsupportedImportedType;
                    const local_symbol = findLocalTypeSymbol(resolution, source_symbol.name) orelse return error.UnsupportedImportedType;
                    try self.nominals.append(self.allocator, .{
                        .store = external_store,
                        .definition_store = external_store,
                        .source_symbol = nominal.symbol,
                        .local_symbol = local_symbol,
                        .identity = 0,
                    });
                    return;
                };
                const definition = &modules[origin.module];
                const definition_resolution = if (definition.resolution) |*value| value else return error.ImportNotCompiled;
                const definition_checked = if (definition.checked) |*value| value else return error.ImportNotChecked;
                const definition_compiled = if (definition.compiled) |*value| value else return error.ImportNotCompiled;
                const definition_symbol = definition_resolution.decl_symbols.get(origin.declaration) orelse return error.UnsupportedImportedType;
                const source_symbol = definition_resolution.symbols.get(definition_symbol) orelse return error.UnsupportedImportedType;
                const local_symbol = try resolution.symbols.add(.{
                    .name = source_symbol.name,
                    .kind = .type,
                    .module_path = "@transitive",
                    .is_exported = true,
                    .span = source_symbol.span,
                });
                const identity = try nominalIdentity(nominal_identities, next_nominal_identity, origin);
                const enum_definition = definition_checked.enum_definitions.get(definition_symbol);
                const generic_struct = definition_checked.generic_nominal_fields.get(definition_symbol);
                const interface_definition = definition_checked.interface_definitions.get(definition_symbol);
                const generic_parameters: ?[]const type_checker.GenericParameter = if (generic_struct) |value|
                    value.parameters
                else if (enum_definition) |value|
                    (if (value.parameters.len != 0) value.parameters else null)
                else if (interface_definition) |value|
                    (if (value.parameters.len != 0) value.parameters else null)
                else
                    null;
                try self.nominals.append(self.allocator, .{
                    .store = external_store,
                    .definition_store = &definition_checked.types,
                    .source_symbol = nominal.symbol,
                    .local_symbol = local_symbol,
                    .identity = identity,
                    .fields = if (generic_struct) |value| value.fields else definition_checked.nominal_fields.get(definition_symbol),
                    .enum_variants = if (enum_definition) |value| value.variants else null,
                    .generic_parameters = generic_parameters,
                    .interface_methods = if (interface_definition) |value| value.methods else null,
                });
                // The source resolver never created a binding for this
                // method in the importing module, so create one alongside
                // the synthetic owner.  The compiler then links it to the
                // already compiled source function exactly as for a direct
                // import.
                for (definition_checked.methods.items) |method| {
                    if (method.owner != definition_symbol) continue;
                    const source_method = definition_resolution.symbols.get(method.symbol) orelse continue;
                    const function_id = definition_compiled.function_ids.get(method.symbol) orelse continue;
                    const local_method = try resolution.symbols.add(.{
                        .name = source_method.name,
                        .kind = .function,
                        .module_path = "@transitive",
                        .is_exported = true,
                        .span = source_method.span,
                    });
                    const signature = definition_checked.symbol_types.get(method.symbol) orelse continue;
                    try self.methods.append(self.allocator, .{
                        .owner = local_symbol,
                        .name = source_method.name,
                        .symbol = local_method,
                        .store = &definition_checked.types,
                        .type_id = signature,
                    });
                    try self.functions.append(self.allocator, .{ .symbol = local_method, .function_id = function_id });
                }
            },
            .array => |element| try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, external_store, element),
            .map => |map| {
                try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, external_store, map.key);
                try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, external_store, map.value);
            },
            .process => |message| try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, external_store, message),
            .pointer => |pointee| try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, external_store, pointee),
            else => {},
        }
    }
};

fn moduleForTypeStore(modules: []const ModuleCompilation, store: *const types.TypeStore) ?usize {
    for (modules, 0..) |*module, index| {
        if (module.checked) |*checked| {
            if (&checked.types == store) return index;
        }
    }
    return null;
}

fn declarationForSymbol(resolution: *const resolver.Resolution, symbol: symbols.SymbolId) ?ast.DeclId {
    var declarations = resolution.decl_symbols.iterator();
    while (declarations.next()) |entry| {
        if (entry.value_ptr.* == symbol) return entry.key_ptr.*;
    }
    return null;
}

fn findLocalTypeSymbol(resolution: *const resolver.Resolution, name: []const u8) ?symbols.SymbolId {
    for (resolution.symbols.symbols.items[1..], 1..) |entry, index| {
        if (entry.kind == .type and entry.module_path == null and std.mem.eql(u8, entry.name, name)) {
            return @enumFromInt(index);
        }
    }
    return null;
}

fn nominalIdentity(
    identities: *std.AutoHashMap(resolver.ImportedSymbolOrigin, u32),
    next_identity: *u32,
    origin: resolver.ImportedSymbolOrigin,
) !u32 {
    if (identities.get(origin)) |identity| return identity;
    if (next_identity.* == 0) return error.NominalIdentityLimitReached;
    const identity = next_identity.*;
    next_identity.* += 1;
    try identities.put(origin, identity);
    return identity;
}

pub fn compileGraph(allocator: std.mem.Allocator, graph: *const module_loader.Graph) !GraphCompileResult {
    return compileGraphForTarget(allocator, graph, .native);
}

pub fn compileGraphForTarget(allocator: std.mem.Allocator, graph: *const module_loader.Graph, target_profile: target_policy.TargetProfile) !GraphCompileResult {
    var result = GraphCompileResult.init(allocator);
    errdefer result.deinit();
    try result.appendDiagnostics(&graph.diagnostics);
    if (result.hasErrors()) return result;

    // Detected by reserved path, not a parameter — a graph built without
    // calling `appendPreludeModule` (every existing test, and any caller not
    // yet updated) compiles exactly as before, no prelude merged anywhere.
    const prelude_module = graph.module_indices.get("@prelude");

    result.modules = try allocator.alloc(ModuleCompilation, graph.modules.items.len);
    @memset(result.modules, .{});
    for (graph.order.items) |module_index| {
        const module = &graph.modules.items[module_index];
        var scope = try module_linker.ImportScope.initWithPrelude(allocator, graph, module_index, prelude_module);
        defer scope.deinit();

        // Skipped for EVERY module once a prelude module exists in the
        // graph — the prelude module itself gets its own real declarations
        // instead, and every OTHER module receives them via the implicit
        // unqualified import above, so the hand-installed duplicates would
        // collide with either path, not just the prelude module's own.
        result.modules[module_index].resolution = try resolver.resolveModuleForTarget(allocator, &module.tree, scope.modules, prelude_module != null, target_profile, module.file.path);
        const resolution = &result.modules[module_index].resolution.?;
        try result.appendDiagnostics(&resolution.diagnostics);
        if (result.hasErrors()) return result;

        var imports = ImportContext.init(allocator);
        defer imports.deinit();
        try imports.collect(resolution, result.modules, &result.nominal_identities, &result.next_nominal_identity, graph);

        result.modules[module_index].checked = try type_checker.checkWithImportContextForTarget(allocator, &module.tree, resolution, .{
            .symbols = imports.imported_types.items,
            .nominals = imports.nominals.items,
            .methods = imports.methods.items,
            .impls = imports.impls.items,
        }, target_profile);
        const checked = &result.modules[module_index].checked.?;
        try result.appendDiagnostics(&checked.diagnostics);
        if (result.hasErrors()) return result;

        result.modules[module_index].compiled = try compiler.compileWithOptions(allocator, &module.tree, resolution, checked, .{
            .program = &result.program,
            .functions = imports.functions.items,
            .constants = imports.constants.items,
        });
        const compiled = &result.modules[module_index].compiled.?;
        try result.appendDiagnostics(&compiled.diagnostics);
        if (result.hasErrors()) return result;
    }
    if (result.modules.len != 0) result.start = findStart(&result.modules[0]);
    return result;
}

fn findStart(module: *const ModuleCompilation) ?bytecode.FunctionId {
    const resolution = module.resolution orelse return null;
    const compiled = module.compiled orelse return null;
    for (resolution.symbols.symbols.items, 0..) |symbol, index| {
        if (symbol.kind != .function or !std.mem.eql(u8, symbol.name, "старт")) continue;
        const id: symbols.SymbolId = @enumFromInt(index);
        return compiled.function_ids.get(id);
    }
    return null;
}

const MemoryReader = struct {
    files: []const File,

    const File = struct {
        path: []const u8,
        bytes: []const u8,
    };

    pub fn read(self: *const MemoryReader, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        for (self.files) |file| {
            if (std.mem.eql(u8, file.path, path)) return allocator.dupe(u8, file.bytes);
        }
        return error.FileNotFound;
    }
};

test "module compiler executes imported primitive functions and constants" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./математика\" как мат\nэкспорт функ старт() -> Число\nмат.сложить(мат.ОТВЕТ, 2)\nконец" },
        .{ .path = "проект/математика.ps", .bytes = "экспорт конст ОТВЕТ = 40\nэкспорт функ сложить(a: Число, b: Число) -> Число\na + b\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler checks imported function arguments" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./математика\" как мат\nэкспорт функ старт() -> Число\nмат.сложить(\"ошибка\", 2)\nконец" },
        .{ .path = "проект/математика.ps", .bytes = "экспорт функ сложить(a: Число, b: Число) -> Число\na + b\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expect(compiled.hasErrors());
    try std.testing.expectEqualStrings("Type Error: аргумент не совпадает с типом параметра", compiled.diagnostics.items.items[0].message);
}

test "module compiler executes a transitive imported function" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./удвоение\" как удв\nэкспорт функ старт() -> Число\nудв.применить(21)\nконец" },
        .{ .path = "проект/удвоение.ps", .bytes = "импорт \"./математика\" как мат\nэкспорт функ применить(x: Число) -> Число\nмат.сложить(x, x)\nконец" },
        .{ .path = "проект/математика.ps", .bytes = "экспорт функ сложить(a: Число, b: Число) -> Число\na + b\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler retains imported string constants in the shared program" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./сообщения\" как сообщ\nэкспорт функ старт() -> Строка\nсообщ.ПРИВЕТ + \"!\"\nконец" },
        .{ .path = "проект/сообщения.ps", .bytes = "экспорт конст ПРИВЕТ = \"привет\"" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| {
            const rendered = result.stringBytes() orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("привет!", rendered);
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler preserves opaque exported nominal types across function calls" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер точка: точки.Точка = точки.создать(40)\nточки.добавить(точка, 2)\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец\nэкспорт функ создать(x: Число) -> Точка\nТочка(x)\nконец\nэкспорт функ добавить(точка: Точка, значение: Число) -> Число\nточка.x + значение\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler keeps same-named nominal exports distinct" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./левый\" как лев\nимпорт \"./правый\" как прав\nэкспорт функ старт() -> Число\nлев.значение(прав.создать(1))\nконец" },
        .{ .path = "проект/левый.ps", .bytes = "экспорт тип Значение = структура\nx: Число\nконец\nэкспорт функ значение(значение: Значение) -> Число\nзначение.x\nконец" },
        .{ .path = "проект/правый.ps", .bytes = "экспорт тип Значение = структура\nx: Число\nконец\nэкспорт функ создать(x: Число) -> Значение\nЗначение(x)\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expect(compiled.hasErrors());
    try std.testing.expectEqualStrings("Type Error: аргумент не совпадает с типом параметра", compiled.diagnostics.items.items[0].message);
}

test "module compiler dispatches a same-file impl method on an imported nominal type" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер точка: точки.Точка = точки.Точка(41)\nточка.увеличить()\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец\nреализация Точка\nфунк увеличить(это: Точка) -> Число\nэто.x + 1\nконец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler constructs and matches an imported enum variant with no fields" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./цвета\" как цвета\nэкспорт функ старт() -> Число\nпер c: цвета.Цвет = цвета.Цвет.Красный()\nвыбор c\nКрасный -> 42\nЗелёный -> 0\nконец\nконец" },
        .{ .path = "проект/цвета.ps", .bytes = "экспорт тип Цвет = перечисление\nКрасный\nЗелёный\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler constructs and matches an imported enum variant carrying a field" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./итог\" как итог\nэкспорт функ старт() -> Число\nпер r: итог.Итог = итог.Итог.Готово(41)\nвыбор r\nГотово(x) -> x + 1\nПусто -> 0\nконец\nконец" },
        .{ .path = "проект/итог.ps", .bytes = "экспорт тип Итог = перечисление\nГотово(Число)\nПусто\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler still rejects an unknown variant on an imported enum type" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./цвета\" как цвета\nэкспорт функ старт() -> Число\nпер c: цвета.Цвет = цвета.Цвет.Синий()\n1\nконец" },
        .{ .path = "проект/цвета.ps", .bytes = "экспорт тип Цвет = перечисление\nКрасный\nЗелёный\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expect(compiled.hasErrors());
}

test "module compiler rejects a non-exhaustive match on an imported enum type" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./цвета\" как цвета\nэкспорт функ старт() -> Число\nпер c: цвета.Цвет = цвета.Цвет.Красный()\nвыбор c\nКрасный -> 1\nконец\nконец" },
        .{ .path = "проект/цвета.ps", .bytes = "экспорт тип Цвет = перечисление\nКрасный\nЗелёный\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expect(compiled.hasErrors());
}

test "module compiler dispatches an impl method on a value returned from an imported constructor function" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер точка: точки.Точка = точки.создать(41)\nточка.увеличить()\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец\nэкспорт функ создать(x: Число) -> Точка\nТочка(x)\nконец\nреализация Точка\nфунк увеличить(это: Точка) -> Число\nэто.x + 1\nконец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler still rejects an unknown method on an imported nominal type" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер точка: точки.Точка = точки.Точка(1)\nточка.нет_такого()\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец\nреализация Точка\nфунк увеличить(это: Точка) -> Число\nэто.x + 1\nконец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expect(compiled.hasErrors());
}

test "module compiler instantiates an imported generic struct's field with a concrete type argument" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./короб\" как короб\nэкспорт функ старт() -> Число\nпер к: короб.Коробка(Число) = короб.Коробка(42)\nк.значение\nконец" },
        .{ .path = "проект/короб.ps", .bytes = "экспорт тип Коробка[T] = структура\nзначение: T\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler dispatches a method on an imported generic struct with a concrete type argument" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./короб\" как короб\nэкспорт функ старт() -> Число\nпер к: короб.Коробка(Число) = короб.Коробка(42)\nк.развернуть(0)\nконец" },
        .{ .path = "проект/короб.ps", .bytes = "экспорт тип Коробка[T] = структура\nзначение: T\nконец\nреализация Коробка\nфунк развернуть(это: Коробка, запас: T) -> T\nэто.значение\nконец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler constructs and matches an imported generic enum variant carrying a concrete-type field" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./короб\" как короб\nэкспорт функ старт() -> Число\nпер к: короб.Ящик(Число) = короб.Ящик.Есть(42)\nвыбор к\nЕсть(x) -> x\nПусто -> 0\nконец\nконец" },
        .{ .path = "проект/короб.ps", .bytes = "экспорт тип Ящик[T] = перечисление\nПусто\nЕсть(T)\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler dispatches a method on an imported generic enum with a concrete type argument" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./короб\" как короб\nэкспорт функ старт() -> Число\nпер к: короб.Ящик(Число) = короб.Ящик.Есть(42)\nк.развернуть(0)\nконец" },
        .{ .path = "проект/короб.ps", .bytes = "экспорт тип Ящик[T] = перечисление\nПусто\nЕсть(T)\nконец\nреализация Ящик\nфунк развернуть(это: Ящик, запас: T) -> T\nвыбор это\nЕсть(x) -> x\nПусто -> запас\nконец\nконец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler dispatches an interface-impl method as an ordinary cross-module call" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер первая: точки.Точка = точки.Точка(40)\nпер вторая: точки.Точка = точки.Точка(2)\nпервая.сравнить(вторая)\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец\nреализация Сравниваемое для Точка\nфунк сравнить(это: Точка, другое: Точка) -> Число\nэто.x - другое.x\nконец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 38), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler resolves a qualified impl target within its own declaring module" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./методы\"\nэкспорт функ старт() -> Число\nметоды.проверить()\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец" },
        .{ .path = "проект/методы.ps", .bytes = "импорт \"./точки\" как точки\nреализация точки.Точка\nфунк увеличить(это: точки.Точка) -> Число\nэто.x + 1\nконец\nконец\nэкспорт функ проверить() -> Число\nпер точка: точки.Точка = точки.Точка(41)\nточка.увеличить()\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler resolves a qualified interface-side impl target across a third module" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер a: точки.Точка = точки.Точка(40)\na.значение()\nконец" },
        .{ .path = "проект/интерфейсы.ps", .bytes = "экспорт тип МойИнтерфейс = интерфейс\nфунк значение() -> Число\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "импорт \"./интерфейсы\" как интерфейсы\nэкспорт тип Точка = структура\nx: Число\nконец\nреализация интерфейсы.МойИнтерфейс для Точка\nфунк значение(это: Точка) -> Число\nэто.x\nконец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 40), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler dispatches an imported struct's interface implementation via a generic bound" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nфунк макс[T: Сравниваемое](a: T, b: T) -> T\nесли a > b тогда a иначе b конец\nконец\nэкспорт функ старт() -> Число\nпер a: точки.Точка = точки.Точка(40)\nпер b: точки.Точка = точки.Точка(2)\nмакс(a, b).x\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец\nреализация Сравниваемое для Точка\nфунк сравнить(это: Точка, другое: Точка) -> Число\nэто.x - другое.x\nконец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 40), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler preserves a prelude bound on an imported generic function" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./библиотека\" как библиотека\nэкспорт функ старт() -> Число\nпер a: библиотека.Точка = библиотека.Точка(40)\nпер b: библиотека.Точка = библиотека.Точка(2)\nбиблиотека.макс(a, b).x\nконец" },
        .{ .path = "проект/библиотека.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец\nреализация Сравниваемое для Точка\nфунк сравнить(это: Точка, другое: Точка) -> Число\nэто.x - другое.x\nконец\nконец\nэкспорт функ макс[T: Сравниваемое](a: T, b: T) -> T\nесли a > b тогда a иначе b конец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 40), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler rejects a value outside an imported generic function bound" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./библиотека\" как библиотека\nэкспорт функ старт() -> Строка\nбиблиотека.макс(\"a\", \"b\")\nконец" },
        .{ .path = "проект/библиотека.ps", .bytes = "экспорт функ макс[T: Сравниваемое](a: T, b: T) -> T\nесли a > b тогда a иначе b конец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expect(compiled.hasErrors());
    try std.testing.expectEqualStrings("Type Error: тип аргумента не реализует ограничение 'Сравниваемое'", compiled.diagnostics.items.items[0].message);
}

test "module compiler dispatches through a direct interface-typed cast on an imported struct" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер a: точки.Точка = точки.Точка(40)\nпер b: точки.Точка = точки.Точка(2)\nпер x: Сравниваемое = a\nx.сравнить(b)\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец\nреализация Сравниваемое для Точка\nфунк сравнить(это: Точка, другое: Точка) -> Число\nэто.x - другое.x\nконец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 38), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler merges an appended prelude module unqualified into every real module" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "экспорт функ старт() -> Число\nпер к: Коробочка(Число) = Коробочка.Есть(42)\nк.развернуть(0)\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");
    _ = try graph.appendPreludeModule(
        \\экспорт тип Коробочка[T] = перечисление
        \\Пусто
        \\Есть(T)
        \\конец
        \\реализация Коробочка
        \\функ развернуть(это: Коробочка, запас: T) -> T
        \\выбор это
        \\Есть(x) -> x
        \\Пусто -> запас
        \\конец
        \\конец
        \\конец
    );

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler constructs and reads exported structure fields" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер точка: точки.Точка = точки.Точка(1)\nточка.x = 40\nточка.x + 2\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler preserves a transitive nominal field type" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./api\" как api\nэкспорт функ старт() -> Число\napi.создать().элемент.значение\nконец" },
        .{ .path = "проект/api.ps", .bytes = "импорт \"./модель\" как модель\nэкспорт тип Ответ = структура\nэлемент: модель.Элемент\nконец\nэкспорт функ создать() -> Ответ\nОтвет(модель.Элемент(42))\nконец" },
        .{ .path = "проект/модель.ps", .bytes = "экспорт тип Элемент = структура\nзначение: Число\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler accepts an imported nominal in an imported generic callback" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./коллекции\" как кол\nимпорт \"./модель\" как модель\nфунк в_число(x: модель.Элемент) -> Число\nx.значение\nконец\nэкспорт функ старт() -> Число\nпер значения = кол.отобразить(массив(модель.Элемент(42)), в_число)\nзначения.получить(0, 0)\nконец" },
        .{ .path = "проект/коллекции.ps", .bytes = "экспорт функ отобразить[T, U](значения: Массив(T), преобразовать: функ(T) -> U) -> Массив(U)\nпер результат: Массив(U) = массив()\nдля значение в значения цикл\nрезультат.добавить(преобразовать(значение))\nконец\nрезультат\nконец" },
        .{ .path = "проект/модель.ps", .bytes = "экспорт тип Элемент = структура\nзначение: Число\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// Real, reproducible segfault found via std/сеть/http.ps's
// `отправить_json(значение: json.Значение) -> Результат(Ответ, Ошибка)`:
// importing a function whose signature combines a TRANSITIVELY-imported
// nominal (`модель.Элемент` here, imported only via `сервис.ps`, never
// directly by `main.ps`) with a LOCALLY-declared struct that has its OWN
// `реализация` methods (`Обёртка.развернуть` here) crashed inside
// `ImportContext.collect`'s `for (self.methods.items) |method|` loop —
// `collectTransitiveNominals` (called from inside that exact loop, for
// the `Обёртка` case) appends MORE entries to `self.methods` itself
// (`.nominal`'s "definition has its own methods" branch), which can
// reallocate the backing array out from under the `for` loop's already-
// captured slice — the classic "mutate a collection while iterating a
// captured slice of it" use-after-free. `модель.Элемент` alone (no local
// struct with methods) never triggered it; `Обёртка` alone (no
// transitive import) never triggered it either — needs both at once,
// exactly like `отправить_json` (`json.Значение` transitive + local
// `Ответ` with a `реализация` block).
test "module compiler imports a function combining a transitive nominal with a local struct that has methods" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./сервис\" как сервис\nимпорт \"./модель\" как модель\nэкспорт функ старт() -> Число\nвыбор сервис.обернуть(модель.Элемент(42))\nРезультат.Успех(о) -> о.развернуть()\nРезультат.Неудача(_) -> -1\nконец\nконец" },
        .{ .path = "проект/сервис.ps", .bytes = "импорт \"./модель\" как модель\nэкспорт тип Обёртка = структура\nзначение: Число\nконец\nреализация Обёртка\nфунк развернуть(это: Обёртка) -> Число\nэто.значение\nконец\nконец\nэкспорт функ обернуть(значение: модель.Элемент) -> Результат(Обёртка, Ошибка)\nРезультат.Успех(Обёртка(значение.значение))\nконец" },
        .{ .path = "проект/модель.ps", .bytes = "экспорт тип Элемент = структура\nзначение: Число\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .number => |number| try std.testing.expectEqual(@as(f64, 42), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}
