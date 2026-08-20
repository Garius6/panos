const std = @import("std");
const source = @import("source.zig");

pub const SymbolId = enum(u32) { _ };
pub const ScopeId = enum(u32) { _ };

pub const invalid_symbol: SymbolId = @enumFromInt(0);

pub const SymbolKind = enum {
    variable,
    function,
    type,
    module,
    builtin,
    enum_variant,
    constant,
};

pub const Symbol = struct {
    name: []const u8,
    full_name: []const u8,
    kind: SymbolKind,
    module_path: ?[]const u8 = null,
    is_exported: bool = false,
    is_pattern_binder: bool = false,
    is_const: bool = false,
    owner_type: SymbolId = invalid_symbol,
    span: source.Span,
};

pub const SymbolSpec = struct {
    name: []const u8,
    kind: SymbolKind,
    module_path: ?[]const u8 = null,
    is_exported: bool = false,
    is_pattern_binder: bool = false,
    is_const: bool = false,
    owner_type: SymbolId = invalid_symbol,
    span: source.Span,
};

pub const SymbolStore = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    symbols: std.ArrayList(Symbol) = .empty,

    pub fn init(allocator: std.mem.Allocator) !SymbolStore {
        var store = SymbolStore{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer store.deinit();
        try store.symbols.append(allocator, .{
            .name = "",
            .full_name = "",
            .kind = .builtin,
            .span = .{ .file_id = 0, .start = 0, .end = 0 },
        });
        return store;
    }

    pub fn deinit(self: *SymbolStore) void {
        self.symbols.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn add(self: *SymbolStore, spec: SymbolSpec) !SymbolId {
        const name = try self.arena.allocator().dupe(u8, spec.name);
        const module_path = if (spec.module_path) |value|
            try self.arena.allocator().dupe(u8, value)
        else
            null;
        const full_name = if (module_path) |path|
            try std.fmt.allocPrint(self.arena.allocator(), "{s}::{s}", .{ path, name })
        else
            name;
        const id: SymbolId = @enumFromInt(self.symbols.items.len);
        try self.symbols.append(self.allocator, .{
            .name = name,
            .full_name = full_name,
            .kind = spec.kind,
            .module_path = module_path,
            .is_exported = spec.is_exported,
            .is_pattern_binder = spec.is_pattern_binder,
            .is_const = spec.is_const,
            .owner_type = spec.owner_type,
            .span = spec.span,
        });
        return id;
    }

    pub fn get(self: *const SymbolStore, id: SymbolId) ?*const Symbol {
        const index = @intFromEnum(id);
        if (index == 0 or index >= self.symbols.items.len) return null;
        return &self.symbols.items[index];
    }
};

pub const Scope = struct {
    parent: ?ScopeId,
    symbols: std.StringHashMap(SymbolId),

    fn init(allocator: std.mem.Allocator, parent: ?ScopeId) Scope {
        return .{
            .parent = parent,
            .symbols = .init(allocator),
        };
    }
};

pub const CaptureSet = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList(SymbolId) = .empty,
    seen: std.AutoHashMap(SymbolId, void),

    pub fn init(allocator: std.mem.Allocator) CaptureSet {
        return .{
            .allocator = allocator,
            .seen = .init(allocator),
        };
    }

    pub fn deinit(self: *CaptureSet) void {
        self.values.deinit(self.allocator);
        self.seen.deinit();
        self.* = undefined;
    }

    fn add(self: *CaptureSet, symbol: SymbolId) !void {
        if (self.seen.contains(symbol)) return;
        try self.seen.put(symbol, {});
        try self.values.append(self.allocator, symbol);
    }
};

const LambdaFrame = struct {
    boundary: ScopeId,
    captures: CaptureSet,
};

pub const ScopeStack = struct {
    allocator: std.mem.Allocator,
    scopes: std.ArrayList(Scope) = .empty,
    current: ScopeId,
    lambda_frames: std.ArrayList(LambdaFrame) = .empty,

    pub fn init(allocator: std.mem.Allocator) !ScopeStack {
        var stack = ScopeStack{
            .allocator = allocator,
            .current = @enumFromInt(0),
        };
        errdefer stack.deinit();
        try stack.scopes.append(allocator, Scope.init(allocator, null));
        return stack;
    }

    pub fn deinit(self: *ScopeStack) void {
        for (self.scopes.items) |*scope_entry| scope_entry.symbols.deinit();
        self.scopes.deinit(self.allocator);
        for (self.lambda_frames.items) |*frame| frame.captures.deinit();
        self.lambda_frames.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn root(self: *const ScopeStack) ScopeId {
        _ = self;
        return @enumFromInt(0);
    }

    pub fn push(self: *ScopeStack) !ScopeId {
        const id: ScopeId = @enumFromInt(self.scopes.items.len);
        try self.scopes.append(self.allocator, Scope.init(self.allocator, self.current));
        self.current = id;
        return id;
    }

    pub fn pop(self: *ScopeStack) !ScopeId {
        const current_scope = self.scopeById(self.current);
        self.current = current_scope.parent orelse return error.CannotPopRootScope;
        return self.current;
    }

    pub fn declare(self: *ScopeStack, symbol_store: *const SymbolStore, symbol: SymbolId) !void {
        const entry = symbol_store.get(symbol) orelse return error.InvalidSymbol;
        var current_scope = self.scopeById(self.current);
        if (current_scope.symbols.contains(entry.name)) return error.DuplicateSymbol;
        try current_scope.symbols.put(entry.name, symbol);
    }

    pub fn lookup(self: *const ScopeStack, name: []const u8) ?SymbolId {
        return self.lookupFrom(self.current, name);
    }

    pub fn lookupFrom(self: *const ScopeStack, first_scope: ScopeId, name: []const u8) ?SymbolId {
        var scope_id: ?ScopeId = first_scope;
        while (scope_id) |id| {
            const scope_entry = self.scopeByIdConst(id);
            if (scope_entry.symbols.get(name)) |symbol| return symbol;
            scope_id = scope_entry.parent;
        }
        return null;
    }

    pub fn enterLambda(self: *ScopeStack) !ScopeId {
        const boundary = try self.push();
        errdefer _ = self.pop() catch unreachable;
        try self.lambda_frames.append(self.allocator, .{
            .boundary = boundary,
            .captures = CaptureSet.init(self.allocator),
        });
        return boundary;
    }

    pub fn leaveLambda(self: *ScopeStack) !CaptureSet {
        if (self.lambda_frames.items.len == 0) return error.NoActiveLambda;
        const index = self.lambda_frames.items.len - 1;
        if (self.lambda_frames.items[index].boundary != self.current) return error.InvalidLambdaScope;
        const frame = self.lambda_frames.items[index];
        self.lambda_frames.items.len = index;
        _ = try self.pop();
        return frame.captures;
    }

    pub fn lookupTrackingCaptures(self: *ScopeStack, symbol_store: *const SymbolStore, name: []const u8) !?SymbolId {
        var crossed_frames: std.ArrayList(usize) = .empty;
        defer crossed_frames.deinit(self.allocator);

        var scope_id: ?ScopeId = self.current;
        var next_frame = self.lambda_frames.items.len;
        while (scope_id) |id| {
            const scope_entry = self.scopeByIdConst(id);
            if (scope_entry.symbols.get(name)) |symbol| {
                const entry = symbol_store.get(symbol) orelse return error.InvalidSymbol;
                if (entry.kind == .variable or entry.kind == .function) {
                    for (crossed_frames.items) |frame_index| {
                        try self.lambda_frames.items[frame_index].captures.add(symbol);
                    }
                }
                return symbol;
            }
            if (next_frame > 0 and id == self.lambda_frames.items[next_frame - 1].boundary) {
                next_frame -= 1;
                try crossed_frames.append(self.allocator, next_frame);
            }
            scope_id = scope_entry.parent;
        }
        return null;
    }

    fn scopeById(self: *ScopeStack, id: ScopeId) *Scope {
        return &self.scopes.items[@intFromEnum(id)];
    }

    // Публичный метод, чтобы вызывающий код (например, проверка
    // неиспользуемых переменных в `resolver.zig`) мог перечислить символы
    // области видимости прямо перед её удалением — единственный безопасный
    // момент: блоки строго вложены, подъёма объявлений нет, поэтому к
    // моменту `pop` все возможные ссылки на эту область уже посещены
    // однопроходным прямым обходом резолвера.
    pub fn scopeByIdConst(self: *const ScopeStack, id: ScopeId) *const Scope {
        return &self.scopes.items[@intFromEnum(id)];
    }
};

test "symbol store creates stable IDs and qualified names" {
    var store = try SymbolStore.init(std.testing.allocator);
    defer store.deinit();

    const symbol = try store.add(.{
        .name = "значение",
        .kind = .variable,
        .module_path = "main.ps",
        .span = .{ .file_id = 1, .start = 4, .end = 12 },
    });
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(symbol));
    const entry = store.get(symbol).?;
    try std.testing.expectEqualStrings("значение", entry.name);
    try std.testing.expectEqualStrings("main.ps::значение", entry.full_name);
    try std.testing.expectEqualDeep(source.Span{ .file_id = 1, .start = 4, .end = 12 }, entry.span);
}

test "scopes shadow outer names without duplicate local declarations" {
    var store = try SymbolStore.init(std.testing.allocator);
    defer store.deinit();
    var scopes = try ScopeStack.init(std.testing.allocator);
    defer scopes.deinit();

    const outer = try store.add(.{ .name = "имя", .kind = .variable, .span = .{ .file_id = 0, .start = 0, .end = 3 } });
    try scopes.declare(&store, outer);
    try std.testing.expectEqual(outer, scopes.lookup("имя").?);
    try std.testing.expectError(error.DuplicateSymbol, scopes.declare(&store, outer));

    _ = try scopes.push();
    const inner = try store.add(.{ .name = "имя", .kind = .variable, .span = .{ .file_id = 0, .start = 4, .end = 7 } });
    try scopes.declare(&store, inner);
    try std.testing.expectEqual(inner, scopes.lookup("имя").?);
    _ = try scopes.pop();
    try std.testing.expectEqual(outer, scopes.lookup("имя").?);
    try std.testing.expectError(error.CannotPopRootScope, scopes.pop());
}

test "nested lambdas capture only outer runtime symbols in lookup order" {
    var store = try SymbolStore.init(std.testing.allocator);
    defer store.deinit();
    var scopes = try ScopeStack.init(std.testing.allocator);
    defer scopes.deinit();

    const global_value = try store.add(.{ .name = "глобальный", .kind = .variable, .span = .{ .file_id = 0, .start = 0, .end = 1 } });
    const type_name = try store.add(.{ .name = "Тип", .kind = .type, .span = .{ .file_id = 0, .start = 2, .end = 3 } });
    try scopes.declare(&store, global_value);
    try scopes.declare(&store, type_name);

    _ = try scopes.enterLambda();
    const outer_local = try store.add(.{ .name = "внешний", .kind = .variable, .span = .{ .file_id = 0, .start = 4, .end = 5 } });
    try scopes.declare(&store, outer_local);
    _ = try scopes.enterLambda();

    try std.testing.expectEqual(global_value, (try scopes.lookupTrackingCaptures(&store, "глобальный")).?);
    try std.testing.expectEqual(outer_local, (try scopes.lookupTrackingCaptures(&store, "внешний")).?);
    try std.testing.expectEqual(type_name, (try scopes.lookupTrackingCaptures(&store, "Тип")).?);

    var inner_captures = try scopes.leaveLambda();
    defer inner_captures.deinit();
    try std.testing.expectEqualSlices(SymbolId, &.{ global_value, outer_local }, inner_captures.values.items);

    var outer_captures = try scopes.leaveLambda();
    defer outer_captures.deinit();
    try std.testing.expectEqualSlices(SymbolId, &.{global_value}, outer_captures.values.items);
}
