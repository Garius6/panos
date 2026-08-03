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
    type_annotation: TypeId,
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

pub const Stmt = union(enum) {
    return_stmt: struct {
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
    error_node: source.Span,
};

pub const Decl = union(enum) {
    import: struct {
        span: source.Span,
        path: []const u8,
        alias: ?[]const u8 = null,
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
};

test "AST IDs remain stable when storage grows" {
    var ast = Ast.init(std.testing.allocator);
    defer ast.deinit();

    const first = try ast.addExpr(.{ .number = .{
        .span = .{ .file_id = 0, .start = 0, .end = 1 },
        .value = 1,
    } });
    const second = try ast.addExpr(.{ .number = .{
        .span = .{ .file_id = 0, .start = 2, .end = 3 },
        .value = 2,
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
