const std = @import("std");
const bytecode = @import("bytecode.zig");
const compiler = @import("compiler.zig");
const diagnostic = @import("diagnostic.zig");
const module_linker = @import("module_linker.zig");
const module_loader = @import("module_loader.zig");
const resolver = @import("resolver.zig");
const symbols = @import("symbols.zig");
const type_checker = @import("type_checker.zig");
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

    pub fn init(allocator: std.mem.Allocator) GraphCompileResult {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .program = bytecode.Program.init(allocator),
        };
    }

    pub fn deinit(self: *GraphCompileResult) void {
        for (self.modules) |*module| module.deinit();
        if (self.modules.len != 0) self.allocator.free(self.modules);
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
    functions: std.ArrayList(compiler.ImportedFunction) = .empty,
    constants: std.ArrayList(compiler.ImportedConstant) = .empty,

    fn init(allocator: std.mem.Allocator) ImportContext {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ImportContext) void {
        self.constants.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.imported_types.deinit(self.allocator);
        self.* = undefined;
    }

    fn collect(self: *ImportContext, resolution: *const resolver.Resolution, modules: []const ModuleCompilation) !void {
        var imported_symbols = resolution.imported_symbols.iterator();
        while (imported_symbols.next()) |entry| {
            const imported_symbol = entry.key_ptr.*;
            const origin = entry.value_ptr.*;
            const exported = resolution.symbols.get(imported_symbol) orelse continue;
            const target = &modules[origin.module];
            const target_resolution = if (target.resolution) |*value| value else return error.ImportNotCompiled;
            const target_checked = if (target.checked) |*value| value else return error.ImportNotChecked;
            const target_compiled = if (target.compiled) |*value| value else return error.ImportNotCompiled;
            const target_symbol = target_resolution.decl_symbols.get(origin.declaration) orelse continue;
            const signature = target_checked.symbol_types.get(target_symbol) orelse continue;

            switch (exported.kind) {
                .function => {
                    const function_id = target_compiled.function_ids.get(target_symbol) orelse continue;
                    try self.imported_types.append(self.allocator, .{
                        .symbol = imported_symbol,
                        .store = &target_checked.types,
                        .type_id = signature,
                    });
                    try self.functions.append(self.allocator, .{
                        .symbol = imported_symbol,
                        .function_id = function_id,
                    });
                },
                .constant => {
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
    }
};

pub fn compileGraph(allocator: std.mem.Allocator, graph: *const module_loader.Graph) !GraphCompileResult {
    var result = GraphCompileResult.init(allocator);
    errdefer result.deinit();
    try result.appendDiagnostics(&graph.diagnostics);
    if (result.hasErrors()) return result;

    result.modules = try allocator.alloc(ModuleCompilation, graph.modules.items.len);
    @memset(result.modules, .{});
    for (graph.order.items) |module_index| {
        const module = &graph.modules.items[module_index];
        var scope = try module_linker.ImportScope.init(allocator, graph, module_index);
        defer scope.deinit();

        result.modules[module_index].resolution = try resolver.resolveWithImports(allocator, &module.tree, scope.modules);
        const resolution = &result.modules[module_index].resolution.?;
        try result.appendDiagnostics(&resolution.diagnostics);
        if (result.hasErrors()) return result;

        var imports = ImportContext.init(allocator);
        defer imports.deinit();
        try imports.collect(resolution, result.modules);

        result.modules[module_index].checked = try type_checker.checkWithImports(allocator, &module.tree, resolution, imports.imported_types.items);
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
