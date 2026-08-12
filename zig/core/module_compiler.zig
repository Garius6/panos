const std = @import("std");
const ast = @import("ast.zig");
const bytecode = @import("bytecode.zig");
const compiler = @import("compiler.zig");
const diagnostic = @import("diagnostic.zig");
const module_linker = @import("module_linker.zig");
const module_loader = @import("module_loader.zig");
const prelude = @import("prelude.zig");
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
    // Each `ImportedNominal.default_method_symbols` (when non-null) is a
    // fresh allocation `bridgeDefaultMethodSymbols` makes with
    // `self.allocator` (not arena-owned like most of what `nominals`
    // otherwise just BORROWS) — tracked here so `deinit` actually frees
    // them instead of leaking one array per cross-module interface with
    // default methods.
    default_method_symbol_arrays: std.ArrayList([]const ?symbols.SymbolId) = .empty,

    fn init(allocator: std.mem.Allocator) ImportContext {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ImportContext) void {
        for (self.default_method_symbol_arrays.items) |array| self.allocator.free(array);
        self.default_method_symbol_arrays.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.impls.deinit(self.allocator);
        for (self.methods.items) |method| if (method.parameter_names.len != 0) self.allocator.free(method.parameter_names);
        self.methods.deinit(self.allocator);
        self.nominals.deinit(self.allocator);
        self.imported_types.deinit(self.allocator);
        self.* = undefined;
    }

    // Mints a LOCAL synthetic symbol standing in for each default
    // method a SOURCE interface declares (parallel to `methods`,
    // `null` where that method has no default) — the SAME "synthetic
    // symbol + `imports.functions` entry" pattern already used for
    // inherent methods elsewhere in this file, just for a default
    // method's compiled function instead. Returns `null` (no array at
    // all) when the interface has no default methods, matching
    // `ImportedNominal.interface_methods` itself staying `null` for a
    // non-interface nominal.
    //
    // WARNING for future callers: this mints a FRESH synthetic symbol on
    // every call, with no dedup of its own — every existing caller
    // (`collect`'s direct-import loop and `collectTransitiveNominals`)
    // is only safe because BOTH append to the same `self.nominals` array
    // and dedup against it BEFORE calling this (`collectTransitiveNominals`
    // explicitly scans `self.nominals.items` for an already-known
    // `(store, source_symbol)` pair and returns early). A third
    // collection path that calls this without first checking
    // `self.nominals` the same way would silently double-mint symbols
    // for the same interface — not a crash, just duplicate/leaked
    // synthetic bindings.
    fn bridgeDefaultMethodSymbols(self: *ImportContext, resolution: *resolver.Resolution, definition_compiled: *const compiler.CompileResult, methods: []const type_checker.InterfaceMethod) !?[]const ?symbols.SymbolId {
        var any_default = false;
        for (methods) |method| {
            if (method.default_symbol != null) {
                any_default = true;
                break;
            }
        }
        if (!any_default) return null;
        const result = try self.allocator.alloc(?symbols.SymbolId, methods.len);
        errdefer self.allocator.free(result);
        for (methods, result) |method, *slot| {
            const source_default = method.default_symbol orelse {
                slot.* = null;
                continue;
            };
            const function_id = definition_compiled.function_ids.get(source_default) orelse {
                slot.* = null;
                continue;
            };
            const local_symbol = try resolution.symbols.add(.{
                .name = method.name,
                .kind = .function,
                .module_path = "@transitive",
                .is_exported = true,
                .span = .{ .file_id = 0, .start = 0, .end = 0 },
            });
            try self.functions.append(self.allocator, .{ .symbol = local_symbol, .function_id = function_id });
            slot.* = local_symbol;
        }
        try self.default_method_symbol_arrays.append(self.allocator, result);
        return result;
    }

    // Does `target` (a symbol within `impl_resolution`, an interface
    // implementation's `.target`) refer to the SAME struct/enum as
    // `{origin_module, origin_declaration}`? Two cases: `target` is
    // itself an import within `impl_resolution` (the common
    // cross-module case, including a THIRD file — compare origins
    // directly); or `target` has no import origin at all, meaning it's
    // a LOCAL declaration in `impl_resolution`'s own module (the
    // same-file impl case) — then it matches only if that module IS
    // `origin_module` and `target` is exactly the symbol THAT module's
    // own resolver minted for `origin_declaration`.
    fn implementationTargetMatches(impl_resolution: *const resolver.Resolution, target: symbols.SymbolId, impl_own_module: usize, origin_module: usize, origin_declaration: ast.DeclId) bool {
        if (impl_resolution.imported_symbols.get(target)) |origin| {
            return origin.module == origin_module and origin.declaration == origin_declaration;
        }
        if (impl_own_module != origin_module) return false;
        return (impl_resolution.decl_symbols.get(origin_declaration) orelse return false) == target;
    }

    // Reverse lookup — does `resolution` (some OTHER module, not
    // necessarily the impl's own) have a local symbol standing in for
    // `{module, declaration}`? Used to resolve a qualified INTERFACE
    // (codegen's `json.ВJSON`) to a symbol the CONSUMING module can
    // actually use — a bare-name lookup can't find it there (only in
    // scope as `модуль.Интерфейс`). `resolution.imported_symbols` is
    // small (one entry per named cross-module reference in a single
    // file), a linear scan here is not a hot path.
    fn findLocalSymbolForOrigin(resolution: *const resolver.Resolution, module: usize, declaration: ast.DeclId) ?symbols.SymbolId {
        var it = resolution.imported_symbols.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.module == module and entry.value_ptr.declaration == declaration) return entry.key_ptr.*;
        }
        return null;
    }

    // Shared by the direct-import (`collect`) and transitive-import
    // (`collectTransitiveNominals`) paths — both re-host a nominal's
    // interface implementations the same way, differing only in which
    // module/resolution/target symbol the source data comes from.
    //
    // `impl_export.module` (where the `реализация` block is physically
    // written) may DIFFER from `origin_module` (where the target struct
    // is declared) — a qualified impl target in a THIRD file (codegen's
    // `_gen.ps` shape: `реализация json.ВJSON для json_fixture.Заказ`,
    // written in neither json_fixture.ps nor the consumer). So this
    // fetches `interface_implementations` from the IMPL's OWN module's
    // checked results (`modules[impl_export.module]`), not the target's
    // — and matches `implementation.target` against `{origin_module,
    // origin_declaration}` by ORIGIN, not raw `SymbolId` equality
    // (`implementation.target` lives in the impl module's OWN symbol
    // table, a DIFFERENT space than `origin_declaration`'s target
    // module OR the consuming module calling this function — comparing
    // them directly only ever coincidentally worked for the two
    // previously-supported shapes, where impl/target/consumer symbol
    // spaces happened to overlap).
    fn appendMatchingImpls(
        self: *ImportContext,
        graph: *const module_loader.Graph,
        modules: []const ModuleCompilation,
        resolution: *const resolver.Resolution,
        own_module: usize,
        origin_module: usize,
        origin_declaration: ast.DeclId,
        owner_symbol: symbols.SymbolId,
    ) !void {
        for (graph.impls.items) |impl_export| {
            if (impl_export.owner_module != origin_module or impl_export.owner_declaration != origin_declaration) continue;
            // A `реализация` block declared IN THIS SAME module (`own_module`
            // — e.g. a consumer file that imports a struct and also
            // implements a qualified interface for it locally) is already
            // registered directly by that module's own `signaturePass`
            // (`defineInterfaceImplementation`) — bridging it here too would
            // read `modules[own_module].checked`, which doesn't exist yet
            // (we're INSIDE collecting for `own_module` right now, its
            // `checked` is only set after `collect()` returns) —
            // `error.ImportNotChecked`, a real crash found via this exact
            // shape (both the "impl in consumer" and "impl in a third file
            // that's ALSO imported directly for other exports" tests).
            if (impl_export.module == own_module) continue;
            const impl_module = &modules[impl_export.module];
            const impl_resolution = if (impl_module.resolution) |*value| value else return error.ImportNotCompiled;
            const impl_checked = if (impl_module.checked) |*value| value else return error.ImportNotChecked;
            for (impl_checked.interface_implementations.items) |implementation| {
                if (!implementationTargetMatches(impl_resolution, implementation.target, impl_export.module, origin_module, origin_declaration)) continue;
                const interface_symbol = impl_resolution.symbols.get(implementation.interface) orelse continue;
                if (!std.mem.eql(u8, interface_symbol.name, impl_export.interface_name)) continue;
                // A qualified interface (codegen's `json.ВJSON`) needs a
                // LOCAL symbol in the CONSUMING module's own resolution
                // to be usable by `type_checker.zig` (a bare-name lookup
                // there can't find it — it's only in scope as
                // `модуль.Интерфейс`, never unqualified). Resolved by
                // ORIGIN, same principle as the target match above; a
                // consumer that never itself imports the interface's
                // module gets `null` here and this impl is skipped for
                // it (degrades to "not found", not a crash — matches
                // the existing skip-on-unresolvable pattern throughout
                // this function).
                const interface_local_symbol = if (impl_export.interface_module) |interface_module|
                    findLocalSymbolForOrigin(resolution, interface_module, impl_export.interface_declaration.?) orelse continue
                else
                    null;
                try self.impls.append(self.allocator, .{
                    .owner = owner_symbol,
                    .interface_name = impl_export.interface_name,
                    .interface_symbol = interface_local_symbol,
                    .method_symbols = implementation.methods,
                    .target_resolution = impl_resolution,
                    .store = &impl_checked.types,
                    .argument_type_ids = implementation.arguments,
                });
            }
        }
    }

    // Bridges CONCRETE (non-interface) methods for `owner_symbol` — the
    // `graph.methods` counterpart of `appendMatchingImpls` above (same
    // "scan the WHOLE graph by owner_module/owner_declaration, not just
    // `own_module`'s own imports" shape, since `реализация X для
    // Модуль.Тип` can live in a THIRD file relative to both the type's
    // own module and any given consumer — codegen's `_gen.ps` pattern).
    //
    // Needed alongside `appendMatchingImpls` (not instead of it) because a
    // nominal reached ONLY TRANSITIVELY — through another module's field/
    // return type, never named/imported directly by `own_module` — used
    // to get its methods bridged ONLY from `definition_checked.methods`
    // (the type's OWN declaring module's typecheck results), which can
    // only ever contain SAME-FILE `реализация` blocks: the declaring
    // module never imports its own `_gen.ps` counterpart, so a
    // third-file method attach was invisible to it. Real gap found via
    // codegen's cross-file nested-struct JSON support: `Фигура.центр:
    // а.Точка` (a.Точка's `.в_json()` implemented in `a_gen.ps`) — `это.
    // центр.в_json()` inside `b_gen.ps` (itself reached via `Фигура`'s
    // field, not a direct import of `a`) failed "у типа нет поля
    // 'в_json'" even though the exact same method resolves fine on a
    // DIRECTLY-imported `a.Точка` value in the same file (`b_gen.ps`
    // reaches `а.Точка` via TWO separate paths — its own `импорт "./a"
    // как а` AND transitively through `Фигура.центр` — each path mints
    // its OWN local symbol, `TypeStore.eql`'s identity check unifies them
    // for type-compatibility purposes, but method lookup is keyed by
    // symbol, and only the directly-imported one got bridged, via
    // `module_linker.zig`'s `buildExportsForTarget`, which does the same
    // `graph.methods` scan this mirrors).
    fn appendMatchingMethods(
        self: *ImportContext,
        graph: *const module_loader.Graph,
        modules: []const ModuleCompilation,
        resolution: *resolver.Resolution,
        own_module: usize,
        origin_module: usize,
        origin_declaration: ast.DeclId,
        owner_symbol: symbols.SymbolId,
    ) !void {
        for (graph.methods.items) |method_export| {
            if (method_export.owner_module != origin_module or method_export.owner_declaration != origin_declaration) continue;
            // Same rationale as `appendMatchingImpls`'s identical check —
            // a method declared IN `own_module` itself is already a plain
            // local declaration there, not something to bridge (and
            // `modules[own_module].checked`/`.compiled` don't exist yet
            // while `own_module` is still being collected).
            if (method_export.module == own_module) continue;
            const method_module = &modules[method_export.module];
            const method_resolution = if (method_module.resolution) |*value| value else return error.ImportNotCompiled;
            const method_checked = if (method_module.checked) |*value| value else return error.ImportNotChecked;
            const method_compiled = if (method_module.compiled) |*value| value else return error.ImportNotCompiled;
            const source_method_symbol = method_resolution.decl_symbols.get(method_export.declaration) orelse continue;
            const source_method = method_resolution.symbols.get(source_method_symbol) orelse continue;
            const function_id = method_compiled.function_ids.get(source_method_symbol) orelse continue;
            const signature = method_checked.symbol_types.get(source_method_symbol) orelse continue;
            const local_method = try resolution.symbols.add(.{
                .name = source_method.name,
                .kind = .function,
                .module_path = "@transitive",
                .is_exported = true,
                .span = source_method.span,
            });
            const parameters = method_resolution.function_parameters.get(method_export.declaration) orelse &.{};
            const parameter_names: []const []const u8 = if (parameters.len == 0) &.{} else blk: {
                const names = try self.allocator.alloc([]const u8, parameters.len);
                for (parameters, names) |parameter, *name| name.* = method_resolution.symbols.get(parameter).?.name;
                break :blk names;
            };
            try self.methods.append(self.allocator, .{
                .owner = owner_symbol,
                .name = source_method.name,
                .symbol = local_method,
                .store = &method_checked.types,
                .type_id = signature,
                .parameter_names = parameter_names,
            });
            try self.functions.append(self.allocator, .{ .symbol = local_method, .function_id = function_id });
        }
    }

    fn collect(
        self: *ImportContext,
        resolution: *resolver.Resolution,
        modules: []const ModuleCompilation,
        nominal_identities: *std.AutoHashMap(resolver.ImportedSymbolOrigin, u32),
        next_nominal_identity: *u32,
        graph: *const module_loader.Graph,
        own_module: usize,
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
                    const identity = if (isPreludeTypeName(exported.name)) 0 else try nominalIdentity(nominal_identities, next_nominal_identity, origin);
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
                    const default_method_symbols = if (interface_methods) |value| try self.bridgeDefaultMethodSymbols(resolution, target_compiled, value) else null;
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
                        .default_method_symbols = default_method_symbols,
                    });
                    try self.appendMatchingImpls(graph, modules, resolution, own_module, origin.module, origin.declaration, imported_symbol);
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
        var touched = bridged_modules.keyIterator();
        while (touched.next()) |module_index_ptr| {
            const target = &modules[module_index_ptr.*];
            const target_resolution = if (target.resolution) |*value| value else return error.ImportNotCompiled;
            const target_checked = if (target.checked) |*value| value else return error.ImportNotChecked;
            for (prelude_type_names) |name| {
                const source_symbol = findLocalTypeSymbol(target_resolution, name) orelse continue;
                const local_symbol = findLocalTypeSymbol(resolution, name) orelse continue;
                // Identity-only, deliberately — a full-data entry (like
                // the ordinary cross-module `.type` case above) would
                // DUPLICATE registration: once a real prelude module is
                // in the graph, THIS module's own copy of `Опция`/
                // `Сравниваемое`/... already flows in fully populated
                // through the ordinary `resolution.imported_symbols`
                // loop above (they're unqualified-imported from the
                // prelude module, same as any real `импорт`) — a SECOND
                // full entry for the same `local_symbol` here would
                // `owner_remaps.put` over the first one and leak it
                // (confirmed via a real leak-checked test before this
                // comment was written). This loop exists ONLY to align
                // a THIRD module's (`target`'s) own separate copy with
                // this one for signature/bound comparisons — pure
                // identity, no data.
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
                    try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, imported.definition_store, field.typ);
                }
            }
            if (imported.enum_variants) |variants| {
                for (variants) |variant| {
                    for (variant.fields) |field| {
                        try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, imported.definition_store, field);
                    }
                }
            }
            if (imported.interface_methods) |methods| {
                for (methods) |method| {
                    for (method.parameters) |parameter| {
                        try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, imported.definition_store, parameter);
                    }
                    try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, imported.definition_store, method.return_type);
                }
            }
        }
        var imported_type_index: usize = 0;
        while (imported_type_index < self.imported_types.items.len) : (imported_type_index += 1) {
            const imported = self.imported_types.items[imported_type_index];
            try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, imported.store, imported.type_id);
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
            try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, method.store, method.type_id);
        }
    }

    fn collectTransitiveNominals(
        self: *ImportContext,
        resolution: *resolver.Resolution,
        modules: []const ModuleCompilation,
        nominal_identities: *std.AutoHashMap(resolver.ImportedSymbolOrigin, u32),
        next_nominal_identity: *u32,
        graph: *const module_loader.Graph,
        own_module: usize,
        external_store: *const types.TypeStore,
        external_type: types.TypeId,
    ) !void {
        const entry = external_store.get(external_type) orelse return error.InvalidImportedType;
        switch (entry.*) {
            .tuple => |elements| for (elements) |element| try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, external_store, element),
            .function => |function| {
                for (function.parameters) |parameter| try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, external_store, parameter);
                try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, external_store, function.return_type);
            },
            .nominal => |nominal| {
                for (nominal.arguments) |argument| try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, external_store, argument);
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
                const transitive_interface_methods = if (interface_definition) |value| value.methods else null;
                const transitive_default_method_symbols = if (transitive_interface_methods) |value| try self.bridgeDefaultMethodSymbols(resolution, definition_compiled, value) else null;
                try self.nominals.append(self.allocator, .{
                    .store = external_store,
                    .definition_store = &definition_checked.types,
                    .source_symbol = nominal.symbol,
                    .local_symbol = local_symbol,
                    .identity = identity,
                    .fields = if (generic_struct) |value| value.fields else definition_checked.nominal_fields.get(definition_symbol),
                    .enum_variants = if (enum_definition) |value| value.variants else null,
                    .generic_parameters = generic_parameters,
                    .interface_methods = transitive_interface_methods,
                    .default_method_symbols = transitive_default_method_symbols,
                });
                // Same bridging the direct-import loop above does for a
                // symbol reached via `resolution.imported_symbols` — a
                // nominal reached ONLY transitively (through another
                // function's signature, never named/imported directly)
                // previously got its STRUCTURAL shape re-hosted (fields/
                // methods, just above) but never its INTERFACE
                // IMPLEMENTATIONS, since this whole `.nominal` case never
                // consulted `graph.impls` at all. Real gap found via
                // `коллекции.итератор(x)` (a prelude function returning
                // `МассивИтератор(T)`, itself only prelude-declared,
                // reachable ONLY through that return type from a
                // consuming module that never names `МассивИтератор`
                // anywhere) — its interface DEFAULT METHOD dispatch
                // (`inferDefaultInterfaceMethodCall`) had nothing to find
                // in the consuming module's OWN `interface_implementations`.
                try self.appendMatchingImpls(graph, modules, resolution, own_module, origin.module, origin.declaration, local_symbol);
                // `graph.methods`-wide scan (not just `definition_checked.
                // methods`, which only ever sees SAME-FILE `реализация`
                // blocks — the type's own declaring module never imports
                // its own third-file `_gen.ps` counterpart) — see
                // `appendMatchingMethods`'s doc comment for the real gap
                // this closes.
                try self.appendMatchingMethods(graph, modules, resolution, own_module, origin.module, origin.declaration, local_symbol);
            },
            .array => |element| try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, external_store, element),
            .map => |map| {
                try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, external_store, map.key);
                try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, external_store, map.value);
            },
            .process => |message| try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, external_store, message),
            .pointer => |pointee| try self.collectTransitiveNominals(resolution, modules, nominal_identities, next_nominal_identity, graph, own_module, external_store, pointee),
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

// `Опция`/`Результат`/6 interfaces — there is only ever ONE real
// declaration (`prelude.zig`), unqualified-merged into every module, so
// unlike an ordinary cross-module struct/enum (where two SEPARATELY
// declared same-named types must NOT be conflated), any two
// reconstructions of one of these must always compare equal. Used at
// TWO sites: (1) `nominalIdentity`'s call site below — forces identity
// 0 (matching how a module's own DIRECT, local use of e.g. `Опция
// (Число)` already gets identity 0, never touching `nominalIdentity`
// at all) instead of minting a fresh nonzero cross-module identity;
// (2) the prelude-bridge loop, aligning a THIRD module's own copy.
// Real gap found only once a real prelude module was actually
// exercised for the first time: `реализация Итерируемое для X`, where
// `следующий() -> Опция(T)` gets reconstructed via `copyImportedType`
// (needs `Опция`'s bridge identity) while `Опция(Число)` used directly
// in the SAME file never goes through that path at all (identity 0,
// default) — a mismatched identity made `TypeStore.eql` treat them as
// different types even though the symbol matched.
const prelude_type_names = [_][]const u8{
    "Результат",
    "Опция",
    "Сравниваемое",
    "Итерируемое",
    "Печатаемое",
    "Копируемое",
    "Равнозначное",
    "Складываемое",
    "Вычитаемое",
    "Умножаемое",
    "Делимое",
};

fn isPreludeTypeName(name: []const u8) bool {
    for (prelude_type_names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
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
    // Phase 1: resolve EVERY module first, in any order — `ImportScope`
    // is built purely from `graph.exports`/`graph.imports` (computed once
    // at load time by `collectExports`/`registerModule`, see
    // `module_linker.zig`'s `buildExportsForTarget`), never from another
    // module's OWN resolve/check/compile results — so resolution has no
    // real inter-module ordering dependency at all, unlike Phase 2 below.
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
    }

    // Phase 2: typecheck + compile. `graph.order` (plain import-edge
    // topological order) is used as the INITIAL queue, but is not
    // actually sufficient by itself: `ImportContext.appendMatchingImpls`
    // scans `graph.impls` for ANY `реализация` matching an imported
    // type's origin, REGARDLESS of whether the impl-declaring module is
    // itself imported by the module being processed — the qualified
    // "third-file impl" shape (codegen's `_gen.ps` pattern: `реализация
    // json.ВJSON для json_fixture.Заказ`, written in neither
    // `json_fixture.ps` nor the consumer) means a module can depend on
    // another module's `.checked`/`.compiled` state WITHOUT there being
    // any import edge between them at all — an ordering constraint
    // `graph.order`'s plain DFS over import edges cannot see or encode.
    // Real, previously-unknown bug found via a genuine diamond import
    // (`main` imports both `A` and `B`, `B` also imports `A`, and a
    // THIRD file `A_gen` — imported only by `main`, not by `B` —
    // implements an interface for `A`'s type): `B` is processed before
    // `A_gen` in plain topological order (nothing requires otherwise —
    // `B` never imports `A_gen`), but `B`'s own `collect()` still touches
    // `A_gen`'s impl while scanning `A`'s import, `A_gen.checked` isn't
    // populated yet → `error.ImportNotChecked`/`ImportNotCompiled`, a
    // hard crash for a perfectly valid program.
    //
    // Fixed with a worklist instead of a single topological pass: a
    // module whose `collect()` hits a not-yet-ready dependency (this
    // hidden impl-driven edge is the ONLY thing that can trigger it —
    // every OTHER `ImportNotCompiled`/`ImportNotChecked` site in
    // `ImportContext` looks up a module `own_module` ACTUALLY imports,
    // already guaranteed ready by `graph.order`) is pushed to the back
    // of the queue and retried later, instead of hard-failing. `stalled`
    // counts consecutive requeues with zero forward progress — reaching
    // the current queue length means every remaining module failed on a
    // full pass, a genuine unresolvable case (not seen in practice; would
    // need a real cycle between qualified impl targets across files) —
    // propagate the underlying error rather than looping forever.
    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(allocator);
    try queue.appendSlice(allocator, graph.order.items);
    var stalled: usize = 0;
    while (queue.items.len != 0) {
        if (stalled >= queue.items.len) {
            // Nothing in the queue made progress across a full pass — the
            // graph state is otherwise unchanged since the last attempt at
            // this exact module, so re-running `collect` is expected to
            // fail identically and `try` propagates that error out of
            // `compileGraphForTarget`. Only reachable for a genuine cycle
            // between qualified impl targets across files (see the doc
            // comment above) — not by any currently-existing panos code.
            const module_index = queue.items[0];
            const resolution = &result.modules[module_index].resolution.?;
            var imports = ImportContext.init(allocator);
            defer imports.deinit();
            try imports.collect(resolution, result.modules, &result.nominal_identities, &result.next_nominal_identity, graph, module_index);
            unreachable;
        }

        const module_index = queue.orderedRemove(0);
        const module = &graph.modules.items[module_index];
        const resolution = &result.modules[module_index].resolution.?;

        var imports = ImportContext.init(allocator);
        defer imports.deinit();
        imports.collect(resolution, result.modules, &result.nominal_identities, &result.next_nominal_identity, graph, module_index) catch |err| switch (err) {
            error.ImportNotCompiled, error.ImportNotChecked => {
                try queue.append(allocator, module_index);
                stalled += 1;
                continue;
            },
            else => return err,
        };
        stalled = 0;

        result.modules[module_index].checked = try type_checker.checkWithImportContextForTarget(allocator, &module.tree, resolution, .{
            .symbols = imports.imported_types.items,
            .nominals = imports.nominals.items,
            .methods = imports.methods.items,
            .impls = imports.impls.items,
            .has_real_prelude = prelude_module != null,
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
        .{ .path = "проект/main.ps", .bytes = "импорт \"./математика\" как мат\nэкспорт функ старт() -> Число\nмат.сложить(мат.ОТВЕТ, 2.0)\nконец" },
        .{ .path = "проект/математика.ps", .bytes = "экспорт конст ОТВЕТ = 40.0\nэкспорт функ сложить(a: Число, b: Число) -> Число\na + b\nконец" },
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
        .{ .path = "проект/main.ps", .bytes = "импорт \"./удвоение\" как удв\nэкспорт функ старт() -> Число\nудв.применить(21.0)\nконец" },
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
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер точка: точки.Точка = точки.создать(40.0)\nточки.добавить(точка, 2.0)\nконец" },
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
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер точка: точки.Точка = точки.Точка(41.0)\nточка.увеличить()\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец\nреализация Точка\nфунк увеличить(это: Точка) -> Число\nэто.x + 1.0\nконец\nконец" },
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
        .{ .path = "проект/main.ps", .bytes = "импорт \"./цвета\" как цвета\nэкспорт функ старт() -> Число\nпер c: цвета.Цвет = цвета.Цвет.Красный()\nвыбор c\nКрасный -> 42.0\nЗелёный -> 0.0\nконец\nконец" },
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
        .{ .path = "проект/main.ps", .bytes = "импорт \"./итог\" как итог\nэкспорт функ старт() -> Число\nпер r: итог.Итог = итог.Итог.Готово(41.0)\nвыбор r\nГотово(x) -> x + 1.0\nПусто -> 0.0\nконец\nконец" },
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
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер точка: точки.Точка = точки.создать(41.0)\nточка.увеличить()\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец\nэкспорт функ создать(x: Число) -> Точка\nТочка(x)\nконец\nреализация Точка\nфунк увеличить(это: Точка) -> Число\nэто.x + 1.0\nконец\nконец" },
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
        .{ .path = "проект/main.ps", .bytes = "импорт \"./короб\" как короб\nэкспорт функ старт() -> Число\nпер к: короб.Коробка(Число) = короб.Коробка(42.0)\nк.значение\nконец" },
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
        .{ .path = "проект/main.ps", .bytes = "импорт \"./короб\" как короб\nэкспорт функ старт() -> Число\nпер к: короб.Коробка(Число) = короб.Коробка(42.0)\nк.развернуть(0.0)\nконец" },
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
        .{ .path = "проект/main.ps", .bytes = "импорт \"./короб\" как короб\nэкспорт функ старт() -> Число\nпер к: короб.Ящик(Число) = короб.Ящик.Есть(42.0)\nвыбор к\nЕсть(x) -> x\nПусто -> 0.0\nконец\nконец" },
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
        .{ .path = "проект/main.ps", .bytes = "импорт \"./короб\" как короб\nэкспорт функ старт() -> Число\nпер к: короб.Ящик(Число) = короб.Ящик.Есть(42.0)\nк.развернуть(0.0)\nконец" },
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
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер первая: точки.Точка = точки.Точка(40.0)\nпер вторая: точки.Точка = точки.Точка(2.0)\nпервая.сравнить(вторая)\nконец" },
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

// Both the interface AND the target are qualified (`реализация
// интерфейсы.МойИнтерфейс для точки.Точка`), and the impl block itself
// is written in the CONSUMING file (main.ps) — this is the shape that
// exposed two real bugs, both now fixed:
// (1) pass ordering — `signaturePass` (processes `реализация` blocks,
//     including the `isImplementableNominal` check) used to run BEFORE
//     `importSignaturePass` (populates `nominal_fields` for imported
//     nominals), so a qualified target's `nominal_fields` entry didn't
//     exist yet when checked, and every such `реализация` was rejected
//     with "интерфейс может реализовать только структура или
//     перечисление" even for a real struct;
// (2) `interfaceMethodMatches`'s receiver type was built via a raw
//     `types.nominal(owner, ...)` (identity=0) instead of `nominalType`
//     (real bridged identity) — `TypeStore.eql`'s nominal case switches
//     to strict identity comparison the moment either side is non-zero,
//     so the receiver never matched the method's `это: точки.Точка`
//     parameter type (which WAS resolved with the real identity via
//     `resolveType`'s own `.qualified` case), rejected as "первый
//     аргумент метода должен иметь тип реализующего типа".
//
// NOT covered here (a separate, larger gap, still open): an impl block
// written in a THIRD file — neither the struct's own file nor the
// consumer's — is invisible to any OTHER file that imports only the
// struct's module (module_loader.zig's `collectMethods` skips qualified
// targets entirely, `target_module != null => continue`, so such impls
// never enter `graph.methods`/`graph.impls` at all) — exactly the shape
// a codegen-generated `_gen.ps` file needs (separate from both the
// source struct's file and whatever imports the generated file).
test "module compiler resolves both qualified interface and qualified target declared in the consumer" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./интерфейсы\" как интерфейсы\nимпорт \"./точки\" как точки\nреализация интерфейсы.МойИнтерфейс для точки.Точка\nфунк значение(это: точки.Точка) -> Число\nэто.x\nконец\nконец\nэкспорт функ старт() -> Число\nточки.Точка(40.0).значение()\nконец" },
        .{ .path = "проект/интерфейсы.ps", .bytes = "экспорт тип МойИнтерфейс = интерфейс\nфунк значение() -> Число\nконец" },
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
            .number => |number| try std.testing.expectEqual(@as(f64, 40), number),
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

// Impl declared in a THIRD file — neither the struct's own file
// (точки.ps) nor the file that actually calls the method (main.ps) —
// mirrors a codegen-generated `_gen.ps`: separate from both the source
// struct's file and whatever imports the generated file. main.ps
// imports точки.ps directly (for the constructor) AND связка.ps (for
// the side effect of registering the impl — exactly what a generated
// `импорт "./<файл>_gen"` does). Was rejected with "у типа нет поля
// 'значение'" before the module_loader/module_linker/resolver fix —
// `collectMethods` (module_loader.zig) skipped any qualified impl
// target entirely, so `graph.methods`/`graph.impls` never got an entry
// for this shape at all.
test "module compiler resolves an impl declared in a third file, separate from both the struct and the consumer" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nимпорт \"./связка\" как связка\nэкспорт функ старт() -> Число\nточки.Точка(40.0).значение()\nконец" },
        .{ .path = "проект/интерфейсы.ps", .bytes = "экспорт тип МойИнтерфейс = интерфейс\nфунк значение() -> Число\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец" },
        .{ .path = "проект/связка.ps", .bytes = "импорт \"./интерфейсы\" как интерфейсы\nимпорт \"./точки\" как точки\nреализация интерфейсы.МойИнтерфейс для точки.Точка\nфунк значение(это: точки.Точка) -> Число\nэто.x\nконец\nконец" },
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

test "module compiler resolves a qualified impl target within its own declaring module" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./методы\"\nэкспорт функ старт() -> Число\nметоды.проверить()\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец" },
        .{ .path = "проект/методы.ps", .bytes = "импорт \"./точки\" как точки\nреализация точки.Точка\nфунк увеличить(это: точки.Точка) -> Число\nэто.x + 1.0\nконец\nконец\nэкспорт функ проверить() -> Число\nпер точка: точки.Точка = точки.Точка(41.0)\nточка.увеличить()\nконец" },
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
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер a: точки.Точка = точки.Точка(40.0)\na.значение()\nконец" },
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
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nфунк макс[T: Сравниваемое](a: T, b: T) -> T\nесли a > b тогда a иначе b конец\nконец\nэкспорт функ старт() -> Число\nпер a: точки.Точка = точки.Точка(40.0)\nпер b: точки.Точка = точки.Точка(2.0)\nмакс(a, b).x\nконец" },
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
        .{ .path = "проект/main.ps", .bytes = "импорт \"./библиотека\" как библиотека\nэкспорт функ старт() -> Число\nпер a: библиотека.Точка = библиотека.Точка(40.0)\nпер b: библиотека.Точка = библиотека.Точка(2.0)\nбиблиотека.макс(a, b).x\nконец" },
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
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер a: точки.Точка = точки.Точка(40.0)\nпер b: точки.Точка = точки.Точка(2.0)\nпер x: Сравниваемое = a\nx.сравнить(b)\nконец" },
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

// Regression: `inferInterfaceCall`/`inferGenericBoundInterfaceCall` are
// tried speculatively for EVERY `.property(...)` call and fall through
// to the next candidate (here: a qualified struct constructor) on a
// non-match, but used to report "именованные аргументы не поддержаны
// для интерфейсного вызова" as a side effect BEFORE confirming the call
// was actually theirs to handle — wrongly rejecting a plain cross-module
// named-argument constructor call (`модуль.Тип(поле = x, ...)`) that has
// nothing to do with interfaces at all.
test "module compiler accepts a qualified struct constructor with named arguments" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./основа\" как основа\nэкспорт функ старт() -> Строка\nпер s = основа.Спавн(имя = \"рабочий\", приоритет = 1)\ns.имя\nконец" },
        .{ .path = "проект/основа.ps", .bytes = "экспорт тип Спавн = структура\nимя: Строка\nприоритет: Целое\nконец" },
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
            const bytes = result.stringBytes() orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("рабочий", bytes);
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}

test "module compiler merges an appended prelude module unqualified into every real module" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "экспорт функ старт() -> Число\nпер к: Коробочка(Число) = Коробочка.Есть(42.0)\nк.развернуть(0.0)\nконец" },
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
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер точка: точки.Точка = точки.Точка(1.0)\nточка.x = 40.0\nточка.x + 2.0\nконец" },
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
        .{ .path = "проект/api.ps", .bytes = "импорт \"./модель\" как модель\nэкспорт тип Ответ = структура\nэлемент: модель.Элемент\nконец\nэкспорт функ создать() -> Ответ\nОтвет(модель.Элемент(42.0))\nконец" },
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
        .{ .path = "проект/main.ps", .bytes = "импорт \"./коллекции\" как кол\nимпорт \"./модель\" как модель\nфунк в_число(x: модель.Элемент) -> Число\nx.значение\nконец\nэкспорт функ старт() -> Число\nпер значения = кол.отобразить(массив(модель.Элемент(42.0)), в_число)\nзначения.получить(0, 0.0)\nконец" }, // index arg (Целое ok), default value arg fixed to Число
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
        .{ .path = "проект/main.ps", .bytes = "импорт \"./сервис\" как сервис\nимпорт \"./модель\" как модель\nэкспорт функ старт() -> Число\nвыбор сервис.обернуть(модель.Элемент(42.0))\nРезультат.Успех(о) -> о.развернуть()\nРезультат.Неудача(_) -> -1.0\nконец\nконец" },
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

// Real `panos run` (`cli/main.zig`'s `main`) now loads the REAL prelude
// module (`graph.appendPreludeModule(prelude.SOURCE)`) instead of relying
// on `type_checker.zig`'s hardcoded Опция/Результат/interface stand-ins
// — this is the graph-pipeline equivalent of what `runner.zig`'s single-
// file pipeline already did. Covers: `Опция` methods (`.получить`) work
// through the real prelude module, AND a cross-module `импорт` + `<`
// through `Сравниваемое` still works with the real prelude module in the
// graph (this exact path leaked — a duplicate `ImportedNominal` entry
// for the prelude's own generic types orphaned an owner_remap — before
// the prelude-bridge loop in `ImportContext.collect` was fixed back to
// identity-only).
test "module compiler works end to end with a real prelude module in the graph" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./точки\" как точки\nэкспорт функ старт() -> Число\nпер o: Опция(Число) = Опция.Есть(42.0)\nпер cmp = точки.Точка(1.0) < точки.Точка(2.0)\nвыбор cmp\nистина -> o.получить(0.0)\nложь -> -1.0\nконец\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец\nреализация Сравниваемое для Точка\nфунк сравнить(это: Точка, другое: Точка) -> Число\nэто.x - другое.x\nконец\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");
    _ = try graph.appendPreludeModule(prelude.SOURCE);
    try std.testing.expectEqual(@as(usize, 0), graph.diagnostics.items.items.len);

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

// Regression: a default method on `Итерируемое` (prelude) dispatched
// from a DIFFERENT module than where the concrete implementing type is
// declared, reached ONLY transitively (through a function's return
// type, never named/imported directly) — real gap found via
// `итератор(массив).отфильтровать(...).отобразить(...).взять(...)
// .собрать()`: `собрать`'s `default_symbol` (a symbol in the PRELUDE
// module's own symbol space) was meaningless in the consuming module,
// and `collectTransitiveNominals` never bridged interface
// IMPLEMENTATIONS for a transitively-reached nominal at all (only its
// structural shape) — `ImportedNominal.default_method_symbols` +
// `bridgeDefaultMethodSymbols` (mint a local synthetic symbol per
// default method, same pattern already used for inherent methods) fix
// both halves.
test "module compiler dispatches a chain of interface default methods across a module boundary" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "экспорт функ старт() -> Массив(Число)\nпер числа = массив(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0)\nитератор(числа).отфильтровать(функ(x: Число) -> Булево\nx > 2.0\nконец).отобразить(функ(x: Число) -> Число\nx * 10.0\nконец).взять(3).собрать()\nконец" },
    } };
    var graph = module_loader.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");
    _ = try graph.appendPreludeModule(prelude.SOURCE);
    try std.testing.expectEqual(@as(usize, 0), graph.diagnostics.items.items.len);

    var compiled = try compileGraph(std.testing.allocator, &graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.diagnostics.items.items.len);
    const start = compiled.start orelse return error.TestUnexpectedResult;
    var machine = vm.Vm.init(std.testing.allocator, &compiled.program);
    defer machine.deinit();
    switch (try machine.run(start, &.{})) {
        .success => |result| switch (result) {
            .array => |array| {
                try std.testing.expectEqual(@as(usize, 3), array.elements.len);
                try std.testing.expectEqual(@as(f64, 30), array.elements[0].number);
                try std.testing.expectEqual(@as(f64, 40), array.elements[1].number);
                try std.testing.expectEqual(@as(f64, 50), array.elements[2].number);
            },
            else => return error.TestUnexpectedResult,
        },
        .runtime_error => return error.TestUnexpectedResult,
    }
}
