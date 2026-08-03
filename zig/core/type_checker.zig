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

pub const InterfaceCast = struct {
    interface: symbols.SymbolId,
    arguments: []const types.TypeId,
    target: symbols.SymbolId,
};

pub const InterfaceCall = struct {
    interface: symbols.SymbolId,
    method_index: u16,
};

pub const ForInKind = enum {
    array,
    iterator,
};

pub const ImportedSymbolType = struct {
    symbol: symbols.SymbolId,
    store: *const types.TypeStore,
    type_id: types.TypeId,
};

pub const ImportedNominal = struct {
    store: *const types.TypeStore,
    source_symbol: symbols.SymbolId,
    local_symbol: symbols.SymbolId,
    identity: u32,
};

pub const ImportContext = struct {
    symbols: []const ImportedSymbolType = &.{},
    nominals: []const ImportedNominal = &.{},
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
        };
    }

    pub fn deinit(self: *CheckResult) void {
        self.for_in_infos.deinit();
        self.call_arguments.deinit();
        self.interface_casts.deinit();
        self.interface_calls.deinit();
        self.method_calls.deinit();
        self.methods.deinit(self.allocator);
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

    fn signaturePass(self: *Checker) !void {
        for (self.tree.program.?.declarations) |declaration| {
            switch (self.tree.decl(declaration).*) {
                .function => |function| try self.defineFunctionSignature(declaration, function.type_parameters, function.parameters, function.return_type),
                .foreign => {},
                .impl => |implementation| {
                    const owner = self.findTypeSymbol(implementation.target_type) orelse {
                        try self.report(implementation.span, "Type Error: неизвестный тип реализации '{s}'", .{implementation.target_type});
                        continue;
                    };
                    const owner_parameters = self.nominalParameters(owner);
                    if (implementation.interface_name) |interface_name| {
                        try self.defineInterfaceImplementation(implementation, owner, owner_parameters, interface_name);
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

    fn importSignaturePass(self: *Checker, imports: ImportContext) !void {
        for (imports.nominals) |imported| try self.result.imported_nominal_identities.put(imported.local_symbol, imported.identity);
        for (imports.symbols) |imported| {
            const copied = self.copyImportedType(imported.store, imported.type_id, imports.nominals) catch |err| switch (err) {
                error.UnsupportedImportedType => {
                    try self.result.unsupported_imports.put(imported.symbol, {});
                    continue;
                },
                else => return err,
            };
            try self.result.symbol_types.put(imported.symbol, copied);
        }
    }

    fn copyImportedType(self: *Checker, external_store: *const types.TypeStore, external_type: types.TypeId, nominals: []const ImportedNominal) !types.TypeId {
        const entry = external_store.get(external_type) orelse return error.UnsupportedImportedType;
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
                for (elements) |element| try copied.append(self.result.allocator, try self.copyImportedType(external_store, element, nominals));
                break :blk self.result.types.tuple(copied.items);
            },
            .function => |function| blk: {
                var copied: std.ArrayList(types.TypeId) = .empty;
                defer copied.deinit(self.result.allocator);
                for (function.parameters) |parameter| try copied.append(self.result.allocator, try self.copyImportedType(external_store, parameter, nominals));
                break :blk self.result.types.function(copied.items, try self.copyImportedType(external_store, function.return_type, nominals));
            },
            .nominal => |nominal| blk: {
                for (nominals) |imported| {
                    if (imported.store != external_store or imported.source_symbol != nominal.symbol) continue;
                    var arguments: std.ArrayList(types.TypeId) = .empty;
                    defer arguments.deinit(self.result.allocator);
                    for (nominal.arguments) |argument| try arguments.append(self.result.allocator, try self.copyImportedType(external_store, argument, nominals));
                    break :blk self.result.types.nominalWithIdentity(imported.local_symbol, imported.identity, arguments.items);
                }
                return error.UnsupportedImportedType;
            },
            .array => |element| self.result.types.array(try self.copyImportedType(external_store, element, nominals)),
            .map => |map| self.result.types.map(
                try self.copyImportedType(external_store, map.key, nominals),
                try self.copyImportedType(external_store, map.value, nominals),
            ),
            .process => |message| self.result.types.process(try self.copyImportedType(external_store, message, nominals)),
            .pointer => |pointee| self.result.types.pointer(try self.copyImportedType(external_store, pointee, nominals)),
            .generic_parameter, .poison => error.UnsupportedImportedType,
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
            if (structure.is_ffi) continue;
            const symbol = self.resolution.decl_symbols.get(declaration) orelse continue;
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

    fn defineInterfaceImplementation(self: *Checker, implementation: anytype, owner: symbols.SymbolId, owner_parameters: []const GenericParameter, interface_name: []const u8) !void {
        const interface_symbol = self.findTypeSymbol(interface_name) orelse {
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
        const actual = try self.inferBlockExpected(body, expected_body);
        if (!self.isType(function_type.return_type, self.result.types.builtins.void) and !self.assignable(actual, function_type.return_type)) {
            const span = self.tree.decl(declaration).function.span;
            try self.report(span, "Type Error: функция должна возвращать объявленный тип", .{});
        }
    }

    fn inferStatement(self: *Checker, statement: ast.StmtId, expected_return: types.TypeId, expected_value: ?types.TypeId) anyerror!types.TypeId {
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
                const value_type = try self.inferExpected(return_statement.value, expected_return);
                if (!self.assignable(value_type, expected_return)) {
                    try self.report(return_statement.span, "Type Error: возвращаемое значение не совпадает с типом функции", .{});
                } else {
                    try self.registerInterfaceCast(return_statement.value, value_type, expected_return);
                }
                break :blk expected_return;
            },
            .expr => |expression| if (expected_value) |expected| blk: {
                const actual = try self.inferExpected(expression.value, expected);
                if (self.assignable(actual, expected)) try self.registerInterfaceCast(expression.value, actual, expected);
                break :blk actual;
            } else self.infer(expression.value),
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
                if (array.elements.len == 0) break :blk try self.result.types.array(try self.result.types.poison());
                const element_type = try self.infer(array.elements[0]);
                for (array.elements[1..]) |element| {
                    if (!self.assignable(try self.infer(element), element_type)) try self.report(array.span, "Type Error: элементы массива имеют разные типы", .{});
                }
                break :blk try self.result.types.array(element_type);
            },
            .map => |map| blk: {
                if (map.entries.len == 0) break :blk try self.result.types.map(try self.result.types.poison(), try self.result.types.poison());
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

    fn inferSpawn(self: *Checker, spawn: anytype) !types.TypeId {
        const call = switch (self.tree.expr(spawn.call).*) {
            .call => |value| value,
            else => {
                try self.report(spawn.span, "Type Error: 'запусти' ожидает вызов функции", .{});
                return self.result.types.process(try self.result.types.poison());
            },
        };
        _ = try self.inferCall(spawn.call, call);
        return self.result.types.process(try self.result.types.poison());
    }

    fn inferExpected(self: *Checker, expression: ast.ExprId, expected: types.TypeId) anyerror!types.TypeId {
        return switch (self.tree.expr(expression).*) {
            .lambda => |lambda| self.recordExpressionType(expression, try self.inferLambda(expression, lambda, expected)),
            .number => |number| if (expected == self.result.types.builtins.integer) blk: {
                if (number.value != std.math.trunc(number.value)) {
                    try self.report(number.span, "Type Error: дробный литерал несовместим с Целое", .{});
                }
                break :blk self.recordExpressionType(expression, expected);
            } else self.infer(expression),
            .unary => |unary| if (expected == self.result.types.builtins.integer and unary.operator == .minus) blk: {
                _ = try self.inferExpected(unary.operand, expected);
                break :blk self.recordExpressionType(expression, expected);
            } else self.infer(expression),
            .binary => |binary| if (expected == self.result.types.builtins.integer and (binary.operator == .plus or binary.operator == .minus or binary.operator == .star)) blk: {
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
                    if (!self.assignable(actual, element_type)) try self.report(tuple.span, "Type Error: элемент тупла не совпадает с ожидаемым типом", .{});
                }
                break :blk self.recordExpressionType(expression, expected);
            },
            .array => |array| blk: {
                const expected_type = self.result.types.get(expected) orelse break :blk self.infer(expression);
                const element_type = switch (expected_type.*) {
                    .array => |element| element,
                    else => break :blk self.infer(expression),
                };
                for (array.elements) |element| {
                    const actual = try self.inferExpected(element, element_type);
                    if (!self.assignable(actual, element_type)) try self.report(array.span, "Type Error: элемент массива не совпадает с ожидаемым типом", .{});
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
                    if (!self.assignable(key, expected_map.key)) try self.report(entry.span, "Type Error: ключ соответствия не совпадает с ожидаемым типом", .{});
                    if (!self.assignable(value, expected_map.value)) try self.report(entry.span, "Type Error: значение соответствия не совпадает с ожидаемым типом", .{});
                }
                break :blk self.recordExpressionType(expression, expected);
            },
            .call => |call| blk: {
                const variant = if (self.resolution.expr_symbols.get(call.callee)) |symbol| self.enumVariant(symbol) else null;
                if (variant) |value| break :blk self.recordExpressionType(expression, try self.inferEnumVariantCallExpected(call, value, expected));
                break :blk self.infer(expression);
            },
            .if_expr => |conditional| self.recordExpressionType(expression, try self.inferIfExpected(conditional, expected)),
            .match_expr => |match| self.recordExpressionType(expression, try self.inferMatchExpected(match, expected)),
            .spawn => |spawn| blk: {
                _ = try self.inferSpawn(spawn);
                const expected_entry = self.result.types.get(expected) orelse break :blk self.infer(expression);
                if (expected_entry.* != .process) break :blk self.infer(expression);
                break :blk self.recordExpressionType(expression, expected);
            },
            else => self.infer(expression),
        };
    }

    fn inferBlock(self: *Checker, statements: []const ast.StmtId) anyerror!types.TypeId {
        return self.inferBlockExpected(statements, null);
    }

    fn inferBlockExpected(self: *Checker, statements: []const ast.StmtId, expected_last: ?types.TypeId) anyerror!types.TypeId {
        var result_type = self.result.types.builtins.void;
        for (statements, 0..) |statement, index| {
            const expected_value = if (index + 1 == statements.len) expected_last else null;
            result_type = try self.inferStatement(statement, self.current_return orelse self.result.types.builtins.void, expected_value);
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
        const then_type = try self.inferBlockExpected(conditional.then_branch, expected);
        const else_type = try self.inferBlockExpected(conditional.else_branch, expected);
        const joined = if (self.isNever(then_type)) else_type else if (self.isNever(else_type)) then_type else null;
        if (joined == null and (!self.assignable(then_type, else_type) or !self.assignable(else_type, then_type))) {
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
            const arm_type = try self.inferBlockExpected(arm.body, expected);
            if (result_type) |previous| {
                if (self.isNever(previous)) {
                    result_type = arm_type;
                } else if (!self.isNever(arm_type) and (!self.assignable(previous, arm_type) or !self.assignable(arm_type, previous))) {
                    try self.report(arm.span, "Type Error: ветви выбора возвращают разные типы", .{});
                }
            } else {
                result_type = arm_type;
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
                if (subject_entry.* == .poison) {
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
                if (entry.kind == .enum_variant) return self.result.types.nominal(entry.owner_type, &.{});
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
        const body_type = try self.inferBlockExpected(lambda.body, return_type);
        if (!self.assignable(body_type, return_type)) try self.report(lambda.span, "Type Error: тело лямбды не совпадает с типом возврата", .{});
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
            .property, .index => {},
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
            if (parameter.typ != type_id) continue;
            for (parameter.bounds) |bound| {
                if (self.isComparableInterface(bound)) return true;
            }
        }
        return false;
    }

    fn isPoison(self: *const Checker, type_id: types.TypeId) bool {
        const entry = self.result.types.get(type_id) orelse return true;
        return entry.* == .poison;
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
            if (self.isBuiltin(symbol, "получить_сигнал")) {
                if (call.arguments.len != 0) try self.report(call.span, "Type Error: получить_сигнал() не принимает аргументы", .{});
                for (call.arguments) |argument| _ = try self.infer(argument);
                const option = self.findTypeSymbol("Опция") orelse return self.result.types.poison();
                const reason = try self.result.types.nominal(option, &.{self.result.types.builtins.string});
                return self.result.types.tuple(&.{ self.result.types.builtins.number, reason });
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
                    for (arguments[0..shared], function.parameters[0..shared]) |argument, parameter| {
                        try self.inferGenericSubstitution(parameter, try self.infer(argument), &substitutions, call.span);
                    }
                    for (generic_parameters) |parameter| {
                        if (!substitutions.contains(parameter.typ)) try self.report(call.span, "Type Error: не удалось вывести type-параметр '{s}'", .{parameter.name});
                    }
                    for (generic_parameters) |parameter| {
                        const actual = substitutions.get(parameter.typ) orelse continue;
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
                    if (call.arguments.len != generic_nominal.fields.len) try self.report(call.span, "Type Error: неверное количество аргументов конструктора структуры", .{});
                    const shared = @min(call.arguments.len, generic_nominal.fields.len);
                    var substitutions = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
                    defer substitutions.deinit();
                    for (call.arguments[0..shared], generic_nominal.fields[0..shared]) |argument, field| {
                        try self.inferGenericSubstitution(field.typ, try self.infer(argument), &substitutions, call.span);
                    }
                    var arguments: std.ArrayList(types.TypeId) = .empty;
                    defer arguments.deinit(self.result.allocator);
                    for (generic_nominal.parameters) |parameter| {
                        if (substitutions.get(parameter.typ)) |argument| {
                            try arguments.append(self.result.allocator, argument);
                        } else {
                            try self.report(call.span, "Type Error: не удалось вывести type-параметр '{s}'", .{parameter.name});
                            try arguments.append(self.result.allocator, try self.result.types.poison());
                        }
                    }
                    const constructor_type = try self.result.types.nominal(nominal.symbol, arguments.items);
                    for (call.arguments[0..shared], generic_nominal.fields[0..shared]) |argument, field| {
                        const expected = try self.substituteGeneric(field.typ, &substitutions);
                        if (!self.assignable(try self.inferExpected(argument, expected), expected)) try self.report(call.span, "Type Error: аргумент конструктора не совпадает с типом поля", .{});
                    }
                    return constructor_type;
                }
                if (self.result.nominal_fields.get(nominal.symbol)) |fields| {
                    if (call.arguments.len != fields.len) try self.report(call.span, "Type Error: неверное количество аргументов конструктора структуры", .{});
                    const shared = @min(call.arguments.len, fields.len);
                    for (call.arguments[0..shared], fields[0..shared]) |argument, field| {
                        if (!self.assignable(try self.inferExpected(argument, field.typ), field.typ)) try self.report(call.span, "Type Error: аргумент конструктора не совпадает с типом поля", .{});
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

    fn functionParameterNames(self: *Checker, symbol: symbols.SymbolId) !?[]const []const u8 {
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

    fn nominalType(self: *Checker, symbol: symbols.SymbolId, arguments: []const types.TypeId) !types.TypeId {
        if (self.result.imported_nominal_identities.get(symbol)) |identity| {
            return self.result.types.nominalWithIdentity(symbol, identity, arguments);
        }
        return self.result.types.nominal(symbol, arguments);
    }

    fn assignable(self: *const Checker, actual: types.TypeId, expected: types.TypeId) bool {
        const actual_type = self.result.types.get(actual) orelse return true;
        const expected_type = self.result.types.get(expected) orelse return true;
        if (actual_type.* == .poison or expected_type.* == .poison) return true;
        if (actual == self.result.types.builtins.never) return true;
        if (actual_type.* == .process and self.isPoison(actual_type.process)) return true;
        if (self.result.types.eql(actual, expected)) return true;
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
                if (parameter.typ != actual) continue;
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
        try self.result.interface_casts.put(expression, .{
            .interface = expected_nominal.symbol,
            .arguments = expected_nominal.arguments,
            .target = actual_nominal.symbol,
        });
    }

    fn inferInterfaceCall(self: *Checker, expression: ast.ExprId, call: anytype, property: anytype, object_type: types.TypeId) !?types.TypeId {
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
        if (call.arguments.len != function.parameters.len - 1) try self.report(call.span, "Type Error: неверное количество аргументов метода", .{});
        if (nominal.arguments.len != method.owner_parameters.len) {
            try self.report(call.span, "Type Error: неверное количество параметров типа получателя", .{});
            return @as(?types.TypeId, try self.result.types.poison());
        }
        var substitutions = std.AutoHashMap(types.TypeId, types.TypeId).init(self.result.allocator);
        defer substitutions.deinit();
        for (method.owner_parameters, nominal.arguments) |parameter, argument| try substitutions.put(parameter.typ, argument);
        const shared = @min(call.arguments.len, function.parameters.len - 1);
        for (call.arguments[0..shared], function.parameters[1 .. shared + 1]) |argument, parameter| {
            try self.inferGenericSubstitution(parameter, try self.infer(argument), &substitutions, call.span);
        }
        for (method.function_parameters) |parameter| {
            if (!substitutions.contains(parameter.typ)) try self.report(call.span, "Type Error: не удалось вывести type-параметр '{s}'", .{parameter.name});
        }
        const receiver = try self.substituteGeneric(function.parameters[0], &substitutions);
        if (!self.assignable(object_type, receiver)) try self.report(call.span, "Type Error: получатель метода имеет неверный тип", .{});
        for (call.arguments[0..shared], function.parameters[1 .. shared + 1]) |argument, parameter| {
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
        return null;
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
            for (parameter.bounds) |bound_name| {
                const bound = self.findTypeSymbol(bound_name) orelse {
                    try self.report(self.resolution.symbols.get(symbol).?.span, "Type Error: неизвестный интерфейс '{s}'", .{bound_name});
                    continue;
                };
                if (!self.result.interface_definitions.contains(bound)) {
                    try self.report(self.resolution.symbols.get(symbol).?.span, "Type Error: ограничение '{s}' должно быть интерфейсом", .{bound_name});
                    continue;
                }
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
            if (!self.assignable(try self.inferExpected(argument, expected), expected)) try self.report(call.span, "Type Error: аргумент конструктора варианта не совпадает с типом поля", .{});
        }
        return self.result.types.nominal(entry.owner_type, arguments.items);
    }

    fn inferEnumVariantCallExpected(self: *Checker, call: anytype, variant: EnumVariant, expected: types.TypeId) !types.TypeId {
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
            if (!self.assignable(try self.inferExpected(argument, expected_field), expected_field)) try self.report(call.span, "Type Error: аргумент конструктора варианта не совпадает с типом поля", .{});
        }
        return expected;
    }

    fn inferGenericSubstitution(self: *Checker, parameter: types.TypeId, argument: types.TypeId, substitutions: *std.AutoHashMap(types.TypeId, types.TypeId), span: source.Span) !void {
        const parameter_type = self.result.types.get(parameter) orelse return;
        switch (parameter_type.*) {
            .generic_parameter => {
                if (substitutions.get(parameter)) |existing| {
                    if (!self.assignable(argument, existing) or !self.assignable(existing, argument)) try self.report(span, "Type Error: type-параметр выведен неоднозначно", .{});
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
                break :blk self.result.types.nominal(nominal.symbol, arguments.items);
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
    try checker.typeAliasPass();
    try checker.nominalPass();
    try checker.preludePass();
    try checker.enumPass();
    try checker.interfacePass();
    try checker.signaturePass();
    try checker.importSignaturePass(imports);
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

    try std.testing.expectEqual(@as(usize, 2), checked.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Type Error: 'продолжить' можно использовать только внутри цикла", checked.diagnostics.items.items[0].message);
    try std.testing.expectEqualStrings("Type Error: 'прервать' можно использовать только внутри цикла", checked.diagnostics.items.items[1].message);
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
