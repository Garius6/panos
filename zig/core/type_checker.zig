const std = @import("std");
const ast = @import("ast.zig");
const diagnostic = @import("diagnostic.zig");
const resolver = @import("resolver.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");
const target_policy = @import("target.zig");
const types = @import("types.zig");

pub const NominalField = struct {
    name: []const u8,
    typ: types.TypeId,
};

pub const GenericParameter = struct {
    name: []const u8,
    typ: types.TypeId,
    bounds: []const symbols.SymbolId = &.{},
};

pub const GenericNominal = struct {
    parameters: []const GenericParameter,
    fields: []const NominalField,
};

pub const EnumVariant = struct {
    symbol: symbols.SymbolId,
    name: []const u8,
    fields: []const types.TypeId,
};

pub const EnumDefinition = struct {
    parameters: []const GenericParameter,
    variants: []const EnumVariant,
};

pub const InterfaceMethod = struct {
    name: []const u8,
    parameters: []const types.TypeId,
    return_type: types.TypeId,
};

pub const InterfaceDefinition = struct {
    parameters: []const GenericParameter,
    methods: []const InterfaceMethod,
};

pub const InterfaceImplementation = struct {
    interface: symbols.SymbolId,
    arguments: []const types.TypeId,
    target: symbols.SymbolId,
    methods: []const symbols.SymbolId,
};

pub const InterfaceCastEntry = struct {
    interface: symbols.SymbolId,
    arguments: []const types.TypeId,
    target: symbols.SymbolId,
};

pub const InterfaceCast = struct {
    entries: []const InterfaceCastEntry,
};

pub const InterfaceCall = struct {
    interface: symbols.SymbolId,
    method_index: u16,
    vtable_index: u16 = 0,
};

pub const ForInKind = enum {
    array,
    iterator,
};

pub const ImportedSymbolType = struct {
    symbol: symbols.SymbolId,
    store: *const types.TypeStore,
    type_id: types.TypeId,
    // Non-null when the imported symbol is a GENERIC FREE FUNCTION (`функ
    // ф[T: Интерфейс](...)`) — the source module's own, UNREMAPPED
    // generic-parameter TypeIds/bounds (bound interface symbols are
    // still the SOURCE module's local symbols here; the importer remaps
    // them via `imports.nominals` when consuming this). Real gap found
    // auditing panosiki's `pan` (`томл.сериализовать_из(манифест)` —
    // `std/кодирование/toml.ps`'s `сериализовать_из[T: ВTOML](это: T)`
    // called cross-module): without this, `copyImportedType`'s
    // `.generic_parameter` case had no remap to consult and silently
    // degraded `T` to `poison` for ANY cross-module generic function
    // call — `poison` is universally assignable, so the call
    // type-checked with zero diagnostics, but the callee's compiled
    // body still expected `это` to arrive already `Cast_Interface`'d
    // (see `interfaceBoundOf`/`inferGenericBoundInterfaceCall`, which
    // never fired here since `generic_function_parameters` was never
    // populated for the imported symbol either) — a silent, guaranteed
    // "Runtime Error: попытка вызвать интерфейсный метод у не-интерфейса"
    // crash on the very first real cross-module use of this pattern.
    generic_parameters: ?[]const GenericParameter = null,
};

pub const ImportedNominal = struct {
    // Store in which `source_symbol` appears in an imported signature.
    store: *const types.TypeStore,
    // Store that owns fields, variants and generic parameters of the
    // nominal's declaration. These differ for a transitive import: module B
    // refers to C.Type through B's local TypeStore, while C owns Type's
    // definition.
    definition_store: *const types.TypeStore,
    source_symbol: symbols.SymbolId,
    local_symbol: symbols.SymbolId,
    identity: u32,
    fields: ?[]const NominalField = null,
    // References the source module's own `EnumDefinition.variants` directly
    // (alive for the whole graph compile) — only `.name`/`.fields` are used;
    // `.symbol` is the source module's own variant symbol, irrelevant here
    // since the local variant symbol is looked up by name instead.
    enum_variants: ?[]const EnumVariant = null,
    // Non-null for a generic owner (struct, enum or interface) — the source
    // module's own generic-parameter TypeIds; importSignaturePass mints fresh
    // local ones, remaps through them for `fields`/`enum_variants`/
    // `interface_methods`, and reuses the same remap for that owner's
    // imported methods.
    generic_parameters: ?[]const GenericParameter = null,
    // References the source module's own `InterfaceDefinition.methods`
    // directly (alive for the whole graph compile), non-null when this
    // nominal is itself an INTERFACE declared in another module — lets a
    // THIRD module implement/bound-check against an interface it never
    // declared itself (`реализация чужой_модуль.Интерфейс для Тип`).
    interface_methods: ?[]const InterfaceMethod = null,
};

pub const ImportedMethod = struct {
    owner: symbols.SymbolId,
    name: []const u8,
    symbol: symbols.SymbolId,
    store: *const types.TypeStore,
    type_id: types.TypeId,
    parameter_names: []const []const u8 = &.{},
};

// An owner's interface implementation, re-hosted from the source module.
// `interface_name` is resolved by name in the IMPORTER's own scope (every
// file gets its own local prelude "Сравниваемое" symbol, so the source
// module's raw interface Symbol_Id is never valid here) — `method_names`
// are matched by name against methods already registered via `ImportContext.
// methods` (interface-impl methods are ordinary inherent methods too, see
// `module_loader.zig`'s `collectMethods`), so no separate FunctionId
// re-hosting is needed for this list itself.
pub const ImportedImpl = struct {
    owner: symbols.SymbolId,
    interface_name: []const u8,
    // References the source module's own `InterfaceImplementation.methods`
    // and `Resolution` directly (both alive for the whole graph compile) —
    // names are looked up on demand, no separate name-list allocation.
    method_symbols: []const symbols.SymbolId,
    target_resolution: *const resolver.Resolution,
    store: *const types.TypeStore,
    argument_type_ids: []const types.TypeId,
};

pub const ImportContext = struct {
    symbols: []const ImportedSymbolType = &.{},
    nominals: []const ImportedNominal = &.{},
    methods: []const ImportedMethod = &.{},
    impls: []const ImportedImpl = &.{},
};

pub const IteratorDispatch = enum {
    direct,
    interface,
};

pub const ForInInfo = struct {
    kind: ForInKind,
    iterator_dispatch: IteratorDispatch = .direct,
    next_method: symbols.SymbolId = symbols.invalid_symbol,
};

pub const MethodDefinition = struct {
    owner: symbols.SymbolId,
    interface: ?symbols.SymbolId,
    symbol: symbols.SymbolId,
    name: []const u8,
    owner_parameters: []const GenericParameter,
    function_parameters: []const GenericParameter,
    all_parameters: []const GenericParameter,
};

const NominalOwner = struct {
    symbol: symbols.SymbolId,
    parameters: []const GenericParameter,
};

pub const CheckResult = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    types: types.TypeStore,
    diagnostics: diagnostic.DiagnosticList = .{},
    expression_types: std.AutoHashMap(ast.ExprId, types.TypeId),
    symbol_types: std.AutoHashMap(symbols.SymbolId, types.TypeId),
    unsupported_imports: std.AutoHashMap(symbols.SymbolId, void),
    imported_nominal_identities: std.AutoHashMap(symbols.SymbolId, u32),
    nominal_fields: std.AutoHashMap(symbols.SymbolId, []const NominalField),
    // Field marshal kinds (declaration order) for `ff_структура` types
    // ONLY — needed at `внешний` struct-by-value call sites to build a
    // libffi struct `ffi_type` (its `elements` array) and to pack/unpack
    // raw bytes at each field's C ABI offset. Ordinary (non-`ff_структура`)
    // nominals never get an entry here.
    ffi_struct_layouts: std.AutoHashMap(symbols.SymbolId, []const ast.ForeignMarshalKind),
    type_aliases: std.AutoHashMap(symbols.SymbolId, types.TypeId),
    alias_type_nodes: std.AutoHashMap(symbols.SymbolId, ast.TypeId),
    generic_function_parameters: std.AutoHashMap(symbols.SymbolId, []const GenericParameter),
    generic_nominal_fields: std.AutoHashMap(symbols.SymbolId, GenericNominal),
    enum_definitions: std.AutoHashMap(symbols.SymbolId, EnumDefinition),
    interface_definitions: std.AutoHashMap(symbols.SymbolId, InterfaceDefinition),
    interface_implementations: std.ArrayList(InterfaceImplementation) = .empty,
    pattern_variants: std.AutoHashMap(ast.PatternId, symbols.SymbolId),
    pattern_types: std.AutoHashMap(ast.PatternId, types.TypeId),
    methods: std.ArrayList(MethodDefinition) = .empty,
    imported_method_parameter_names: std.AutoHashMap(symbols.SymbolId, []const []const u8),
    method_calls: std.AutoHashMap(ast.ExprId, symbols.SymbolId),
    interface_calls: std.AutoHashMap(ast.ExprId, InterfaceCall),
    interface_casts: std.AutoHashMap(ast.ExprId, InterfaceCast),
    call_arguments: std.AutoHashMap(ast.ExprId, []const ast.ExprId),
    for_in_infos: std.AutoHashMap(ast.StmtId, ForInInfo),

    pub fn init(allocator: std.mem.Allocator) !CheckResult {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .types = try types.TypeStore.init(allocator),
            .expression_types = .init(allocator),
            .symbol_types = .init(allocator),
            .unsupported_imports = .init(allocator),
            .imported_nominal_identities = .init(allocator),
            .nominal_fields = .init(allocator),
            .ffi_struct_layouts = .init(allocator),
            .type_aliases = .init(allocator),
            .alias_type_nodes = .init(allocator),
            .generic_function_parameters = .init(allocator),
            .generic_nominal_fields = .init(allocator),
            .enum_definitions = .init(allocator),
            .interface_definitions = .init(allocator),
            .pattern_variants = .init(allocator),
            .pattern_types = .init(allocator),
            .method_calls = .init(allocator),
            .interface_calls = .init(allocator),
            .interface_casts = .init(allocator),
            .call_arguments = .init(allocator),
            .for_in_infos = .init(allocator),
            .imported_method_parameter_names = .init(allocator),
        };
    }

    pub fn deinit(self: *CheckResult) void {
        self.for_in_infos.deinit();
        self.call_arguments.deinit();
        self.interface_casts.deinit();
        self.interface_calls.deinit();
        self.method_calls.deinit();
        self.methods.deinit(self.allocator);
        self.imported_method_parameter_names.deinit();
        self.pattern_types.deinit();
        self.pattern_variants.deinit();
        self.interface_implementations.deinit(self.allocator);
        self.interface_definitions.deinit();
        self.enum_definitions.deinit();
        self.generic_nominal_fields.deinit();
        self.generic_function_parameters.deinit();
        self.alias_type_nodes.deinit();
        self.type_aliases.deinit();
        self.nominal_fields.deinit();
        self.ffi_struct_layouts.deinit();
        self.imported_nominal_identities.deinit();
        self.unsupported_imports.deinit();
        self.symbol_types.deinit();
        self.expression_types.deinit();
        self.diagnostics.deinit(self.allocator);
        self.types.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

const Checker = struct {
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    result: *CheckResult,
    current_return: ?types.TypeId = null,
    current_generic_parameters: []const GenericParameter = &.{},
    current_nominal_owner: ?NominalOwner = null,
    loop_depth: usize = 0,
    next_generic_parameter: u32 = 1,
    target_profile: target_policy.TargetProfile,
    resolving_aliases: std.AutoHashMap(symbols.SymbolId, void),

    fn report(self: *Checker, span: source.Span, comptime format: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.result.arena.allocator(), format, args);
        _ = try self.result.diagnostics.appendUnique(self.result.allocator, .{
            .phase = .type_checker,
            .severity = .err,
            .span = span,
            .message = message,
        });
    }

    // Ported from `core/type_cheker.odin`'s `report_warning` — same
    // shape as `report` above, `.severity = .warning` instead of `.err`.
    // `diagnostics_have_error`-equivalent gating (`SourceRun.hasErrors`)
    // already treats `.warning` as non-blocking; this is what actually
    // PRODUCES that severity — before `check_unreachable_code`/unused-
    // variable warnings below, NOTHING in `zig/core/*.zig` ever
    // constructed a `.warning` diagnostic at all.
    fn reportWarning(self: *Checker, span: source.Span, comptime format: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.result.arena.allocator(), format, args);
        _ = try self.result.diagnostics.appendUnique(self.result.allocator, .{
            .phase = .type_checker,
            .severity = .warning,
            .span = span,
            .message = message,
        });
    }

    fn signaturePass(self: *Checker) !void {
        for (self.tree.program.?.declarations) |declaration| {
            switch (self.tree.decl(declaration).*) {
                .function => |function| try self.defineFunctionSignature(declaration, function.type_parameters, function.parameters, function.return_type),
                .foreign => |foreign| try self.defineForeignSignature(declaration, foreign),
                .impl => |implementation| {
                    const owner = (if (implementation.target_module) |module_name|
                        self.findQualifiedTypeSymbol(module_name, implementation.target_type)
                    else
                        self.findTypeSymbol(implementation.target_type)) orelse {
                        try self.report(implementation.span, "Type Error: неизвестный тип реализации '{s}'", .{implementation.target_type});
                        continue;
                    };
                    const owner_parameters = self.nominalParameters(owner);
                    if (implementation.interface_name) |interface_name| {
                        try self.defineInterfaceImplementation(implementation, owner, owner_parameters, interface_name, implementation.interface_module);
                    } else {
                        for (implementation.methods) |method| {
                            const function = self.tree.decl(method).function;
                            try self.defineMethodSignature(method, owner, null, owner_parameters, function.type_parameters, function.parameters, function.return_type);
                        }
                    }
                },
                else => {},
            }
        }
    }

    // Registers opaque cross-module identity for every imported nominal type
    // BEFORE `signaturePass` runs — `signaturePass` already resolves qualified
    // type annotations (e.g. an impl's receiver parameter, `это: точки.Точка`)
    // via `nominalType`, which reads `imported_nominal_identities`; running
    // this after `signaturePass` (as `importSignaturePass` does for
    // fields/methods, which don't need it that early) left every qualified
    // annotation resolved during `signaturePass` silently defaulting to
    // identity=0 instead of the real opaque identity, causing "получатель
    // метода имеет неверный тип" for a same-module qualified impl target
    // (`реализация точки.Точка ... конец`) — the annotation and the call
    // site's own value ended up with DIFFERENT identities for the same type.
    // Also builds the per-owner generic-parameter remap and, for an imported
    // INTERFACE type, its `InterfaceDefinition` — both must exist before
    // `signaturePass` runs, since it resolves qualified impl targets
    // (`реализация чужой_модуль.Интерфейс для Тип`) and needs
    // `interface_definitions` to validate the implementation right away.
    // `owner_remaps`/`owner_parameters_by_symbol` are then reused as-is by
    // `importSignaturePass` for fields/enum variants/methods/impls, which
    // don't need to run this early.
    fn importIdentityPass(
        self: *Checker,
        imports: ImportContext,
        owner_remaps: *std.AutoHashMap(symbols.SymbolId, std.AutoHashMap(types.TypeId, types.TypeId)),
        owner_parameters_by_symbol: *std.AutoHashMap(symbols.SymbolId, []const GenericParameter),
    ) !void {
        for (imports.nominals) |imported| {
            try self.result.imported_nominal_identities.put(imported.local_symbol, imported.identity);
            if (imported.generic_parameters) |source_parameters| {
                var remap = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
                var owner_parameters: std.ArrayList(GenericParameter) = .empty;
                defer owner_parameters.deinit(self.result.allocator);
                for (source_parameters) |parameter| {
                    const local_typ = try self.result.types.genericParameter(self.next_generic_parameter);
                    self.next_generic_parameter += 1;
                    try remap.put(parameter.typ, local_typ);
                    try owner_parameters.append(self.result.allocator, .{
                        .name = try self.result.arena.allocator().dupe(u8, parameter.name),
                        .typ = local_typ,
                    });
                }
                try owner_remaps.put(imported.local_symbol, remap);
                try owner_parameters_by_symbol.put(imported.local_symbol, try self.result.arena.allocator().dupe(GenericParameter, owner_parameters.items));
            }
            const owner_remap = owner_remaps.getPtr(imported.local_symbol);
            if (imported.interface_methods) |source_methods| {
                var methods: std.ArrayList(InterfaceMethod) = .empty;
                defer methods.deinit(self.result.allocator);
                var unsupported = false;
                for (source_methods) |source_method| {
                    var parameters: std.ArrayList(types.TypeId) = .empty;
                    defer parameters.deinit(self.result.allocator);
                    for (source_method.parameters) |parameter| {
                        const copied = self.copyImportedType(imported.definition_store, parameter, imports.nominals, owner_remap) catch |err| switch (err) {
                            error.UnsupportedImportedType => {
                                unsupported = true;
                                break;
                            },
                            else => return err,
                        };
                        try parameters.append(self.result.allocator, copied);
                    }
                    if (unsupported) break;
                    const return_type = self.copyImportedType(imported.definition_store, source_method.return_type, imports.nominals, owner_remap) catch |err| switch (err) {
                        error.UnsupportedImportedType => {
                            unsupported = true;
                            break;
                        },
                        else => return err,
                    };
                    try methods.append(self.result.allocator, .{
                        .name = try self.result.arena.allocator().dupe(u8, source_method.name),
                        .parameters = try self.result.arena.allocator().dupe(types.TypeId, parameters.items),
                        .return_type = return_type,
                    });
                }
                if (!unsupported) {
                    const parameters = owner_parameters_by_symbol.get(imported.local_symbol) orelse &.{};
                    try self.result.interface_definitions.put(imported.local_symbol, .{
                        .parameters = parameters,
                        .methods = try self.result.arena.allocator().dupe(InterfaceMethod, methods.items),
                    });
                }
            }
        }
    }

    fn importSignaturePass(
        self: *Checker,
        imports: ImportContext,
        owner_remaps: *std.AutoHashMap(symbols.SymbolId, std.AutoHashMap(types.TypeId, types.TypeId)),
        owner_parameters_by_symbol: *std.AutoHashMap(symbols.SymbolId, []const GenericParameter),
    ) !void {
        for (imports.nominals) |imported| {
            const owner_remap = owner_remaps.getPtr(imported.local_symbol);
            if (imported.fields) |source_fields| {
                var fields: std.ArrayList(NominalField) = .empty;
                defer fields.deinit(self.result.allocator);
                for (source_fields) |field| {
                    // A field type may reference a nominal type from a
                    // module the CURRENT file never imports directly (an
                    // imported struct's field pointing at a THIRD
                    // module's type, e.g. `слог.Логгер` reached via
                    // `Менеджер.логгер` when only `Менеджер`'s owning
                    // module is imported here) — `imports.nominals` only
                    // ever lists the local file's OWN direct imports, so
                    // `copyImportedType` correctly can't resolve it.
                    // Falls back to `poison` (assignable to/from
                    // anything, see `assignable`'s own top check) rather
                    // than letting `error.UnsupportedImportedType`
                    // propagate uncaught — a real gap found auditing
                    // panosiki (`тест.ps` importing `tempfiles.ps`'s
                    // `Менеджер`, itself importing `слог.Логгер`): the
                    // WHOLE compilation crashed with a raw Zig stack
                    // trace instead of failing (or degrading) cleanly.
                    const field_type = self.copyImportedType(imported.definition_store, field.typ, imports.nominals, owner_remap) catch |err| switch (err) {
                        error.UnsupportedImportedType => try self.result.types.poison(),
                        else => return err,
                    };
                    try fields.append(self.result.allocator, .{
                        .name = try self.result.arena.allocator().dupe(u8, field.name),
                        .typ = field_type,
                    });
                }
                const copied_fields = try self.result.arena.allocator().dupe(NominalField, fields.items);
                if (owner_parameters_by_symbol.get(imported.local_symbol)) |parameters| {
                    try self.result.generic_nominal_fields.put(imported.local_symbol, .{ .parameters = parameters, .fields = copied_fields });
                } else {
                    try self.result.nominal_fields.put(imported.local_symbol, copied_fields);
                }
            }
            if (imported.enum_variants) |source_variants| {
                var variants: std.ArrayList(EnumVariant) = .empty;
                defer variants.deinit(self.result.allocator);
                for (source_variants) |source_variant| {
                    const variant_symbol = self.resolution.findEnumVariant(imported.local_symbol, source_variant.name) orelse continue;
                    var fields: std.ArrayList(types.TypeId) = .empty;
                    defer fields.deinit(self.result.allocator);
                    for (source_variant.fields) |field| {
                        const field_type = self.copyImportedType(imported.definition_store, field, imports.nominals, owner_remap) catch |err| switch (err) {
                            error.UnsupportedImportedType => try self.result.types.poison(),
                            else => return err,
                        };
                        try fields.append(self.result.allocator, field_type);
                    }
                    try variants.append(self.result.allocator, .{
                        .symbol = variant_symbol,
                        .name = try self.result.arena.allocator().dupe(u8, source_variant.name),
                        .fields = try self.result.arena.allocator().dupe(types.TypeId, fields.items),
                    });
                }
                const parameters = owner_parameters_by_symbol.get(imported.local_symbol) orelse &.{};
                try self.result.enum_definitions.put(imported.local_symbol, .{
                    .parameters = parameters,
                    .variants = try self.result.arena.allocator().dupe(EnumVariant, variants.items),
                });
            }
        }
        for (imports.symbols) |imported| {
            // Imported GENERIC FREE FUNCTION — mint fresh LOCAL
            // generic-parameter TypeIds (one per target parameter),
            // remap the signature through them (instead of `null`,
            // which silently poisons every `T` reference — see
            // `ImportedSymbolType.generic_parameters`'s own doc comment
            // for the crash this caused), and register the remapped
            // parameters/bounds into `generic_function_parameters` so
            // the call site's existing same-file machinery
            // (`interfaceBoundOf`/generic-call substitution) works
            // identically for a cross-module call.
            var local_generic_remap: ?std.AutoHashMap(types.TypeId, types.TypeId) = null;
            defer if (local_generic_remap) |*map| map.deinit();
            if (imported.generic_parameters) |target_parameters| {
                var remap = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
                var local_parameters: std.ArrayList(GenericParameter) = .empty;
                defer local_parameters.deinit(self.result.allocator);
                var unsupported_contract = false;
                for (target_parameters) |target_parameter| {
                    const local_typ = try self.result.types.genericParameter(self.next_generic_parameter);
                    self.next_generic_parameter += 1;
                    try remap.put(target_parameter.typ, local_typ);
                    var local_bounds: std.ArrayList(symbols.SymbolId) = .empty;
                    defer local_bounds.deinit(self.result.allocator);
                    for (target_parameter.bounds) |target_bound| {
                        var remapped = false;
                        for (imports.nominals) |nominal| {
                            if (nominal.store != imported.store or nominal.source_symbol != target_bound) continue;
                            try local_bounds.append(self.result.allocator, nominal.local_symbol);
                            remapped = true;
                            break;
                        }
                        // A bound is part of the exported function's
                        // contract. Dropping it turns `[T: Интерфейс]`
                        // into `[T]` and lets an uncast value reach the
                        // source module's interface dispatch at runtime.
                        // Import only a complete contract.
                        if (!remapped) {
                            unsupported_contract = true;
                            break;
                        }
                    }
                    if (unsupported_contract) break;
                    try local_parameters.append(self.result.allocator, .{
                        .name = target_parameter.name,
                        .typ = local_typ,
                        .bounds = try self.result.arena.allocator().dupe(symbols.SymbolId, local_bounds.items),
                    });
                }
                if (unsupported_contract) {
                    remap.deinit();
                    try self.result.unsupported_imports.put(imported.symbol, {});
                    continue;
                }
                // Invariant this whole bridging step depends on: one
                // fresh local TypeId per target parameter, no collisions,
                // nothing dropped. A violation here would silently
                // produce a WRONG cross-module generic signature (the
                // exact bug class `interfaceBoundOf`/bound-dispatch broke
                // on before this session) — assert loudly in Debug
                // instead of compiling a subtly incorrect signature that
                // only surfaces as a confusing runtime crash three layers
                // away, in a DIFFERENT file, later.
                std.debug.assert(remap.count() == target_parameters.len);
                std.debug.assert(local_parameters.items.len == target_parameters.len);
                try self.result.generic_function_parameters.put(imported.symbol, try self.result.arena.allocator().dupe(GenericParameter, local_parameters.items));
                local_generic_remap = remap;
            }
            const copied = self.copyImportedType(imported.store, imported.type_id, imports.nominals, if (local_generic_remap) |*map| map else null) catch |err| switch (err) {
                error.UnsupportedImportedType => {
                    try self.result.unsupported_imports.put(imported.symbol, {});
                    continue;
                },
                else => return err,
            };
            try self.result.symbol_types.put(imported.symbol, copied);
        }
        for (imports.methods) |imported| {
            const owner_remap = owner_remaps.getPtr(imported.owner);
            const copied = self.copyImportedType(imported.store, imported.type_id, imports.nominals, owner_remap) catch |err| switch (err) {
                error.UnsupportedImportedType => continue,
                else => return err,
            };
            try self.result.symbol_types.put(imported.symbol, copied);
            try self.result.imported_method_parameter_names.put(imported.symbol, imported.parameter_names);
            const owner_parameters = owner_parameters_by_symbol.get(imported.owner) orelse &.{};
            try self.result.methods.append(self.result.allocator, .{
                .owner = imported.owner,
                .interface = null,
                .symbol = imported.symbol,
                .name = imported.name,
                .owner_parameters = owner_parameters,
                .function_parameters = &.{},
                .all_parameters = owner_parameters,
            });
        }
        for (imports.impls) |imported| {
            const interface_symbol = self.findTypeSymbol(imported.interface_name) orelse continue;
            const owner_remap = owner_remaps.getPtr(imported.owner);
            var arguments: std.ArrayList(types.TypeId) = .empty;
            defer arguments.deinit(self.result.allocator);
            var unsupported = false;
            for (imported.argument_type_ids) |argument| {
                const copied = self.copyImportedType(imported.store, argument, imports.nominals, owner_remap) catch |err| switch (err) {
                    error.UnsupportedImportedType => {
                        unsupported = true;
                        break;
                    },
                    else => return err,
                };
                try arguments.append(self.result.allocator, copied);
            }
            if (unsupported) continue;
            var methods: std.ArrayList(symbols.SymbolId) = .empty;
            defer methods.deinit(self.result.allocator);
            for (imported.method_symbols) |source_method_symbol| {
                const source_method = imported.target_resolution.symbols.get(source_method_symbol) orelse continue;
                const method = self.inherentMethod(imported.owner, source_method.name) orelse continue;
                try methods.append(self.result.allocator, method.symbol);
            }
            if (methods.items.len != imported.method_symbols.len) continue;
            try self.result.interface_implementations.append(self.result.allocator, .{
                .interface = interface_symbol,
                .arguments = try self.result.arena.allocator().dupe(types.TypeId, arguments.items),
                .target = imported.owner,
                .methods = try self.result.arena.allocator().dupe(symbols.SymbolId, methods.items),
            });
        }
    }

    // `generic_remap` maps an external generic-parameter TypeId to a FRESH
    // local generic-parameter TypeId, minted once per imported generic owner
    // and reused across that owner's fields/variants/methods so `T` in a
    // struct field and `T` in one of its imported methods land on the SAME
    // local type — without it (null), `.generic_parameter` stays unsupported,
    // preserving prior behavior for non-generic imports.
    // A NESTED type reference that can't be copied (see `copyImportedType`'s
    // `.nominal` case) degrades to `poison` HERE instead of failing the
    // WHOLE containing type — `poison` is universally assignable
    // (`assignable`'s own top check), so one field/parameter/return
    // reaching a type from a module the current file doesn't import
    // directly (`Менеджер.логгер: слог.Логгер` when only `Менеджер`'s
    // module is imported) no longer takes down the entire struct/method
    // signature with it. Real gap found auditing panosiki: a method whose
    // signature touched ANY such transitively-unsupported type used to
    // vanish ENTIRELY from `self.result.methods` (the top-level `catch
    // ... continue` in `importSignaturePass`), producing "у типа нет поля
    // '...'" for methods that have NOTHING to do with the actually-broken
    // type. The TOP-level call (`imports.symbols`' own `try
    // self.copyImportedType(...)`) still propagates the error uncaught —
    // that one path wants the "импортированный экспорт '...' использует
    // пока неподдерживаемый тип" diagnostic, not a silent poison.
    fn copyImportedTypeOrPoison(self: *Checker, external_store: *const types.TypeStore, external_type: types.TypeId, nominals: []const ImportedNominal, generic_remap: ?*const std.AutoHashMap(types.TypeId, types.TypeId)) anyerror!types.TypeId {
        return self.copyImportedType(external_store, external_type, nominals, generic_remap) catch |err| switch (err) {
            error.UnsupportedImportedType => self.result.types.poison(),
            else => err,
        };
    }

    fn copyImportedType(self: *Checker, external_store: *const types.TypeStore, external_type: types.TypeId, nominals: []const ImportedNominal, generic_remap: ?*const std.AutoHashMap(types.TypeId, types.TypeId)) !types.TypeId {
        const entry = try external_store.require(external_type);
        return switch (entry.*) {
            .primitive => |primitive| switch (primitive) {
                .number => self.result.types.builtins.number,
                .integer => self.result.types.builtins.integer,
                .boolean => self.result.types.builtins.boolean,
                .void => self.result.types.builtins.void,
                .never => self.result.types.builtins.never,
                .string => self.result.types.builtins.string,
                .error_value => self.result.types.builtins.error_value,
            },
            .tuple => |elements| blk: {
                var copied: std.ArrayList(types.TypeId) = .empty;
                defer copied.deinit(self.result.allocator);
                for (elements) |element| try copied.append(self.result.allocator, try self.copyImportedTypeOrPoison(external_store, element, nominals, generic_remap));
                break :blk self.result.types.tuple(copied.items);
            },
            .function => |function| blk: {
                var copied: std.ArrayList(types.TypeId) = .empty;
                defer copied.deinit(self.result.allocator);
                for (function.parameters) |parameter| try copied.append(self.result.allocator, try self.copyImportedTypeOrPoison(external_store, parameter, nominals, generic_remap));
                break :blk self.result.types.function(copied.items, try self.copyImportedTypeOrPoison(external_store, function.return_type, nominals, generic_remap));
            },
            .nominal => |nominal| blk: {
                for (nominals) |imported| {
                    if (imported.store != external_store or imported.source_symbol != nominal.symbol) continue;
                    var arguments: std.ArrayList(types.TypeId) = .empty;
                    defer arguments.deinit(self.result.allocator);
                    for (nominal.arguments) |argument| try arguments.append(self.result.allocator, try self.copyImportedTypeOrPoison(external_store, argument, nominals, generic_remap));
                    break :blk self.result.types.nominalWithIdentity(imported.local_symbol, imported.identity, arguments.items);
                }
                return error.UnsupportedImportedType;
            },
            .array => |element| self.result.types.array(try self.copyImportedTypeOrPoison(external_store, element, nominals, generic_remap)),
            .map => |map| self.result.types.map(
                try self.copyImportedTypeOrPoison(external_store, map.key, nominals, generic_remap),
                try self.copyImportedTypeOrPoison(external_store, map.value, nominals, generic_remap),
            ),
            .process => |message| self.result.types.process(try self.copyImportedTypeOrPoison(external_store, message, nominals, generic_remap)),
            .pointer => |pointee| self.result.types.pointer(try self.copyImportedTypeOrPoison(external_store, pointee, nominals, generic_remap)),
            .generic_parameter => blk: {
                const remap = generic_remap orelse return error.UnsupportedImportedType;
                break :blk remap.get(external_type) orelse return error.UnsupportedImportedType;
            },
            .poison, .unconstrained => error.UnsupportedImportedType,
        };
    }

    fn typeAliasPass(self: *Checker) !void {
        for (self.tree.program.?.declarations) |declaration| {
            const alias = switch (self.tree.decl(declaration).*) {
                .type_alias => |value| value,
                else => continue,
            };
            const symbol = self.resolution.decl_symbols.get(declaration) orelse continue;
            try self.result.alias_type_nodes.put(symbol, alias.aliased_type);
        }
    }

    fn nominalPass(self: *Checker) !void {
        for (self.tree.program.?.declarations) |declaration| {
            const structure = switch (self.tree.decl(declaration).*) {
                .struct_decl => |value| value,
                else => continue,
            };
            const symbol = self.resolution.decl_symbols.get(declaration) orelse continue;
            if (structure.is_ffi) {
                // `ff_структура` fields carry a marshal kind, not a real
                // type annotation (parser.zig's `parseFfiStructDeclaration`
                // restricts them to Целое(8|32|64)/Число(32|64) — always
                // scalar, never nested) — panos-side field TYPE is derived
                // from that marshal kind the same way an ordinary
                // `внешний функ` parameter's type is (`foreignMarshalType`),
                // so `Вектор2(x, y)`/`.x` construction and field access get
                // the SAME real arity/type checking an ordinary struct's
                // fields already have — this was silently unchecked before
                // (is_ffi structs got skipped here entirely, no
                // `nominal_fields` entry at all).
                var ffi_fields: std.ArrayList(NominalField) = .empty;
                defer ffi_fields.deinit(self.result.allocator);
                var layout: std.ArrayList(ast.ForeignMarshalKind) = .empty;
                defer layout.deinit(self.result.allocator);
                for (structure.fields) |field| {
                    const kind = field.marshal orelse .int32;
                    try ffi_fields.append(self.result.allocator, .{
                        .name = field.name,
                        .typ = try self.foreignMarshalType(kind, null, null, field.span),
                    });
                    try layout.append(self.result.allocator, kind);
                }
                try self.result.nominal_fields.put(symbol, try self.result.arena.allocator().dupe(NominalField, ffi_fields.items));
                try self.result.ffi_struct_layouts.put(symbol, try self.result.arena.allocator().dupe(ast.ForeignMarshalKind, layout.items));
                continue;
            }
            var fields: std.ArrayList(NominalField) = .empty;
            defer fields.deinit(self.result.allocator);
            const generic_parameters = try self.defineGenericNominalParameters(symbol, structure.type_parameters);
            const resolved_fields = blk: {
                const previous_generic_parameters = self.current_generic_parameters;
                self.current_generic_parameters = generic_parameters;
                defer self.current_generic_parameters = previous_generic_parameters;
                for (structure.fields) |field| {
                    const annotation = field.type_annotation orelse continue;
                    try fields.append(self.result.allocator, .{
                        .name = field.name,
                        .typ = try self.resolveType(annotation),
                    });
                }
                break :blk try self.result.arena.allocator().dupe(NominalField, fields.items);
            };
            if (generic_parameters.len == 0) {
                try self.result.nominal_fields.put(symbol, resolved_fields);
            } else {
                try self.result.generic_nominal_fields.put(symbol, .{
                    .parameters = generic_parameters,
                    .fields = resolved_fields,
                });
            }
        }
    }

    fn enumPass(self: *Checker) !void {
        for (self.tree.program.?.declarations) |declaration| {
            const enumeration = switch (self.tree.decl(declaration).*) {
                .enum_decl => |value| value,
                else => continue,
            };
            const symbol = self.resolution.decl_symbols.get(declaration) orelse continue;
            const parameters = try self.defineGenericEnumParameters(enumeration.type_parameters);
            var variants: std.ArrayList(EnumVariant) = .empty;
            defer variants.deinit(self.result.allocator);
            const previous_generic_parameters = self.current_generic_parameters;
            self.current_generic_parameters = parameters;
            defer self.current_generic_parameters = previous_generic_parameters;
            for (enumeration.variants) |variant| {
                const variant_symbol = self.resolution.findEnumVariant(symbol, variant.name) orelse continue;
                var fields: std.ArrayList(types.TypeId) = .empty;
                defer fields.deinit(self.result.allocator);
                for (variant.types) |field| try fields.append(self.result.allocator, try self.resolveType(field));
                try variants.append(self.result.allocator, .{
                    .symbol = variant_symbol,
                    .name = variant.name,
                    .fields = try self.result.arena.allocator().dupe(types.TypeId, fields.items),
                });
            }
            try self.result.enum_definitions.put(symbol, .{
                .parameters = parameters,
                .variants = try self.result.arena.allocator().dupe(EnumVariant, variants.items),
            });
        }
    }

    fn interfacePass(self: *Checker) !void {
        for (self.tree.program.?.declarations) |declaration| {
            const interface = switch (self.tree.decl(declaration).*) {
                .interface_decl => |value| value,
                else => continue,
            };
            const symbol = self.resolution.decl_symbols.get(declaration) orelse continue;
            const parameters = try self.defineGenericNominalParameters(symbol, interface.type_parameters);
            const previous_generic_parameters = self.current_generic_parameters;
            self.current_generic_parameters = parameters;
            defer self.current_generic_parameters = previous_generic_parameters;
            var methods: std.ArrayList(InterfaceMethod) = .empty;
            defer methods.deinit(self.result.allocator);
            for (interface.methods) |method| {
                var method_parameters: std.ArrayList(types.TypeId) = .empty;
                defer method_parameters.deinit(self.result.allocator);
                for (method.parameters) |parameter| try method_parameters.append(self.result.allocator, try self.resolveType(parameter.type_annotation.?));
                try methods.append(self.result.allocator, .{
                    .name = method.name,
                    .parameters = try self.result.arena.allocator().dupe(types.TypeId, method_parameters.items),
                    .return_type = try self.resolveType(method.return_type),
                });
            }
            try self.result.interface_definitions.put(symbol, .{
                .parameters = parameters,
                .methods = try self.result.arena.allocator().dupe(InterfaceMethod, methods.items),
            });
        }
    }

    fn preludePass(self: *Checker) !void {
        const option_symbol = self.findTypeSymbol("Опция") orelse return;
        const result_symbol = self.findTypeSymbol("Результат") orelse return;
        const comparable_symbol = self.findTypeSymbol("Сравниваемое") orelse return;
        const iterable_symbol = self.findTypeSymbol("Итерируемое") orelse return;
        const printable_symbol = self.findTypeSymbol("Печатаемое");
        const option_parameters = try self.defineGenericEnumParameters(&.{"T"});
        const result_parameters = try self.defineGenericEnumParameters(&.{ "T", "E" });
        const option_variants = try self.result.arena.allocator().alloc(EnumVariant, 2);
        option_variants[0] = .{
            .symbol = self.resolution.findEnumVariant(option_symbol, "Нет") orelse return,
            .name = "Нет",
            .fields = &.{},
        };
        option_variants[1] = .{
            .symbol = self.resolution.findEnumVariant(option_symbol, "Есть") orelse return,
            .name = "Есть",
            .fields = try self.result.arena.allocator().dupe(types.TypeId, &.{option_parameters[0].typ}),
        };
        try self.result.enum_definitions.put(option_symbol, .{
            .parameters = option_parameters,
            .variants = option_variants,
        });
        const result_variants = try self.result.arena.allocator().alloc(EnumVariant, 2);
        result_variants[0] = .{
            .symbol = self.resolution.findEnumVariant(result_symbol, "Успех") orelse return,
            .name = "Успех",
            .fields = try self.result.arena.allocator().dupe(types.TypeId, &.{result_parameters[0].typ}),
        };
        result_variants[1] = .{
            .symbol = self.resolution.findEnumVariant(result_symbol, "Неудача") orelse return,
            .name = "Неудача",
            .fields = try self.result.arena.allocator().dupe(types.TypeId, &.{result_parameters[1].typ}),
        };
        try self.result.enum_definitions.put(result_symbol, .{
            .parameters = result_parameters,
            .variants = result_variants,
        });
        select_source: {
            const select_symbol = self.findTypeSymbol("ИсточникОжидания") orelse break :select_source;
            const select_parameters = try self.defineGenericEnumParameters(&.{ "T", "R" });
            const message_type = select_parameters[0].typ;
            const result_type = select_parameters[1].typ;
            const select_variants = try self.result.arena.allocator().alloc(EnumVariant, 3);
            select_variants[0] = .{
                .symbol = self.resolution.findEnumVariant(select_symbol, "Сообщение") orelse break :select_source,
                .name = "Сообщение",
                .fields = try self.result.arena.allocator().dupe(types.TypeId, &.{message_type}),
            };
            // `Сигнал` carries the SAME `(Число, Опция(Строка))` shape as
            // `получить_сигнал()`'s own return value (see that builtin's
            // handling above — the reason is a plain `Строка`, not an
            // `Ошибка`), as a single tuple field — so a `Сигнал(с)` arm
            // binds `с` the same way a direct `получить_сигнал()` call
            // already would.
            select_variants[1] = .{
                .symbol = self.resolution.findEnumVariant(select_symbol, "Сигнал") orelse break :select_source,
                .name = "Сигнал",
                .fields = try self.result.arena.allocator().dupe(types.TypeId, &.{
                    try self.result.types.tuple(&.{
                        self.result.types.builtins.number,
                        try self.result.types.nominal(option_symbol, &.{self.result.types.builtins.string}),
                    }),
                }),
            };
            select_variants[2] = .{
                .symbol = self.resolution.findEnumVariant(select_symbol, "Готово") orelse break :select_source,
                .name = "Готово",
                .fields = try self.result.arena.allocator().dupe(types.TypeId, &.{
                    try self.result.types.process(result_type),
                    try self.result.types.nominal(result_symbol, &.{ result_type, self.result.types.builtins.error_value }),
                }),
            };
            try self.result.enum_definitions.put(select_symbol, .{
                .parameters = select_parameters,
                .variants = select_variants,
            });
        }
        const comparable_methods = try self.result.arena.allocator().alloc(InterfaceMethod, 1);
        comparable_methods[0] = .{
            .name = "сравнить",
            .parameters = &.{self.result.types.builtins.never},
            .return_type = self.result.types.builtins.number,
        };
        try self.result.interface_definitions.put(comparable_symbol, .{
            .parameters = &.{},
            .methods = comparable_methods,
        });
        const iterable_parameters = try self.defineGenericEnumParameters(&.{"T"});
        const iterable_methods = try self.result.arena.allocator().alloc(InterfaceMethod, 1);
        iterable_methods[0] = .{
            .name = "следующий",
            .parameters = &.{},
            .return_type = try self.result.types.nominal(option_symbol, &.{iterable_parameters[0].typ}),
        };
        try self.result.interface_definitions.put(iterable_symbol, .{
            .parameters = iterable_parameters,
            .methods = iterable_methods,
        });
        if (printable_symbol) |symbol| {
            const printable_methods = try self.result.arena.allocator().alloc(InterfaceMethod, 1);
            printable_methods[0] = .{
                .name = "вСтроку",
                .parameters = &.{},
                .return_type = self.result.types.builtins.string,
            };
            try self.result.interface_definitions.put(symbol, .{
                .parameters = &.{},
                .methods = printable_methods,
            });
        }
        // `Копируемое` — restoring copy-on-send (see `resolver.zig`'s
        // `installPreludeInterface("Копируемое")` comment for the full
        // rationale). `клонировать() -> Копируемое` returns the
        // implementing type itself ("Self") — a fresh, throwaway generic
        // parameter here (never tied to any real declared type parameter
        // list) lets `defineInterfaceImplementation`'s existing generic-
        // substitution machinery unify it against whatever concrete
        // return type each individual `реализация Копируемое для X`
        // actually declares, exactly like an ordinary generic method
        // parameter — no special-casing needed beyond minting the
        // placeholder.
        if (self.findTypeSymbol("Копируемое")) |symbol| {
            const self_placeholder = try self.result.types.genericParameter(self.next_generic_parameter);
            self.next_generic_parameter += 1;
            const clone_methods = try self.result.arena.allocator().alloc(InterfaceMethod, 1);
            clone_methods[0] = .{
                .name = "клонировать",
                .parameters = &.{},
                .return_type = self_placeholder,
            };
            try self.result.interface_definitions.put(symbol, .{
                .parameters = &.{},
                .methods = clone_methods,
            });
        }
    }

    // Panos-side type for a `внешний` parameter/return marshal kind —
    // marshal kind is purely ABI metadata (which C width to pack into),
    // the panos type it appears as is independent of that width: Int8/32/
    // 64 are all plain `Целое` (same `Число` int flavor a `для`-loop
    // counter uses, matching Odin's `TY_INT` choice here), Float32/64 are
    // both `Число`, `CString` is an ordinary `Строка` (copied into a real
    // GC string on return, borrowed on the way in — see `vm.zig`).
    // `.struct_value` (struct-by-value marshaling) isn't ported yet —
    // mirrors Odin's own history, where it was a later addition on top
    // of the scalar-only first slice, not a from-day-one requirement.
    fn foreignMarshalType(self: *Checker, marshal: ast.ForeignMarshalKind, pointee: ?ast.TypeId, struct_type_name: ?[]const u8, span: source.Span) anyerror!types.TypeId {
        return switch (marshal) {
            .void => self.result.types.builtins.void,
            .int8, .int32, .int64 => self.result.types.builtins.integer,
            .float32, .float64 => self.result.types.builtins.number,
            .c_string => self.result.types.builtins.string,
            // A real, well-defined marshal kind — rejected here only
            // because this VM has no `Указатель` RUNTIME value
            // representation yet to marshal it into (the type system
            // already models `Указатель(T)`, e.g. `types.zig`'s
            // `.pointer` — nothing constructs a live value of it yet).
            // Matches Odin's own history: `внешний` shipped scalar-only
            // first, pointers were a later, separate addition.
            .pointer => blk: {
                _ = pointee;
                try self.report(span, "Type Error: 'внешний' с Указатель(T) ещё не поддержан Zig-версией", .{});
                break :blk try self.result.types.poison();
            },
            // The panos-side type of a struct-by-value parameter/return is
            // the `ff_структура` itself — an ordinary nominal type, same
            // as any other struct parameter (`nominalPass`'s `is_ffi`
            // branch already registered real fields/a `ffi_struct_layouts`
            // entry for it, keyed by the SAME symbol found here). The
            // parser already restricted `ff_структура` fields to flat
            // scalars (no nesting) — `invokeForeign` (vm.zig) relies on
            // that invariant when packing/unpacking raw bytes.
            .struct_value => blk: {
                const name = struct_type_name orelse {
                    try self.report(span, "Type Error: 'внешний' ожидает имя ff_структура", .{});
                    break :blk try self.result.types.poison();
                };
                const symbol = self.findTypeSymbol(name) orelse {
                    try self.report(span, "Type Error: неизвестная структура '{s}'", .{name});
                    break :blk try self.result.types.poison();
                };
                if (!self.result.ffi_struct_layouts.contains(symbol)) {
                    try self.report(span, "Type Error: '{s}' не является ff_структура", .{name});
                    break :blk try self.result.types.poison();
                }
                break :blk try self.result.types.nominal(symbol, &.{});
            },
        };
    }

    fn defineForeignSignature(self: *Checker, declaration: ast.DeclId, foreign: anytype) !void {
        const symbol = self.resolution.decl_symbols.get(declaration) orelse return;
        var parameter_types: std.ArrayList(types.TypeId) = .empty;
        defer parameter_types.deinit(self.result.allocator);
        for (foreign.parameters) |parameter| {
            try parameter_types.append(self.result.allocator, try self.foreignMarshalType(parameter.marshal, parameter.pointee, parameter.struct_type_name, parameter.span));
        }
        const return_type = try self.foreignMarshalType(foreign.return_marshal, foreign.return_pointee, foreign.return_struct_type_name, foreign.span);
        const signature = try self.result.types.function(parameter_types.items, return_type);
        try self.result.symbol_types.put(symbol, signature);
    }

    fn defineFunctionSignature(self: *Checker, declaration: ast.DeclId, type_parameters: []const ast.TypeParameter, parameters: []const ast.ParamDecl, return_type: ast.TypeId) !void {
        const symbol = self.resolution.decl_symbols.get(declaration) orelse return;
        const generic_parameters = try self.defineGenericParameters(symbol, type_parameters);
        const previous_generic_parameters = self.current_generic_parameters;
        self.current_generic_parameters = generic_parameters;
        defer self.current_generic_parameters = previous_generic_parameters;
        const previous_nominal_owner = self.current_nominal_owner;
        self.current_nominal_owner = null;
        defer self.current_nominal_owner = previous_nominal_owner;
        var parameter_types: std.ArrayList(types.TypeId) = .empty;
        defer parameter_types.deinit(self.result.allocator);
        for (parameters) |parameter| {
            try parameter_types.append(self.result.allocator, try self.resolveType(parameter.type_annotation.?));
        }
        const signature = try self.result.types.function(parameter_types.items, try self.resolveType(return_type));
        try self.result.symbol_types.put(symbol, signature);
    }

    fn defineMethodSignature(self: *Checker, declaration: ast.DeclId, owner: symbols.SymbolId, interface: ?symbols.SymbolId, owner_parameters: []const GenericParameter, function_parameters: []const ast.TypeParameter, parameters: []const ast.ParamDecl, return_type: ast.TypeId) !void {
        const symbol = self.resolution.decl_symbols.get(declaration) orelse return;
        const method_parameters = try self.defineGenericParameters(symbol, function_parameters);
        var all_parameters: std.ArrayList(GenericParameter) = .empty;
        defer all_parameters.deinit(self.result.allocator);
        try all_parameters.appendSlice(self.result.allocator, owner_parameters);
        try all_parameters.appendSlice(self.result.allocator, method_parameters);
        const parameter_scope = try self.result.arena.allocator().dupe(GenericParameter, all_parameters.items);
        const previous_generic_parameters = self.current_generic_parameters;
        self.current_generic_parameters = parameter_scope;
        defer self.current_generic_parameters = previous_generic_parameters;
        const previous_nominal_owner = self.current_nominal_owner;
        self.current_nominal_owner = .{ .symbol = owner, .parameters = owner_parameters };
        defer self.current_nominal_owner = previous_nominal_owner;
        var parameter_types: std.ArrayList(types.TypeId) = .empty;
        defer parameter_types.deinit(self.result.allocator);
        for (parameters) |parameter| {
            try parameter_types.append(self.result.allocator, try self.resolveType(parameter.type_annotation.?));
        }
        const signature = try self.result.types.function(parameter_types.items, try self.resolveType(return_type));
        try self.result.symbol_types.put(symbol, signature);
        try self.result.methods.append(self.result.allocator, .{
            .owner = owner,
            .interface = interface,
            .symbol = symbol,
            .name = self.tree.decl(declaration).function.name,
            .owner_parameters = owner_parameters,
            .function_parameters = method_parameters,
            .all_parameters = parameter_scope,
        });
    }

    fn defineInterfaceImplementation(self: *Checker, implementation: anytype, owner: symbols.SymbolId, owner_parameters: []const GenericParameter, interface_name: []const u8, interface_module: ?[]const u8) !void {
        const interface_symbol = (if (interface_module) |module_name|
            self.findQualifiedTypeSymbol(module_name, interface_name)
        else
            self.findTypeSymbol(interface_name)) orelse {
            try self.report(implementation.span, "Type Error: неизвестный интерфейс '{s}'", .{interface_name});
            return;
        };
        const definition = self.result.interface_definitions.get(interface_symbol) orelse {
            try self.report(implementation.span, "Type Error: '{s}' не является интерфейсом", .{interface_name});
            return;
        };
        if (!self.isImplementableNominal(owner)) {
            try self.report(implementation.span, "Type Error: интерфейс может реализовать только структура или перечисление", .{});
            return;
        }
        for (implementation.methods) |method| {
            const function = self.tree.decl(method).function;
            try self.defineMethodSignature(method, owner, interface_symbol, owner_parameters, function.type_parameters, function.parameters, function.return_type);
        }

        var implementation_methods: std.ArrayList(symbols.SymbolId) = .empty;
        defer implementation_methods.deinit(self.result.allocator);
        var substitutions = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
        defer substitutions.deinit();
        var valid = true;
        for (definition.methods) |interface_method| {
            var matched: ?ast.DeclId = null;
            for (implementation.methods) |method| {
                const function = self.tree.decl(method).function;
                if (!std.mem.eql(u8, function.name, interface_method.name)) continue;
                if (matched != null) {
                    try self.report(function.span, "Type Error: метод '{s}' повторён в реализации интерфейса", .{interface_method.name});
                    valid = false;
                    continue;
                }
                matched = method;
            }
            const method = matched orelse {
                try self.report(implementation.span, "Type Error: в реализации отсутствует метод '{s}'", .{interface_method.name});
                valid = false;
                continue;
            };
            const method_symbol = self.resolution.decl_symbols.get(method) orelse {
                valid = false;
                continue;
            };
            try implementation_methods.append(self.result.allocator, method_symbol);
            const signature_id = self.result.symbol_types.get(method_symbol) orelse {
                valid = false;
                continue;
            };
            const signature = self.result.types.get(signature_id) orelse {
                valid = false;
                continue;
            };
            const implementation_function = self.tree.decl(method).function;
            const function = switch (signature.*) {
                .function => |value| value,
                else => continue,
            };
            if (function.parameters.len == interface_method.parameters.len + 1) {
                for (interface_method.parameters, function.parameters[1..]) |expected, actual| {
                    try self.inferGenericSubstitution(expected, actual, &substitutions, implementation_function.span);
                }
                try self.inferGenericSubstitution(interface_method.return_type, function.return_type, &substitutions, implementation_function.span);
            }
            if (!try self.interfaceMethodMatches(interface_symbol, owner, owner_parameters, method_symbol, interface_method, &substitutions)) valid = false;
        }
        for (implementation.methods) |method| {
            const function = self.tree.decl(method).function;
            if (self.interfaceMethod(definition, function.name) == null) {
                try self.report(function.span, "Type Error: метод '{s}' отсутствует в интерфейсе", .{function.name});
                valid = false;
            }
        }
        if (!valid or implementation_methods.items.len != definition.methods.len) return;
        var arguments: std.ArrayList(types.TypeId) = .empty;
        defer arguments.deinit(self.result.allocator);
        for (definition.parameters) |parameter| {
            const argument = substitutions.get(parameter.typ) orelse {
                try self.report(implementation.span, "Type Error: не удалось вывести параметр типа интерфейса '{s}'", .{parameter.name});
                return;
            };
            try arguments.append(self.result.allocator, argument);
        }
        try self.result.interface_implementations.append(self.result.allocator, .{
            .interface = interface_symbol,
            .arguments = try self.result.arena.allocator().dupe(types.TypeId, arguments.items),
            .target = owner,
            .methods = try self.result.arena.allocator().dupe(symbols.SymbolId, implementation_methods.items),
        });
    }

    fn interfaceMethodMatches(self: *Checker, interface: symbols.SymbolId, owner: symbols.SymbolId, owner_parameters: []const GenericParameter, method_symbol: symbols.SymbolId, interface_method: InterfaceMethod, substitutions: *const std.AutoHashMap(types.TypeId, types.TypeId)) !bool {
        const signature_id = self.result.symbol_types.get(method_symbol) orelse return false;
        const signature = self.result.types.get(signature_id) orelse return false;
        const function = switch (signature.*) {
            .function => |value| value,
            else => return false,
        };
        if (function.parameters.len != interface_method.parameters.len + 1) {
            try self.report(self.resolution.symbols.get(method_symbol).?.span, "Type Error: сигнатура метода не совпадает с интерфейсом", .{});
            return false;
        }
        var owner_arguments: std.ArrayList(types.TypeId) = .empty;
        defer owner_arguments.deinit(self.result.allocator);
        for (owner_parameters) |parameter| try owner_arguments.append(self.result.allocator, parameter.typ);
        const receiver = try self.result.types.nominal(owner, owner_arguments.items);
        if (!self.result.types.eql(function.parameters[0], receiver)) {
            try self.report(self.resolution.symbols.get(method_symbol).?.span, "Type Error: первый аргумент метода должен иметь тип реализующего типа", .{});
            return false;
        }
        if (self.isComparableInterface(interface)) {
            if (function.parameters.len != 2 or !self.result.types.eql(function.parameters[1], receiver) or !self.result.types.eql(function.return_type, self.result.types.builtins.number)) {
                try self.report(self.resolution.symbols.get(method_symbol).?.span, "Type Error: сигнатура метода 'сравнить' должна принимать реализующий тип и возвращать Число", .{});
                return false;
            }
            return true;
        }
        for (function.parameters[1..], interface_method.parameters) |parameter, expected| {
            if (!self.result.types.eql(parameter, try self.substituteGeneric(expected, substitutions))) {
                try self.report(self.resolution.symbols.get(method_symbol).?.span, "Type Error: сигнатура метода не совпадает с интерфейсом", .{});
                return false;
            }
        }
        if (!self.result.types.eql(function.return_type, try self.substituteGeneric(interface_method.return_type, substitutions))) {
            try self.report(self.resolution.symbols.get(method_symbol).?.span, "Type Error: сигнатура метода не совпадает с интерфейсом", .{});
            return false;
        }
        return true;
    }

    fn bodyPass(self: *Checker) !void {
        for (self.tree.program.?.declarations) |declaration| {
            switch (self.tree.decl(declaration).*) {
                .function => |function| try self.checkFunction(declaration, function.body),
                .impl => |implementation| for (implementation.methods) |method| {
                    const function = self.tree.decl(method).function;
                    _ = function;
                    try self.checkFunction(method, self.tree.decl(method).function.body);
                },
                else => {},
            }
        }
    }

    fn constantPass(self: *Checker) !void {
        for (self.tree.program.?.declarations) |declaration| {
            const constant = switch (self.tree.decl(declaration).*) {
                .constant => |value| value,
                else => continue,
            };
            if (!self.isTopLevelConstantLiteral(constant.value)) {
                try self.report(constant.span, "Type Error: константа верхнего уровня должна быть числовым, строковым или булевым литералом", .{});
            }
            const value_type = try self.infer(constant.value);
            if (self.resolution.decl_symbols.get(declaration)) |symbol| try self.result.symbol_types.put(symbol, value_type);
        }
    }

    fn isTopLevelConstantLiteral(self: *const Checker, expression: ast.ExprId) bool {
        return switch (self.tree.expr(expression).*) {
            .number, .boolean, .string => true,
            .unary => |unary| unary.operator == .minus and self.tree.expr(unary.operand).* == .number,
            else => false,
        };
    }

    fn checkFunction(self: *Checker, declaration: ast.DeclId, body: []const ast.StmtId) !void {
        const function_symbol = self.resolution.decl_symbols.get(declaration) orelse return;
        const signature = self.result.symbol_types.get(function_symbol) orelse return;
        const function_type = self.result.types.get(signature).?.function;
        const method = self.methodBySymbol(function_symbol);
        const previous_generic_parameters = self.current_generic_parameters;
        self.current_generic_parameters = if (method) |definition| definition.all_parameters else self.result.generic_function_parameters.get(function_symbol) orelse &.{};
        defer self.current_generic_parameters = previous_generic_parameters;
        const previous_nominal_owner = self.current_nominal_owner;
        self.current_nominal_owner = if (method) |definition| .{ .symbol = definition.owner, .parameters = definition.owner_parameters } else null;
        defer self.current_nominal_owner = previous_nominal_owner;
        const previous_return = self.current_return;
        self.current_return = function_type.return_type;
        defer self.current_return = previous_return;
        const parameter_symbols = self.resolution.function_parameters.get(declaration) orelse &.{};
        for (parameter_symbols, function_type.parameters) |parameter_symbol, parameter_type| {
            try self.result.symbol_types.put(parameter_symbol, parameter_type);
        }
        const expected_body = if (self.isType(function_type.return_type, self.result.types.builtins.void)) null else function_type.return_type;
        const actual = try self.inferBlockExpected(body, expected_body, false);
        if (!self.isType(function_type.return_type, self.result.types.builtins.void) and !self.assignable(actual, function_type.return_type)) {
            const span = self.tree.decl(declaration).function.span;
            try self.report(span, "Type Error: функция должна возвращать объявленный тип", .{});
        }
        try self.checkUnreachableCode(body);
    }

    // Ported from `core/type_cheker.odin`'s `stmt_always_diverges`/
    // `block_always_diverges`/`expr_always_diverges`/
    // `stmt_diverges_for_reachability`/`check_unreachable_code`/
    // `check_unreachable_code_expr` — warns (`.severity = .warning`, does
    // NOT block execution) about code that follows a guaranteed-diverging
    // statement in the SAME block. `если` without `иначе` never counts as
    // diverging (the false-condition path falls straight through) — only
    // `stmtAlwaysDiverges`'s `.if_expr` case matters here, reached via
    // `exprAlwaysDiverges`.
    fn stmtAlwaysDiverges(self: *const Checker, statement: ast.StmtId) bool {
        return switch (self.tree.stmt(statement).*) {
            .return_stmt => true,
            .expr => |value| self.exprAlwaysDiverges(value.value),
            else => false,
        };
    }

    fn blockAlwaysDiverges(self: *const Checker, body: []const ast.StmtId) bool {
        for (body) |statement| {
            if (self.stmtAlwaysDiverges(statement)) return true;
        }
        return false;
    }

    fn exprAlwaysDiverges(self: *const Checker, expression: ast.ExprId) bool {
        switch (self.tree.expr(expression).*) {
            .if_expr => |conditional| {
                // No `иначе` — the false-condition path falls straight
                // through, never diverges.
                if (conditional.else_branch.len == 0) return false;
                return self.blockAlwaysDiverges(conditional.then_branch) and self.blockAlwaysDiverges(conditional.else_branch);
            },
            .match_expr => |match| {
                if (match.arms.len == 0) return false;
                for (match.arms) |arm| {
                    if (!self.blockAlwaysDiverges(arm.body)) return false;
                }
                return true;
            },
            else => {},
        }
        // Everything else (panic/infinite recursion etc.) is already
        // typed `Никогда` by ordinary Never-propagation — `expression_types`
        // is already fully populated by the time this runs (after the
        // whole body's been inferred once).
        const expression_type = self.result.expression_types.get(expression) orelse return false;
        return self.isType(expression_type, self.result.types.builtins.never);
    }

    // Superset of `stmtAlwaysDiverges` — `прервать`/`продолжить` also
    // make the REST OF THIS BLOCK unreachable (they don't make the
    // enclosing function/block itself always-diverge, which is why this
    // is a SEPARATE function from `stmtAlwaysDiverges`, not a shared one).
    fn stmtDivergesForReachability(self: *const Checker, statement: ast.StmtId) bool {
        return switch (self.tree.stmt(statement).*) {
            .return_stmt, .break_stmt, .continue_stmt => true,
            .expr => |value| self.exprAlwaysDiverges(value.value),
            else => false,
        };
    }

    fn stmtSpan(self: *const Checker, statement: ast.StmtId) source.Span {
        return switch (self.tree.stmt(statement).*) {
            .return_stmt => |value| value.span,
            .let => |value| value.span,
            .expr => |value| value.span,
            .continue_stmt => |span| span,
            .break_stmt => |span| span,
            .for_in => |value| value.span,
            .for_range => |value| value.span,
            .error_node => |span| span,
        };
    }

    fn checkUnreachableCode(self: *Checker, body: []const ast.StmtId) anyerror!void {
        for (body, 0..) |statement, index| {
            switch (self.tree.stmt(statement).*) {
                .expr => |value| try self.checkUnreachableCodeExpr(value.value),
                .for_in => |value| try self.checkUnreachableCode(value.body),
                .for_range => |value| try self.checkUnreachableCode(value.body),
                else => {},
            }
            if (self.stmtDivergesForReachability(statement) and index + 1 < body.len) {
                const first = self.stmtSpan(body[index + 1]);
                const last = self.stmtSpan(body[body.len - 1]);
                try self.reportWarning(.{ .file_id = first.file_id, .start = first.start, .end = last.end }, "недостижимый код", .{});
                return;
            }
        }
    }

    fn checkUnreachableCodeExpr(self: *Checker, expression: ast.ExprId) anyerror!void {
        switch (self.tree.expr(expression).*) {
            .if_expr => |conditional| {
                try self.checkUnreachableCode(conditional.then_branch);
                try self.checkUnreachableCode(conditional.else_branch);
            },
            .match_expr => |match| {
                for (match.arms) |arm| try self.checkUnreachableCode(arm.body);
            },
            .while_expr => |loop| try self.checkUnreachableCode(loop.body),
            else => {},
        }
    }

    fn inferStatement(self: *Checker, statement: ast.StmtId, expected_return: types.TypeId, expected_value: ?types.TypeId, tail_value_needed: bool) anyerror!types.TypeId {
        return switch (self.tree.stmt(statement).*) {
            .let => |let| blk: {
                const expected = if (let.type_annotation) |annotation| try self.resolveType(annotation) else null;
                const value_type = if (expected) |type_id| try self.inferExpected(let.value, type_id) else try self.infer(let.value);
                if (expected) |type_id| {
                    if (!self.assignable(value_type, type_id)) {
                        try self.report(let.span, "Type Error: значение переменной не совпадает с аннотацией", .{});
                    } else {
                        try self.registerInterfaceCast(let.value, value_type, type_id);
                    }
                }
                const binding_type = expected orelse value_type;
                if (self.isType(binding_type, self.result.types.builtins.void)) try self.report(let.span, "Type Error: переменная не может иметь тип 'Пусто'", .{});
                if (let.destructure_type != null) {
                    try self.bindNominalDestructure(statement, let, binding_type);
                } else {
                    try self.bindStatementValue(statement, binding_type, let.span, "Type Error: деструктуризация ожидает тупл с соответствующим числом значений");
                }
                break :blk self.result.types.builtins.void;
            },
            .return_stmt => |return_statement| blk: {
                const return_value = return_statement.value orelse {
                    // Bare `возврат` — a void return, only valid where the
                    // function's declared return type actually IS `Пусто`
                    // (matching an ordinary `Пусто`-returning function
                    // that just falls off the end of its body).
                    if (!self.isType(expected_return, self.result.types.builtins.void)) {
                        try self.report(return_statement.span, "Type Error: 'возврат' без значения допустим только в функции, возвращающей Пусто", .{});
                    }
                    break :blk self.result.types.builtins.never;
                };
                const value_type = try self.inferExpected(return_value, expected_return);
                if (!self.assignable(value_type, expected_return)) {
                    try self.report(return_statement.span, "Type Error: возвращаемое значение не совпадает с типом функции", .{});
                } else {
                    try self.registerInterfaceCast(return_value, value_type, expected_return);
                }
                // `Никогда`, NOT `expected_return` — a `возврат` diverges
                // the ENCLOSING FUNCTION, it doesn't produce a value at
                // this point at all. Real gap found auditing panosiki's
                // `std/математика.ps`: `если n == 0 тогда возврат 1 конец`
                // (no `иначе`) used as a plain statement failed with
                // "ветви 'если' возвращают разные типы" — `inferIfExpected`
                // already has `isNever(then_type)`-based exemption logic
                // for EXACTLY this shape, but it could never fire because
                // this case returned `expected_return` (e.g. `Число`)
                // instead of `Никогда`, so the then-branch's inferred type
                // never matched the implicit empty else-branch's `Пусто`.
                break :blk self.result.types.builtins.never;
            },
            .expr => |expression| if (expected_value) |expected| blk: {
                const actual = try self.inferExpected(expression.value, expected);
                if (self.assignable(actual, expected)) try self.registerInterfaceCast(expression.value, actual, expected);
                break :blk actual;
            } else if (!tail_value_needed and self.tree.expr(expression.value).* == .if_expr)
                // `если` used as a BARE STATEMENT (not the block's trailing
                // value) never needs its branches to agree on a type — its
                // result is unconditionally discarded, mirroring
                // `compiler.zig`'s OWN `compileStatement` comment on this
                // exact shape ("Expr_Stmt — value is ALWAYS discarded...
                // lower with want_value=false"). The type-checker never
                // got the matching exemption: `если снимок.содержит(x)
                // тогда x.добавить(y) конец` (no `иначе`, `.добавить`
                // returns `Пусто`) was fine, but `если ... тогда
                // фс.удалить_директорию(x) конец` (no `иначе`,
                // `удалить_директорию` returns `Результат(...)`) failed
                // "ветви 'если' возвращают разные типы" against the
                // implicit empty `Пусто` else-branch — a real gap found
                // auditing panosiki's `std/tempfiles.ps`.
                //
                // `tail_value_needed` is NOT the same thing as
                // `expected_value != null`: a block's TRAILING statement
                // whose value is actually consumed (function/lambda body,
                // an if-expression branch, a match arm) but with no
                // concrete expected type propagated to THIS point
                // (expected_value == null) must still go through full
                // branch unification — otherwise a nested if-expression as
                // the tail of an else-branch (found running `pan`'s own
                // `семвер` module) silently took the discard path, always
                // inferred as `Пусто` regardless of its real branches, and
                // the OUTER if-expression failed "ветви 'если' возвращают
                // разные типы" against two branches whose types were
                // actually identical.
                try self.inferIfAsStatement(self.tree.expr(expression.value).if_expr)
            else
                self.infer(expression.value),
            .for_in => |loop| try self.inferForIn(statement, loop),
            .for_range => |range| try self.inferForRange(statement, range),
            .continue_stmt => |span| blk: {
                if (self.loop_depth == 0) try self.report(span, "Type Error: 'продолжить' можно использовать только внутри цикла", .{});
                break :blk self.result.types.builtins.void;
            },
            .break_stmt => |span| blk: {
                if (self.loop_depth == 0) try self.report(span, "Type Error: 'прервать' можно использовать только внутри цикла", .{});
                break :blk self.result.types.builtins.void;
            },
            else => self.result.types.builtins.void,
        };
    }

    fn infer(self: *Checker, expression: ast.ExprId) anyerror!types.TypeId {
        const inferred = switch (self.tree.expr(expression).*) {
            .number => self.result.types.builtins.number,
            .boolean => self.result.types.builtins.boolean,
            .string => self.result.types.builtins.string,
            .ident => |ident| blk: {
                const symbol = self.resolution.expr_symbols.get(expression) orelse break :blk try self.result.types.poison();
                if (self.resolution.symbols.get(symbol)) |entry| {
                    if (entry.kind == .type) break :blk try self.result.types.nominal(symbol, &.{});
                }
                if (self.result.unsupported_imports.contains(symbol)) {
                    try self.report(ident.span, "Type Error: импортированный экспорт '{s}' использует пока неподдерживаемый тип", .{self.resolution.symbols.get(symbol).?.name});
                }
                break :blk self.result.symbol_types.get(symbol) orelse try self.result.types.poison();
            },
            .unary => |unary| try self.inferUnary(unary),
            .binary => |binary| try self.inferBinary(binary),
            .call => |call| try self.inferCall(expression, call),
            .tuple => |tuple| blk: {
                var element_types: std.ArrayList(types.TypeId) = .empty;
                defer element_types.deinit(self.result.allocator);
                for (tuple.elements) |element| try element_types.append(self.result.allocator, try self.infer(element));
                break :blk try self.result.types.tuple(element_types.items);
            },
            .array => |array| blk: {
                if (array.elements.len == 0) break :blk try self.result.types.array(try self.result.types.unconstrained());
                const element_type = try self.infer(array.elements[0]);
                for (array.elements[1..]) |element| {
                    if (!self.assignable(try self.infer(element), element_type)) try self.report(array.span, "Type Error: элементы массива имеют разные типы", .{});
                }
                break :blk try self.result.types.array(element_type);
            },
            .map => |map| blk: {
                if (map.entries.len == 0) break :blk try self.result.types.map(try self.result.types.unconstrained(), try self.result.types.unconstrained());
                const key = try self.infer(map.entries[0].key);
                const value = try self.infer(map.entries[0].value);
                for (map.entries[1..]) |entry| {
                    if (!self.assignable(try self.infer(entry.key), key)) try self.report(entry.span, "Type Error: ключи соответствия имеют разные типы", .{});
                    if (!self.assignable(try self.infer(entry.value), value)) try self.report(entry.span, "Type Error: значения соответствия имеют разные типы", .{});
                }
                break :blk try self.result.types.map(key, value);
            },
            .index => |index| try self.inferIndex(index),
            .property => |property| try self.inferProperty(expression, property),
            .lambda => |lambda| try self.inferLambda(expression, lambda, null),
            .if_expr => |conditional| try self.inferIf(conditional),
            .while_expr => |loop| try self.inferWhile(loop),
            .spawn => |spawn| try self.inferSpawn(spawn),
            .try_expr => |try_expression| try self.inferTry(try_expression),
            .match_expr => |match| try self.inferMatch(match),
            .select_wait => |select| try self.inferSelectWait(select),
            else => try self.result.types.poison(),
        };
        return self.recordExpressionType(expression, inferred);
    }

    fn inferTry(self: *Checker, try_expression: anytype) !types.TypeId {
        const value_type = try self.infer(try_expression.value);
        const value_entry = self.result.types.get(value_type) orelse return self.result.types.poison();
        const value_nominal = switch (value_entry.*) {
            .nominal => |nominal| nominal,
            else => {
                try self.report(try_expression.span, "Type Error: оператор '?' ожидает Опцию или Результат", .{});
                return self.result.types.poison();
            },
        };
        const value_owner = self.resolution.symbols.get(value_nominal.symbol) orelse return self.result.types.poison();
        const return_type = self.current_return orelse {
            try self.report(try_expression.span, "Type Error: оператор '?' можно использовать только внутри функции", .{});
            return self.result.types.poison();
        };
        if (std.mem.eql(u8, value_owner.name, "Опция")) {
            if (value_nominal.arguments.len != 1) return self.result.types.poison();
            const return_entry = self.result.types.get(return_type) orelse return self.result.types.poison();
            const return_nominal = switch (return_entry.*) {
                .nominal => |nominal| nominal,
                else => {
                    try self.report(try_expression.span, "Type Error: оператор '?' для Опции можно использовать только в функции, возвращающей Опцию", .{});
                    return self.result.types.poison();
                },
            };
            const return_owner = self.resolution.symbols.get(return_nominal.symbol) orelse return self.result.types.poison();
            if (!std.mem.eql(u8, return_owner.name, "Опция")) {
                try self.report(try_expression.span, "Type Error: оператор '?' для Опции можно использовать только в функции, возвращающей Опцию", .{});
                return self.result.types.poison();
            }
            return value_nominal.arguments[0];
        }
        if (std.mem.eql(u8, value_owner.name, "Результат")) {
            if (value_nominal.arguments.len != 2) return self.result.types.poison();
            const return_entry = self.result.types.get(return_type) orelse return self.result.types.poison();
            const return_nominal = switch (return_entry.*) {
                .nominal => |nominal| nominal,
                else => {
                    try self.report(try_expression.span, "Type Error: оператор '?' можно использовать только в функции, возвращающей Результат", .{});
                    return self.result.types.poison();
                },
            };
            const return_owner = self.resolution.symbols.get(return_nominal.symbol) orelse return self.result.types.poison();
            if (!std.mem.eql(u8, return_owner.name, "Результат")) {
                try self.report(try_expression.span, "Type Error: оператор '?' можно использовать только в функции, возвращающей Результат", .{});
                return self.result.types.poison();
            }
            if (return_nominal.arguments.len != 2 or !self.result.types.eql(value_nominal.arguments[1], return_nominal.arguments[1])) {
                try self.report(try_expression.span, "Type Error: оператор '?' возвращает ошибку другого типа", .{});
                return self.result.types.poison();
            }
            return value_nominal.arguments[0];
        }
        try self.report(try_expression.span, "Type Error: оператор '?' ожидает Опцию или Результат", .{});
        return self.result.types.poison();
    }

    // `выбор ожидание(источник) ... конец` — `источник` must be
    // `Массив(Процесс(R))`; R comes straight from that array's element
    // type (ordinary array-literal unification already rejects
    // heterogeneous `Процесс(T)` elements, same as any other array — not
    // a new limitation introduced here). The message payload of a
    // `Сообщение` arm stays poison/untyped, matching `получить()`'s own
    // return type — the mailbox has no static element type today either.
    fn inferSelectWait(self: *Checker, select: anytype) !types.TypeId {
        const source_type = try self.infer(select.source);
        const source_entry = self.result.types.get(source_type) orelse return self.result.types.poison();
        const result_r = switch (source_entry.*) {
            .array => |element_type| blk: {
                const element_entry = self.result.types.get(element_type) orelse break :blk try self.result.types.poison();
                break :blk switch (element_entry.*) {
                    .process => |r| r,
                    .poison => try self.result.types.poison(),
                    else => blk2: {
                        try self.report(select.span, "Type Error: 'ожидание' ожидает Массив(Процесс(R))", .{});
                        break :blk2 try self.result.types.poison();
                    },
                };
            },
            .poison => return self.result.types.poison(),
            else => blk: {
                try self.report(select.span, "Type Error: 'ожидание' ожидает Массив(Процесс(R))", .{});
                break :blk try self.result.types.poison();
            },
        };
        const symbol = self.findTypeSymbol("ИсточникОжидания") orelse return self.result.types.poison();
        return self.result.types.nominal(symbol, &.{ try self.result.types.poison(), result_r });
    }

    fn inferSpawn(self: *Checker, spawn: anytype) !types.TypeId {
        const call = switch (self.tree.expr(spawn.call).*) {
            .call => |value| value,
            else => {
                try self.report(spawn.span, "Type Error: 'запусти' ожидает вызов функции", .{});
                return self.result.types.process(try self.result.types.poison());
            },
        };
        const call_return_type = try self.inferCall(spawn.call, call);
        // An ordinary long-lived actor is written as a `-> Пусто` function
        // driven by `получить()` in a loop — `Процесс(T)`'s T on THAT kind
        // of spawn conventionally annotates the MESSAGE type the actor
        // accepts, not its (void) return value, and that message type is
        // not something this checker can infer (would need analyzing
        // `получить()` call sites inside the callee — a separate, larger
        // inference feature) — so it stays poison, unchecked, exactly as
        // before, to avoid breaking every existing actor-style spawn.
        // A function that actually RETURNS a value is being used
        // task-style instead (one-shot computation, result read back via
        // `ждать`) — for that case T becomes the real return type, so
        // `ждать` can deliver it.
        if (self.isType(call_return_type, self.result.types.builtins.void)) {
            return self.result.types.process(try self.result.types.poison());
        }
        return self.result.types.process(call_return_type);
    }

    fn inferExpected(self: *Checker, expression: ast.ExprId, expected: types.TypeId) anyerror!types.TypeId {
        return switch (self.tree.expr(expression).*) {
            .lambda => |lambda| self.recordExpressionType(expression, try self.inferLambda(expression, lambda, expected)),
            .number => |number| if (expected.eql(self.result.types.builtins.integer)) blk: {
                if (number.value != std.math.trunc(number.value)) {
                    try self.report(number.span, "Type Error: дробный литерал несовместим с Целое", .{});
                }
                break :blk self.recordExpressionType(expression, expected);
            } else self.infer(expression),
            .unary => |unary| if (expected.eql(self.result.types.builtins.integer) and unary.operator == .minus) blk: {
                _ = try self.inferExpected(unary.operand, expected);
                break :blk self.recordExpressionType(expression, expected);
            } else self.infer(expression),
            .binary => |binary| if (expected.eql(self.result.types.builtins.integer) and (binary.operator == .plus or binary.operator == .minus or binary.operator == .star)) blk: {
                const left = try self.inferExpected(binary.left, expected);
                const right = try self.inferExpected(binary.right, expected);
                if (!self.assignable(left, expected) or !self.assignable(right, expected)) {
                    try self.report(binary.span, "Type Error: целочисленное выражение содержит несовместимый операнд", .{});
                    break :blk self.recordExpressionType(expression, try self.result.types.poison());
                }
                break :blk self.recordExpressionType(expression, expected);
            } else self.infer(expression),
            .tuple => |tuple| blk: {
                const expected_type = self.result.types.get(expected) orelse break :blk self.infer(expression);
                if (expected_type.* != .tuple or expected_type.tuple.len != tuple.elements.len) break :blk self.infer(expression);
                for (tuple.elements, expected_type.tuple) |element, element_type| {
                    const actual = try self.inferExpected(element, element_type);
                    if (self.assignable(actual, element_type)) {
                        try self.registerInterfaceCast(element, actual, element_type);
                    } else {
                        try self.report(tuple.span, "Type Error: элемент тупла не совпадает с ожидаемым типом", .{});
                    }
                }
                break :blk self.recordExpressionType(expression, expected);
            },
            // `Массив(Интерфейс) = массив(КонкретныйТип(...), ...)` — real
            // gap found designing `супервизор.ps`'s Phase E rewrite:
            // unlike a `пер`/return/argument site (all of which call
            // `registerInterfaceCast` on an assignable mismatch), a
            // collection LITERAL's element only ever ran `assignable()`
            // here — true (poison-tolerant `.process`-style structural
            // check aside), but never recorded the cast the COMPILER
            // needs to actually BOX the concrete struct value as an
            // interface at runtime. Every element ended up stored
            // unboxed, and any later interface-dispatched call through it
            // (`массив[i].метод()`, even via an intermediate local)
            // panicked "попытка вызвать интерфейсный метод у
            // не-интерфейса" — 100% reproducible, not an edge case, for
            // ANY interface-typed collection literal.
            .array => |array| blk: {
                const expected_type = self.result.types.get(expected) orelse break :blk self.infer(expression);
                const element_type = switch (expected_type.*) {
                    .array => |element| element,
                    else => break :blk self.infer(expression),
                };
                for (array.elements) |element| {
                    const actual = try self.inferExpected(element, element_type);
                    if (self.assignable(actual, element_type)) {
                        try self.registerInterfaceCast(element, actual, element_type);
                    } else {
                        try self.report(array.span, "Type Error: элемент массива не совпадает с ожидаемым типом", .{});
                    }
                }
                break :blk self.recordExpressionType(expression, expected);
            },
            .map => |map| blk: {
                const expected_type = self.result.types.get(expected) orelse break :blk self.infer(expression);
                const expected_map = switch (expected_type.*) {
                    .map => |value| value,
                    else => break :blk self.infer(expression),
                };
                for (map.entries) |entry| {
                    const key = try self.inferExpected(entry.key, expected_map.key);
                    const value = try self.inferExpected(entry.value, expected_map.value);
                    if (self.assignable(key, expected_map.key)) {
                        try self.registerInterfaceCast(entry.key, key, expected_map.key);
                    } else {
                        try self.report(entry.span, "Type Error: ключ соответствия не совпадает с ожидаемым типом", .{});
                    }
                    if (self.assignable(value, expected_map.value)) {
                        try self.registerInterfaceCast(entry.value, value, expected_map.value);
                    } else {
                        try self.report(entry.span, "Type Error: значение соответствия не совпадает с ожидаемым типом", .{});
                    }
                }
                break :blk self.recordExpressionType(expression, expected);
            },
            .call => |call| blk: {
                const variant = if (self.resolution.expr_symbols.get(call.callee)) |symbol| self.enumVariant(symbol) else null;
                if (variant) |value| break :blk self.recordExpressionType(expression, try self.inferEnumVariantCallExpected(call, value, expected));
                break :blk self.recordExpressionType(expression, try self.inferCallExpected(expression, call, expected));
            },
            .if_expr => |conditional| self.recordExpressionType(expression, try self.inferIfExpected(conditional, expected)),
            .match_expr => |match| self.recordExpressionType(expression, try self.inferMatchExpected(match, expected)),
            .spawn => |spawn| blk: {
                const actual = try self.inferSpawn(spawn);
                if (!self.assignable(actual, expected)) {
                    try self.report(spawn.span, "Type Error: тип 'запусти' не совпадает с ожидаемым Процесс(T)", .{});
                }
                break :blk self.recordExpressionType(expression, actual);
            },
            else => self.infer(expression),
        };
    }

    // `inferBlock` is used ONLY for loop bodies (см. `inferForIn`/
    // `inferForRange`/`выбор` над `получить`) — a loop's body value is
    // NEVER consumed by anything, so its trailing statement is discarded
    // exactly like `инferIfAsStatement`'s two sub-blocks, not "value
    // needed, type unknown" (`discard_tail = true`, see `inferBlockExpected`).
    fn inferBlock(self: *Checker, statements: []const ast.StmtId) anyerror!types.TypeId {
        return self.inferBlockExpected(statements, null, true);
    }

    // `discard_tail` distinguishes two DIFFERENT reasons the trailing
    // statement's `expected_last` can be `null`: (1) the block's value is
    // never consumed at all (loop bodies, `inferIfAsStatement`'s two
    // branches — `discard_tail = true`, trailing `если` may still take
    // the cheap discard path in `inferStatement`), vs (2) the block's
    // value genuinely matters (function/lambda body, an if-expression
    // branch, a match arm) but no concrete type was propagated INTO this
    // point (`discard_tail = false` — the trailing statement must still
    // be fully inferred/unified, see `tail_value_needed` in
    // `inferStatement`). Conflating these two into a single `null` was a
    // real bug found running `pan`'s own `семвер` module: a nested
    // if-expression as the tail of an else-branch silently discarded
    // instead of unifying, and the OUTER if-expression then failed
    // "ветви 'если' возвращают разные типы" on two branches whose actual
    // types were identical.
    fn inferBlockExpected(self: *Checker, statements: []const ast.StmtId, expected_last: ?types.TypeId, discard_tail: bool) anyerror!types.TypeId {
        var result_type = self.result.types.builtins.void;
        for (statements, 0..) |statement, index| {
            const is_last = index + 1 == statements.len;
            const expected_value = if (is_last) expected_last else null;
            const tail_value_needed = is_last and !discard_tail;
            result_type = try self.inferStatement(statement, self.current_return orelse self.result.types.builtins.void, expected_value, tail_value_needed);
        }
        return result_type;
    }

    fn inferIf(self: *Checker, conditional: anytype) anyerror!types.TypeId {
        return self.inferIfExpected(conditional, null);
    }

    fn inferIfExpected(self: *Checker, conditional: anytype, expected: ?types.TypeId) anyerror!types.TypeId {
        const condition = try self.infer(conditional.condition);
        if (!self.assignable(condition, self.result.types.builtins.boolean)) {
            try self.report(conditional.span, "Type Error: условие 'если' должно иметь тип Булево", .{});
        }
        const diagnostics_before_then = self.result.diagnostics.items.items.len;
        var then_type = try self.inferBlockExpected(conditional.then_branch, expected, false);
        const then_failed = self.result.diagnostics.items.items.len > diagnostics_before_then;
        const diagnostics_before_else = self.result.diagnostics.items.items.len;
        var else_type = try self.inferBlockExpected(conditional.else_branch, expected, false);
        const else_failed = self.result.diagnostics.items.items.len > diagnostics_before_else;
        // Real gap found auditing panosiki's `gitsync`
        // (`пер remote_опция = если remote == "" тогда Опция.Нет()
        // иначе Опция.Есть(remote) конец`, no `: Тип` annotation): with
        // no `expected` propagated at all, `Опция.Нет()` has ZERO
        // arguments to infer its own `T` from (`inferEnumVariantCall`
        // reports "не удалось вывести type-параметр 'T'" and falls back
        // to `poison`) — a fully ordinary, common panos idiom that
        // NEVER worked without an explicit annotation. When exactly ONE
        // branch fails this way while the other infers cleanly, retry
        // the FAILED branch using the SUCCESSFUL branch's inferred type
        // as `expected` — this routes back through the SAME
        // `inferEnumVariantCallExpected` mechanism that already makes
        // `Опция.Нет()` work fine in every OTHER expected-type context
        // (a struct field, a return position, ...). The failed attempt's
        // diagnostics are rolled back (`shrinkRetainingCapacity`) before
        // retrying so a since-fixed error doesn't linger.
        if (expected == null and then_failed and !else_failed and !self.isNever(else_type)) {
            self.result.diagnostics.items.shrinkRetainingCapacity(diagnostics_before_then);
            then_type = try self.inferBlockExpected(conditional.then_branch, else_type, false);
        } else if (expected == null and else_failed and !then_failed and !self.isNever(then_type)) {
            self.result.diagnostics.items.shrinkRetainingCapacity(diagnostics_before_else);
            else_type = try self.inferBlockExpected(conditional.else_branch, then_type, false);
        }
        const joined = if (self.isNever(then_type)) else_type else if (self.isNever(else_type)) then_type else null;
        // `both_satisfy_expected` — when `expected` is known AND both
        // branches are ALREADY individually valid against it (checked
        // again, explicitly, right below), the pairwise mutual check is
        // skipped: `assignable` isn't symmetric for interfaces, so two
        // branches that each satisfy an interface-typed `expected` (one
        // via a bare interface-typed value, the other via a concrete
        // implementor — e.g. `слог.Логгер` vs a bare `СтандартныйЛоггер`)
        // can still fail the OLD mutual check against each other even
        // though the join is perfectly sound. Scoped narrowly to that
        // case (not "skip whenever expected != null") so a GENUINELY
        // mismatched pair (e.g. one branch's actual type failing
        // `expected` outright) still falls through to the pairwise
        // check below and keeps reporting the same
        // "ветви 'если' возвращают разные типы" message existing tests
        // rely on, rather than the different "не совпадают с ожидаемым
        // типом" message from the check further down.
        const both_satisfy_expected = if (expected) |expected_type|
            (self.isNever(then_type) or self.assignable(then_type, expected_type)) and (self.isNever(else_type) or self.assignable(else_type, expected_type))
        else
            false;
        if (joined == null and !both_satisfy_expected and (!self.assignable(then_type, else_type) or !self.assignable(else_type, then_type))) {
            try self.report(conditional.span, "Type Error: ветви 'если' возвращают разные типы", .{});
            return self.result.types.poison();
        }
        if (expected) |expected_type| {
            if (!self.assignable(then_type, expected_type) or !self.assignable(else_type, expected_type)) {
                try self.report(conditional.span, "Type Error: ветви 'если' не совпадают с ожидаемым типом", .{});
                return self.result.types.poison();
            }
            return expected_type;
        }
        return joined orelse then_type;
    }

    // `если` as a bare statement — type-checks the condition and BOTH
    // branch bodies independently (each with `expected_value = null`, so
    // a NESTED trailing если/выбор inside either branch still gets its
    // own correct treatment), but never requires them to agree with each
    // other or produce any usable value — see the call site's comment in
    // `inferStatement` for why (`compiler.zig`'s existing want_value=false
    // codegen for this exact shape has no such requirement either).
    fn inferIfAsStatement(self: *Checker, conditional: anytype) anyerror!types.TypeId {
        const condition = try self.infer(conditional.condition);
        if (!self.assignable(condition, self.result.types.builtins.boolean)) {
            try self.report(conditional.span, "Type Error: условие 'если' должно иметь тип Булево", .{});
        }
        _ = try self.inferBlockExpected(conditional.then_branch, null, true);
        _ = try self.inferBlockExpected(conditional.else_branch, null, true);
        return self.result.types.builtins.void;
    }

    fn inferMatch(self: *Checker, match: anytype) anyerror!types.TypeId {
        return self.inferMatchExpected(match, null);
    }

    fn inferMatchExpected(self: *Checker, match: anytype, expected: ?types.TypeId) anyerror!types.TypeId {
        const subject_type = try self.infer(match.subject);
        const subject_entry = self.result.types.get(subject_type) orelse return self.result.types.poison();
        const enum_definition = switch (subject_entry.*) {
            .nominal => |nominal| self.result.enum_definitions.get(nominal.symbol),
            else => null,
        };
        const supports_patterns = switch (subject_entry.*) {
            .primitive => |primitive| primitive == .number or primitive == .integer or primitive == .boolean or primitive == .string,
            .nominal => |nominal| enum_definition != null or (try self.fieldsForNominal(nominal)) != null,
            .poison => true,
            else => false,
        };
        if (!supports_patterns) {
            try self.report(match.span, "Type Error: выбор не поддерживает этот тип", .{});
            return self.result.types.poison();
        }
        var covered = std.AutoHashMap(symbols.SymbolId, void).init(self.result.allocator);
        defer covered.deinit();
        var fallback_seen = false;
        var true_covered = false;
        var false_covered = false;
        var result_type: ?types.TypeId = null;
        for (match.arms) |arm| {
            if (fallback_seen) try self.report(arm.span, "Type Error: шаблон после универсальной ветки недостижим", .{});
            if (try self.inferMatchPattern(arm.pattern, subject_type, true)) |variant| {
                if (enum_definition != null) {
                    if (covered.contains(variant)) {
                        try self.report(arm.span, "Type Error: вариант перечисления повторён в выборе", .{});
                    } else {
                        try covered.put(variant, {});
                    }
                }
            }
            if (self.isCatchAllPattern(arm.pattern)) {
                fallback_seen = true;
            } else if (subject_entry.* == .primitive and subject_entry.primitive == .boolean) {
                if (patternBooleanLiteral(self.tree, arm.pattern)) |value| {
                    if (value) true_covered = true else false_covered = true;
                }
            }
            const arm_type = try self.inferBlockExpected(arm.body, expected, false);
            // When `expected` is known (the match sits in a context with
            // a declared type — a function's return position, an
            // annotated `пер`, ...), each arm is ALREADY validated
            // against it individually just below — that alone is enough
            // to prove the join is sound, so the separate pairwise
            // mutual-assignability check between arms is skipped
            // entirely in that case. Real gap found auditing panosiki's
            // `gitsync` (`выбор контекст.логгер \n Опция.Есть(л) -> л \n
            // Опция.Нет -> слог.логгер().с_уровнем(...) \n конец`,
            // function declared `-> слог.Логгер`): one arm's value is
            // already interface-typed (`л`, unwrapped from
            // `Опция(слог.Логгер)`), the other a CONCRETE
            // `СтандартныйЛоггер` — each is individually assignable to
            // the declared `слог.Логгер` (one directly, one via
            // interface implementation), but `assignable` is NOT
            // symmetric for interface types (a concrete struct is
            // assignable TO an interface it implements, never the
            // reverse) — the old pairwise check compared the two arms
            // directly against EACH OTHER (mutually, both directions)
            // and always failed for exactly this legitimate pattern.
            if (expected == null) {
                if (result_type) |previous| {
                    if (self.isNever(previous)) {
                        result_type = arm_type;
                    } else if (!self.isNever(arm_type) and (!self.assignable(previous, arm_type) or !self.assignable(arm_type, previous))) {
                        try self.report(arm.span, "Type Error: ветви выбора возвращают разные типы", .{});
                    }
                } else {
                    result_type = arm_type;
                }
            }
            if (expected) |expected_type| {
                if (!self.assignable(arm_type, expected_type)) try self.report(arm.span, "Type Error: ветвь выбора не совпадает с ожидаемым типом", .{});
            }
        }
        if (!fallback_seen and subject_entry.* != .poison) {
            if (enum_definition) |definition| {
                for (definition.variants) |variant| {
                    if (!covered.contains(variant.symbol)) try self.report(match.span, "Type Error: выбор не исчерпывает вариант '{s}'", .{variant.name});
                }
            } else if (subject_entry.* == .primitive and subject_entry.primitive == .boolean) {
                if (!true_covered) try self.report(match.span, "Type Error: выбор не исчерпывает значение 'истина'", .{});
                if (!false_covered) try self.report(match.span, "Type Error: выбор не исчерпывает значение 'ложь'", .{});
            } else {
                try self.report(match.span, "Type Error: выбор требует универсальную ветку", .{});
            }
        }
        return expected orelse result_type orelse self.result.types.builtins.void;
    }

    fn inferMatchPattern(self: *Checker, pattern_id: ast.PatternId, subject_type: types.TypeId, allow_short_variant: bool) !?symbols.SymbolId {
        try self.result.pattern_types.put(pattern_id, subject_type);
        switch (self.tree.pattern(pattern_id).*) {
            .wildcard => return null,
            .ident => |ident| {
                if (allow_short_variant) {
                    const subject_entry = self.result.types.get(subject_type) orelse return null;
                    if (subject_entry.* == .nominal) {
                        if (self.resolution.findEnumVariant(subject_entry.nominal.symbol, ident.name)) |variant_symbol| {
                            if (self.enumVariant(variant_symbol)) |variant| {
                                if (variant.fields.len == 0) {
                                    try self.result.pattern_variants.put(pattern_id, variant_symbol);
                                    return variant_symbol;
                                }
                            }
                        }
                    }
                }
                const binding = self.resolution.pattern_symbols.get(pattern_id) orelse return null;
                try self.result.symbol_types.put(binding, subject_type);
                return null;
            },
            .literal => |literal| {
                const literal_type = try self.inferExpected(literal.value, subject_type);
                if (!self.assignable(literal_type, subject_type)) try self.report(literal.span, "Type Error: литеральный шаблон не совпадает с типом значения выбора", .{});
                return null;
            },
            .constructor => |constructor| {
                const subject_entry = self.result.types.get(subject_type) orelse return null;
                if (subject_entry.* == .poison or subject_entry.* == .unconstrained) {
                    if (self.resolution.pattern_symbols.get(pattern_id)) |variant| {
                        try self.result.pattern_variants.put(pattern_id, variant);
                        return variant;
                    }
                    return null;
                }
                const subject = switch (subject_entry.*) {
                    .nominal => |value| value,
                    else => {
                        try self.report(constructor.span, "Type Error: шаблон-конструктор ожидает структуру или перечисление", .{});
                        return null;
                    },
                };
                if (self.result.enum_definitions.contains(subject.symbol)) {
                    if (constructor.field_names != null) try self.report(constructor.span, "Type Error: именованные поля шаблона перечисления пока не поддержаны", .{});
                    const resolved_variant = self.resolution.pattern_symbols.get(pattern_id) orelse (if (constructor.module_name == null) self.resolution.findEnumVariant(subject.symbol, constructor.name) else null);
                    const variant_symbol = resolved_variant orelse {
                        try self.report(constructor.span, "Type Error: неизвестный вариант перечисления в шаблоне", .{});
                        return null;
                    };
                    const variant_entry = self.resolution.symbols.get(variant_symbol) orelse return null;
                    if (variant_entry.kind != .enum_variant or variant_entry.owner_type != subject.symbol) {
                        try self.report(constructor.span, "Type Error: вариант шаблона не принадлежит типу значения выбора", .{});
                        return null;
                    }
                    try self.result.pattern_variants.put(pattern_id, variant_symbol);
                    const variant = self.enumVariant(variant_symbol) orelse return null;
                    const fields = try self.enumVariantFields(variant, subject_type) orelse return null;
                    if (constructor.arguments.len != fields.len) try self.report(constructor.span, "Type Error: неверное количество полей шаблона варианта", .{});
                    const shared = @min(constructor.arguments.len, fields.len);
                    for (constructor.arguments[0..shared], fields[0..shared]) |argument, field| {
                        _ = try self.inferMatchPattern(argument, field, false);
                    }
                    return variant_symbol;
                }
                const constructor_symbol = self.findTypeSymbol(constructor.name) orelse {
                    try self.report(constructor.span, "Type Error: неизвестный тип структуры в шаблоне", .{});
                    return null;
                };
                if (constructor_symbol != subject.symbol or constructor.module_name != null) {
                    try self.report(constructor.span, "Type Error: шаблон структуры не совпадает с типом значения выбора", .{});
                    return null;
                }
                const fields = try self.fieldsForNominal(subject) orelse {
                    try self.report(constructor.span, "Type Error: шаблон-конструктор ожидает структуру", .{});
                    return null;
                };
                if (constructor.field_names) |field_names| {
                    if (field_names.len != constructor.arguments.len) try self.report(constructor.span, "Type Error: некорректные именованные поля шаблона", .{});
                    var seen = std.StringHashMap(void).init(self.result.allocator);
                    defer seen.deinit();
                    const shared = @min(field_names.len, constructor.arguments.len);
                    for (field_names[0..shared], constructor.arguments[0..shared]) |field_name, argument| {
                        if (seen.contains(field_name)) {
                            try self.report(constructor.span, "Type Error: поле '{s}' повторено в шаблоне", .{field_name});
                            continue;
                        }
                        try seen.put(field_name, {});
                        const field = findNominalField(fields, field_name) orelse {
                            try self.report(constructor.span, "Type Error: у структуры нет поля '{s}'", .{field_name});
                            continue;
                        };
                        _ = try self.inferMatchPattern(argument, field.typ, false);
                    }
                } else {
                    if (constructor.arguments.len != fields.len) try self.report(constructor.span, "Type Error: неверное количество полей шаблона структуры", .{});
                    const shared = @min(constructor.arguments.len, fields.len);
                    for (constructor.arguments[0..shared], fields[0..shared]) |argument, field| {
                        _ = try self.inferMatchPattern(argument, field.typ, false);
                    }
                }
                return null;
            },
            .error_node => return null,
        }
    }

    fn isCatchAllPattern(self: *const Checker, pattern_id: ast.PatternId) bool {
        if (self.patternVariant(pattern_id) != null) return false;
        return switch (self.tree.pattern(pattern_id).*) {
            .wildcard, .ident => true,
            .constructor => |constructor| blk: {
                for (constructor.arguments) |argument| {
                    if (!self.isCatchAllPattern(argument)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        };
    }

    fn patternVariant(self: *const Checker, pattern_id: ast.PatternId) ?symbols.SymbolId {
        return self.result.pattern_variants.get(pattern_id);
    }

    fn recordExpressionType(self: *Checker, expression: ast.ExprId, inferred: types.TypeId) !types.TypeId {
        try self.result.expression_types.put(expression, inferred);
        return inferred;
    }

    fn inferWhile(self: *Checker, loop: anytype) anyerror!types.TypeId {
        const condition = try self.infer(loop.condition);
        if (!self.assignable(condition, self.result.types.builtins.boolean)) {
            try self.report(loop.span, "Type Error: условие 'пока' должно иметь тип Булево", .{});
        }
        self.loop_depth += 1;
        defer self.loop_depth -= 1;
        _ = try self.inferBlock(loop.body);
        return self.result.types.builtins.void;
    }

    fn inferForIn(self: *Checker, statement: ast.StmtId, loop: anytype) anyerror!types.TypeId {
        const iterable_type = try self.infer(loop.iterable);
        const iterable = self.result.types.get(iterable_type) orelse return self.result.types.builtins.void;
        switch (iterable.*) {
            .array => |element| {
                try self.bindStatementValue(statement, element, loop.span, "Type Error: шаблон 'для (...)' не совпадает с элементом массива");
                try self.result.for_in_infos.put(statement, .{ .kind = .array });
            },
            .map => {
                try self.report(loop.span, "Type Error: Соответствие не поддерживает позиционный доступ; для перебора элементов используйте .записи() и 'для (ключ, значение) в ...'", .{});
                try self.bindStatementPoison(statement);
            },
            .poison => try self.bindStatementPoison(statement),
            else => {
                if (try self.iterableForIn(iterable_type)) |info| {
                    try self.bindStatementValue(statement, info.element_type, loop.span, "Type Error: шаблон 'для (...)' не совпадает со значением Итерируемое");
                    try self.result.for_in_infos.put(statement, .{ .kind = .iterator, .next_method = info.next_method });
                } else if (try self.interfaceIterableElement(iterable_type)) |element_type| {
                    try self.bindStatementValue(statement, element_type, loop.span, "Type Error: шаблон 'для (...)' не совпадает со значением Итерируемое");
                    try self.result.for_in_infos.put(statement, .{ .kind = .iterator, .iterator_dispatch = .interface });
                } else {
                    try self.report(loop.span, "Type Error: тип не поддерживает 'для x в' (нужен Массив или Итерируемое)", .{});
                    try self.bindStatementPoison(statement);
                }
            },
        }
        self.loop_depth += 1;
        defer self.loop_depth -= 1;
        _ = try self.inferBlock(loop.body);
        return self.result.types.builtins.void;
    }

    const IterableForIn = struct {
        element_type: types.TypeId,
        next_method: symbols.SymbolId,
    };

    fn iterableForIn(self: *Checker, iterable_type: types.TypeId) !?IterableForIn {
        const iterable_entry = self.result.types.get(iterable_type) orelse return null;
        const target = switch (iterable_entry.*) {
            .nominal => |nominal| nominal.symbol,
            else => return null,
        };
        const iterable = self.findTypeSymbol("Итерируемое") orelse return null;
        const definition = self.result.interface_definitions.get(iterable) orelse return null;
        if (definition.parameters.len != 1 or definition.methods.len != 1 or !std.mem.eql(u8, definition.methods[0].name, "следующий")) return null;
        for (self.result.interface_implementations.items) |implementation| {
            if (implementation.interface != iterable or implementation.target != target or implementation.arguments.len != 1 or implementation.methods.len != 1) continue;
            return .{
                .element_type = implementation.arguments[0],
                .next_method = implementation.methods[0],
            };
        }
        return null;
    }

    fn interfaceIterableElement(self: *Checker, iterable_type: types.TypeId) !?types.TypeId {
        const iterable_entry = self.result.types.get(iterable_type) orelse return null;
        const nominal = switch (iterable_entry.*) {
            .nominal => |value| value,
            else => return null,
        };
        const iterable = self.findTypeSymbol("Итерируемое") orelse return null;
        if (nominal.symbol != iterable or nominal.arguments.len != 1) return null;
        const definition = self.result.interface_definitions.get(iterable) orelse return null;
        if (definition.parameters.len != 1 or definition.methods.len != 1 or !std.mem.eql(u8, definition.methods[0].name, "следующий")) return null;
        return nominal.arguments[0];
    }

    fn inferForRange(self: *Checker, statement: ast.StmtId, range: anytype) anyerror!types.TypeId {
        const integer = self.result.types.builtins.integer;
        const start = try self.infer(range.start);
        const end = try self.infer(range.end);
        if (!self.assignable(start, integer) and !self.assignable(start, self.result.types.builtins.number)) {
            try self.report(range.span, "Type Error: начало диапазона 'для' должно быть числом", .{});
        }
        if (!self.assignable(end, integer) and !self.assignable(end, self.result.types.builtins.number)) {
            try self.report(range.span, "Type Error: конец диапазона 'для' должен быть числом", .{});
        }
        try self.bindStatementValue(statement, integer, range.span, "Type Error: диапазон 'для' объявляет одну переменную");
        self.loop_depth += 1;
        defer self.loop_depth -= 1;
        _ = try self.inferBlock(range.body);
        return self.result.types.builtins.void;
    }

    fn bindStatementValue(self: *Checker, statement: ast.StmtId, value_type: types.TypeId, span: source.Span, mismatch_message: []const u8) !void {
        const bindings = self.resolution.stmt_bindings.get(statement) orelse return;
        if (bindings.len == 1) {
            try self.result.symbol_types.put(bindings[0], value_type);
            return;
        }
        const value = self.result.types.get(value_type) orelse return;
        if (value.* == .tuple and value.tuple.len == bindings.len) {
            for (bindings, value.tuple) |symbol, element_type| try self.result.symbol_types.put(symbol, element_type);
            return;
        }
        try self.report(span, "{s}", .{mismatch_message});
        try self.bindStatementPoison(statement);
    }

    fn bindStatementPoison(self: *Checker, statement: ast.StmtId) !void {
        const bindings = self.resolution.stmt_bindings.get(statement) orelse return;
        const poison = try self.result.types.poison();
        for (bindings) |symbol| try self.result.symbol_types.put(symbol, poison);
    }

    fn bindNominalDestructure(self: *Checker, statement: ast.StmtId, let: anytype, value_type: types.TypeId) !void {
        const bindings = self.resolution.stmt_bindings.get(statement) orelse return;
        const expected_name = let.destructure_type orelse return;
        const value = self.result.types.get(value_type) orelse return;
        const nominal = switch (value.*) {
            .nominal => |entry| entry,
            else => {
                try self.report(let.span, "Type Error: деструктуризация '{s}' ожидает структуру", .{expected_name});
                try self.bindStatementPoison(statement);
                return;
            },
        };
        const symbol = self.resolution.symbols.get(nominal.symbol) orelse {
            try self.bindStatementPoison(statement);
            return;
        };
        if (!std.mem.eql(u8, symbol.name, expected_name)) {
            try self.report(let.span, "Type Error: деструктуризация ожидает структуру '{s}'", .{expected_name});
            try self.bindStatementPoison(statement);
            return;
        }
        const fields = try self.fieldsForNominal(nominal) orelse {
            try self.report(let.span, "Type Error: тип '{s}' нельзя деструктурировать", .{expected_name});
            try self.bindStatementPoison(statement);
            return;
        };
        if (let.destructure_field_names) |names| {
            if (names.len != bindings.len) {
                try self.report(let.span, "Type Error: именованная деструктуризация имеет неверное число полей", .{});
                try self.bindStatementPoison(statement);
                return;
            }
            for (bindings, names) |binding, name| {
                for (fields) |field| {
                    if (!std.mem.eql(u8, field.name, name)) continue;
                    try self.result.symbol_types.put(binding, field.typ);
                    break;
                } else {
                    try self.report(let.span, "Type Error: у структуры '{s}' нет поля '{s}'", .{ expected_name, name });
                    try self.result.symbol_types.put(binding, try self.result.types.poison());
                }
            }
            return;
        }
        if (fields.len != bindings.len) {
            try self.report(let.span, "Type Error: деструктуризация структуры ожидает все поля по порядку", .{});
            try self.bindStatementPoison(statement);
            return;
        }
        for (bindings, fields) |binding, field| try self.result.symbol_types.put(binding, field.typ);
    }

    fn inferIndex(self: *Checker, index: anytype) anyerror!types.TypeId {
        const object_type = try self.infer(index.object);
        const index_type = try self.infer(index.index);
        const object = self.result.types.get(object_type) orelse return self.result.types.poison();
        return switch (object.*) {
            .primitive => |primitive| if (primitive == .string) blk: {
                if (!self.assignable(index_type, self.result.types.builtins.integer) and !self.assignable(index_type, self.result.types.builtins.number)) {
                    try self.report(index.span, "Type Error: индекс строки должен быть числом", .{});
                }
                break :blk self.result.types.builtins.string;
            } else blk: {
                try self.report(index.span, "Type Error: индексирование поддержано только для строки, массива и соответствия", .{});
                break :blk try self.result.types.poison();
            },
            .array => |element| blk: {
                if (!self.assignable(index_type, self.result.types.builtins.integer) and !self.assignable(index_type, self.result.types.builtins.number)) {
                    try self.report(index.span, "Type Error: индекс массива должен быть числом", .{});
                }
                break :blk element;
            },
            .map => |map| blk: {
                if (!self.assignable(index_type, map.key)) try self.report(index.span, "Type Error: ключ соответствия имеет неверный тип", .{});
                break :blk map.value;
            },
            else => blk: {
                try self.report(index.span, "Type Error: индексирование поддержано только для строки, массива и соответствия", .{});
                break :blk try self.result.types.poison();
            },
        };
    }

    fn inferProperty(self: *Checker, expression: ast.ExprId, property: anytype) anyerror!types.TypeId {
        if (self.resolution.expr_symbols.get(expression)) |symbol| {
            if (self.resolution.symbols.get(symbol)) |entry| {
                if (entry.kind == .enum_variant) return self.nominalType(entry.owner_type, &.{});
                if (entry.kind == .type) return self.nominalType(symbol, &.{});
                if (self.result.unsupported_imports.contains(symbol)) {
                    try self.report(property.span, "Type Error: импортированный экспорт '{s}' использует пока неподдерживаемый тип", .{entry.name});
                    return self.result.types.poison();
                }
            }
            if (self.result.symbol_types.get(symbol)) |typ| return typ;
        }
        const object_type = try self.infer(property.object);
        if (self.isType(object_type, self.result.types.builtins.error_value)) {
            if (std.mem.eql(u8, property.property, "код") or std.mem.eql(u8, property.property, "сообщение")) return self.result.types.builtins.string;
        }
        const object = self.result.types.get(object_type) orelse return self.result.types.poison();
        switch (object.*) {
            .tuple => |elements| if (tuplePropertyIndex(property.property)) |index| {
                if (index < elements.len) return elements[index];
            },
            .nominal => |nominal| if (try self.fieldsForNominal(nominal)) |fields| {
                for (fields) |field| {
                    if (std.mem.eql(u8, field.name, property.property)) return field.typ;
                }
            },
            else => {},
        }
        try self.report(property.span, "Type Error: у типа нет поля '{s}'", .{property.property});
        return self.result.types.poison();
    }

    fn inferLambda(self: *Checker, expression: ast.ExprId, lambda: anytype, expected: ?types.TypeId) anyerror!types.TypeId {
        var parameter_types: std.ArrayList(types.TypeId) = .empty;
        defer parameter_types.deinit(self.result.allocator);
        var return_type = self.result.types.builtins.void;
        if (expected) |expected_type| {
            const signature = self.result.types.get(expected_type) orelse return self.result.types.poison();
            switch (signature.*) {
                .function => |function| {
                    if (lambda.parameters.len != function.parameters.len) {
                        try self.report(lambda.span, "Type Error: лямбда имеет неверное количество параметров", .{});
                    }
                    for (lambda.parameters, 0..) |parameter, index| {
                        if (index < function.parameters.len) {
                            try parameter_types.append(self.result.allocator, function.parameters[index]);
                        } else {
                            try parameter_types.append(self.result.allocator, try self.result.types.poison());
                        }
                        if (parameter.type_annotation) |annotation| {
                            const declared = try self.resolveType(annotation);
                            if (!self.assignable(declared, parameter_types.items[index])) try self.report(parameter.span, "Type Error: параметр лямбды не совпадает с ожидаемым типом", .{});
                        }
                    }
                    return_type = function.return_type;
                },
                else => {
                    try self.report(lambda.span, "Type Error: лямбда ожидает тип функции", .{});
                    return self.result.types.poison();
                },
            }
        } else {
            for (lambda.parameters) |parameter| {
                try parameter_types.append(self.result.allocator, if (parameter.type_annotation) |annotation| try self.resolveType(annotation) else try self.result.types.poison());
            }
            return_type = if (lambda.return_type) |annotation| try self.resolveType(annotation) else try self.result.types.poison();
        }

        const parameter_symbols = self.resolution.lambda_parameters.get(expression) orelse &.{};
        for (parameter_symbols, parameter_types.items) |symbol, parameter_type| try self.result.symbol_types.put(symbol, parameter_type);
        const previous_return = self.current_return;
        self.current_return = return_type;
        defer self.current_return = previous_return;
        // Mirrors `checkFunction`'s OWN void-return exemption exactly — a
        // real gap found auditing panosiki's `std/слог.ps`: an ordinary
        // `функ ... -> Пусто ... конец` whose last statement is a non-void
        // expression (its value simply discarded) has ALWAYS been allowed
        // (`checkFunction` skips the assignability check entirely when
        // the declared return type is `Пусто`), but a LAMBDA with the
        // exact same shape (`функ(x) -> Пусто ... конец`) unconditionally
        // required an exact type match, rejecting the identical pattern.
        const expected_body = if (self.isType(return_type, self.result.types.builtins.void)) null else return_type;
        const body_type = try self.inferBlockExpected(lambda.body, expected_body, false);
        if (!self.isType(return_type, self.result.types.builtins.void) and !self.assignable(body_type, return_type)) {
            try self.report(lambda.span, "Type Error: тело лямбды не совпадает с типом возврата", .{});
        }
        return self.result.types.function(parameter_types.items, return_type);
    }

    fn inferUnary(self: *Checker, unary: anytype) anyerror!types.TypeId {
        const operand = try self.infer(unary.operand);
        return switch (unary.operator) {
            .negate => blk: {
                if (!self.isType(operand, self.result.types.builtins.boolean)) try self.report(unary.span, "Type Error: оператор 'не' ожидает Булево", .{});
                break :blk self.result.types.builtins.boolean;
            },
            .tilde => blk: {
                if (!self.isType(operand, self.result.types.builtins.integer)) try self.report(unary.span, "Type Error: оператор '~' ожидает Целое", .{});
                break :blk self.result.types.builtins.integer;
            },
            .minus => blk: {
                if (!self.isNumeric(operand)) {
                    try self.report(unary.span, "Type Error: унарный '-' ожидает число", .{});
                    break :blk try self.result.types.poison();
                }
                break :blk operand;
            },
            else => operand,
        };
    }

    fn inferBinary(self: *Checker, binary: anytype) anyerror!types.TypeId {
        var left = try self.infer(binary.left);
        var right = try self.infer(binary.right);
        left = try self.narrowIntegerLiteral(binary.left, left, right);
        right = try self.narrowIntegerLiteral(binary.right, right, left);
        return switch (binary.operator) {
            .assign => blk: {
                try self.checkAssignmentTarget(binary.left, binary.span);
                if (!self.assignable(right, left)) try self.report(binary.span, "Type Error: присваивание несовместимых типов", .{});
                break :blk self.result.types.builtins.void;
            },
            .equal, .not_equal => blk: {
                if (!self.isPoison(left) and !self.isPoison(right) and !self.result.types.eql(left, right)) {
                    try self.report(binary.span, "Type Error: оператор сравнения ожидает значения одного типа", .{});
                }
                break :blk self.result.types.builtins.boolean;
            },
            .less, .less_equal, .greater, .greater_equal => blk: {
                const comparable = self.isComparableGeneric(left) and self.result.types.eql(left, right);
                if (!self.isPoison(left) and !self.isPoison(right) and !comparable and (!self.isNumeric(left) or !self.isNumeric(right) or !self.result.types.eql(left, right))) {
                    try self.report(binary.span, "Type Error: оператор сравнения ожидает два числа одного типа", .{});
                }
                break :blk self.result.types.builtins.boolean;
            },
            .and_expr, .or_expr => blk: {
                if (!self.isPoison(left) and !self.isPoison(right) and (!self.isType(left, self.result.types.builtins.boolean) or !self.isType(right, self.result.types.builtins.boolean))) {
                    try self.report(binary.span, "Type Error: логический оператор ожидает два значения Булево", .{});
                }
                break :blk self.result.types.builtins.boolean;
            },
            .plus => blk: {
                if (self.isType(left, self.result.types.builtins.string) and self.isType(right, self.result.types.builtins.string)) break :blk self.result.types.builtins.string;
                if (self.isPoison(left) or self.isPoison(right)) break :blk try self.result.types.poison();
                if (!self.isNumeric(left) or !self.isNumeric(right) or !self.result.types.eql(left, right)) {
                    try self.report(binary.span, "Type Error: оператор '+' ожидает два числа одного типа или две строки", .{});
                    break :blk try self.result.types.poison();
                }
                break :blk left;
            },
            .minus, .star, .slash => blk: {
                if (self.isPoison(left) or self.isPoison(right)) break :blk try self.result.types.poison();
                if (!self.isNumeric(left) or !self.isNumeric(right) or !self.result.types.eql(left, right)) {
                    try self.report(binary.span, "Type Error: арифметический оператор ожидает два числа одного типа", .{});
                    break :blk try self.result.types.poison();
                }
                break :blk left;
            },
            .percent, .ampersand, .pipe, .caret, .less_less, .greater_greater => blk: {
                if (self.isPoison(left) or self.isPoison(right)) break :blk try self.result.types.poison();
                if (!self.isType(left, self.result.types.builtins.integer) or !self.isType(right, self.result.types.builtins.integer)) {
                    try self.report(binary.span, "Type Error: целочисленный оператор ожидает два значения Целое", .{});
                    break :blk try self.result.types.poison();
                }
                break :blk self.result.types.builtins.integer;
            },
            else => try self.result.types.poison(),
        };
    }

    fn narrowIntegerLiteral(self: *Checker, expression: ast.ExprId, inferred: types.TypeId, other: types.TypeId) !types.TypeId {
        if (self.isType(inferred, self.result.types.builtins.number) and self.isType(other, self.result.types.builtins.integer)) {
            return self.inferExpected(expression, self.result.types.builtins.integer);
        }
        return inferred;
    }

    fn checkAssignmentTarget(self: *Checker, expression: ast.ExprId, span: source.Span) !void {
        switch (self.tree.expr(expression).*) {
            .ident => {
                const symbol = self.resolution.expr_symbols.get(expression) orelse return;
                const entry = self.resolution.symbols.get(symbol) orelse return;
                if (entry.kind == .constant or entry.is_const) {
                    try self.report(span, "Type Error: нельзя присваивать константе", .{});
                } else if (entry.kind != .variable) {
                    try self.report(span, "Type Error: присваивание возможно только переменной, полю или индексу", .{});
                }
            },
            .property => {},
            .index => |index| {
                const object_type = try self.infer(index.object);
                const object = self.result.types.get(object_type) orelse return;
                switch (object.*) {
                    .array, .map => {},
                    else => try self.report(span, "Type Error: присваивание по индексу возможно только массиву или соответствию", .{}),
                }
            },
            else => try self.report(span, "Type Error: присваивание возможно только переменной, полю или индексу", .{}),
        }
    }

    fn isType(self: *const Checker, actual: types.TypeId, expected: types.TypeId) bool {
        return self.result.types.eql(actual, expected);
    }

    fn isNumeric(self: *const Checker, type_id: types.TypeId) bool {
        return self.isType(type_id, self.result.types.builtins.number) or self.isType(type_id, self.result.types.builtins.integer);
    }

    fn isComparableGeneric(self: *const Checker, type_id: types.TypeId) bool {
        for (self.current_generic_parameters) |parameter| {
            if (!parameter.typ.eql(type_id)) continue;
            for (parameter.bounds) |bound| {
                if (self.isComparableInterface(bound)) return true;
            }
        }
        return false;
    }

    // Broadened to also match `.unconstrained` — every EXISTING caller
    // of `isPoison` uses it to mean "no real type info here, skip
    // further constraint checking" (error-recovery AND the deliberate-
    // permissive-generic case both qualify equally for that). Keeping
    // that behavior identical for both variants is intentional — this
    // pass only makes the two DISTINGUISHABLE in the type representation
    // itself (`types.zig`'s `Type.unconstrained`), it does not change
    // when either one is treated as "unconstrained" for checking
    // purposes. Use `isUnconstrained` below when the distinction itself
    // (not just "skip checking") actually matters.
    fn isPoison(self: *const Checker, type_id: types.TypeId) bool {
        const entry = self.result.types.get(type_id) orelse return false;
        return entry.* == .poison or entry.* == .unconstrained;
    }

    fn isUnconstrained(self: *const Checker, type_id: types.TypeId) bool {
        const entry = self.result.types.get(type_id) orelse return false;
        return entry.* == .unconstrained;
    }

    fn isNever(self: *const Checker, type_id: types.TypeId) bool {
        return self.isType(type_id, self.result.types.builtins.never);
    }

    fn isErrorConstructor(self: *const Checker, symbol: symbols.SymbolId) bool {
        const entry = self.resolution.symbols.get(symbol) orelse return false;
        return entry.kind == .builtin and std.mem.eql(u8, entry.name, "Ошибка");
    }

    fn isLengthBuiltin(self: *const Checker, symbol: symbols.SymbolId) bool {
        const entry = self.resolution.symbols.get(symbol) orelse return false;
        return entry.kind == .builtin and std.mem.eql(u8, entry.name, "длина");
    }

    fn isPanicBuiltin(self: *const Checker, symbol: symbols.SymbolId) bool {
        const entry = self.resolution.symbols.get(symbol) orelse return false;
        return entry.kind == .builtin and std.mem.eql(u8, entry.name, "паника");
    }

    fn isBuiltin(self: *const Checker, symbol: symbols.SymbolId, name: []const u8) bool {
        const entry = self.resolution.symbols.get(symbol) orelse return false;
        return entry.kind == .builtin and std.mem.eql(u8, entry.name, name);
    }

    fn isBuiltinModule(self: *const Checker, symbol: symbols.SymbolId, module: []const u8, name: []const u8) bool {
        const entry = self.resolution.symbols.get(symbol) orelse return false;
        return entry.kind == .builtin and entry.module_path != null and std.mem.eql(u8, entry.module_path.?, module) and std.mem.eql(u8, entry.name, name);
    }

    // `Результат(value_type, Ошибка)` for a native builtin that can fail —
    // `Результат` is prelude-provided (hardcoded for direct pipelines,
    // real-and-imported once a graph merges the embedded prelude, see
    // `zig/core/prelude.zig`); `nominalType` picks the right identity for
    // either case.
    fn resultOfString(self: *Checker, value_type: types.TypeId) ?types.TypeId {
        const result_symbol = self.findTypeSymbol("Результат") orelse return null;
        return self.nominalType(result_symbol, &.{ value_type, self.result.types.builtins.error_value }) catch null;
    }

    // `Опция(value_type)` — symmetric to `resultOfString` above, for native
    // builtins whose "failure" is absence rather than an `Ошибка` (`ос.
    // окружение`, matching Odin's `stdlib_option_type`).
    fn optionOf(self: *Checker, value_type: types.TypeId) ?types.TypeId {
        const option_symbol = self.findTypeSymbol("Опция") orelse return null;
        return self.nominalType(option_symbol, &.{value_type}) catch null;
    }

    fn rejectUnavailableBuiltin(self: *Checker, callee: ast.ExprId, span: source.Span) !bool {
        const symbol = self.resolution.expr_symbols.get(callee) orelse return false;
        const entry = self.resolution.symbols.get(symbol) orelse return false;
        if (entry.kind != .builtin) return false;
        const name = if (entry.module_path) |module|
            try std.fmt.allocPrint(self.result.arena.allocator(), "{s}::{s}", .{ module, entry.name })
        else
            entry.name;
        if (target_policy.builtinAvailableForTarget(name, self.target_profile)) return false;
        _ = try self.result.diagnostics.appendUnique(self.result.allocator, .{
            .phase = .type_checker,
            .severity = .err,
            .span = span,
            .message = try target_policy.typeErrorMessage(self.result.arena.allocator(), name, self.target_profile),
        });
        return true;
    }

    fn inferCall(self: *Checker, expression: ast.ExprId, call: anytype) anyerror!types.TypeId {
        return self.inferCallExpected(expression, call, null);
    }

    // `expected_return` — non-null only when this call is the value of an
    // expression with a KNOWN expected type (currently: the right-hand
    // side of an annotated `пер`, via `inferExpected`'s `.call` case).
    // Used to seed generic substitutions from the function's RETURN type
    // before falling back to argument-only inference — the bidirectional
    // half `funcё[T](x: Строка) -> Тип(T)` needs when `T` never appears in
    // any parameter. Real gap found auditing panosiki: `Тип(T)` could
    // ONLY ever be inferred from arguments, so a type parameter used
    // solely in the return position silently degraded to `poison` even
    // when the caller had explicitly written the expected type
    // (`пер к: Коробка(Число) = новая_коробка("x")`) right there — this
    // is exactly the caller-provided context that should have resolved
    // it. Deliberately does NOT attempt full Hindley-Milner unification
    // (no cross-statement/deferred inference) — only this one caller-
    // adjacent context.
    fn inferCallExpected(self: *Checker, expression: ast.ExprId, call: anytype, expected_return: ?types.TypeId) anyerror!types.TypeId {
        if (try self.rejectUnavailableBuiltin(call.callee, call.span)) {
            for (call.arguments) |argument| _ = try self.infer(argument);
            return self.result.types.poison();
        }
        if (self.resolution.expr_symbols.get(call.callee)) |symbol| {
            if (self.enumVariant(symbol)) |variant| return self.inferEnumVariantCall(call, variant);
            if (self.isErrorConstructor(symbol)) {
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: Ошибка ожидает 2 аргумент(а)", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.error_value;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: Ошибка ожидает строки кода и сообщения", .{});
                    }
                }
                return self.result.types.builtins.error_value;
            }
            if (self.isBuiltin(symbol, "Целое") or self.isBuiltin(symbol, "Число")) {
                const is_integer = self.isBuiltin(symbol, "Целое");
                const target_type = if (is_integer) self.result.types.builtins.integer else self.result.types.builtins.number;
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: {s}(x) ожидает 1 аргумент", .{if (is_integer) "Целое" else "Число"});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return target_type;
                }
                const argument_type = try self.infer(call.arguments[0]);
                if (!self.isType(argument_type, self.result.types.builtins.integer) and !self.isType(argument_type, self.result.types.builtins.number)) {
                    try self.report(call.span, "Type Error: {s}(x) ожидает Число или Целое", .{if (is_integer) "Целое" else "Число"});
                }
                return target_type;
            }
            if (self.isBuiltin(symbol, "встроку")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: встроку(x) ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                _ = try self.infer(call.arguments[0]);
                return self.result.types.builtins.string;
            }
            if (self.isPanicBuiltin(symbol)) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: паника ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.never;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: паника ожидает строку", .{});
                }
                return self.result.types.builtins.never;
            }
            if (self.isBuiltinModule(symbol, "фс", "есть")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: фс.есть() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.boolean;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: фс.есть() ожидает путь типа Строка", .{});
                }
                return self.result.types.builtins.boolean;
            }
            if (self.isBuiltinModule(symbol, "фс", "удалить")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: фс.удалить() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.boolean;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: фс.удалить() ожидает путь типа Строка", .{});
                }
                return self.result.types.builtins.boolean;
            }
            if (self.isBuiltinModule(symbol, "фс", "прочитать")) {
                const result_type = self.resultOfString(self.result.types.builtins.string) orelse return self.result.types.poison();
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: фс.прочитать() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: фс.прочитать() ожидает путь типа Строка", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "фс", "записать")) {
                const result_type = self.resultOfString(self.result.types.builtins.number) orelse return self.result.types.poison();
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: фс.записать() ожидает 2 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: фс.записать() ожидает путь и содержимое типа Строка", .{});
                    }
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "фс", "открыть")) {
                const file_symbol = self.findTypeSymbol("Файл") orelse return self.result.types.poison();
                const file_type = try self.nominalType(file_symbol, &.{});
                const result_type = self.resultOfString(file_type) orelse return self.result.types.poison();
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: фс.открыть() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: фс.открыть() ожидает путь типа Строка", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "фс", "это_директория")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: фс.это_директория() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.boolean;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: фс.это_директория() ожидает путь типа Строка", .{});
                }
                return self.result.types.builtins.boolean;
            }
            if (self.isBuiltinModule(symbol, "фс", "создать_директорию")) {
                const result_type = self.resultOfString(self.result.types.builtins.number) orelse return self.result.types.poison();
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: фс.создать_директорию() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: фс.создать_директорию() ожидает путь типа Строка", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "фс", "список_директории")) {
                const array_type = try self.result.types.array(self.result.types.builtins.string);
                const result_type = self.resultOfString(array_type) orelse return self.result.types.poison();
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: фс.список_директории() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: фс.список_директории() ожидает путь типа Строка", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "фс", "удалить_директорию")) {
                const result_type = self.resultOfString(self.result.types.builtins.number) orelse return self.result.types.poison();
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: фс.удалить_директорию() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: фс.удалить_директорию() ожидает путь типа Строка", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "ос", "аргументы")) {
                if (call.arguments.len != 0) try self.report(call.span, "Type Error: ос.аргументы() не принимает аргументы", .{});
                for (call.arguments) |argument| _ = try self.infer(argument);
                return self.result.types.array(self.result.types.builtins.string);
            }
            if (self.isBuiltinModule(symbol, "ос", "версия_паноса")) {
                if (call.arguments.len != 0) try self.report(call.span, "Type Error: ос.версия_паноса() не принимает аргументы", .{});
                for (call.arguments) |argument| _ = try self.infer(argument);
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "ос", "окружение")) {
                const option_type = self.optionOf(self.result.types.builtins.string) orelse return self.result.types.poison();
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: ос.окружение() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return option_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: ос.окружение() ожидает имя переменной типа Строка", .{});
                }
                return option_type;
            }
            if (self.isBuiltinModule(symbol, "ос", "установить_окружение")) {
                const result_type = self.resultOfString(self.result.types.builtins.number) orelse return self.result.types.poison();
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: ос.установить_окружение() ожидает 2 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: ос.установить_окружение() ожидает имя и значение типа Строка", .{});
                    }
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "ос", "удалить_окружение")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: ос.удалить_окружение() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.boolean;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: ос.удалить_окружение() ожидает имя переменной типа Строка", .{});
                }
                return self.result.types.builtins.boolean;
            }
            if (self.isBuiltinModule(symbol, "ос", "выполнить")) {
                // (код_завершения, stdout, stderr) — плоский tuple, тот же
                // паттерн, что и у Odin (`builtin_export_type`, `core/
                // stdlib.odin`): core-builtin возвращает сырые данные,
                // именованная обёртка (если понадобится) — задача panos-
                // уровня, не системы типов.
                const exec_tuple = try self.result.types.tuple(&.{ self.result.types.builtins.number, self.result.types.builtins.string, self.result.types.builtins.string });
                const result_type = self.resultOfString(exec_tuple) orelse return self.result.types.poison();
                if (call.arguments.len != 3) {
                    try self.report(call.span, "Type Error: ос.выполнить() ожидает 3 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: ос.выполнить() ожидает программу типа Строка первым аргументом", .{});
                }
                const args_array = try self.result.types.array(self.result.types.builtins.string);
                if (!self.assignable(try self.inferExpected(call.arguments[1], args_array), args_array)) {
                    try self.report(call.span, "Type Error: ос.выполнить() ожидает Массив(Строка) вторым аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[2], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: ос.выполнить() ожидает рабочую директорию типа Строка третьим аргументом", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "ос", "завершить")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: ос.завершить() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.never;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.number), self.result.types.builtins.number)) {
                    try self.report(call.span, "Type Error: ос.завершить() ожидает код завершения типа Число", .{});
                }
                return self.result.types.builtins.never;
            }
            if (self.isBuiltinModule(symbol, "время", "сейчас_мс")) {
                if (call.arguments.len != 0) try self.report(call.span, "Type Error: время.сейчас_мс() не принимает аргументы", .{});
                for (call.arguments) |argument| _ = try self.infer(argument);
                return self.result.types.builtins.number;
            }
            if (self.isBuiltinModule(symbol, "время", "монотонно_мс")) {
                if (call.arguments.len != 0) try self.report(call.span, "Type Error: время.монотонно_мс() не принимает аргументы", .{});
                for (call.arguments) |argument| _ = try self.infer(argument);
                return self.result.types.builtins.number;
            }
            if (self.isBuiltinModule(symbol, "время", "спать_мс")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: время.спать_мс() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.number;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.number), self.result.types.builtins.number)) {
                    try self.report(call.span, "Type Error: время.спать_мс() ожидает миллисекунды типа Число", .{});
                }
                return self.result.types.builtins.number;
            }
            if (self.isBuiltinModule(symbol, "DOM", "текст")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: DOM.текст() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.number;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: DOM.текст() ожидает CSS-селектор типа Строка", .{});
                }
                return self.result.types.builtins.number;
            }
            if (self.isBuiltinModule(symbol, "DOM", "установить_текст")) {
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: DOM.установить_текст() ожидает 2 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.void;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: DOM.установить_текст() ожидает CSS-селектор типа Строка первым аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[1], self.result.types.builtins.number), self.result.types.builtins.number)) {
                    try self.report(call.span, "Type Error: DOM.установить_текст() ожидает значение типа Число вторым аргументом", .{});
                }
                return self.result.types.builtins.void;
            }
            if (self.isBuiltinModule(symbol, "DOM", "на_клик")) {
                if (call.arguments.len != 2 and call.arguments.len != 3) {
                    try self.report(call.span, "Type Error: DOM.на_клик() ожидает 2 или 3 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.void;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: DOM.на_клик() ожидает селектор, имя обработчика и необязательный контекст типа Строка", .{});
                    }
                }
                return self.result.types.builtins.void;
            }
            if (self.isBuiltinModule(symbol, "DOM", "текст_строка") or self.isBuiltinModule(symbol, "DOM", "значение_поля")) {
                const name = if (self.isBuiltinModule(symbol, "DOM", "текст_строка")) "текст_строка" else "значение_поля";
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: DOM.{s}() ожидает 1 аргумент", .{name});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: DOM.{s}() ожидает CSS-селектор типа Строка", .{name});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "DOM", "установить_текст_строка") or self.isBuiltinModule(symbol, "DOM", "установить_значение_поля")) {
                const name = if (self.isBuiltinModule(symbol, "DOM", "установить_текст_строка")) "установить_текст_строка" else "установить_значение_поля";
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: DOM.{s}() ожидает 2 аргумента", .{name});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.void;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: DOM.{s}() ожидает селектор и значение типа Строка", .{name});
                    }
                }
                return self.result.types.builtins.void;
            }
            if (self.isBuiltinModule(symbol, "DOM", "создать_и_добавить")) {
                if (call.arguments.len != 3) {
                    try self.report(call.span, "Type Error: DOM.создать_и_добавить() ожидает 3 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.void;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: DOM.создать_и_добавить() ожидает родительский CSS-селектор, тег и id типа Строка", .{});
                    }
                }
                return self.result.types.builtins.void;
            }
            if (self.isBuiltinModule(symbol, "DOM", "после_кадра")) {
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: DOM.после_кадра() ожидает имя обработчика и контекст", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.void;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: DOM.после_кадра() ожидает имя обработчика и контекст типа Строка", .{});
                    }
                }
                return self.result.types.builtins.void;
            }
            if (self.isBuiltinModule(symbol, "ввод_вывод", "печать") or self.isBuiltinModule(symbol, "ввод_вывод", "строка")) {
                const name = if (self.isBuiltinModule(symbol, "ввод_вывод", "печать")) "печать" else "строка";
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: ввод_вывод.{s}() ожидает 1 аргумент", .{name});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.void;
                }
                // "любой тип" — no assignability check, unlike every other
                // builtin here: `.печать`/`.строка` accept literally
                // anything (renders via `vm.zig`'s `renderRuntimeValue`,
                // a structural dump for compound values — Печатаемое-
                // interface dispatch, mentioned in the docs as the
                // preferred path when implemented, is NOT wired up yet,
                // a separate follow-up).
                _ = try self.infer(call.arguments[0]);
                return self.result.types.builtins.void;
            }
            if (self.isBuiltinModule(symbol, "ввод_вывод", "прочитать_строку")) {
                if (call.arguments.len != 0) {
                    try self.report(call.span, "Type Error: ввод_вывод.прочитать_строку() не принимает аргументов", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                }
                // `Результат(Строка, Ошибка)`, NOT `Опция(Строка)` — real
                // usage found auditing panosiki's `cli-selector`
                // (`строка_ввода.ошибка()`/`.значение()`): EOF is
                // reported as a real `Неудача(Ошибка(...))`, matching
                // every OTHER native I/O builtin that can fail
                // (`фс.прочитать`, `сеть.http_запрос`, ...), not the
                // `Опция` shape this was first (wrongly) modeled after.
                const result_symbol = self.findTypeSymbol("Результат") orelse return self.result.types.poison();
                return self.nominalType(result_symbol, &.{ self.result.types.builtins.string, self.result.types.builtins.error_value });
            }
            if (self.isBuiltinModule(symbol, "строки", "байт")) {
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: строки.байт() ожидает 2 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.integer;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: строки.байт() ожидает строку первым аргументом", .{});
                }
                if (!self.isNumeric(try self.infer(call.arguments[1]))) {
                    try self.report(call.span, "Type Error: строки.байт() ожидает индекс-число вторым аргументом", .{});
                }
                return self.result.types.builtins.integer;
            }
            if (self.isBuiltinModule(symbol, "строки", "длина_байт")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: строки.длина_байт() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.integer;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: строки.длина_байт() ожидает строку", .{});
                }
                return self.result.types.builtins.integer;
            }
            if (self.isBuiltinModule(symbol, "строки", "срез_байт")) {
                if (call.arguments.len != 3) {
                    try self.report(call.span, "Type Error: строки.срез_байт() ожидает 3 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: строки.срез_байт() ожидает строку первым аргументом", .{});
                }
                for (call.arguments[1..3]) |argument| {
                    if (!self.isNumeric(try self.infer(argument))) {
                        try self.report(call.span, "Type Error: строки.срез_байт() ожидает границы-числа", .{});
                    }
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "строки", "из_байтов")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: строки.из_байтов() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                const array_type = try self.result.types.array(self.result.types.builtins.integer);
                if (!self.assignable(try self.inferExpected(call.arguments[0], array_type), array_type)) {
                    try self.report(call.span, "Type Error: строки.из_байтов() ожидает Массив(Целое)", .{});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "строки", "в_число")) {
                const result_type = self.resultOfString(self.result.types.builtins.number) orelse return self.result.types.poison();
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: строки.в_число() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: строки.в_число() ожидает строку", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "строки", "из_числа")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: строки.из_числа() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.number), self.result.types.builtins.number)) {
                    try self.report(call.span, "Type Error: строки.из_числа() ожидает Число", .{});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "строки", "из_целого")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: строки.из_целого() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.integer), self.result.types.builtins.integer)) {
                    try self.report(call.span, "Type Error: строки.из_целого() ожидает Целое", .{});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "строки", "верхний_регистр") or self.isBuiltinModule(symbol, "строки", "нижний_регистр") or self.isBuiltinModule(symbol, "строки", "обрезать")) {
                const name = if (self.isBuiltinModule(symbol, "строки", "верхний_регистр"))
                    "верхний_регистр"
                else if (self.isBuiltinModule(symbol, "строки", "нижний_регистр"))
                    "нижний_регистр"
                else
                    "обрезать";
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: строки.{s}() ожидает 1 аргумент", .{name});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: строки.{s}() ожидает строку", .{name});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "строки", "цифра_или_буква")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: строки.цифра_или_буква() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.boolean;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: строки.цифра_или_буква() ожидает строку", .{});
                }
                return self.result.types.builtins.boolean;
            }
            if (self.isBuiltinModule(symbol, "строки", "это_буква") or self.isBuiltinModule(symbol, "строки", "это_цифра")) {
                const name = if (self.isBuiltinModule(symbol, "строки", "это_буква")) "это_буква" else "это_цифра";
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: строки.{s}() ожидает 1 аргумент", .{name});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.boolean;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: строки.{s}() ожидает строку", .{name});
                }
                return self.result.types.builtins.boolean;
            }
            if (self.isBuiltinModule(symbol, "строки", "заканчивается_на") or
                self.isBuiltinModule(symbol, "строки", "начинается_с") or
                self.isBuiltinModule(symbol, "строки", "содержит"))
            {
                const name = if (self.isBuiltinModule(symbol, "строки", "заканчивается_на"))
                    "заканчивается_на"
                else if (self.isBuiltinModule(symbol, "строки", "начинается_с"))
                    "начинается_с"
                else
                    "содержит";
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: строки.{s}() ожидает 2 аргумента", .{name});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.boolean;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: строки.{s}() ожидает строки", .{name});
                    }
                }
                return self.result.types.builtins.boolean;
            }
            if (self.isBuiltinModule(symbol, "строки", "найти")) {
                // (s, подстрока, начало: Целое) -> Целое (-1, если не
                // найдено) — matches every REAL caller found auditing
                // panosiki (`gitrunner/git.ps`, `std/флаги.ps`, both
                // `строки.найти(s, "=", 0)` compared against `-1`
                // directly), not the `Опция(Целое)`/2-argument shape
                // invented here originally with no real caller to check
                // against.
                if (call.arguments.len != 3) {
                    try self.report(call.span, "Type Error: строки.найти() ожидает 3 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.integer;
                }
                for (call.arguments[0..2]) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: строки.найти() ожидает строки первым и вторым аргументом", .{});
                    }
                }
                if (!self.isNumeric(try self.infer(call.arguments[2]))) {
                    try self.report(call.span, "Type Error: строки.найти() ожидает начальный индекс-число третьим аргументом", .{});
                }
                return self.result.types.builtins.integer;
            }
            if (self.isBuiltinModule(symbol, "строки", "заменить")) {
                if (call.arguments.len != 3) {
                    try self.report(call.span, "Type Error: строки.заменить() ожидает 3 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: строки.заменить() ожидает строки", .{});
                    }
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "строки", "срез")) {
                if (call.arguments.len != 3) {
                    try self.report(call.span, "Type Error: строки.срез() ожидает 3 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: строки.срез() ожидает строку первым аргументом", .{});
                }
                for (call.arguments[1..3]) |argument| {
                    if (!self.isNumeric(try self.infer(argument))) {
                        try self.report(call.span, "Type Error: строки.срез() ожидает границы-числа", .{});
                    }
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "строки", "разбить")) {
                const array_type = try self.result.types.array(self.result.types.builtins.string);
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: строки.разбить() ожидает 2 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return array_type;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: строки.разбить() ожидает строки", .{});
                    }
                }
                return array_type;
            }
            if (self.isBuiltinModule(symbol, "строки", "соединить")) {
                const array_type = try self.result.types.array(self.result.types.builtins.string);
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: строки.соединить() ожидает 2 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], array_type), array_type)) {
                    try self.report(call.span, "Type Error: строки.соединить() ожидает Массив(Строка) первым аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[1], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: строки.соединить() ожидает разделитель типа Строка", .{});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "сжатие", "разжать_gzip")) {
                const result_type = self.resultOfString(self.result.types.builtins.string) orelse return self.result.types.poison();
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: сжатие.разжать_gzip() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: сжатие.разжать_gzip() ожидает Строку", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "синтаксис", "структуры")) {
                const array_type = try self.result.types.array(self.result.types.builtins.string);
                const result_type = self.resultOfString(array_type) orelse return self.result.types.poison();
                return self.checkStringArgsBuiltin(call, "синтаксис.структуры", 1, result_type);
            }
            if (self.isBuiltinModule(symbol, "синтаксис", "поля")) {
                const field_pair = try self.result.types.tuple(&.{ self.result.types.builtins.string, self.result.types.builtins.string });
                const array_type = try self.result.types.array(field_pair);
                const result_type = self.resultOfString(array_type) orelse return self.result.types.poison();
                return self.checkStringArgsBuiltin(call, "синтаксис.поля", 2, result_type);
            }
            if (self.isBuiltinModule(symbol, "синтаксис", "аннотации")) {
                const array_type = try self.result.types.array(self.result.types.builtins.string);
                const result_type = self.resultOfString(array_type) orelse return self.result.types.poison();
                return self.checkStringArgsBuiltin(call, "синтаксис.аннотации", 2, result_type);
            }
            if (self.isBuiltinModule(symbol, "синтаксис", "аргумент_аннотации")) {
                const option_type = self.optionOf(self.result.types.builtins.string) orelse return self.result.types.poison();
                const result_type = self.resultOfString(option_type) orelse return self.result.types.poison();
                return self.checkStringArgsBuiltin(call, "синтаксис.аргумент_аннотации", 3, result_type);
            }
            if (self.isBuiltinModule(symbol, "синтаксис", "аннотации_поля")) {
                const array_type = try self.result.types.array(self.result.types.builtins.string);
                const result_type = self.resultOfString(array_type) orelse return self.result.types.poison();
                return self.checkStringArgsBuiltin(call, "синтаксис.аннотации_поля", 3, result_type);
            }
            if (self.isBuiltinModule(symbol, "синтаксис", "аргумент_аннотации_поля")) {
                const option_type = self.optionOf(self.result.types.builtins.string) orelse return self.result.types.poison();
                const result_type = self.resultOfString(option_type) orelse return self.result.types.poison();
                return self.checkStringArgsBuiltin(call, "синтаксис.аргумент_аннотации_поля", 4, result_type);
            }
            if (self.isBuiltinModule(symbol, "сеть", "подключиться")) {
                const connection_symbol = self.findTypeSymbol("Соединение") orelse return self.result.types.poison();
                const connection_type = try self.nominalType(connection_symbol, &.{});
                const result_type = self.resultOfString(connection_type) orelse return self.result.types.poison();
                if (call.arguments.len != 2) {
                    try self.report(call.span, "Type Error: сеть.подключиться() ожидает 2 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: сеть.подключиться() ожидает хост типа Строка первым аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[1], self.result.types.builtins.number), self.result.types.builtins.number)) {
                    try self.report(call.span, "Type Error: сеть.подключиться() ожидает порт типа Число вторым аргументом", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "сеть", "кодировать_url")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: сеть.кодировать_url() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: сеть.кодировать_url() ожидает Строку", .{});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "сеть", "декодировать_url")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: сеть.декодировать_url() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.string;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: сеть.декодировать_url() ожидает Строку", .{});
                }
                return self.result.types.builtins.string;
            }
            if (self.isBuiltinModule(symbol, "сеть", "http_запрос")) {
                // (статус, заголовки, тело) — плоский tuple, тот же
                // паттерн, что и у `ос.выполнить`: сырые данные, не
                // именованная структура (см. Odin's `core/stdlib.odin`
                // комментарий про `сеть::http_запрос`).
                const pair_type = try self.result.types.tuple(&.{ self.result.types.builtins.string, self.result.types.builtins.string });
                const headers_array = try self.result.types.array(pair_type);
                const success_type = try self.result.types.tuple(&.{ self.result.types.builtins.integer, headers_array, self.result.types.builtins.string });
                const result_type = self.resultOfString(success_type) orelse return self.result.types.poison();
                if (call.arguments.len != 4) {
                    try self.report(call.span, "Type Error: сеть.http_запрос() ожидает 4 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: сеть.http_запрос() ожидает метод типа Строка первым аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[1], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: сеть.http_запрос() ожидает url типа Строка вторым аргументом", .{});
                }
                if (!self.assignable(try self.inferExpected(call.arguments[2], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: сеть.http_запрос() ожидает тело типа Строка третьим аргументом", .{});
                }
                const headers_map_type = try self.result.types.map(self.result.types.builtins.string, self.result.types.builtins.string);
                if (!self.assignable(try self.inferExpected(call.arguments[3], headers_map_type), headers_map_type)) {
                    try self.report(call.span, "Type Error: сеть.http_запрос() ожидает Соответствие(Строка, Строка) четвёртым аргументом", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "сеть", "http_запрос_sync")) {
                const option_type = self.optionOf(self.result.types.builtins.string) orelse return self.result.types.poison();
                if (call.arguments.len != 3) {
                    try self.report(call.span, "Type Error: сеть.http_запрос_sync() ожидает 3 аргумента", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return option_type;
                }
                for (call.arguments) |argument| {
                    if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: сеть.http_запрос_sync() ожидает метод, url и тело типа Строка", .{});
                    }
                }
                return option_type;
            }
            if (self.isBuiltinModule(symbol, "сеть", "http_сервер_слушать")) {
                const listener_symbol = self.findTypeSymbol("Слушатель") orelse return self.result.types.poison();
                const listener_type = try self.nominalType(listener_symbol, &.{});
                const result_type = self.resultOfString(listener_type) orelse return self.result.types.poison();
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: сеть.http_сервер_слушать() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.number), self.result.types.builtins.number)) {
                    try self.report(call.span, "Type Error: сеть.http_сервер_слушать() ожидает порт типа Число", .{});
                }
                return result_type;
            }
            if (self.isBuiltinModule(symbol, "бд", "открыть")) {
                const connection_symbol = self.findTypeSymbol("Соединение_БД") orelse return self.result.types.poison();
                const connection_type = try self.nominalType(connection_symbol, &.{});
                const result_type = self.resultOfString(connection_type) orelse return self.result.types.poison();
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: бд.открыть() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return result_type;
                }
                if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: бд.открыть() ожидает путь типа Строка", .{});
                }
                return result_type;
            }
            if (self.isBuiltin(symbol, "получить")) {
                if (call.arguments.len != 0) try self.report(call.span, "Type Error: получить() не принимает аргументы", .{});
                for (call.arguments) |argument| _ = try self.infer(argument);
                return self.result.types.poison();
            }
            if (self.isBuiltin(symbol, "себя")) {
                if (call.arguments.len != 0) try self.report(call.span, "Type Error: себя() не принимает аргументы", .{});
                for (call.arguments) |argument| _ = try self.infer(argument);
                return self.result.types.process(try self.result.types.poison());
            }
            if (self.isBuiltin(symbol, "убить")) {
                if (call.arguments.len != 1) try self.report(call.span, "Type Error: убить() ожидает 1 аргумент", .{});
                for (call.arguments, 0..) |argument, index| {
                    const argument_type = try self.infer(argument);
                    if (index != 0) continue;
                    const argument_entry = self.result.types.get(argument_type) orelse continue;
                    switch (argument_entry.*) {
                        .process, .poison => {},
                        else => try self.report(call.span, "Type Error: убить() ожидает Процесс(T) первым аргументом", .{}),
                    }
                }
                return self.result.types.builtins.void;
            }
            if (self.isBuiltin(symbol, "связать")) {
                if (call.arguments.len != 1) try self.report(call.span, "Type Error: связать() ожидает 1 аргумент", .{});
                for (call.arguments, 0..) |argument, index| {
                    const argument_type = try self.infer(argument);
                    if (index != 0) continue;
                    const argument_entry = self.result.types.get(argument_type) orelse continue;
                    switch (argument_entry.*) {
                        .process, .poison => {},
                        else => try self.report(call.span, "Type Error: связать() ожидает Процесс(T) первым аргументом", .{}),
                    }
                }
                return self.result.types.builtins.void;
            }
            if (self.isBuiltin(symbol, "отправить")) {
                if (call.arguments.len != 2) try self.report(call.span, "Type Error: отправить() ожидает 2 аргумент(а)", .{});
                for (call.arguments) |argument| _ = try self.infer(argument);
                return self.result.types.builtins.void;
            }
            if (self.isBuiltin(symbol, "наблюдать")) {
                if (call.arguments.len != 1) try self.report(call.span, "Type Error: наблюдать() ожидает 1 аргумент", .{});
                for (call.arguments) |argument| _ = try self.infer(argument);
                return self.result.types.builtins.void;
            }
            if (self.isBuiltin(symbol, "ждать")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: ждать() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.poison();
                }
                const argument_type = try self.infer(call.arguments[0]);
                const argument_entry = self.result.types.get(argument_type) orelse return self.result.types.poison();
                const result_type = switch (argument_entry.*) {
                    .process => |value_type| value_type,
                    .poison => return self.result.types.poison(),
                    else => blk: {
                        try self.report(call.span, "Type Error: ждать() ожидает Процесс(T) первым аргументом", .{});
                        break :blk try self.result.types.poison();
                    },
                };
                return self.resultOfString(result_type) orelse self.result.types.poison();
            }
            if (self.isBuiltin(symbol, "получить_сигнал")) {
                if (call.arguments.len != 0) try self.report(call.span, "Type Error: получить_сигнал() не принимает аргументы", .{});
                for (call.arguments) |argument| _ = try self.infer(argument);
                const option = self.findTypeSymbol("Опция") orelse return self.result.types.poison();
                const reason = try self.result.types.nominal(option, &.{self.result.types.builtins.string});
                return self.result.types.tuple(&.{ self.result.types.builtins.number, reason });
            }
            if (self.isBuiltin(symbol, "ограничить_почту")) {
                if (call.arguments.len != 1) try self.report(call.span, "Type Error: ограничить_почту() ожидает 1 аргумент", .{});
                for (call.arguments) |argument| _ = try self.infer(argument);
                return self.result.types.builtins.void;
            }
            if (self.isBuiltin(symbol, "отправить_или")) {
                if (call.arguments.len != 2) try self.report(call.span, "Type Error: отправить_или() ожидает 2 аргумент(а)", .{});
                for (call.arguments) |argument| _ = try self.infer(argument);
                return self.resultOfString(self.result.types.builtins.void) orelse self.result.types.poison();
            }
            if (self.isBuiltin(symbol, "отмена")) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: отмена() ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.void;
                }
                const argument_type = try self.infer(call.arguments[0]);
                const argument_entry = self.result.types.get(argument_type) orelse return self.result.types.builtins.void;
                switch (argument_entry.*) {
                    .process, .poison => {},
                    else => try self.report(call.span, "Type Error: отмена() ожидает Процесс(T) первым аргументом", .{}),
                }
                return self.result.types.builtins.void;
            }
            if (self.isBuiltin(symbol, "отменено")) {
                if (call.arguments.len != 0) try self.report(call.span, "Type Error: отменено() не принимает аргументы", .{});
                for (call.arguments) |argument| _ = try self.infer(argument);
                return self.result.types.builtins.boolean;
            }
            if (self.isLengthBuiltin(symbol)) {
                if (call.arguments.len != 1) {
                    try self.report(call.span, "Type Error: длина ожидает 1 аргумент", .{});
                    for (call.arguments) |argument| _ = try self.infer(argument);
                    return self.result.types.builtins.integer;
                }
                const argument_type = try self.infer(call.arguments[0]);
                const argument = self.result.types.get(argument_type) orelse return self.result.types.poison();
                switch (argument.*) {
                    .primitive => |primitive| if (primitive == .string) return self.result.types.builtins.integer,
                    .array, .map => return self.result.types.builtins.integer,
                    .poison => return argument_type,
                    else => {},
                }
                try self.report(call.span, "Type Error: длина ожидает строку, массив или соответствие", .{});
                return self.result.types.poison();
            }
        }
        switch (self.tree.expr(call.callee).*) {
            .property => |property| {
                const object_type = try self.infer(property.object);
                if (try self.inferProcessMethod(call, property, object_type)) |method_type| return method_type;
                if (try self.inferPreludeEnumMethod(call, property, object_type)) |method_type| return method_type;
                if (try self.inferInterfaceCall(expression, call, property, object_type)) |method_type| return method_type;
                if (try self.inferGenericBoundInterfaceCall(expression, call, property, object_type)) |method_type| return method_type;
                if (try self.inferMethodCall(expression, call, property, object_type)) |method_type| return method_type;
                const object = self.result.types.get(object_type) orelse return self.result.types.poison();
                switch (object.*) {
                    .array => |element| {
                        if (std.mem.eql(u8, property.property, "длина")) {
                            try self.checkMethodArity(call, "длина", 0);
                            return self.result.types.builtins.integer;
                        }
                        if (std.mem.eql(u8, property.property, "есть")) {
                            try self.checkMethodArity(call, "есть", 1);
                            if (call.arguments.len != 0) {
                                const index = try self.infer(call.arguments[0]);
                                if (!self.isNumeric(index)) try self.report(call.span, "Type Error: индекс массива должен быть числом", .{});
                            }
                            return self.result.types.builtins.boolean;
                        }
                        if (std.mem.eql(u8, property.property, "получить")) {
                            try self.checkMethodArity(call, "получить", 2);
                            if (call.arguments.len != 0) {
                                const index = try self.infer(call.arguments[0]);
                                if (!self.isNumeric(index)) try self.report(call.span, "Type Error: индекс массива должен быть числом", .{});
                            }
                            if (call.arguments.len > 1 and !self.assignable(try self.inferExpected(call.arguments[1], element), element)) {
                                try self.report(call.span, "Type Error: значение по умолчанию имеет неверный тип", .{});
                            }
                            return element;
                        }
                        if (std.mem.eql(u8, property.property, "добавить")) {
                            try self.checkMethodArity(call, "добавить", 1);
                            if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], element), element)) {
                                try self.report(call.span, "Type Error: элемент массива имеет неверный тип", .{});
                            }
                            return self.result.types.builtins.void;
                        }
                        if (std.mem.eql(u8, property.property, "содержит")) {
                            try self.checkMethodArity(call, "содержит", 1);
                            if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], element), element)) {
                                try self.report(call.span, "Type Error: элемент массива имеет неверный тип", .{});
                            }
                            return self.result.types.builtins.boolean;
                        }
                        if (std.mem.eql(u8, property.property, "срез")) {
                            try self.checkMethodArity(call, "срез", 2);
                            for (call.arguments) |argument| {
                                if (!self.isNumeric(try self.infer(argument))) {
                                    try self.report(call.span, "Type Error: .срез() ожидает границы-числа", .{});
                                }
                            }
                            return object_type;
                        }
                    },
                    .primitive => |primitive| {
                        // `Строка` had no `.длина()` at all — only the free
                        // function `длина(x)` worked on strings (Массив/
                        // Соответствие have BOTH), a confusing asymmetry
                        // (`Type Error: у типа нет поля 'длина'` reads like
                        // a typo, not "use the free function instead").
                        // Same `.string_length`/`строки::длина` runtime
                        // path the free function already uses — no VM
                        // change, purely a dispatch gap.
                        if (primitive == .string and std.mem.eql(u8, property.property, "длина")) {
                            try self.checkMethodArity(call, "длина", 0);
                            return self.result.types.builtins.integer;
                        }
                    },
                    .map => |map| {
                        if (std.mem.eql(u8, property.property, "длина")) {
                            try self.checkMethodArity(call, "длина", 0);
                            return self.result.types.builtins.integer;
                        }
                        if (std.mem.eql(u8, property.property, "есть")) {
                            try self.checkMethodArity(call, "есть", 1);
                            if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], map.key), map.key)) {
                                try self.report(call.span, "Type Error: ключ соответствия имеет неверный тип", .{});
                            }
                            return self.result.types.builtins.boolean;
                        }
                        if (std.mem.eql(u8, property.property, "получить")) {
                            try self.checkMethodArity(call, "получить", 2);
                            if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], map.key), map.key)) {
                                try self.report(call.span, "Type Error: ключ соответствия имеет неверный тип", .{});
                            }
                            if (call.arguments.len > 1 and !self.assignable(try self.inferExpected(call.arguments[1], map.value), map.value)) {
                                try self.report(call.span, "Type Error: значение по умолчанию имеет неверный тип", .{});
                            }
                            return map.value;
                        }
                        if (std.mem.eql(u8, property.property, "записи")) {
                            try self.checkMethodArity(call, "записи", 0);
                            const entry = try self.result.types.tuple(&.{ map.key, map.value });
                            return self.result.types.array(entry);
                        }
                        if (std.mem.eql(u8, property.property, "удалить")) {
                            try self.checkMethodArity(call, "удалить", 1);
                            if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], map.key), map.key)) {
                                try self.report(call.span, "Type Error: ключ соответствия имеет неверный тип", .{});
                            }
                            return self.result.types.builtins.boolean;
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
        const callee_type = try self.infer(call.callee);
        const entry = self.result.types.get(callee_type) orelse return self.result.types.poison();
        switch (entry.*) {
            .function => |function| {
                const callee_symbol = self.resolution.expr_symbols.get(call.callee);
                const arguments = if (call.argument_names) |_| blk: {
                    const symbol = callee_symbol orelse {
                        try self.report(call.span, "Type Error: именованные аргументы не поддержаны для этого вызова", .{});
                        break :blk call.arguments;
                    };
                    const parameter_names = (try self.functionParameterNames(symbol)) orelse {
                        try self.report(call.span, "Type Error: именованные аргументы не поддержаны для этого вызова", .{});
                        break :blk call.arguments;
                    };
                    break :blk try self.reorderNamedArguments(expression, call, parameter_names);
                } else call.arguments;
                if (arguments.len != function.parameters.len) try self.report(call.span, "Type Error: неверное количество аргументов функции", .{});
                const shared = @min(arguments.len, function.parameters.len);
                const generic_parameters: []const GenericParameter = if (callee_symbol) |symbol|
                    self.result.generic_function_parameters.get(symbol) orelse &.{}
                else
                    &.{};
                if (generic_parameters.len != 0) {
                    var substitutions = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
                    defer substitutions.deinit();
                    // Seed from the caller's KNOWN expected type FIRST
                    // (bidirectional half) — see `inferCallExpected`'s doc
                    // comment. Structural unification against
                    // `function.return_type`, same mechanism argument
                    // inference already uses, just walked in the other
                    // direction (parameter shape = return type, argument
                    // shape = the caller's expected type).
                    if (expected_return) |expected_type| {
                        try self.inferGenericSubstitution(function.return_type, expected_type, &substitutions, call.span);
                    }
                    for (arguments[0..shared], function.parameters[0..shared]) |argument, parameter| {
                        try self.inferGenericSubstitution(parameter, try self.infer(argument), &substitutions, call.span);
                    }
                    // A type parameter that appears ONLY in the RETURN
                    // type (never in any parameter) can't be inferred
                    // from the call's arguments alone — the seeding step
                    // above handles the case where the CALLER provided an
                    // expected type; if that's ALSO absent, there is
                    // truly no context anywhere to resolve it from (panos
                    // has no cross-statement/deferred inference and no
                    // explicit generic type-argument call syntax).
                    // Silently substituting `poison` in that fully-
                    // unconstrained case (not reporting an error) is NOT
                    // a new leniency — real gap found the hard way:
                    // before cross-module generic function signatures
                    // started tracking `T` for real (see
                    // `ImportedSymbolType.generic_parameters`), EVERY
                    // such call already got exactly this behavior by
                    // accident (`copyImportedType` degraded any
                    // unremapped `.generic_parameter` to `poison` on
                    // import, unconditionally). Panosiki code —
                    // `выборка.новый_селектор(...)` (`cli-selector`),
                    // i.e. `функ ф[T](x: Строка) -> Тип(T)` called with NO
                    // annotation anywhere, T only ever pinned down later
                    // through USAGE — depends on this exact fallback.
                    // But when `expected_return` WAS available and
                    // substitution STILL failed (the seeding step above
                    // ran and didn't resolve every parameter), that's a
                    // genuine inference failure, not an absence-of-
                    // context case — report it instead of poisoning
                    // silently, matching the "no unconstrained T out of
                    // thin air when context exists" soundness goal.
                    for (generic_parameters) |parameter| {
                        if (substitutions.contains(parameter.typ)) continue;
                        if (expected_return != null) {
                            try self.report(call.span, "Type Error: не удалось вывести type-параметр '{s}'", .{parameter.name});
                            try substitutions.put(parameter.typ, try self.result.types.poison());
                        } else {
                            try substitutions.put(parameter.typ, try self.result.types.unconstrained());
                        }
                    }
                    for (generic_parameters) |parameter| {
                        // The fill-loop right above guarantees every
                        // `generic_parameters` entry has a substitution
                        // by now (found from context, or explicitly
                        // poison-filled) — `orelse` here would mean that
                        // guarantee broke silently; make it loud instead.
                        const actual = substitutions.get(parameter.typ) orelse unreachable;
                        if (self.isPoison(actual)) continue;
                        for (parameter.bounds) |bound| {
                            if (!self.satisfiesInterfaceBound(actual, bound)) {
                                const interface = self.resolution.symbols.get(bound) orelse continue;
                                try self.report(call.span, "Type Error: тип аргумента не реализует ограничение '{s}'", .{interface.name});
                            }
                        }
                    }
                    for (arguments[0..shared], function.parameters[0..shared]) |argument, parameter| {
                        const expected = try self.substituteGeneric(parameter, &substitutions);
                        const actual = try self.inferExpected(argument, expected);
                        if (!self.assignable(actual, expected)) {
                            try self.report(call.span, "Type Error: аргумент не совпадает с типом параметра", .{});
                        } else if (try self.genericInterfaceBounds(parameter, generic_parameters)) |bounds| {
                            // Generic function whose parameter is bound by
                            // a user-defined interface (`функ ф[T: ИзTOML]
                            // (это: T, ...)`), called with a concrete
                            // struct argument. Panos generic functions are
                            // NOT monomorphized (compiled once, generically
                            // — no per-call-site specialization exists at
                            // all), so `это.метод()` inside the generic
                            // body has no concrete type to dispatch
                            // against; the ONLY mechanism this VM has for
                            // dispatching a method call without knowing
                            // the concrete type at compile time is the
                            // existing interface vtable (`Cast_Interface`/
                            // `Invoke_Interface`). Casting the ARGUMENT to
                            // the bound interface type here (instead of to
                            // `expected`, which — since substitution
                            // resolves T to the argument's OWN concrete
                            // type — is always a same-type no-op cast) is
                            // what makes that dispatch possible: the value
                            // actually entering the generic function's `T`
                            // parameter slot is the interface-wrapped
                            // runtime representation, so `inferMethodCall`'s
                            // sibling handling for `.generic_parameter`
                            // receiver types (see `interfaceBoundOf`/
                            // `inferInterfaceCall`) can compile `это.метод()`
                            // as an ordinary `call_interface` against that
                            // same vtable — no monomorphization needed.
                            try self.registerGenericInterfaceCasts(argument, actual, bounds);
                        } else {
                            try self.registerInterfaceCast(argument, actual, expected);
                        }
                    }
                    return self.substituteGeneric(function.return_type, &substitutions);
                }
                for (arguments[0..shared], function.parameters[0..shared]) |argument, parameter| {
                    const actual = try self.inferExpected(argument, parameter);
                    if (!self.assignable(actual, parameter)) {
                        try self.report(call.span, "Type Error: аргумент не совпадает с типом параметра", .{});
                    } else {
                        try self.registerInterfaceCast(argument, actual, parameter);
                    }
                }
                return function.return_type;
            },
            .nominal => |nominal| {
                if (self.result.generic_nominal_fields.get(nominal.symbol)) |generic_nominal| {
                    // Named-argument constructor calls (`Тип(поле = x,
                    // ...)`) were NEVER reordered here — every field got
                    // checked in DECLARATION order regardless of what
                    // order the CALLER actually wrote them in. Real gap
                    // found auditing panosiki's `cli` package
                    // (`Конфигурация(флаги = ..., действие = Опция.
                    // Нет(), ...)`, field order in the call not matching
                    // declaration order): `Опция.Нет()` got checked
                    // against an unrelated field's type, so its own
                    // generic `T` could never be inferred ("не удалось
                    // вывести type-параметр 'T'"). Same
                    // `reorderNamedArguments`/`call_arguments` cache a
                    // regular named-argument FUNCTION call already used
                    // above — `compiler.zig`'s `compileCall` already
                    // reads that SAME cache for codegen, so fixing the
                    // order here is enough for both type-checking AND
                    // codegen.
                    const arguments = if (call.argument_names) |_| blk: {
                        const names = try self.result.arena.allocator().alloc([]const u8, generic_nominal.fields.len);
                        for (generic_nominal.fields, names) |field, *name| name.* = field.name;
                        break :blk try self.reorderNamedArguments(expression, call, names);
                    } else call.arguments;
                    if (arguments.len != generic_nominal.fields.len) try self.report(call.span, "Type Error: неверное количество аргументов конструктора структуры", .{});
                    const shared = @min(arguments.len, generic_nominal.fields.len);
                    var substitutions = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
                    defer substitutions.deinit();
                    for (arguments[0..shared], generic_nominal.fields[0..shared]) |argument, field| {
                        try self.inferGenericSubstitution(field.typ, try self.infer(argument), &substitutions, call.span);
                    }
                    var type_arguments: std.ArrayList(types.TypeId) = .empty;
                    defer type_arguments.deinit(self.result.allocator);
                    for (generic_nominal.parameters) |parameter| {
                        if (substitutions.get(parameter.typ)) |argument| {
                            try type_arguments.append(self.result.allocator, argument);
                        } else {
                            try self.report(call.span, "Type Error: не удалось вывести type-параметр '{s}'", .{parameter.name});
                            try type_arguments.append(self.result.allocator, try self.result.types.poison());
                        }
                    }
                    const constructor_type = try self.nominalType(nominal.symbol, type_arguments.items);
                    for (arguments[0..shared], generic_nominal.fields[0..shared]) |argument, field| {
                        const expected = try self.substituteGeneric(field.typ, &substitutions);
                        const actual = try self.inferExpected(argument, expected);
                        if (!self.assignable(actual, expected)) {
                            try self.report(call.span, "Type Error: аргумент конструктора не совпадает с типом поля", .{});
                        } else {
                            try self.registerInterfaceCast(argument, actual, expected);
                        }
                    }
                    return constructor_type;
                }
                if (self.result.nominal_fields.get(nominal.symbol)) |fields| {
                    const arguments = if (call.argument_names) |_| blk: {
                        const names = try self.result.arena.allocator().alloc([]const u8, fields.len);
                        for (fields, names) |field, *name| name.* = field.name;
                        break :blk try self.reorderNamedArguments(expression, call, names);
                    } else call.arguments;
                    if (arguments.len != fields.len) try self.report(call.span, "Type Error: неверное количество аргументов конструктора структуры", .{});
                    const shared = @min(arguments.len, fields.len);
                    for (arguments[0..shared], fields[0..shared]) |argument, field| {
                        // `registerInterfaceCast` — real gap found
                        // auditing panosiki: every OTHER argument-check
                        // site (return, method call, enum variant) already
                        // calls this on success; a plain struct
                        // constructor never did, so `Держатель(слог.
                        // логгер())` (a field typed `слог.Логгер`, an
                        // interface, given a concrete `СтандартныйЛоггер`)
                        // stored the raw concrete value uncast — calling
                        // `.инфо(...)` on that field later crashed at
                        // runtime ("попытка вызвать интерфейсный метод у
                        // не-интерфейса") since the compiler had no cast
                        // recorded to compile a real `Cast_Interface`.
                        const actual = try self.inferExpected(argument, field.typ);
                        if (!self.assignable(actual, field.typ)) {
                            try self.report(call.span, "Type Error: аргумент конструктора не совпадает с типом поля", .{});
                        } else {
                            try self.registerInterfaceCast(argument, actual, field.typ);
                        }
                    }
                    return callee_type;
                }
                try self.report(call.span, "Type Error: вызвано значение, не являющееся функцией", .{});
                return self.result.types.poison();
            },
            else => {
                try self.report(call.span, "Type Error: вызвано значение, не являющееся функцией", .{});
                return self.result.types.poison();
            },
        }
    }

    fn checkMethodArity(self: *Checker, call: anytype, name: []const u8, expected: usize) !void {
        if (call.arguments.len == expected) return;
        try self.report(call.span, "Type Error: метод '{s}' ожидает {d} аргумент(а)", .{ name, expected });
        for (call.arguments) |argument| _ = try self.infer(argument);
    }

    // Shared arity+all-Строка-arguments check for `синтаксис.*` (2-4
    // plain `Строка` path/name arguments, no per-argument distinctions
    // worth spelling out individually — unlike `ос.выполнить`, which
    // mixes `Строка`/`Массив(Строка)`).
    fn checkStringArgsBuiltin(self: *Checker, call: anytype, name: []const u8, expected_arity: usize, result_type: types.TypeId) !types.TypeId {
        if (call.arguments.len != expected_arity) {
            try self.report(call.span, "Type Error: {s}() ожидает {d} аргумент(а)", .{ name, expected_arity });
            for (call.arguments) |argument| _ = try self.infer(argument);
            return result_type;
        }
        for (call.arguments) |argument| {
            if (!self.assignable(try self.inferExpected(argument, self.result.types.builtins.string), self.result.types.builtins.string)) {
                try self.report(call.span, "Type Error: {s}() ожидает аргументы типа Строка", .{name});
            }
        }
        return result_type;
    }

    fn functionParameterNames(self: *Checker, symbol: symbols.SymbolId) !?[]const []const u8 {
        if (self.result.imported_method_parameter_names.get(symbol)) |names| return names;
        var functions = self.resolution.function_parameters.iterator();
        while (functions.next()) |entry| {
            const declaration = entry.key_ptr.*;
            const function_symbol = self.resolution.decl_symbols.get(declaration) orelse continue;
            if (function_symbol != symbol) continue;
            const parameters = entry.value_ptr.*;
            const names = try self.result.arena.allocator().alloc([]const u8, parameters.len);
            for (parameters, names) |parameter, *name| name.* = self.resolution.symbols.get(parameter).?.name;
            return names;
        }
        return null;
    }

    fn reorderNamedArguments(self: *Checker, expression: ast.ExprId, call: anytype, parameter_names: []const []const u8) ![]const ast.ExprId {
        const argument_names = call.argument_names orelse return call.arguments;
        if (argument_names.len != parameter_names.len) {
            try self.report(call.span, "Type Error: ожидалось {d} именованных аргументов, получено {d}", .{ parameter_names.len, argument_names.len });
            return call.arguments;
        }
        const ordered = try self.result.arena.allocator().alloc(ast.ExprId, argument_names.len);
        const matched = try self.result.allocator.alloc(bool, parameter_names.len);
        defer self.result.allocator.free(matched);
        @memset(matched, false);
        var valid = true;
        for (argument_names, call.arguments) |argument_name, argument| {
            var parameter_index: ?usize = null;
            for (parameter_names, 0..) |parameter_name, index| {
                if (std.mem.eql(u8, argument_name, parameter_name)) {
                    parameter_index = index;
                    break;
                }
            }
            const index = parameter_index orelse {
                try self.report(call.span, "Type Error: неизвестный именованный аргумент '{s}'", .{argument_name});
                valid = false;
                continue;
            };
            if (matched[index]) {
                try self.report(call.span, "Type Error: именованный аргумент '{s}' указан повторно", .{argument_name});
                valid = false;
                continue;
            }
            matched[index] = true;
            ordered[index] = argument;
        }
        if (!valid) return call.arguments;
        try self.result.call_arguments.put(expression, ordered);
        return ordered;
    }

    fn resolveType(self: *Checker, type_node: ast.TypeId) !types.TypeId {
        return switch (self.tree.typeNode(type_node).*) {
            .ident => |ident| self.findGenericParameter(ident.name) orelse builtinType(&self.result.types, ident.name) orelse blk: {
                if (self.findTypeSymbol(ident.name)) |symbol| {
                    if (self.result.alias_type_nodes.contains(symbol)) break :blk try self.resolveAlias(symbol, ident.span);
                    if (self.current_nominal_owner) |owner| {
                        if (owner.symbol == symbol) {
                            var arguments: std.ArrayList(types.TypeId) = .empty;
                            defer arguments.deinit(self.result.allocator);
                            for (owner.parameters) |parameter| try arguments.append(self.result.allocator, parameter.typ);
                            break :blk try self.result.types.nominal(symbol, arguments.items);
                        }
                    }
                    break :blk try self.nominalType(symbol, &.{});
                }
                try self.report(ident.span, "Type Error: неизвестный тип '{s}'", .{ident.name});
                break :blk try self.result.types.poison();
            },
            .generic => |generic| blk: {
                if (std.mem.eql(u8, generic.name, "Массив") and generic.parameters.len == 1) break :blk try self.result.types.array(try self.resolveType(generic.parameters[0]));
                if (std.mem.eql(u8, generic.name, "Соответствие") and generic.parameters.len == 2) break :blk try self.result.types.map(try self.resolveType(generic.parameters[0]), try self.resolveType(generic.parameters[1]));
                if (std.mem.eql(u8, generic.name, "Процесс") and generic.parameters.len == 1) break :blk try self.result.types.process(try self.resolveType(generic.parameters[0]));
                if (self.findTypeSymbol(generic.name)) |symbol| {
                    var arguments: std.ArrayList(types.TypeId) = .empty;
                    defer arguments.deinit(self.result.allocator);
                    for (generic.parameters) |parameter| try arguments.append(self.result.allocator, try self.resolveType(parameter));
                    break :blk try self.nominalType(symbol, arguments.items);
                }
                try self.report(generic.span, "Type Error: неизвестный generic-тип '{s}'", .{generic.name});
                break :blk try self.result.types.poison();
            },
            .tuple => |tuple| blk: {
                var elements: std.ArrayList(types.TypeId) = .empty;
                defer elements.deinit(self.result.allocator);
                for (tuple.elements) |element| try elements.append(self.result.allocator, try self.resolveType(element));
                break :blk try self.result.types.tuple(elements.items);
            },
            .function => |function| blk: {
                var parameters: std.ArrayList(types.TypeId) = .empty;
                defer parameters.deinit(self.result.allocator);
                for (function.parameters) |parameter| try parameters.append(self.result.allocator, try self.resolveType(parameter));
                break :blk try self.result.types.function(parameters.items, try self.resolveType(function.return_type));
            },
            .qualified => |qualified| blk: {
                const symbol = self.findQualifiedTypeSymbol(qualified.module_name, qualified.name) orelse {
                    try self.report(qualified.span, "Type Error: неизвестный тип '{s}.{s}'", .{ qualified.module_name, qualified.name });
                    break :blk try self.result.types.poison();
                };
                var arguments: std.ArrayList(types.TypeId) = .empty;
                defer arguments.deinit(self.result.allocator);
                for (qualified.parameters) |parameter| try arguments.append(self.result.allocator, try self.resolveType(parameter));
                break :blk try self.nominalType(symbol, arguments.items);
            },
            else => try self.result.types.poison(),
        };
    }

    // Returns the FIRST interface bound of `parameter`, if `parameter`
    // (as written in the declaration, before generic substitution) is a
    // `.generic_parameter` type with at least one interface bound.
    // "first" — real usage in practice (`std/кодирование/toml.ps`'s
    // `[T: ИзTOML]`/`[T: ВTOML]`) never declares more than one bound per
    // parameter; a value can only be `Cast_Interface`'d to ONE interface
    // type at a time anyway (see `registerInterfaceCast`'s single
    // `interface_casts` entry per expression), so multiple bounds would
    // need a genuinely different mechanism this doesn't attempt.
    fn interfaceBoundOf(self: *const Checker, parameter: types.TypeId, generic_parameters: []const GenericParameter) !?symbols.SymbolId {
        const entry = self.result.types.get(parameter) orelse return null;
        if (entry.* != .generic_parameter) return null;
        for (generic_parameters) |candidate| {
            if (!candidate.typ.eql(parameter)) continue;
            for (candidate.bounds) |bound| {
                // `Сравниваемое` is deliberately EXCLUDED here — it has
                // its own, older, non-vtable dispatch mechanism for
                // generic-bound comparisons (`compiler.zig`'s
                // `registerComparableMethods`/`addComparableMethod`,
                // driven by the VM looking up a method by the runtime
                // value's OWN struct name, not by an interface vtable).
                // That mechanism requires the value to arrive at the
                // generic function PLAIN (uncast) — an ordinary Число or
                // an ordinary struct aggregate — so casting it to the
                // interface type here (turning it into an
                // interface-wrapped runtime value) would break `a > b`
                // dispatch for every existing `[T: Сравниваемое]` caller.
                // Every OTHER user-defined interface bound has no such
                // pre-existing mechanism, so casting is the only way
                // `это.метод()` inside the generic body can dispatch at
                // all (see `inferGenericBoundInterfaceCall`).
                if (self.isComparableInterface(bound)) continue;
                return bound;
            }
            return null;
        }
        return null;
    }

    fn genericInterfaceBounds(self: *const Checker, parameter: types.TypeId, generic_parameters: []const GenericParameter) !?[]const symbols.SymbolId {
        const entry = self.result.types.get(parameter) orelse return null;
        if (entry.* != .generic_parameter) return null;
        for (generic_parameters) |candidate| {
            if (!candidate.typ.eql(parameter)) continue;
            var count: usize = 0;
            for (candidate.bounds) |bound| {
                if (!self.isComparableInterface(bound)) count += 1;
            }
            if (count == 0) return null;
            const result = try self.result.arena.allocator().alloc(symbols.SymbolId, count);
            var index: usize = 0;
            for (candidate.bounds) |bound| {
                if (self.isComparableInterface(bound)) continue;
                result[index] = bound;
                index += 1;
            }
            return result;
        }
        return null;
    }

    fn nominalType(self: *Checker, symbol: symbols.SymbolId, arguments: []const types.TypeId) !types.TypeId {
        if (self.result.imported_nominal_identities.get(symbol)) |identity| {
            return self.result.types.nominalWithIdentity(symbol, identity, arguments);
        }
        return self.result.types.nominal(symbol, arguments);
    }

    fn assignable(self: *const Checker, actual: types.TypeId, expected: types.TypeId) bool {
        const actual_type = self.result.types.get(actual) orelse return false;
        const expected_type = self.result.types.get(expected) orelse return false;
        if (actual_type.* == .poison or expected_type.* == .poison) return true;
        if (actual_type.* == .unconstrained or expected_type.* == .unconstrained) return true;
        if (actual.eql(self.result.types.builtins.never)) return true;
        if (actual_type.* == .process and self.isPoison(actual_type.process)) return true;
        if (self.result.types.eql(actual, expected)) return true;
        // An EMPTY array/map literal (`массив()`/`соответствие()`) infers
        // as `Массив(poison)`/`Соответствие(poison, poison)` (`inferBinary`'s
        // `.array`/`.map` cases have no elements to infer a real type
        // from) — `eql` above already rejects that against any concretely
        // -typed array/map (poison isn't structurally equal to anything),
        // so a completely ordinary `это.поле = массив()` (reset a typed
        // field/variable to empty) failed "присваивание несовместимых
        // типов", a real gap found auditing panosiki's `std/tempfiles.ps`.
        // Recursing through `assignable` itself (not `eql`) lets the
        // top-of-function poison short-circuit fire for the ELEMENT type.
        switch (actual_type.*) {
            .array => |actual_element| switch (expected_type.*) {
                .array => |expected_element| return self.assignable(actual_element, expected_element),
                else => {},
            },
            .map => |actual_map| switch (expected_type.*) {
                .map => |expected_map| return self.assignable(actual_map.key, expected_map.key) and self.assignable(actual_map.value, expected_map.value),
                else => {},
            },
            .function => |actual_function| switch (expected_type.*) {
                .function => |expected_function| {
                    if (actual_function.parameters.len != expected_function.parameters.len) return false;
                    for (actual_function.parameters, expected_function.parameters) |actual_parameter, expected_parameter| {
                        if (!self.isPoison(actual_parameter) and !self.isPoison(expected_parameter) and !self.result.types.eql(actual_parameter, expected_parameter)) return false;
                    }
                    return self.isPoison(actual_function.return_type) or self.isPoison(expected_function.return_type) or
                        self.result.types.eql(actual_function.return_type, expected_function.return_type) or
                        self.isType(actual_function.return_type, self.result.types.builtins.never);
                },
                else => {},
            },
            else => {},
        }
        const actual_nominal = switch (actual_type.*) {
            .nominal => |value| value,
            else => return false,
        };
        const expected_nominal = switch (expected_type.*) {
            .nominal => |value| value,
            else => return false,
        };
        if (self.result.interface_definitions.get(expected_nominal.symbol)) |interface| {
            if (interface.parameters.len != expected_nominal.arguments.len) return false;
            return self.interfaceImplementation(expected_nominal.symbol, expected_nominal.arguments, actual_nominal.symbol) != null;
        }
        // Same generic struct/enum, argument-wise assignable (not `eql`)
        // type arguments — e.g. `Селектор(poison)` vs the declared
        // `Селектор(T)`. Mirrors the array/map elementwise-assignable
        // recursion just above; real gap found auditing panosiki's
        // `cli-selector` (`функ новый_селектор[T](...) -> Селектор(T)`
        // whose body constructs `Селектор(заголовок, массив())` — the
        // struct's own `T` can't be inferred from an EMPTY array
        // argument, so `fillUnknownWithPoison` substitutes `poison`
        // there; without this case, `eql`'s exact-match requirement
        // rejected `Селектор(poison)` against the declared `Селектор(T)`
        // return type even though `poison` is assignable to/from
        // anything, including `T`).
        const same_declaration = if (actual_nominal.identity != 0 or expected_nominal.identity != 0)
            actual_nominal.identity != 0 and actual_nominal.identity == expected_nominal.identity
        else
            actual_nominal.symbol == expected_nominal.symbol;
        if (same_declaration and actual_nominal.arguments.len == expected_nominal.arguments.len) {
            for (actual_nominal.arguments, expected_nominal.arguments) |actual_argument, expected_argument| {
                if (!self.assignable(actual_argument, expected_argument)) return false;
            }
            return true;
        }
        return false;
    }

    fn findTypeSymbol(self: *const Checker, name: []const u8) ?symbols.SymbolId {
        for (self.resolution.symbols.symbols.items[1..], 1..) |entry, index| {
            if (entry.kind == .type and std.mem.eql(u8, entry.name, name)) return @enumFromInt(index);
        }
        return null;
    }

    fn findQualifiedTypeSymbol(self: *const Checker, module_name: []const u8, name: []const u8) ?symbols.SymbolId {
        for (self.resolution.symbols.symbols.items[1..], 1..) |entry, index| {
            if (entry.kind == .type and entry.module_path != null and std.mem.eql(u8, entry.module_path.?, module_name) and std.mem.eql(u8, entry.name, name)) {
                return @enumFromInt(index);
            }
        }
        return null;
    }

    fn nominalParameters(self: *const Checker, symbol: symbols.SymbolId) []const GenericParameter {
        if (self.result.generic_nominal_fields.get(symbol)) |nominal| return nominal.parameters;
        if (self.result.enum_definitions.get(symbol)) |enumeration| return enumeration.parameters;
        if (self.result.interface_definitions.get(symbol)) |interface| return interface.parameters;
        return &.{};
    }

    fn methodBySymbol(self: *const Checker, symbol: symbols.SymbolId) ?MethodDefinition {
        for (self.result.methods.items) |method| {
            if (method.symbol == symbol) return method;
        }
        return null;
    }

    fn inherentMethod(self: *const Checker, owner: symbols.SymbolId, name: []const u8) ?MethodDefinition {
        for (self.result.methods.items) |method| {
            if (method.owner == owner and std.mem.eql(u8, method.name, name)) return method;
        }
        return null;
    }

    fn interfaceMethod(_: *const Checker, definition: InterfaceDefinition, name: []const u8) ?InterfaceMethod {
        for (definition.methods) |method| {
            if (std.mem.eql(u8, method.name, name)) return method;
        }
        return null;
    }

    fn interfaceImplementation(self: *const Checker, interface: symbols.SymbolId, arguments: []const types.TypeId, target: symbols.SymbolId) ?InterfaceImplementation {
        for (self.result.interface_implementations.items) |implementation| {
            if (implementation.interface != interface or implementation.target != target or implementation.arguments.len != arguments.len) continue;
            for (implementation.arguments, arguments) |actual, expected| {
                if (!self.result.types.eql(actual, expected)) break;
            } else return implementation;
        }
        return null;
    }

    fn isComparableInterface(self: *const Checker, interface: symbols.SymbolId) bool {
        const entry = self.resolution.symbols.get(interface) orelse return false;
        return std.mem.eql(u8, entry.name, "Сравниваемое");
    }

    fn satisfiesInterfaceBound(self: *const Checker, actual: types.TypeId, interface: symbols.SymbolId) bool {
        if (self.isComparableInterface(interface) and self.isNumeric(actual)) return true;
        const actual_entry = self.result.types.get(actual) orelse return false;
        if (actual_entry.* == .generic_parameter) {
            for (self.current_generic_parameters) |parameter| {
                if (!parameter.typ.eql(actual)) continue;
                for (parameter.bounds) |bound| if (bound == interface) return true;
            }
            return false;
        }
        const nominal = switch (actual_entry.*) {
            .nominal => |value| value,
            else => return false,
        };
        return self.interfaceImplementation(interface, &.{}, nominal.symbol) != null;
    }

    fn isImplementableNominal(self: *const Checker, symbol: symbols.SymbolId) bool {
        return self.result.nominal_fields.contains(symbol) or self.result.generic_nominal_fields.contains(symbol) or self.result.enum_definitions.contains(symbol);
    }

    fn registerInterfaceCast(self: *Checker, expression: ast.ExprId, actual: types.TypeId, expected: types.TypeId) !void {
        if (self.result.types.eql(actual, expected)) return;
        const actual_entry = self.result.types.get(actual) orelse return;
        const expected_entry = self.result.types.get(expected) orelse return;
        const actual_nominal = switch (actual_entry.*) {
            .nominal => |value| value,
            else => return,
        };
        const expected_nominal = switch (expected_entry.*) {
            .nominal => |value| value,
            else => return,
        };
        if (!self.result.interface_definitions.contains(expected_nominal.symbol)) return;
        if (self.result.interface_definitions.contains(actual_nominal.symbol)) return;
        if (self.interfaceImplementation(expected_nominal.symbol, expected_nominal.arguments, actual_nominal.symbol) == null) return;
        const entries = try self.result.arena.allocator().dupe(InterfaceCastEntry, &.{.{
            .interface = expected_nominal.symbol,
            .arguments = expected_nominal.arguments,
            .target = actual_nominal.symbol,
        }});
        try self.result.interface_casts.put(expression, .{ .entries = entries });
    }

    fn registerGenericInterfaceCasts(self: *Checker, expression: ast.ExprId, actual: types.TypeId, bounds: []const symbols.SymbolId) !void {
        const actual_entry = self.result.types.get(actual) orelse return;
        const target = switch (actual_entry.*) {
            .nominal => |nominal| nominal.symbol,
            else => return,
        };
        var entries: std.ArrayList(InterfaceCastEntry) = .empty;
        defer entries.deinit(self.result.allocator);
        for (bounds) |bound| {
            if (self.interfaceImplementation(bound, &.{}, target) == null) continue;
            try entries.append(self.result.allocator, .{ .interface = bound, .arguments = &.{}, .target = target });
        }
        if (entries.items.len != 0) try self.result.interface_casts.put(expression, .{ .entries = try self.result.arena.allocator().dupe(InterfaceCastEntry, entries.items) });
    }

    fn inferInterfaceCall(self: *Checker, expression: ast.ExprId, call: anytype, property: anytype, object_type: types.TypeId) !?types.TypeId {
        if (call.argument_names != null) try self.report(call.span, "Type Error: именованные аргументы не поддержаны для интерфейсного вызова", .{});
        const object = self.result.types.get(object_type) orelse return null;
        const nominal = switch (object.*) {
            .nominal => |value| value,
            else => return null,
        };
        const definition = self.result.interface_definitions.get(nominal.symbol) orelse return null;
        if (nominal.arguments.len != definition.parameters.len) {
            try self.report(call.span, "Type Error: неверное количество параметров типа интерфейса", .{});
            return @as(?types.TypeId, try self.result.types.poison());
        }
        var method_index: ?usize = null;
        for (definition.methods, 0..) |method, index| {
            if (std.mem.eql(u8, method.name, property.property)) {
                method_index = index;
                break;
            }
        }
        const index = method_index orelse return null;
        const method = definition.methods[index];
        if (call.arguments.len != method.parameters.len) try self.report(call.span, "Type Error: неверное количество аргументов метода", .{});
        var substitutions = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
        defer substitutions.deinit();
        for (definition.parameters, nominal.arguments) |parameter, argument| try substitutions.put(parameter.typ, argument);
        const shared = @min(call.arguments.len, method.parameters.len);
        for (call.arguments[0..shared], method.parameters[0..shared]) |argument, parameter| {
            const expected = try self.substituteGeneric(parameter, &substitutions);
            const actual = try self.inferExpected(argument, expected);
            if (!self.assignable(actual, expected)) {
                try self.report(call.span, "Type Error: аргумент метода не совпадает с типом параметра", .{});
            } else {
                try self.registerInterfaceCast(argument, actual, expected);
            }
        }
        if (index > std.math.maxInt(u16)) return error.MethodLimitReached;
        try self.result.interface_calls.put(expression, .{
            .interface = nominal.symbol,
            .method_index = @intCast(index),
        });
        return @as(?types.TypeId, try self.substituteGeneric(method.return_type, &substitutions));
    }

    // `это.метод()` where `это`'s static type is a bare GENERIC
    // PARAMETER bound by a user-defined interface (inside the body of a
    // generic function like `функ разобрать_в[T: ИзTOML](это: T, ...)`
    // in `std/кодирование/toml.ps`) — real gap found auditing panosiki's
    // `configor` package. Panos generics are never monomorphized, so
    // there is no concrete type available here to resolve `.метод`
    // against; this compiles the call exactly like `inferInterfaceCall`
    // (an ordinary `call_interface`/vtable dispatch) against whichever
    // bound interface declares the method — safe ONLY because callers
    // are required (see `interfaceBoundOf`, used at every generic
    // function-call site) to have already cast their concrete argument
    // to that SAME interface type before it reaches this parameter, so
    // the runtime value here already carries a real vtable to dispatch
    // through.
    fn inferGenericBoundInterfaceCall(self: *Checker, expression: ast.ExprId, call: anytype, property: anytype, object_type: types.TypeId) !?types.TypeId {
        if (call.argument_names != null) try self.report(call.span, "Type Error: именованные аргументы не поддержаны для интерфейсного вызова", .{});
        const object = self.result.types.get(object_type) orelse return null;
        if (object.* != .generic_parameter) return null;
        var bounds: []const symbols.SymbolId = &.{};
        for (self.current_generic_parameters) |parameter| {
            if (!parameter.typ.eql(object_type)) continue;
            bounds = parameter.bounds;
            break;
        }
        var vtable_index: usize = 0;
        for (bounds) |bound| {
            if (self.isComparableInterface(bound)) continue;
            const definition = self.result.interface_definitions.get(bound) orelse continue;
            var method_index: ?usize = null;
            for (definition.methods, 0..) |method, index| {
                if (std.mem.eql(u8, method.name, property.property)) {
                    method_index = index;
                    break;
                }
            }
            const index = method_index orelse {
                vtable_index += 1;
                continue;
            };
            const method = definition.methods[index];
            if (call.arguments.len != method.parameters.len) try self.report(call.span, "Type Error: неверное количество аргументов метода", .{});
            const shared = @min(call.arguments.len, method.parameters.len);
            for (call.arguments[0..shared], method.parameters[0..shared]) |argument, parameter| {
                const actual = try self.inferExpected(argument, parameter);
                if (!self.assignable(actual, parameter)) {
                    try self.report(call.span, "Type Error: аргумент метода не совпадает с типом параметра", .{});
                } else {
                    try self.registerInterfaceCast(argument, actual, parameter);
                }
            }
            if (index > std.math.maxInt(u16)) return error.MethodLimitReached;
            try self.result.interface_calls.put(expression, .{
                .interface = bound,
                .method_index = @intCast(index),
                .vtable_index = @intCast(vtable_index),
            });
            return @as(?types.TypeId, method.return_type);
        }
        return null;
    }

    fn inferProcessMethod(self: *Checker, call: anytype, property: anytype, object_type: types.TypeId) !?types.TypeId {
        const object = self.result.types.get(object_type) orelse return null;
        if (object.* != .process) return null;
        if (!std.mem.eql(u8, property.property, "номер")) return null;
        try self.checkMethodArity(call, "номер", 0);
        return self.result.types.builtins.number;
    }

    fn inferMethodCall(self: *Checker, expression: ast.ExprId, call: anytype, property: anytype, object_type: types.TypeId) !?types.TypeId {
        const object = self.result.types.get(object_type) orelse return null;
        const nominal = switch (object.*) {
            .nominal => |value| value,
            else => return null,
        };
        const method = self.inherentMethod(nominal.symbol, property.property) orelse return null;
        const signature_id = self.result.symbol_types.get(method.symbol) orelse return null;
        const signature = self.result.types.get(signature_id) orelse return null;
        const function = switch (signature.*) {
            .function => |value| value,
            else => return null,
        };
        if (function.parameters.len == 0) {
            try self.report(call.span, "Type Error: метод '{s}' должен принимать получатель первым параметром", .{property.property});
            return @as(?types.TypeId, try self.result.types.poison());
        }
        const arguments = if (call.argument_names) |_| blk: {
            const names = (try self.functionParameterNames(method.symbol)) orelse {
                try self.report(call.span, "Type Error: именованные аргументы не поддержаны для этого вызова", .{});
                break :blk call.arguments;
            };
            if (names.len == 0) break :blk call.arguments;
            break :blk try self.reorderNamedArguments(expression, call, names[1..]);
        } else call.arguments;
        if (arguments.len != function.parameters.len - 1) try self.report(call.span, "Type Error: неверное количество аргументов метода", .{});
        if (nominal.arguments.len != method.owner_parameters.len) {
            try self.report(call.span, "Type Error: неверное количество параметров типа получателя", .{});
            return @as(?types.TypeId, try self.result.types.poison());
        }
        var substitutions = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
        defer substitutions.deinit();
        for (method.owner_parameters, nominal.arguments) |parameter, argument| try substitutions.put(parameter.typ, argument);
        const shared = @min(arguments.len, function.parameters.len - 1);
        for (arguments[0..shared], function.parameters[1 .. shared + 1]) |argument, parameter| {
            try self.inferGenericSubstitution(parameter, try self.infer(argument), &substitutions, call.span);
        }
        for (method.function_parameters) |parameter| {
            if (!substitutions.contains(parameter.typ)) try self.report(call.span, "Type Error: не удалось вывести type-параметр '{s}'", .{parameter.name});
        }
        const receiver = try self.substituteGeneric(function.parameters[0], &substitutions);
        if (!self.assignable(object_type, receiver)) try self.report(call.span, "Type Error: получатель метода имеет неверный тип", .{});
        for (arguments[0..shared], function.parameters[1 .. shared + 1]) |argument, parameter| {
            const expected = try self.substituteGeneric(parameter, &substitutions);
            const actual = try self.inferExpected(argument, expected);
            if (!self.assignable(actual, expected)) {
                try self.report(call.span, "Type Error: аргумент метода не совпадает с типом параметра", .{});
            } else {
                try self.registerInterfaceCast(argument, actual, expected);
            }
        }
        try self.result.method_calls.put(expression, method.symbol);
        return @as(?types.TypeId, try self.substituteGeneric(function.return_type, &substitutions));
    }

    fn inferPreludeEnumMethod(self: *Checker, call: anytype, property: anytype, object_type: types.TypeId) !?types.TypeId {
        const object = self.result.types.get(object_type) orelse return null;
        const nominal = switch (object.*) {
            .nominal => |value| value,
            else => return null,
        };
        const owner = self.resolution.symbols.get(nominal.symbol) orelse return null;
        if (std.mem.eql(u8, owner.name, "Опция")) {
            if (nominal.arguments.len != 1) return null;
            const element = nominal.arguments[0];
            if (std.mem.eql(u8, property.property, "есть") or std.mem.eql(u8, property.property, "пусто")) {
                try self.checkMethodArity(call, property.property, 0);
                return self.result.types.builtins.boolean;
            }
            if (std.mem.eql(u8, property.property, "получить")) {
                try self.checkMethodArity(call, "получить", 1);
                if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], element), element)) try self.report(call.span, "Type Error: значение по умолчанию имеет неверный тип", .{});
                return element;
            }
            if (std.mem.eql(u8, property.property, "значение")) {
                try self.checkMethodArity(call, "значение", 0);
                return element;
            }
            if (std.mem.eql(u8, property.property, "ожидать")) {
                try self.checkMethodArity(call, "ожидать", 1);
                if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) try self.report(call.span, "Type Error: сообщение ожидания должно быть строкой", .{});
                return element;
            }
            if (std.mem.eql(u8, property.property, "запас")) {
                try self.checkMethodArity(call, "запас", 1);
                if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], object_type), object_type)) try self.report(call.span, "Type Error: запасная опция имеет неверный тип", .{});
                return object_type;
            }
            if (std.mem.eql(u8, property.property, "заменить_значение")) {
                try self.checkMethodArity(call, "заменить_значение", 1);
                if (call.arguments.len == 0) return @as(?types.TypeId, try self.result.types.poison());
                return @as(?types.TypeId, try self.result.types.nominal(nominal.symbol, &.{try self.infer(call.arguments[0])}));
            }
            if (std.mem.eql(u8, property.property, "результат_или")) {
                try self.checkMethodArity(call, "результат_или", 1);
                if (call.arguments.len == 0) return @as(?types.TypeId, try self.result.types.poison());
                const result_symbol = self.findTypeSymbol("Результат") orelse return @as(?types.TypeId, try self.result.types.poison());
                return @as(?types.TypeId, try self.result.types.nominal(result_symbol, &.{ element, try self.infer(call.arguments[0]) }));
            }
        }
        if (std.mem.eql(u8, owner.name, "Результат")) {
            if (nominal.arguments.len != 2) return null;
            const success = nominal.arguments[0];
            const failure = nominal.arguments[1];
            if (std.mem.eql(u8, property.property, "успех") or std.mem.eql(u8, property.property, "ошибка")) {
                try self.checkMethodArity(call, property.property, 0);
                return self.result.types.builtins.boolean;
            }
            if (std.mem.eql(u8, property.property, "получить")) {
                try self.checkMethodArity(call, "получить", 1);
                if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], success), success)) try self.report(call.span, "Type Error: значение по умолчанию имеет неверный тип", .{});
                return success;
            }
            if (std.mem.eql(u8, property.property, "значение")) {
                try self.checkMethodArity(call, "значение", 0);
                return success;
            }
            if (std.mem.eql(u8, property.property, "причина")) {
                try self.checkMethodArity(call, "причина", 0);
                return failure;
            }
            if (std.mem.eql(u8, property.property, "ожидать")) {
                try self.checkMethodArity(call, "ожидать", 1);
                if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) try self.report(call.span, "Type Error: сообщение ожидания должно быть строкой", .{});
                return success;
            }
            if (std.mem.eql(u8, property.property, "ожидать_ошибку")) {
                try self.checkMethodArity(call, "ожидать_ошибку", 1);
                if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) try self.report(call.span, "Type Error: сообщение ожидания должно быть строкой", .{});
                return failure;
            }
            if (std.mem.eql(u8, property.property, "получить_ошибку")) {
                try self.checkMethodArity(call, "получить_ошибку", 1);
                if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], failure), failure)) try self.report(call.span, "Type Error: ошибка по умолчанию имеет неверный тип", .{});
                return failure;
            }
            if (std.mem.eql(u8, property.property, "запас")) {
                try self.checkMethodArity(call, "запас", 1);
                if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], object_type), object_type)) try self.report(call.span, "Type Error: запасной результат имеет неверный тип", .{});
                return object_type;
            }
            if (std.mem.eql(u8, property.property, "заменить_значение")) {
                try self.checkMethodArity(call, "заменить_значение", 1);
                if (call.arguments.len == 0) return @as(?types.TypeId, try self.result.types.poison());
                return @as(?types.TypeId, try self.result.types.nominal(nominal.symbol, &.{ try self.infer(call.arguments[0]), failure }));
            }
            if (std.mem.eql(u8, property.property, "заменить_ошибку")) {
                try self.checkMethodArity(call, "заменить_ошибку", 1);
                if (call.arguments.len == 0) return @as(?types.TypeId, try self.result.types.poison());
                return @as(?types.TypeId, try self.result.types.nominal(nominal.symbol, &.{ success, try self.infer(call.arguments[0]) }));
            }
            if (std.mem.eql(u8, property.property, "опция")) {
                try self.checkMethodArity(call, "опция", 0);
                const option_symbol = self.findTypeSymbol("Опция") orelse return @as(?types.TypeId, try self.result.types.poison());
                return @as(?types.TypeId, try self.result.types.nominal(option_symbol, &.{success}));
            }
            if (std.mem.eql(u8, property.property, "ошибка_опция")) {
                try self.checkMethodArity(call, "ошибка_опция", 0);
                const option_symbol = self.findTypeSymbol("Опция") orelse return @as(?types.TypeId, try self.result.types.poison());
                return @as(?types.TypeId, try self.result.types.nominal(option_symbol, &.{failure}));
            }
        }
        if (std.mem.eql(u8, owner.name, "Файл")) {
            if (std.mem.eql(u8, property.property, "прочитать") or std.mem.eql(u8, property.property, "прочитать_строку")) {
                try self.checkMethodArity(call, property.property, 0);
                return @as(?types.TypeId, self.resultOfString(self.result.types.builtins.string) orelse try self.result.types.poison());
            }
            if (std.mem.eql(u8, property.property, "записать")) {
                try self.checkMethodArity(call, "записать", 1);
                if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: Файл.записать() ожидает содержимое типа Строка", .{});
                }
                return @as(?types.TypeId, self.resultOfString(self.result.types.builtins.number) orelse try self.result.types.poison());
            }
            if (std.mem.eql(u8, property.property, "закрыть")) {
                try self.checkMethodArity(call, "закрыть", 0);
                return self.result.types.builtins.void;
            }
        }
        if (std.mem.eql(u8, owner.name, "Соединение")) {
            if (std.mem.eql(u8, property.property, "получить") or std.mem.eql(u8, property.property, "получить_строку")) {
                try self.checkMethodArity(call, property.property, 0);
                return @as(?types.TypeId, self.resultOfString(self.result.types.builtins.string) orelse try self.result.types.poison());
            }
            if (std.mem.eql(u8, property.property, "отправить")) {
                try self.checkMethodArity(call, "отправить", 1);
                if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: Соединение.отправить() ожидает содержимое типа Строка", .{});
                }
                return @as(?types.TypeId, self.resultOfString(self.result.types.builtins.number) orelse try self.result.types.poison());
            }
            if (std.mem.eql(u8, property.property, "закрыть")) {
                try self.checkMethodArity(call, "закрыть", 0);
                return self.result.types.builtins.void;
            }
        }
        if (std.mem.eql(u8, owner.name, "Слушатель")) {
            if (std.mem.eql(u8, property.property, "принять_запрос")) {
                try self.checkMethodArity(call, "принять_запрос", 0);
                const request_symbol = self.findTypeSymbol("Запрос") orelse return @as(?types.TypeId, try self.result.types.poison());
                const request_type = try self.nominalType(request_symbol, &.{});
                return @as(?types.TypeId, self.resultOfString(request_type) orelse try self.result.types.poison());
            }
        }
        if (std.mem.eql(u8, owner.name, "Запрос")) {
            if (std.mem.eql(u8, property.property, "метод") or std.mem.eql(u8, property.property, "путь")) {
                try self.checkMethodArity(call, property.property, 0);
                return @as(?types.TypeId, self.result.types.builtins.string);
            }
            if (std.mem.eql(u8, property.property, "тело")) {
                try self.checkMethodArity(call, "тело", 0);
                return @as(?types.TypeId, self.result.types.builtins.string);
            }
            if (std.mem.eql(u8, property.property, "заголовок")) {
                try self.checkMethodArity(call, "заголовок", 1);
                if (call.arguments.len != 0 and !self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
                    try self.report(call.span, "Type Error: Запрос.заголовок() ожидает имя типа Строка", .{});
                }
                const option_type = self.optionOf(self.result.types.builtins.string) orelse return @as(?types.TypeId, try self.result.types.poison());
                return @as(?types.TypeId, option_type);
            }
            if (std.mem.eql(u8, property.property, "ответить")) {
                try self.checkMethodArity(call, "ответить", 3);
                if (call.arguments.len == 3) {
                    if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.number), self.result.types.builtins.number)) {
                        try self.report(call.span, "Type Error: Запрос.ответить() ожидает статус типа Число первым аргументом", .{});
                    }
                    if (!self.assignable(try self.inferExpected(call.arguments[1], self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: Запрос.ответить() ожидает тип содержимого типа Строка вторым аргументом", .{});
                    }
                    if (!self.assignable(try self.inferExpected(call.arguments[2], self.result.types.builtins.string), self.result.types.builtins.string)) {
                        try self.report(call.span, "Type Error: Запрос.ответить() ожидает тело типа Строка третьим аргументом", .{});
                    }
                }
                return @as(?types.TypeId, self.result.types.builtins.void);
            }
        }
        if (std.mem.eql(u8, owner.name, "Соединение_БД")) {
            if (std.mem.eql(u8, property.property, "выполнить")) {
                try self.checkMethodArity(call, "выполнить", 2);
                if (call.arguments.len == 2) try self.checkSqlArgs(call);
                return @as(?types.TypeId, self.resultOfString(self.result.types.builtins.number) orelse try self.result.types.poison());
            }
            if (std.mem.eql(u8, property.property, "запрос")) {
                try self.checkMethodArity(call, "запрос", 2);
                if (call.arguments.len == 2) try self.checkSqlArgs(call);
                const row_type = try self.result.types.map(self.result.types.builtins.string, self.result.types.builtins.string);
                const rows_type = try self.result.types.array(row_type);
                return @as(?types.TypeId, self.resultOfString(rows_type) orelse try self.result.types.poison());
            }
            if (std.mem.eql(u8, property.property, "закрыть")) {
                try self.checkMethodArity(call, "закрыть", 0);
                return self.result.types.builtins.void;
            }
        }
        return null;
    }

    // Shared arg-type check for `Соединение_БД.выполнить`/`.запрос` —
    // both take `(sql: Строка, параметры: Массив(Строка))`.
    fn checkSqlArgs(self: *Checker, call: anytype) !void {
        if (!self.assignable(try self.inferExpected(call.arguments[0], self.result.types.builtins.string), self.result.types.builtins.string)) {
            try self.report(call.span, "Type Error: ожидается SQL типа Строка первым аргументом", .{});
        }
        const params_type = try self.result.types.array(self.result.types.builtins.string);
        if (!self.assignable(try self.inferExpected(call.arguments[1], params_type), params_type)) {
            try self.report(call.span, "Type Error: ожидается Массив(Строка) вторым аргументом", .{});
        }
    }

    fn resolveAlias(self: *Checker, symbol: symbols.SymbolId, span: source.Span) anyerror!types.TypeId {
        if (self.result.type_aliases.get(symbol)) |resolved| return resolved;
        const target = self.result.alias_type_nodes.get(symbol) orelse return self.result.types.poison();
        if (self.resolving_aliases.contains(symbol)) {
            try self.report(span, "Type Error: циклический псевдоним типа", .{});
            return self.result.types.poison();
        }
        try self.resolving_aliases.put(symbol, {});
        defer _ = self.resolving_aliases.remove(symbol);
        const resolved = try self.resolveType(target);
        try self.result.type_aliases.put(symbol, resolved);
        return resolved;
    }

    fn defineGenericParameters(self: *Checker, symbol: symbols.SymbolId, parameters: []const ast.TypeParameter) ![]const GenericParameter {
        if (self.result.generic_function_parameters.get(symbol)) |existing| return existing;
        const generic_parameters = try self.result.arena.allocator().alloc(GenericParameter, parameters.len);
        for (parameters, generic_parameters) |parameter, *generic_parameter| {
            var bounds: std.ArrayList(symbols.SymbolId) = .empty;
            defer bounds.deinit(self.result.allocator);
            var seen_bounds = std.AutoHashMap(symbols.SymbolId, void).init(self.result.allocator);
            defer seen_bounds.deinit();
            for (parameter.bounds) |bound_name| {
                const bound = self.findTypeSymbol(bound_name) orelse {
                    try self.report(self.resolution.symbols.get(symbol).?.span, "Type Error: неизвестный интерфейс '{s}'", .{bound_name});
                    continue;
                };
                if (!self.result.interface_definitions.contains(bound)) {
                    try self.report(self.resolution.symbols.get(symbol).?.span, "Type Error: ограничение '{s}' должно быть интерфейсом", .{bound_name});
                    continue;
                }
                if (seen_bounds.contains(bound)) {
                    try self.report(self.resolution.symbols.get(symbol).?.span, "Type Error: ограничение '{s}' указано повторно", .{bound_name});
                    continue;
                }
                try seen_bounds.put(bound, {});
                try bounds.append(self.result.allocator, bound);
            }
            generic_parameter.* = .{
                .name = parameter.name,
                .typ = try self.result.types.genericParameter(self.next_generic_parameter),
                .bounds = try self.result.arena.allocator().dupe(symbols.SymbolId, bounds.items),
            };
            self.next_generic_parameter += 1;
        }
        try self.result.generic_function_parameters.put(symbol, generic_parameters);
        return generic_parameters;
    }

    fn defineGenericNominalParameters(self: *Checker, symbol: symbols.SymbolId, parameters: []const []const u8) ![]const GenericParameter {
        if (self.result.generic_nominal_fields.get(symbol)) |existing| return existing.parameters;
        const generic_parameters = try self.result.arena.allocator().alloc(GenericParameter, parameters.len);
        for (parameters, generic_parameters) |parameter, *generic_parameter| {
            generic_parameter.* = .{
                .name = parameter,
                .typ = try self.result.types.genericParameter(self.next_generic_parameter),
            };
            self.next_generic_parameter += 1;
        }
        return generic_parameters;
    }

    fn defineGenericEnumParameters(self: *Checker, parameters: []const []const u8) ![]const GenericParameter {
        const generic_parameters = try self.result.arena.allocator().alloc(GenericParameter, parameters.len);
        for (parameters, generic_parameters) |parameter, *generic_parameter| {
            generic_parameter.* = .{
                .name = parameter,
                .typ = try self.result.types.genericParameter(self.next_generic_parameter),
            };
            self.next_generic_parameter += 1;
        }
        return generic_parameters;
    }

    fn findGenericParameter(self: *const Checker, name: []const u8) ?types.TypeId {
        for (self.current_generic_parameters) |parameter| {
            if (std.mem.eql(u8, parameter.name, name)) return parameter.typ;
        }
        return null;
    }

    fn enumVariant(self: *const Checker, symbol: symbols.SymbolId) ?EnumVariant {
        const entry = self.resolution.symbols.get(symbol) orelse return null;
        if (entry.kind != .enum_variant) return null;
        const definition = self.result.enum_definitions.get(entry.owner_type) orelse return null;
        for (definition.variants) |variant| {
            if (variant.symbol == symbol) return variant;
        }
        return null;
    }

    fn enumVariantFields(self: *Checker, variant: EnumVariant, nominal_type: types.TypeId) !?[]const types.TypeId {
        const entry = self.resolution.symbols.get(variant.symbol) orelse return null;
        const definition = self.result.enum_definitions.get(entry.owner_type) orelse return null;
        const type_entry = self.result.types.get(nominal_type) orelse return null;
        const nominal = switch (type_entry.*) {
            .nominal => |value| value,
            else => return null,
        };
        if (definition.parameters.len != nominal.arguments.len) return null;
        if (definition.parameters.len == 0) return variant.fields;
        var substitutions = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
        defer substitutions.deinit();
        for (definition.parameters, nominal.arguments) |parameter, argument| {
            try substitutions.put(parameter.typ, argument);
        }
        var fields: std.ArrayList(types.TypeId) = .empty;
        defer fields.deinit(self.result.allocator);
        for (variant.fields) |field| try fields.append(self.result.allocator, try self.substituteGeneric(field, &substitutions));
        return try self.result.arena.allocator().dupe(types.TypeId, fields.items);
    }

    fn inferEnumVariantCall(self: *Checker, call: anytype, variant: EnumVariant) !types.TypeId {
        if (call.argument_names != null) try self.report(call.span, "Type Error: именованные аргументы не поддержаны для конструктора варианта", .{});
        const entry = self.resolution.symbols.get(variant.symbol) orelse return self.result.types.poison();
        const definition = self.result.enum_definitions.get(entry.owner_type) orelse return self.result.types.poison();
        if (call.arguments.len != variant.fields.len) try self.report(call.span, "Type Error: неверное количество аргументов конструктора варианта", .{});
        const shared = @min(call.arguments.len, variant.fields.len);
        var substitutions = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
        defer substitutions.deinit();
        for (call.arguments[0..shared], variant.fields[0..shared]) |argument, field| {
            try self.inferGenericSubstitution(field, try self.infer(argument), &substitutions, call.span);
        }
        var arguments: std.ArrayList(types.TypeId) = .empty;
        defer arguments.deinit(self.result.allocator);
        for (definition.parameters) |parameter| {
            if (substitutions.get(parameter.typ)) |argument| {
                try arguments.append(self.result.allocator, argument);
            } else {
                try self.report(call.span, "Type Error: не удалось вывести type-параметр '{s}'", .{parameter.name});
                try arguments.append(self.result.allocator, try self.result.types.poison());
            }
        }
        for (call.arguments[0..shared], variant.fields[0..shared]) |argument, field| {
            const expected = try self.substituteGeneric(field, &substitutions);
            const actual = try self.inferExpected(argument, expected);
            if (self.assignable(actual, expected)) {
                try self.registerInterfaceCast(argument, actual, expected);
            } else {
                try self.report(call.span, "Type Error: аргумент конструктора варианта не совпадает с типом поля", .{});
            }
        }
        return self.nominalType(entry.owner_type, arguments.items);
    }

    fn inferEnumVariantCallExpected(self: *Checker, call: anytype, variant: EnumVariant, expected: types.TypeId) !types.TypeId {
        if (call.argument_names != null) try self.report(call.span, "Type Error: именованные аргументы не поддержаны для конструктора варианта", .{});
        const entry = self.resolution.symbols.get(variant.symbol) orelse return self.result.types.poison();
        const expected_entry = self.result.types.get(expected) orelse return self.inferEnumVariantCall(call, variant);
        const nominal = switch (expected_entry.*) {
            .nominal => |value| value,
            else => return self.inferEnumVariantCall(call, variant),
        };
        if (nominal.symbol != entry.owner_type) return self.inferEnumVariantCall(call, variant);
        const definition = self.result.enum_definitions.get(entry.owner_type) orelse return self.result.types.poison();
        if (definition.parameters.len != nominal.arguments.len) {
            try self.report(call.span, "Type Error: неверное количество параметров типа перечисления", .{});
            return self.result.types.poison();
        }
        if (call.arguments.len != variant.fields.len) try self.report(call.span, "Type Error: неверное количество аргументов конструктора варианта", .{});
        var substitutions = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
        defer substitutions.deinit();
        for (definition.parameters, nominal.arguments) |parameter, argument| {
            try substitutions.put(parameter.typ, argument);
        }
        const shared = @min(call.arguments.len, variant.fields.len);
        for (call.arguments[0..shared], variant.fields[0..shared]) |argument, field| {
            const expected_field = try self.substituteGeneric(field, &substitutions);
            const actual = try self.inferExpected(argument, expected_field);
            if (self.assignable(actual, expected_field)) {
                try self.registerInterfaceCast(argument, actual, expected_field);
            } else {
                try self.report(call.span, "Type Error: аргумент конструктора варианта не совпадает с типом поля", .{});
            }
        }
        return expected;
    }

    // Structurally walks `type_id`, filling `poison` into `substitutions`
    // for every bare generic-parameter reached that isn't already
    // constrained — used when `inferGenericSubstitution` hits a shape it
    // can't unify against (most commonly an EMPTY array/map literal,
    // `массив()`/`соответствие()`, whose element type is already
    // `poison` per its own inference rule — see `assignable`'s array/map
    // cases). Real gap found auditing panosiki's `cli-selector`
    // (`Селектор(заголовок, массив())` inside `новый_селектор[T]`,
    // constructing `Селектор[T]{пункты: Массив(Пункт(T))}` from an empty
    // array): without this, `T` was NEVER added to `substitutions` at
    // all (the old code just silently `return`ed on the shape mismatch),
    // so the very next pass reported "не удалось вывести type-параметр"
    // even though the missing type is provably safe to leave as
    // `poison` (assignable to/from anything, same reasoning `assignable`
    // already applies to empty-literal elements directly).
    // `placeholder` is whichever of `poison()`/`unconstrained()` the
    // ORIGINAL argument that triggered this fill already was (see the
    // call site in `inferGenericSubstitution`) — a single TypeId
    // instance, reused for every nested generic-parameter position
    // found by this walk (both variants carry a `void` payload, so one
    // instance is structurally interchangeable with a fresh one
    // everywhere `.eql`/`assignable` look at it). This propagates the
    // SAME kind (real error vs deliberately-unconstrained) all the way
    // through, instead of collapsing every fill back to a hardcoded
    // `.poison`.
    fn fillUnknownWithPoison(self: *Checker, type_id: types.TypeId, substitutions: *std.AutoHashMap(types.TypeId, types.TypeId), placeholder: types.TypeId) !void {
        const entry = self.result.types.get(type_id) orelse return;
        switch (entry.*) {
            .generic_parameter => {
                if (!substitutions.contains(type_id)) try substitutions.put(type_id, placeholder);
            },
            .tuple => |elements| for (elements) |element| try self.fillUnknownWithPoison(element, substitutions, placeholder),
            .array => |element| try self.fillUnknownWithPoison(element, substitutions, placeholder),
            .map => |map| {
                try self.fillUnknownWithPoison(map.key, substitutions, placeholder);
                try self.fillUnknownWithPoison(map.value, substitutions, placeholder);
            },
            .nominal => |nominal| for (nominal.arguments) |argument| try self.fillUnknownWithPoison(argument, substitutions, placeholder),
            else => {},
        }
    }

    fn inferGenericSubstitution(self: *Checker, parameter: types.TypeId, argument: types.TypeId, substitutions: *std.AutoHashMap(types.TypeId, types.TypeId), span: source.Span) !void {
        const parameter_type = self.result.types.get(parameter) orelse return;
        if (self.isPoison(argument)) return self.fillUnknownWithPoison(parameter, substitutions, argument);
        switch (parameter_type.*) {
            .generic_parameter => {
                if (substitutions.get(parameter)) |existing| {
                    // Число/Целое share ONE f64 runtime representation
                    // (see `Целое(x)`/`Число(x)` casts — `Число` is a
                    // pure no-op precisely because of this) — unifying a
                    // generic parameter across TWO occurrences where one
                    // argument is an untyped numeric literal (`0`,
                    // inferred as plain `Число` with no expected-type
                    // context to narrow it) and the other is a real
                    // `Целое` (e.g. `.длина()`) is completely safe, not
                    // a genuine ambiguity. Real regression found while
                    // fixing cross-module generic-bound dispatch: every
                    // cross-module generic call USED to skip this check
                    // entirely (silently permissive, via the "T always
                    // degrades to poison" gap this session's OTHER fix
                    // just closed) — `std/тест.ps`'s `т.равны[T](a, b:
                    // T, ...)`, called all over panosiki as `т.равны(...,
                    // массив.длина(), 0, ...)`, only started hitting
                    // this path once cross-module generics actually
                    // started tracking `T` for real.
                    if (self.isNumeric(argument) and self.isNumeric(existing)) {
                        if (self.isType(existing, self.result.types.builtins.integer) or self.isType(argument, self.result.types.builtins.integer)) {
                            try substitutions.put(parameter, self.result.types.builtins.integer);
                        }
                    } else if (!self.assignable(argument, existing) or !self.assignable(existing, argument)) {
                        try self.report(span, "Type Error: type-параметр выведен неоднозначно", .{});
                    }
                } else {
                    try substitutions.put(parameter, argument);
                }
            },
            .tuple => |parameters| {
                const argument_type = self.result.types.get(argument) orelse return;
                if (argument_type.* != .tuple or argument_type.tuple.len != parameters.len) return;
                for (parameters, argument_type.tuple) |nested_parameter, nested_argument| try self.inferGenericSubstitution(nested_parameter, nested_argument, substitutions, span);
            },
            .array => |element| {
                const argument_type = self.result.types.get(argument) orelse return;
                if (argument_type.* == .array) try self.inferGenericSubstitution(element, argument_type.array, substitutions, span);
            },
            .map => |map| {
                const argument_type = self.result.types.get(argument) orelse return;
                if (argument_type.* != .map) return;
                try self.inferGenericSubstitution(map.key, argument_type.map.key, substitutions, span);
                try self.inferGenericSubstitution(map.value, argument_type.map.value, substitutions, span);
            },
            .nominal => |nominal| {
                const argument_type = self.result.types.get(argument) orelse return;
                if (argument_type.* != .nominal or argument_type.nominal.symbol != nominal.symbol or argument_type.nominal.arguments.len != nominal.arguments.len) return;
                for (nominal.arguments, argument_type.nominal.arguments) |nested_parameter, nested_argument| {
                    try self.inferGenericSubstitution(nested_parameter, nested_argument, substitutions, span);
                }
            },
            else => {},
        }
    }

    fn fieldsForNominal(self: *Checker, nominal: anytype) !?[]const NominalField {
        if (self.result.nominal_fields.get(nominal.symbol)) |fields| return fields;
        const generic_nominal = self.result.generic_nominal_fields.get(nominal.symbol) orelse return null;
        if (nominal.arguments.len != generic_nominal.parameters.len) return null;
        var substitutions = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
        defer substitutions.deinit();
        for (generic_nominal.parameters, nominal.arguments) |parameter, argument| {
            try substitutions.put(parameter.typ, argument);
        }
        var fields: std.ArrayList(NominalField) = .empty;
        defer fields.deinit(self.result.allocator);
        for (generic_nominal.fields) |field| {
            try fields.append(self.result.allocator, .{
                .name = field.name,
                .typ = try self.substituteGeneric(field.typ, &substitutions),
            });
        }
        return try self.result.arena.allocator().dupe(NominalField, fields.items);
    }

    fn substituteGeneric(self: *Checker, type_id: types.TypeId, substitutions: *const std.AutoHashMap(types.TypeId, types.TypeId)) !types.TypeId {
        const entry = self.result.types.get(type_id) orelse return self.result.types.poison();
        return switch (entry.*) {
            .generic_parameter => substitutions.get(type_id) orelse type_id,
            .tuple => |elements| blk: {
                var substituted: std.ArrayList(types.TypeId) = .empty;
                defer substituted.deinit(self.result.allocator);
                for (elements) |element| try substituted.append(self.result.allocator, try self.substituteGeneric(element, substitutions));
                break :blk self.result.types.tuple(substituted.items);
            },
            .function => |function| blk: {
                var parameters: std.ArrayList(types.TypeId) = .empty;
                defer parameters.deinit(self.result.allocator);
                for (function.parameters) |parameter| try parameters.append(self.result.allocator, try self.substituteGeneric(parameter, substitutions));
                break :blk self.result.types.function(parameters.items, try self.substituteGeneric(function.return_type, substitutions));
            },
            .nominal => |nominal| blk: {
                var arguments: std.ArrayList(types.TypeId) = .empty;
                defer arguments.deinit(self.result.allocator);
                for (nominal.arguments) |argument| try arguments.append(self.result.allocator, try self.substituteGeneric(argument, substitutions));
                break :blk self.result.types.nominalWithIdentity(nominal.symbol, nominal.identity, arguments.items);
            },
            .array => |element| self.result.types.array(try self.substituteGeneric(element, substitutions)),
            .map => |map| self.result.types.map(try self.substituteGeneric(map.key, substitutions), try self.substituteGeneric(map.value, substitutions)),
            .process => |message| self.result.types.process(try self.substituteGeneric(message, substitutions)),
            .pointer => |pointee| self.result.types.pointer(try self.substituteGeneric(pointee, substitutions)),
            else => type_id,
        };
    }
};

pub fn check(allocator: std.mem.Allocator, tree: *const ast.Ast, resolution: *const resolver.Resolution) !CheckResult {
    return checkWithImports(allocator, tree, resolution, &.{});
}

pub fn checkWithImports(
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    imports: []const ImportedSymbolType,
) !CheckResult {
    return checkWithImportContextForTarget(allocator, tree, resolution, .{ .symbols = imports }, .native);
}

pub fn checkWithImportsForTarget(
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    imports: []const ImportedSymbolType,
    target_profile: target_policy.TargetProfile,
) !CheckResult {
    return checkWithImportContextForTarget(allocator, tree, resolution, .{ .symbols = imports }, target_profile);
}

pub fn checkWithImportContext(
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    imports: ImportContext,
) !CheckResult {
    return checkWithImportContextForTarget(allocator, tree, resolution, imports, .native);
}

pub fn checkWithImportContextForTarget(
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    imports: ImportContext,
    target_profile: target_policy.TargetProfile,
) !CheckResult {
    var result = try CheckResult.init(allocator);
    errdefer result.deinit();
    var checker = Checker{
        .tree = tree,
        .resolution = resolution,
        .result = &result,
        .target_profile = target_profile,
        .resolving_aliases = .init(allocator),
    };
    defer checker.resolving_aliases.deinit();
    var owner_remaps = std.AutoHashMap(symbols.SymbolId, std.AutoHashMap(types.TypeId, types.TypeId)).init(allocator);
    defer {
        var it = owner_remaps.valueIterator();
        while (it.next()) |remap| remap.deinit();
        owner_remaps.deinit();
    }
    var owner_parameters_by_symbol = std.AutoHashMap(symbols.SymbolId, []const GenericParameter).init(allocator);
    defer owner_parameters_by_symbol.deinit();
    try checker.typeAliasPass();
    try checker.preludePass();
    try checker.enumPass();
    try checker.interfacePass();
    // `nominalPass` (struct field types, INCLUDING qualified ones like
    // `слог.Логгер`) must run AFTER `importIdentityPass`, for the exact
    // same reason `importIdentityPass`'s own doc comment already
    // documents for `signaturePass`: `nominalType` reads
    // `imported_nominal_identities`, and a qualified annotation resolved
    // before that map is populated silently gets identity=0 instead of
    // the real cross-module identity. Real gap found auditing panosiki's
    // `std/слог.ps`: a struct field (`логгер: слог.Логгер`, resolved by
    // the OLD earlier `nominalPass`) and a method parameter of the
    // IDENTICAL declared type (resolved later, by `signaturePass`, AFTER
    // `importIdentityPass` already ran) ended up with two DIFFERENT
    // identities for "the same" type — assigning one to the other then
    // failed "присваивание несовместимых типов" even though both sides
    // were declared with the exact same annotation.
    try checker.importIdentityPass(imports, &owner_remaps, &owner_parameters_by_symbol);
    try checker.nominalPass();
    try checker.signaturePass();
    try checker.importSignaturePass(imports, &owner_remaps, &owner_parameters_by_symbol);
    try checker.constantPass();
    try checker.bodyPass();
    return result;
}

fn tuplePropertyIndex(property: []const u8) ?usize {
    if (property.len == 0) return null;
    return std.fmt.parseInt(usize, property, 10) catch null;
}

fn findNominalField(fields: []const NominalField, name: []const u8) ?NominalField {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field;
    }
    return null;
}

fn patternBooleanLiteral(tree: *const ast.Ast, pattern: ast.PatternId) ?bool {
    const literal = switch (tree.pattern(pattern).*) {
        .literal => |value| value,
        else => return null,
    };
    return switch (tree.expr(literal.value).*) {
        .boolean => |value| value.value,
        else => null,
    };
}

fn builtinType(store: *types.TypeStore, name: []const u8) ?types.TypeId {
    if (std.mem.eql(u8, name, "Число")) return store.builtins.number;
    if (std.mem.eql(u8, name, "Целое")) return store.builtins.integer;
    if (std.mem.eql(u8, name, "Булево")) return store.builtins.boolean;
    if (std.mem.eql(u8, name, "Строка")) return store.builtins.string;
    if (std.mem.eql(u8, name, "Пусто")) return store.builtins.void;
    if (std.mem.eql(u8, name, "Никогда")) return store.builtins.never;
    if (std.mem.eql(u8, name, "Ошибка")) return store.builtins.error_value;
    return null;
}

test "type checker verifies local arithmetic and direct calls" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ сложить(a: Число, b: Число) -> Число\na + b\nконец\nфунк старт() -> Число\nпер сумма: Число = сложить(1, 2)\nсумма\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

test "type checker accumulates argument type diagnostics" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ число(x: Число) -> Число\nx\nконец\nфунк старт() -> Число\nчисло(\"нет\")\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 1), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: аргумент не совпадает с типом параметра", checked.diagnostics.items.items[0].message);
}

test "type checker checks control-flow conditions and branch results" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ выбрать(условие: Булево) -> Число\nесли условие тогда\n1\nиначе\n2\nконец\nконец\nфунк ошибка() -> Число\nесли 1 тогда\n\"нет\"\nиначе\n2\nконец\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 2), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: условие 'если' должно иметь тип Булево", checked.diagnostics.items.items[0].message);
    try std.testing.expectEqualStrings("Type Error: ветви 'если' возвращают разные типы", checked.diagnostics.items.items[1].message);
}

test "type checker infers collection elements through indexing" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ элемент() -> Число\nпер числа = массив(1, 2)\nпер цены = соответствие(\"яблоко\" = числа[0])\nцены[\"яблоко\"]\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    const function = parsed.ast.decl(parsed.ast.program.?.declarations[0]).function;
    const index = parsed.ast.stmt(function.body[2]).expr.value;
    try std.testing.expectEqual(checked.types.builtins.number, checked.expression_types.get(index).?);
}

// Real gap found this session: `Строка` had `.есть()`/`.получить()`/etc
// counterparts nowhere, but specifically `.длина()` was missing while
// Массив/Соответствие both have it AND the free function `длина(x)`
// already worked fine on strings — a confusing asymmetry, not a
// deliberate omission. Fixed by adding a `.primitive == .string` arm
// alongside the existing `.array`/`.map` arms in the same dispatch.
test "type checker allows .длина() as a method on Строка, matching Массив/Соответствие" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f() -> Целое\nпер s = \"привет\"\ns.длина()\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

test "type checker infers lambda parameters from a function annotation" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ применить(f: функ(Число) -> Число, x: Число) -> Число\nf(x)\nконец\nфунк старт() -> Число\nпер удвоить: функ(Число) -> Число = функ(значение)\nзначение * 2\nконец\nприменить(удвоить, 3)\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

test "type checker preserves nominal user types in function signatures" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Точка = структура\nx: Число\nконец\nфунк та_же(точка: Точка) -> Точка\nточка\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

test "type checker checks struct constructors and field access" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Точка = структура\nx: Число\ny: Число\nконец\nфунк взять_x() -> Число\nпер точка = Точка(3, 4)\nточка.x\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    const function = parsed.ast.decl(parsed.ast.program.?.declarations[1]).function;
    const property = parsed.ast.stmt(function.body[1]).expr.value;
    try std.testing.expectEqual(checked.types.builtins.number, checked.expression_types.get(property).?);
}

test "type checker types destructuring and loop binders" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ сумма() -> Число\nпер (x, y) = (1, 2)\nпер результат = 0\nдля значение в массив(x, y) цикл\nрезультат = результат + значение\nконец\nпер целый_результат: Целое = 0\nдля индекс = 1 по 2 цикл\nцелый_результат = целый_результат + индекс\nконец\nрезультат\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    const function = parsed.ast.decl(parsed.ast.program.?.declarations[0]).function;
    const for_in_binder = resolved.stmt_bindings.get(function.body[2]).?[0];
    const for_range_binder = resolved.stmt_bindings.get(function.body[4]).?[0];
    try std.testing.expectEqual(checked.types.builtins.number, checked.symbol_types.get(for_in_binder).?);
    try std.testing.expectEqual(checked.types.builtins.integer, checked.symbol_types.get(for_range_binder).?);
}

test "type checker rejects loop control outside a loop" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f() -> Пусто\nпродолжить\nпрервать\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    // 3, not 2: `продолжить` (unconditionally diverges-for-reachability)
    // is immediately followed by `прервать` in the same block — a real
    // "недостижимый код" warning, ported from Odin's `check_unreachable_
    // code` (`core/type_cheker.odin`) alongside these two pre-existing
    // errors. Confirmed Odin produces the exact same warning text for the
    // equivalent program before adding this assertion.
    try std.testing.expectEqual(@as(usize, 3), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: 'продолжить' можно использовать только внутри цикла", checked.diagnostics.items.items[0].message);
    try std.testing.expectEqualStrings("Type Error: 'прервать' можно использовать только внутри цикла", checked.diagnostics.items.items[1].message);
    try std.testing.expectEqualStrings("недостижимый код", checked.diagnostics.items.items[2].message);
}

test "type checker narrows integer literals in an expected context" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ взять(значение: Целое) -> Целое\nзначение\nконец\nфунк сумма() -> Целое\nпер значения: Массив(Целое) = массив(1, 2)\nвзять(значения[0]) + 3\nконец\nфунк ошибка() -> Целое\nпер дробь: Целое = 1.5\nдробь\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 1), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: дробный литерал несовместим с Целое", checked.diagnostics.items.items[0].message);
    const sum = parsed.ast.decl(parsed.ast.program.?.declarations[1]).function;
    const expression = parsed.ast.stmt(sum.body[1]).expr.value;
    try std.testing.expectEqual(checked.types.builtins.integer, checked.expression_types.get(expression).?);
}

test "type checker validates operators and assignment targets" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ проверить(целое: Целое) -> Пусто\nконст неизменно = 1\nнеизменно = 2\nпер отрицание = не 1\nпер сумма = 1 + истина\nпер биты = целое & 2\nесли 1 и ложь тогда\n0\nиначе\n0\nконец\nпер финал = 0\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 4), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: нельзя присваивать константе", checked.diagnostics.items.items[0].message);
    try std.testing.expectEqualStrings("Type Error: оператор 'не' ожидает Булево", checked.diagnostics.items.items[1].message);
    try std.testing.expectEqualStrings("Type Error: оператор '+' ожидает два числа одного типа или две строки", checked.diagnostics.items.items[2].message);
    try std.testing.expectEqualStrings("Type Error: логический оператор ожидает два значения Булево", checked.diagnostics.items.items[3].message);
    const function = parsed.ast.decl(parsed.ast.program.?.declarations[0]).function;
    const bitwise_value = parsed.ast.stmt(function.body[4]).let.value;
    try std.testing.expectEqual(checked.types.builtins.integer, checked.expression_types.get(bitwise_value).?);
}

test "type checker restricts top-level constants to literals" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "конст ПЛОХО = массив(1)\nконст НОРМА = -1\nфунк старт() -> Число\nНОРМА\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 1), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: константа верхнего уровня должна быть числовым, строковым или булевым литералом", checked.diagnostics.items.items[0].message);
}

test "type checker resolves aliases before and after their declaration" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Первый = Второй\nтип Второй = Число\nфунк взять(значение: Первый) -> Второй\nпер копия: Первый = значение\nкопия\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

test "type checker rejects local values of type void" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f() -> Пусто\nпер пусто: Пусто = пока ложь цикл\nконец\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 1), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: переменная не может иметь тип 'Пусто'", checked.diagnostics.items.items[0].message);
}

test "type checker accepts generic interface implementations and records casts" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(
        std.testing.allocator,
        "тип Печатаемый = интерфейс\n" ++
            "функ вСтроку() -> Строка\n" ++
            "конец\n" ++
            "тип Коробка[T] = структура\n" ++
            "значение: T\n" ++
            "конец\n" ++
            "реализация Печатаемый для Коробка\n" ++
            "функ вСтроку(это: Коробка) -> Строка\n" ++
            "\"коробка\"\n" ++
            "конец\n" ++
            "конец\n" ++
            "функ показать(значение: Печатаемый) -> Строка\n" ++
            "значение.вСтроку()\n" ++
            "конец\n" ++
            "функ старт() -> Строка\n" ++
            "показать(Коробка(\"готово\"))\n" ++
            "конец",
        0,
    );
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.items.items.len);
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 1), checked.interface_implementations.items.len);
    try std.testing.expectEqual(@as(usize, 1), checked.interface_calls.count());
    try std.testing.expectEqual(@as(usize, 1), checked.interface_casts.count());
}

test "type checker restricts try expressions to compatible return envelopes" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ неверная_опция(значение: Опция(Число)) -> Число\nзначение?\nконец\nфунк неверный_результат(значение: Результат(Число, Строка)) -> Результат(Число, Число)\nзначение?\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 2), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: оператор '?' для Опции можно использовать только в функции, возвращающей Опцию", checked.diagnostics.items.items[0].message);
    try std.testing.expectEqualStrings("Type Error: оператор '?' возвращает ошибку другого типа", checked.diagnostics.items.items[1].message);
}

test "type checker enforces Comparable generic bounds" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ макс[T: Сравниваемое](a: T, b: T) -> T\nесли a > b тогда a иначе b конец\nконец\nфунк неверно() -> Строка\nмакс(\"a\", \"b\")\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 1), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: тип аргумента не реализует ограничение 'Сравниваемое'", checked.diagnostics.items.items[0].message);
}

test "type checker rejects invalid index writes and unsupported named enum calls" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Ответ = перечисление\nДа(Число)\nконец\nфунк f() -> Пусто\n\"строка\"[0] = \"x\"\nпер ответ = Ответ.Да(значение = 1)\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 2), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: присваивание по индексу возможно только массиву или соответствию", checked.diagnostics.items.items[0].message);
    try std.testing.expectEqualStrings("Type Error: именованные аргументы не поддержаны для конструктора варианта", checked.diagnostics.items.items[1].message);
}

test "type checker warns on code after an unconditional возврат" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f() -> Число\nвозврат 1\n2\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 1), checked.diagnostics.items.items.len);
    try std.testing.expectEqual(diagnostic.Severity.warning, checked.diagnostics.items.items[0].severity);
    try std.testing.expectEqualStrings("недостижимый код", checked.diagnostics.items.items[0].message);
}

test "type checker warns on code after an if/else where both branches return" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f(x: Булево) -> Число\nесли x тогда\nвозврат 1\nиначе\nвозврат 2\nконец\n3\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 1), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("недостижимый код", checked.diagnostics.items.items[0].message);
}

// Real bug found running `pan`'s own `семвер.pns` module (this session):
// a nested if-expression used as the TAIL of an else-branch, with no
// type annotation anywhere propagating an `expected` type down to it,
// wrongly reported "ветви 'если' возвращают разные типы" — even though
// both branches produced the exact same nominal struct type. Root cause:
// `inferBlockExpected`'s trailing statement dispatch used
// `expected_value == null` as a proxy for "discard this if-expression's
// value" (the correct, cheap path for loop bodies / bare-`если`-as-
// statement sub-blocks), but that's also exactly what a normal
// annotation-less block tail looks like — the nested `если`'s branches
// never got unified at all, silently inferred as `Пусто`.
test "type checker unifies branches of a nested if-expression used as an else-branch's tail, with no type annotation anywhere" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип Т = структура\nx: Число\nконец\nфунк f(a: Т) -> Число\nпер b = если истина тогда\nТ(2)\nиначе\nесли ложь тогда\nТ(3)\nиначе\na\nконец\nконец\nb.x\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

// Pre-emptive coverage, not a fix — an older memory of a bug report
// claimed `массив()` (empty array literal) inside a `выбор` arm doesn't
// inherit its element type from the enclosing function's declared `->
// Массив(T)` return type. Re-tested directly this session: NOT
// reproducible, on this commit or on the one right before `5515580`'s
// nested-if-expression fix — `inferMatchExpected` already threads
// `expected` correctly into each arm via `inferBlockExpected(arm.body,
// expected, false)`. Zero prior test coverage of this exact shape
// existed, though, and it's the same "trailing value type propagation"
// category `5515580` fixed a real bug in — this locks the behavior in
// so a future regression here doesn't go unnoticed the same way.
test "type checker infers массив() element type inside a выбор arm from the function's declared return type" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var lexed = try lexer.tokenize(std.testing.allocator, "тип E = перечисление\nА\nБ\nконец\nфунк f(e: E) -> Массив(Число)\nвыбор e\nE.А -> массив()\nE.Б -> массив(1)\nконец\nконец\nфунк старт() -> Массив(Число)\nf(E.А)\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}

test "type checker does not warn when an if has no else (false path falls through)" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    // `если x тогда паника("boom") конец` — `Никогда`-typed then-branch,
    // no `иначе`, so the whole `если` never claims to always diverge (the
    // false-condition path falls straight through) — the trailing `2`
    // must NOT be flagged unreachable. `паника` avoids an unrelated,
    // pre-existing if-expression-value-type inference limitation this
    // exact shape hits with `возврат` in a lone then-branch (separate
    // from what this test is checking).
    var lexed = try lexer.tokenize(std.testing.allocator, "функ f(x: Булево) -> Число\nесли x тогда\nпаника(\"boom\")\nконец\n2\nконец", 0);
    defer lexed.deinit();
    var parsed = try parser.parse(std.testing.allocator, lexed.tokens.items);
    defer parsed.deinit();
    var resolved = try resolver.resolve(std.testing.allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try check(std.testing.allocator, &parsed.ast, &resolved);
    defer checked.deinit();

    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);
}
