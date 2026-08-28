const std = @import("std");
const source = @import("source.zig");
const token = @import("token.zig");

pub const ExprId = enum(u32) { _ };
pub const StmtId = enum(u32) { _ };
pub const DeclId = enum(u32) { _ };
pub const TypeId = enum(u32) { _ };
pub const PatternId = enum(u32) { _ };

pub const Program = struct {
    declarations: []const DeclId,
};

pub const AnnotationValue = union(enum) {
    string: []const u8,
    number: []const u8,
    boolean: []const u8,
    ident: []const u8,
};

pub const AnnotationArgument = struct {
    name: ?[]const u8 = null,
    value: AnnotationValue,
};

pub const Annotation = struct {
    span: source.Span,
    name: []const u8,
    arguments: []const AnnotationArgument = &.{},
};

pub const TypeParameter = struct {
    name: []const u8,
    bounds: []const []const u8 = &.{},
};

pub const ParamDecl = struct {
    span: source.Span,
    name: []const u8,
    type_annotation: ?TypeId = null,
};

pub const MethodSignature = struct {
    span: source.Span,
    name: []const u8,
    parameters: []const ParamDecl,
    return_type: TypeId,
};

pub const ForeignMarshalKind = enum {
    void,
    int8,
    int32,
    int64,
    float32,
    float64,
    c_string,
    pointer,
    struct_value,
};

pub const ForeignParam = struct {
    span: source.Span,
    name: []const u8,
    marshal: ForeignMarshalKind,
    pointee: ?TypeId = null,
    struct_type_name: ?[]const u8 = null,
};

pub const FieldDecl = struct {
    span: source.Span,
    name: []const u8,
    type_annotation: ?TypeId = null,
    marshal: ?ForeignMarshalKind = null,
    annotations: []const Annotation = &.{},
};

pub const VariantDecl = struct {
    span: source.Span,
    name: []const u8,
    types: []const TypeId = &.{},
};

pub const TypeNode = union(enum) {
    ident: struct {
        span: source.Span,
        name: []const u8,
    },
    generic: struct {
        span: source.Span,
        name: []const u8,
        parameters: []const TypeId,
    },
    qualified: struct {
        span: source.Span,
        module_name: []const u8,
        name: []const u8,
        parameters: []const TypeId,
    },
    tuple: struct {
        span: source.Span,
        elements: []const TypeId,
    },
    function: struct {
        span: source.Span,
        parameters: []const TypeId,
        return_type: TypeId,
    },
    error_node: source.Span,
};

pub const Pattern = union(enum) {
    wildcard: source.Span,
    literal: struct {
        span: source.Span,
        value: ExprId,
    },
    ident: struct {
        span: source.Span,
        name: []const u8,
    },
    constructor: struct {
        span: source.Span,
        module_name: ?[]const u8 = null,
        name: []const u8,
        arguments: []const PatternId = &.{},
        field_names: ?[]const []const u8 = null,
    },
    error_node: source.Span,
};

pub const MatchArm = struct {
    span: source.Span,
    pattern: PatternId,
    body: []const StmtId,
};

pub const MapEntry = struct {
    span: source.Span,
    key: ExprId,
    value: ExprId,
};

pub const Expr = union(enum) {
    number: struct {
        span: source.Span,
        value: f64,
        // true, если в лексеме исходника нет `.` — чисто синтаксический
        // факт, устанавливается парсером по сырому тексту лексемы.
        // Напрямую определяет статический тип литерала (`Целое` при true,
        // `Число` при false) — см. случай `.number` в `type_checker.zig`.
        is_integer_literal: bool,
    },
    boolean: struct {
        span: source.Span,
        value: bool,
    },
    string: struct {
        span: source.Span,
        value: []const u8,
    },
    ident: struct {
        span: source.Span,
        name: []const u8,
    },
    unary: struct {
        span: source.Span,
        operator: token.TokenKind,
        operand: ExprId,
    },
    // `x как Тип` — явное числовое приведение (пока только Число<->Целое,
    // см. случай инференса `.cast` в `type_checker.zig`). Связывает крепче
    // бинарных операторов, но слабее унарных (как `as` в Rust: `-x как
    // Целое` это `(-x) как Целое`, `x как Число + 1` это `(x как Число) +
    // 1`) — разбирается как суффиксный цикл сразу после `parseUnary()`,
    // до входа в разбор бинарных операторов по приоритетам.
    cast: struct {
        span: source.Span,
        operand: ExprId,
        target: TypeId,
        target_span: source.Span,
    },
    binary: struct {
        span: source.Span,
        left: ExprId,
        operator: token.TokenKind,
        right: ExprId,
    },
    call: struct {
        span: source.Span,
        callee: ExprId,
        arguments: []const ExprId,
        argument_names: ?[]const []const u8 = null,
    },
    spawn: struct {
        span: source.Span,
        call: ExprId,
    },
    // `выбор ожидание(источник) ... конец` — слот "субъекта" обычного
    // `match_expr`, производится только этим специальным путём разбора.
    // `source` (`Массив(Процесс(R))`) — дополнительный набор процессов,
    // за завершением которых нужно следить наряду с собственными
    // почтовым ящиком/очередями сигналов процесса. Вычисление этого
    // выражения И ЕСТЬ точка приостановки — см. `Vm.selectWait`.
    select_wait: struct {
        span: source.Span,
        source: ExprId,
    },
    property: struct {
        span: source.Span,
        object: ExprId,
        property: []const u8,
    },
    if_expr: struct {
        span: source.Span,
        condition: ExprId,
        then_branch: []const StmtId,
        else_branch: []const StmtId,
    },
    while_expr: struct {
        span: source.Span,
        condition: ExprId,
        body: []const StmtId,
    },
    tuple: struct {
        span: source.Span,
        elements: []const ExprId,
    },
    lambda: struct {
        span: source.Span,
        parameters: []const ParamDecl,
        return_type: ?TypeId = null,
        body: []const StmtId,
    },
    array: struct {
        span: source.Span,
        elements: []const ExprId,
    },
    map: struct {
        span: source.Span,
        entries: []const MapEntry,
    },
    index: struct {
        span: source.Span,
        object: ExprId,
        index: ExprId,
    },
    try_expr: struct {
        span: source.Span,
        value: ExprId,
    },
    match_expr: struct {
        span: source.Span,
        subject: ExprId,
        arms: []const MatchArm,
    },
    error_node: source.Span,
};

pub fn exprSpan(expression: Expr) source.Span {
    return switch (expression) {
        .number => |value| value.span,
        .boolean => |value| value.span,
        .string => |value| value.span,
        .ident => |value| value.span,
        .unary => |value| value.span,
        .cast => |value| value.span,
        .binary => |value| value.span,
        .call => |value| value.span,
        .spawn => |value| value.span,
        .select_wait => |value| value.span,
        .property => |value| value.span,
        .if_expr => |value| value.span,
        .while_expr => |value| value.span,
        .tuple => |value| value.span,
        .lambda => |value| value.span,
        .array => |value| value.span,
        .map => |value| value.span,
        .index => |value| value.span,
        .try_expr => |value| value.span,
        .match_expr => |value| value.span,
        .error_node => |span| span,
    };
}

pub const Stmt = union(enum) {
    return_stmt: struct {
        span: source.Span,
        // `null` — голый `возврат` (пустой возврат без выражения,
        // например ранний выход из функции, возвращающей `Пусто`).
        value: ?ExprId,
    },
    defer_stmt: struct {
        span: source.Span,
        value: ExprId,
    },
    let: struct {
        span: source.Span,
        name: ?[]const u8 = null,
        value: ExprId,
        type_annotation: ?TypeId = null,
        is_const: bool,
        destructure_names: []const []const u8 = &.{},
        destructure_type: ?[]const u8 = null,
        destructure_field_names: ?[]const []const u8 = null,
    },
    expr: struct {
        span: source.Span,
        value: ExprId,
    },
    continue_stmt: source.Span,
    break_stmt: source.Span,
    for_in: struct {
        span: source.Span,
        names: []const []const u8,
        iterable: ExprId,
        body: []const StmtId,
    },
    for_range: struct {
        span: source.Span,
        name: []const u8,
        start: ExprId,
        end: ExprId,
        body: []const StmtId,
    },
    error_node: source.Span,
};

pub const Decl = union(enum) {
    import: struct {
        span: source.Span,
        path: []const u8,
        alias: ?[]const u8 = null,
    },
    // `экспорт "путь"` — реэкспорт (стиль Dart `export`): символы,
    // экспортированные ЦЕЛЕВЫМ модулем, становятся видны ПОД ИХ
    // РОДНЫМИ ИМЕНАМИ, ПЛОСКО (не через вложенный алиас) любому
    // модулю, импортирующему ЭТОТ файл — но НЕ дают локального
    // доступа в файле, где написана эта директива (для этого — отдельно
    // обычный `импорт` того же пути). См. `buildExportsForTarget` в
    // module_linker.zig.
    reexport: struct {
        span: source.Span,
        path: []const u8,
    },
    function: struct {
        span: source.Span,
        name: []const u8,
        name_span: source.Span,
        doc: []const u8,
        type_parameters: []const TypeParameter,
        parameters: []const ParamDecl,
        return_type: TypeId,
        body: []const StmtId,
        is_exported: bool,
        annotations: []const Annotation = &.{},
    },
    struct_decl: struct {
        span: source.Span,
        name: []const u8,
        doc: []const u8,
        type_parameters: []const []const u8,
        fields: []const FieldDecl,
        is_exported: bool,
        annotations: []const Annotation = &.{},
        is_ffi: bool = false,
    },
    impl: struct {
        span: source.Span,
        interface_module: ?[]const u8 = null,
        interface_name: ?[]const u8 = null,
        target_module: ?[]const u8 = null,
        target_type: []const u8,
        methods: []const DeclId,
    },
    interface_decl: struct {
        span: source.Span,
        name: []const u8,
        doc: []const u8,
        type_parameters: []const []const u8,
        methods: []const MethodSignature,
        // Методы по умолчанию — полноценные декларации `.function`
        // (получатель `это: Интерфейс(...)` указан явно, как у любого
        // другого метода), разбираются наряду с чисто абстрактными
        // сигнатурами выше всякий раз, когда у метода есть тело. Для
        // каждого также создаётся соответствующая запись (без получателя)
        // в `methods` — для существующей машинерии работы с сигнатурами.
        default_methods: []const DeclId = &.{},
        is_exported: bool,
        annotations: []const Annotation = &.{},
    },
    enum_decl: struct {
        span: source.Span,
        name: []const u8,
        doc: []const u8,
        type_parameters: []const []const u8,
        variants: []const VariantDecl,
        is_exported: bool,
        annotations: []const Annotation = &.{},
    },
    foreign: struct {
        span: source.Span,
        library: []const u8,
        name: []const u8,
        parameters: []const ForeignParam,
        return_marshal: ForeignMarshalKind,
        return_pointee: ?TypeId = null,
        return_struct_type_name: ?[]const u8 = null,
        return_owned: bool = false,
        // `экспорт внешний "хост" функ ...` — только для `"хост"`
        // (нативный in-process registry, не настоящий dlopen/dlsym), см.
        // doc-комментарий у ограничения в `parser.zig`'s
        // `parseTopLevelDeclarations`.
        is_exported: bool = false,
    },
    constant: struct {
        span: source.Span,
        name: []const u8,
        name_span: source.Span,
        doc: []const u8,
        value: ExprId,
        is_exported: bool,
    },
    type_alias: struct {
        span: source.Span,
        name: []const u8,
        doc: []const u8,
        is_exported: bool,
        annotations: []const Annotation = &.{},
        aliased_type: TypeId,
    },
    error_node: source.Span,
};

pub const Ast = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    expressions: std.ArrayList(Expr) = .empty,
    statements: std.ArrayList(Stmt) = .empty,
    declarations: std.ArrayList(Decl) = .empty,
    types: std.ArrayList(TypeNode) = .empty,
    patterns: std.ArrayList(Pattern) = .empty,
    program: ?Program = null,

    pub fn init(allocator: std.mem.Allocator) Ast {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Ast) void {
        self.expressions.deinit(self.allocator);
        self.statements.deinit(self.allocator);
        self.declarations.deinit(self.allocator);
        self.types.deinit(self.allocator);
        self.patterns.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn copyText(self: *Ast, value: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, value);
    }

    pub fn copySlice(self: *Ast, comptime T: type, values: []const T) ![]const T {
        return self.arena.allocator().dupe(T, values);
    }

    pub fn addExpr(self: *Ast, value: Expr) !ExprId {
        const id: ExprId = @enumFromInt(@as(u32, @intCast(self.expressions.items.len)));
        try self.expressions.append(self.allocator, value);
        return id;
    }

    pub fn addStmt(self: *Ast, value: Stmt) !StmtId {
        const id: StmtId = @enumFromInt(@as(u32, @intCast(self.statements.items.len)));
        try self.statements.append(self.allocator, value);
        return id;
    }

    pub fn addDecl(self: *Ast, value: Decl) !DeclId {
        const id: DeclId = @enumFromInt(@as(u32, @intCast(self.declarations.items.len)));
        try self.declarations.append(self.allocator, value);
        return id;
    }

    pub fn addType(self: *Ast, value: TypeNode) !TypeId {
        const id: TypeId = @enumFromInt(@as(u32, @intCast(self.types.items.len)));
        try self.types.append(self.allocator, value);
        return id;
    }

    pub fn addPattern(self: *Ast, value: Pattern) !PatternId {
        const id: PatternId = @enumFromInt(@as(u32, @intCast(self.patterns.items.len)));
        try self.patterns.append(self.allocator, value);
        return id;
    }

    pub fn setProgram(self: *Ast, declarations: []const DeclId) !void {
        self.program = .{ .declarations = try self.copySlice(DeclId, declarations) };
    }

    pub fn expr(self: *const Ast, id: ExprId) *const Expr {
        return &self.expressions.items[@intFromEnum(id)];
    }

    pub fn stmt(self: *const Ast, id: StmtId) *const Stmt {
        return &self.statements.items[@intFromEnum(id)];
    }

    pub fn decl(self: *const Ast, id: DeclId) *const Decl {
        return &self.declarations.items[@intFromEnum(id)];
    }

    pub fn typeNode(self: *const Ast, id: TypeId) *const TypeNode {
        return &self.types.items[@intFromEnum(id)];
    }

    pub fn pattern(self: *const Ast, id: PatternId) *const Pattern {
        return &self.patterns.items[@intFromEnum(id)];
    }

    pub fn findExpressionAt(self: *const Ast, file_id: source.FileId, offset: u32) ?ExprId {
        var result: ?ExprId = null;
        var result_size: u32 = std.math.maxInt(u32);
        for (self.expressions.items, 0..) |expression, index| {
            const span = exprSpan(expression);
            if (!span.contains(file_id, offset)) continue;
            const size = span.end - span.start;
            if (size >= result_size) continue;
            result = @enumFromInt(index);
            result_size = size;
        }
        return result;
    }
};

test "AST IDs remain stable when storage grows" {
    var ast = Ast.init(std.testing.allocator);
    defer ast.deinit();

    const first = try ast.addExpr(.{ .number = .{
        .span = .{ .file_id = 0, .start = 0, .end = 1 },
        .value = 1,
        .is_integer_literal = true,
    } });
    const second = try ast.addExpr(.{ .number = .{
        .span = .{ .file_id = 0, .start = 2, .end = 3 },
        .value = 2,
        .is_integer_literal = true,
    } });

    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(first));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(second));
    switch (ast.expr(first).*) {
        .number => |value| try std.testing.expectEqual(@as(f64, 1), value.value),
        else => return error.TestUnexpectedResult,
    }
}

test "AST owns copied text and program child IDs" {
    var ast = Ast.init(std.testing.allocator);
    defer ast.deinit();

    var source_name = [_]u8{ 'n', 'a', 'm', 'e' };
    const name = try ast.copyText(&source_name);
    const expression = try ast.addExpr(.{ .ident = .{
        .span = .{ .file_id = 0, .start = 0, .end = 4 },
        .name = name,
    } });
    source_name[0] = 'x';
    switch (ast.expr(expression).*) {
        .ident => |value| try std.testing.expectEqualStrings("name", value.name),
        else => return error.TestUnexpectedResult,
    }

    const declaration = try ast.addDecl(.{ .constant = .{
        .span = .{ .file_id = 0, .start = 0, .end = 4 },
        .name = name,
        .name_span = .{ .file_id = 0, .start = 0, .end = 4 },
        .doc = "",
        .value = expression,
        .is_exported = false,
    } });
    const declarations = [_]DeclId{declaration};
    try ast.setProgram(&declarations);
    try std.testing.expectEqual(@as(usize, 1), ast.program.?.declarations.len);
    try std.testing.expectEqual(declaration, ast.program.?.declarations[0]);
}

test "AST finds the most nested expression at a source offset" {
    var ast = Ast.init(std.testing.allocator);
    defer ast.deinit();

    const left = try ast.addExpr(.{ .number = .{ .span = .{ .file_id = 2, .start = 4, .end = 5 }, .value = 1, .is_integer_literal = true } });
    const right = try ast.addExpr(.{ .number = .{ .span = .{ .file_id = 2, .start = 8, .end = 9 }, .value = 2, .is_integer_literal = true } });
    const binary = try ast.addExpr(.{ .binary = .{
        .span = .{ .file_id = 2, .start = 4, .end = 9 },
        .left = left,
        .operator = .plus,
        .right = right,
    } });

    try std.testing.expectEqual(left, ast.findExpressionAt(2, 4).?);
    try std.testing.expectEqual(binary, ast.findExpressionAt(2, 6).?);
    try std.testing.expectEqual(right, ast.findExpressionAt(2, 8).?);
    try std.testing.expect(ast.findExpressionAt(2, 9) == null);
    try std.testing.expect(ast.findExpressionAt(3, 4) == null);
}
