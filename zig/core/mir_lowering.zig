const std = @import("std");
const ast = @import("ast.zig");
const mir = @import("mir.zig");
const mir_builder = @import("mir_builder.zig");
const resolver = @import("resolver.zig");
const source = @import("source.zig");
const symbols = @import("symbols.zig");
const type_checker = @import("type_checker.zig");
const types = @import("types.zig");
const wasm_module = @import("wasm_module.zig");
const wasm_heap = @import("wasm_heap.zig");

// Not tied to any real declared variable — same "dummy" convention
// `wasm_heap.zig` already established for compiler-synthesized locals.
const dummy_symbol: symbols.SymbolId = @enumFromInt(0);


// AST (post resolve+typecheck) → MIR. Ported from `core/mir_lowering.odin`
// (~2000 lines there) — works at the SAME pipeline point `compiler.zig`
// already does: reads the already-computed resolver/type-checker side
// tables (`resolution.expr_symbols`/`decl_symbols`/`function_parameters`,
// `checked.expression_types`/`symbol_types`/`types`), NEVER mutates or
// recomputes them, never modifies the AST.
//
// SCOPE — deliberately narrower than even Odin's own "Phase 1" (see that
// file's own doc comment): number/boolean/string literals, locals
// (declare/read via `пер`/parameters), unary/binary operators (including
// short-circuit `и`/`или`), `если`/`иначе`, `пока` (+ `прервать`/
// `продолжить`), plain function calls (by identifier OR by an arbitrary
// value — the generic `Call_Value_Instr` fallback), `возврат`. NOT covered
// (reported via `unsupported`, matching Odin's `lower_unsupported` —
// panics with a clear message rather than silently producing incorrect
// MIR, since this pipeline isn't reachable from normal compilation yet):
// `выбор`/ADTs, closures, interfaces, actors, async I/O, generics,
// operator-overload sugar (Сравниваемое/Арифметика), `для`/`для..in`,
// destructuring, builtins, methods, `внешний`. Each of these is a REAL
// Phase-2-equivalent addition, not an oversight — same split Odin made.

pub const FlowResult = enum { continues, terminates };

const ExprOutcome = struct {
    value: mir.ValueId,
    flow: FlowResult,
};

fn continuesWith(value: mir.ValueId) ExprOutcome {
    return .{ .value = value, .flow = .continues };
}

const terminated: ExprOutcome = .{ .value = mir.invalid_value, .flow = .terminates };

const LoopTargets = struct {
    continue_target: mir.BlockId,
    break_target: mir.BlockId,
};

// Populated ONLY while lowering a lambda BODY (`lowerLambda` below) — a
// captured symbol resolves via `frame_load{env_local, slot}` instead of
// the ordinary `symbol_to_local` map, since it lives in the closure's
// environment allocation, not a real WASM local of the lambda body
// itself. `env_local` is the lambda body's own trailing `env_ptr`
// parameter (a `LocalId`, loaded fresh via `load_local` each time it's
// needed — same "reload from a Local" discipline this whole file
// already uses everywhere else).
const CaptureEnv = struct {
    env_local: mir.LocalId,
    index_of: std.AutoHashMap(symbols.SymbolId, u32),

    fn deinit(self: *CaptureEnv) void {
        self.index_of.deinit();
    }
};

const LoweringContext = struct {
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
    builder: mir_builder.Builder,
    symbol_to_local: std.AutoHashMap(symbols.SymbolId, mir.LocalId),
    symbol_to_function: *const std.AutoHashMap(symbols.SymbolId, mir.FunctionId),
    loops: std.ArrayList(LoopTargets) = .empty,
    capture_env: ?CaptureEnv = null,

    fn deinit(self: *LoweringContext) void {
        self.loops.deinit(self.allocator);
        self.symbol_to_local.deinit();
        if (self.capture_env) |*env| env.deinit();
        self.* = undefined;
    }
};

// Was `@panic(...)` — crashed the whole `panos build --target=wasm`
// process with a Zig stack trace on ANY unsupported-for-wasm construct
// (real Phase-1 scope gaps: `для..в`, struct methods, ADTs beyond
// simple match, ...). Prints the specific reason immediately (the only
// place that context exists — by the time an `anyerror!` unwinds to
// `cli/main.zig`'s catch, the "what" string is long gone) and returns a
// plain error instead, so `lowerModule`/`lowerGraph`'s caller can report
// a clean compile failure (exit code, no trace) like every other AOT
// failure mode already does (`emitModule`/`writeFile` in `main.zig`).
fn unsupported(comptime what: []const u8) error{AotUnsupported} {
    std.debug.print("panos build: AOT (wasm) не поддерживает — " ++ what ++ "\n", .{});
    return error.AotUnsupported;
}

fn expressionSpan(tree: *const ast.Ast, expression: ast.ExprId) source.Span {
    return switch (tree.expr(expression).*) {
        .error_node => |span| span,
        inline else => |value| value.span,
    };
}

fn functionReturnType(checked: *const type_checker.CheckResult, symbol: symbols.SymbolId) types.TypeId {
    const signature_id = checked.symbol_types.get(symbol) orelse return checked.types.builtins.void;
    const entry = checked.types.get(signature_id) orelse return checked.types.builtins.void;
    return switch (entry.*) {
        .function => |value| value.return_type,
        else => checked.types.builtins.void,
    };
}

pub fn lowerModule(
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
) !mir.Module {
    var module = mir.Module.init(allocator);
    errdefer module.deinit(allocator);

    var symbol_to_function: std.AutoHashMap(symbols.SymbolId, mir.FunctionId) = .init(allocator);
    defer symbol_to_function.deinit();

    const program = tree.program orelse return module;

    // Two-pass — pass 1 reserves every function (forward references and
    // recursion both need the callee's FunctionId to exist before any
    // body is lowered); pass 2 lowers bodies.
    for (program.declarations) |decl_id| {
        const function = switch (tree.decl(decl_id).*) {
            .function => |value| value,
            else => continue,
        };
        // Generic free functions are no longer skipped (were, "Phase 2")
        // — panos generics are never monomorphized (see `type_checker.
        // zig`'s own doc comments), so a generic body compiles exactly
        // once, unspecialized, the SAME reasoning already applied to
        // `.interface_decl` default methods this session (see
        // `reserveMethods`'s own doc comment on that arm). Safe under
        // the same condition: `T` must only ever be touched through an
        // interface bound (ordinary `checked.interface_calls`/
        // `interface_casts` dispatch, ALREADY handled by `lowerCall`/
        // `applyInterfaceCast` — ordinary interface dispatch doesn't
        // care whether the interface-typed value came from a generic
        // bound-cast or an explicit non-generic interface parameter) or
        // as an opaque `.nominal`/`.function`/struct-field pass-through
        // (`wasm_objects.zig`'s `frame_store`/`frame_load` type each
        // value from its OWN concrete producing expression at that call
        // site, never from the generic declared type) — NOT as a bare
        // returned/stored `T` value whose OWN WASM representation
        // (i32 vs f64) could legitimately differ across different
        // instantiations reachable from the same compiled body (that
        // narrower case would need real per-instantiation specialization,
        // not attempted here — no such function exists in the prelude or
        // any current fixture).
        const symbol = resolution.decl_symbols.get(decl_id) orelse continue;
        const result_type = functionReturnType(checked, symbol);
        const function_id = try mir_builder.newFunction(&module, allocator, function.name, symbol, result_type, function.span);
        module.functions.items[@intFromEnum(function_id)].type_store = &checked.types;
        try symbol_to_function.put(symbol, function_id);
    }
    try reserveMethods(&module, allocator, tree, resolution, checked, program, &symbol_to_function, null, 0);

    for (program.declarations) |decl_id| {
        const function = switch (tree.decl(decl_id).*) {
            .function => |value| value,
            else => continue,
        };
        const symbol = resolution.decl_symbols.get(decl_id) orelse continue;
        const function_id = symbol_to_function.get(symbol) orelse continue;
        try lowerFunctionBody(allocator, tree, resolution, checked, &module, function_id, decl_id, function.body, &symbol_to_function);
    }
    try lowerMethods(&module, allocator, tree, resolution, checked, program, &symbol_to_function);

    return module;
}

// `реализация Тип ... конец` methods — compiled by the NATIVE bytecode
// backend (`compiler.zig`) as nothing more than an extra pass over
// `implementation.methods` calling the same `predeclareFunction`/
// `compileFunction` used for top-level `.function` decls (`это` is
// just `parameters[0]`, no special binding) — `mir_lowering.zig` had
// ZERO handling for `.impl` at all before this (confirmed: reservation
// switched only `.function`, `.impl` fell into `else => continue`),
// which made ANY struct method (e.g. `std/математика.pns`'s
// `Генератор.следующее()`) an AOT-unsupported compile error (a process
// panic before an earlier fix this session). Mirrors the native path
// exactly: `lowerFunctionBody` is already fully generic over
// `decl_id`/`body`, a method needs nothing method-specific there.
//
// The one real difference from a plain function: the name a method's
// `FunctionId` is reserved under is MANGLED (`"{Тип}::{метод}"`, same
// convention the native VM already uses for its own method registry —
// see the "interface vtables" fix) rather than the bare method name,
// because `wasm_emit.zig`'s export section writes EVERY function's
// name unconditionally with no dedup — two different structs both
// defining a same-named method (e.g. `.длина()`-shaped collisions)
// would otherwise produce duplicate WASM export entries.
fn mangledMethodName(module: *mir.Module, target_type: []const u8, method_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(module.arena.allocator(), "{s}::{s}", .{ target_type, method_name });
}

fn reserveMethods(
    module: *mir.Module,
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
    program: anytype,
    symbol_to_function: *std.AutoHashMap(symbols.SymbolId, mir.FunctionId),
    reachable: ?*const ReachableSet,
    module_index: usize,
) !void {
    for (program.declarations) |decl_id| {
        switch (tree.decl(decl_id).*) {
            .impl => |implementation| for (implementation.methods) |method_decl_id| {
                const function = tree.decl(method_decl_id).function;
                const symbol = resolution.decl_symbols.get(method_decl_id) orelse continue;
                if (!isReachable(reachable, module_index, symbol)) continue;
                const result_type = functionReturnType(checked, symbol);
                const name = try mangledMethodName(module, implementation.target_type, function.name);
                const function_id = try mir_builder.newFunction(module, allocator, name, symbol, result_type, function.span);
                module.functions.items[@intFromEnum(function_id)].type_store = &checked.types;
                try symbol_to_function.put(symbol, function_id);
            },
            // Default interface methods (`тип X = интерфейс \n функ м(это:
            // X(...), ...) -> ... \n <тело> \n конец`) — a SEPARATE
            // declaration kind from `.impl` (mirrors `compiler.zig`'s own
            // `predeclareFunctions`: `.impl` and `.interface_decl` handled
            // as two arms of the same switch, not one). `это`'s receiver
            // here is the ABSTRACT interface type, not a concrete struct —
            // reserved the SAME way regardless (mangled `"{Интерфейс}::
            // {метод}"` name, ordinary `newFunction` — the interface-vs-
            // concrete distinction only matters for the CALLING convention,
            // handled separately in `wasm_interfaces.zig`).
            .interface_decl => |interface| for (interface.default_methods) |method_decl_id| {
                const function = tree.decl(method_decl_id).function;
                const symbol = resolution.decl_symbols.get(method_decl_id) orelse continue;
                if (!isReachable(reachable, module_index, symbol)) continue;
                const result_type = functionReturnType(checked, symbol);
                const name = try mangledMethodName(module, interface.name, function.name);
                const function_id = try mir_builder.newFunction(module, allocator, name, symbol, result_type, function.span);
                module.functions.items[@intFromEnum(function_id)].type_store = &checked.types;
                try symbol_to_function.put(symbol, function_id);
            },
            else => {},
        }
    }
}

fn lowerMethods(
    module: *mir.Module,
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
    program: anytype,
    symbol_to_function: *const std.AutoHashMap(symbols.SymbolId, mir.FunctionId),
) !void {
    for (program.declarations) |decl_id| {
        switch (tree.decl(decl_id).*) {
            .impl => |implementation| for (implementation.methods) |method_decl_id| {
                const function = tree.decl(method_decl_id).function;
                const symbol = resolution.decl_symbols.get(method_decl_id) orelse continue;
                const function_id = symbol_to_function.get(symbol) orelse continue;
                try lowerFunctionBody(allocator, tree, resolution, checked, module, function_id, method_decl_id, function.body, symbol_to_function);
            },
            .interface_decl => |interface| for (interface.default_methods) |method_decl_id| {
                const function = tree.decl(method_decl_id).function;
                const symbol = resolution.decl_symbols.get(method_decl_id) orelse continue;
                const function_id = symbol_to_function.get(symbol) orelse continue;
                try lowerFunctionBody(allocator, tree, resolution, checked, module, function_id, method_decl_id, function.body, symbol_to_function);
            },
            else => {},
        }
    }
}

// --- Tree-shaking -----------------------------------------------------
//
// `cli/main.zig`'s AOT build path always links the FULL prelude into the
// module graph, unconditionally — every declaration, whether or not the
// actual program calls it. Every "AOT (wasm) не поддерживает X" build
// failure hit across this whole multi-session WASM-AOT initiative
// (generic struct fields, interface dispatch, default interface methods,
// closures-as-values, cross-module TypeStore bugs...) was in prelude code
// NO test program was even using — just reachable-in-principle. Without
// reachability filtering, the NEXT unfamiliar prelude feature blocks the
// NEXT program the exact same way, forever. This must run BEFORE
// lowering (not as a dead-code-eliminate pass on the already-lowered MIR
// module) — an unreachable declaration that fails to LOWER aborts the
// whole build before any later pass could ever get a chance to discard
// it.
//
// `SymbolId` is scoped per-module (a fresh `Resolution` per file — see
// `lowerGraph`'s own "Imported symbols are freshly minted in the
// importing Resolution" comment above), so a bare `SymbolId` is not
// globally unique across the graph; every reachability key carries its
// owning module index alongside the symbol.
const ReachKey = struct {
    module_index: usize,
    symbol: symbols.SymbolId,
};
pub const ReachableSet = std.AutoHashMap(ReachKey, void);

// A generic function/method's parameter or return type that stays a
// BARE, unwrapped `.generic_parameter` (not `.nominal`/`.function` — see
// `5cced87`'s own doc comment on why those ARE safe unspecialized) needs
// ONE consistent WASM representation across every call site reachable in
// the compiled program. `Category` classifies a concrete instantiation's
// WASM value shape the same way `wasm_module.wasmValTypeForStore` does;
// `MixedMap` records, per generic symbol, which categories were actually
// seen — more than one means a single unspecialized compiled body would
// need to treat the SAME local/return slot as both an i32 handle and an
// f64 number depending on the caller, which is not representable without
// real per-instantiation specialization (deliberately not implemented —
// see `project_panos_wasm_no_monomorphization_needed` memory).
const Category = enum { i32_like, f64_like };
const MixedMap = std.AutoHashMap(ReachKey, std.EnumSet(Category));

fn categoryOf(store: *const types.TypeStore, type_id: types.TypeId) Category {
    return if (wasm_module.wasmValTypeForStore(store, type_id) == wasm_module.wasm_i32) .i32_like else .f64_like;
}

fn isBareGenericParameter(store: *const types.TypeStore, type_id: types.TypeId) bool {
    const entry = store.get(type_id) orelse return false;
    return entry.* == .generic_parameter;
}

// Resolves `symbol`'s own function/method SIGNATURE type directly from
// `checked.symbol_types` (a `.function{parameters, return_type}` —
// panos generic signatures are stored as ordinary function types, T's
// substitution status included, same lookup `functionReturnType` already
// uses for the return half). Returns `null` for anything that isn't a
// "risky" generic signature (no bare `.generic_parameter` anywhere in
// it) — the common, safe case, skipped without further work.
const RiskySignature = struct { parameters: []const types.TypeId, return_type: types.TypeId };

fn riskyGenericSignature(checked: *const type_checker.CheckResult, symbol: symbols.SymbolId) ?RiskySignature {
    const signature_id = checked.symbol_types.get(symbol) orelse return null;
    const entry = checked.types.get(signature_id) orelse return null;
    const function_type = switch (entry.*) {
        .function => |value| value,
        else => return null,
    };
    var risky = isBareGenericParameter(&checked.types, function_type.return_type);
    if (!risky) for (function_type.parameters) |parameter| {
        if (isBareGenericParameter(&checked.types, parameter)) {
            risky = true;
            break;
        }
    };
    if (!risky) return null;
    return RiskySignature{ .parameters = function_type.parameters, .return_type = function_type.return_type };
}

// Records, for a CALL to a "risky" generic symbol, which WASM
// representation category each risky-typed argument's ACTUAL concrete
// type maps to — called from `walkExpr`'s own `.call` case, reusing the
// SAME import-redirect logic `recordReference` already applies (a
// generic function called across a module boundary must be tracked
// under the EXPORTING module's own symbol, not the importing alias).
fn recordGenericInstantiation(
    compiled: anytype,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
    mixed: *MixedMap,
    module_index: usize,
    callee_symbol: symbols.SymbolId,
    call: anytype,
) !void {
    var target_module_index = module_index;
    var target_symbol = callee_symbol;
    if (resolution.imported_symbols.get(callee_symbol)) |origin| {
        const target_resolution = if (compiled.modules[origin.module].resolution) |*value| value else return;
        target_symbol = target_resolution.decl_symbols.get(origin.declaration) orelse return;
        target_module_index = origin.module;
    }
    const target_checked = if (compiled.modules[target_module_index].checked) |*value| value else return;
    const signature = riskyGenericSignature(target_checked, target_symbol) orelse return;

    const key = ReachKey{ .module_index = target_module_index, .symbol = target_symbol };
    const shared = @min(call.arguments.len, signature.parameters.len);
    for (call.arguments[0..shared], signature.parameters[0..shared]) |argument, parameter_type| {
        if (!isBareGenericParameter(&target_checked.types, parameter_type)) continue;
        const argument_type = checked.expression_types.get(argument) orelse continue;
        const category = categoryOf(&checked.types, argument_type);
        const entry = try mixed.getOrPut(key);
        if (!entry.found_existing) entry.value_ptr.* = .initEmpty();
        entry.value_ptr.insert(category);
    }
}

fn isReachable(reachable: ?*const ReachableSet, module_index: usize, symbol: symbols.SymbolId) bool {
    // `null` — no filtering at all (the single-file `lowerModule` path
    // used by unit tests, which has no real module graph / entry point
    // to compute reachability from) — every declaration compiles,
    // exactly like before tree-shaking existed.
    const set = reachable orelse return true;
    return set.contains(.{ .module_index = module_index, .symbol = symbol });
}

fn markReachable(allocator: std.mem.Allocator, set: *ReachableSet, worklist: *std.ArrayList(ReachKey), module_index: usize, symbol: symbols.SymbolId) !void {
    const key = ReachKey{ .module_index = module_index, .symbol = symbol };
    if (set.contains(key)) return;
    try set.put(key, {});
    try worklist.append(allocator, key);
}

// A referenced symbol may be a LOCAL declaration in `module_index`'s own
// module, or an IMPORT ALIAS — `resolution.imported_symbols` (freshly
// minted per importing module, see `lowerGraph`'s own comment) redirects
// an alias straight to the exporting declaration's OWN module + symbol,
// the exact same redirect `lowerGraph`'s existing "Imported symbols..."
// loop already performs for `function_maps` — reused here unchanged.
fn recordReference(
    allocator: std.mem.Allocator,
    compiled: anytype,
    resolution: *const resolver.Resolution,
    set: *ReachableSet,
    worklist: *std.ArrayList(ReachKey),
    module_index: usize,
    symbol: symbols.SymbolId,
) !void {
    if (resolution.imported_symbols.get(symbol)) |origin| {
        const target_resolution = if (compiled.modules[origin.module].resolution) |*value| value else return;
        const target_symbol = target_resolution.decl_symbols.get(origin.declaration) orelse return;
        try markReachable(allocator, set, worklist, origin.module, target_symbol);
        return;
    }
    try markReachable(allocator, set, worklist, module_index, symbol);
}

// Finds the body of whichever declaration (top-level function, `.impl`
// method, or `.interface_decl` default method) owns `symbol` in this
// module — a plain linear scan (not a pre-built reverse index): this
// runs once per worklist item, not a hot path, and program sizes here
// are small enough that the extra bookkeeping of a cached reverse map
// isn't worth it.
fn findSymbolBody(tree: *const ast.Ast, resolution: *const resolver.Resolution, symbol: symbols.SymbolId) ?[]const ast.StmtId {
    const program = tree.program orelse return null;
    for (program.declarations) |decl_id| {
        switch (tree.decl(decl_id).*) {
            .function => |function| {
                if ((resolution.decl_symbols.get(decl_id) orelse continue) == symbol) return function.body;
            },
            .impl => |implementation| for (implementation.methods) |method_decl_id| {
                if ((resolution.decl_symbols.get(method_decl_id) orelse continue) == symbol) return tree.decl(method_decl_id).function.body;
            },
            .interface_decl => |interface| for (interface.default_methods) |method_decl_id| {
                if ((resolution.decl_symbols.get(method_decl_id) orelse continue) == symbol) return tree.decl(method_decl_id).function.body;
            },
            else => {},
        }
    }
    return null;
}

// Every interface cast anywhere in reachable code pulls in the concrete
// implementation it resolves to — mirrors `applyInterfaceCast`'s own
// vtable-building loop exactly (same `findInterfaceImplementation` call,
// same default-vs-override method selection), just marking symbols
// reachable instead of emitting MIR. Checked at EVERY expression (not
// just calls) — `registerInterfaceCast` (type_checker.zig) attaches a
// cast to let-bindings/returns/params/array-or-map-elements, not only
// call arguments.
fn recordInterfaceCastEdges(
    allocator: std.mem.Allocator,
    compiled: anytype,
    checked: *const type_checker.CheckResult,
    resolution: *const resolver.Resolution,
    set: *ReachableSet,
    worklist: *std.ArrayList(ReachKey),
    module_index: usize,
    expression: ast.ExprId,
) !void {
    const cast = checked.interface_casts.get(expression) orelse return;
    for (cast.entries) |entry| {
        var ambiguous = false;
        const implementation = type_checker.findInterfaceImplementation(checked, entry.interface, entry.arguments, entry.target, entry.target_arguments, &ambiguous) orelse continue;
        for (implementation.methods) |method_symbol| {
            try recordReference(allocator, compiled, resolution, set, worklist, module_index, method_symbol);
        }
    }
}

fn walkExpr(
    allocator: std.mem.Allocator,
    compiled: anytype,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
    set: *ReachableSet,
    worklist: *std.ArrayList(ReachKey),
    mixed: *MixedMap,
    module_index: usize,
    expression: ast.ExprId,
) anyerror!void {
    if (resolution.expr_symbols.get(expression)) |symbol| {
        try recordReference(allocator, compiled, resolution, set, worklist, module_index, symbol);
    }
    if (checked.method_calls.get(expression)) |symbol| {
        try recordReference(allocator, compiled, resolution, set, worklist, module_index, symbol);
    }
    try recordInterfaceCastEdges(allocator, compiled, checked, resolution, set, worklist, module_index, expression);

    switch (tree.expr(expression).*) {
        .number, .boolean, .string, .ident, .error_node => {},
        .unary => |v| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.operand),
        .cast => |v| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.operand),
        .binary => |v| {
            try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.left);
            try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.right);
        },
        .call => |v| {
            if (resolution.expr_symbols.get(v.callee)) |callee_symbol| {
                try recordGenericInstantiation(compiled, resolution, checked, mixed, module_index, callee_symbol, v);
            }
            if (checked.method_calls.get(expression)) |method_symbol| {
                try recordGenericInstantiation(compiled, resolution, checked, mixed, module_index, method_symbol, v);
            }
            try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.callee);
            for (v.arguments) |argument| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, argument);
        },
        .spawn => |v| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.call),
        .select_wait => |v| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.source),
        .property => |v| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.object),
        .if_expr => |v| {
            try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.condition);
            try walkStmts(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.then_branch);
            try walkStmts(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.else_branch);
        },
        .while_expr => |v| {
            try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.condition);
            try walkStmts(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.body);
        },
        .tuple => |v| for (v.elements) |element| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, element),
        .lambda => |v| try walkStmts(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.body),
        .array => |v| for (v.elements) |element| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, element),
        .map => |v| for (v.entries) |entry| {
            try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, entry.key);
            try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, entry.value);
        },
        .index => |v| {
            try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.object);
            try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.index);
        },
        .try_expr => |v| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.value),
        .match_expr => |v| {
            try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.subject);
            for (v.arms) |arm| {
                if (tree.pattern(arm.pattern).* == .literal) try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, tree.pattern(arm.pattern).literal.value);
                try walkStmts(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, arm.body);
            }
        },
    }
}

fn walkStmts(
    allocator: std.mem.Allocator,
    compiled: anytype,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
    set: *ReachableSet,
    worklist: *std.ArrayList(ReachKey),
    mixed: *MixedMap,
    module_index: usize,
    statements: []const ast.StmtId,
) anyerror!void {
    for (statements) |statement| {
        switch (tree.stmt(statement).*) {
            .return_stmt => |v| if (v.value) |value| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, value),
            .let => |v| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.value),
            .expr => |v| try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.value),
            .for_in => |v| {
                try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.iterable);
                try walkStmts(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.body);
            },
            .for_range => |v| {
                try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.start);
                try walkExpr(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.end);
                try walkStmts(allocator, compiled, tree, resolution, checked, set, worklist, mixed, module_index, v.body);
            },
            .continue_stmt, .break_stmt, .error_node => {},
        }
    }
}

// `DOM.на_клик` (2-arg form, no context, OR 3-arg form — SAME source-
// level property name either way, `lowerDomBuiltinCall` disambiguates
// by argument COUNT into `DOM::на_клик`/`DOM::на_клик_контекст`
// internally) and `DOM.после_кадра` take a handler function's NAME as a
// STRING LITERAL argument (`aot-dom-loader.js`'s `instance.exports[name]`
// — resolved by STRING at runtime, invisible to the ordinary call-graph
// walk above). Scans every string-literal argument to one of these
// calls anywhere in ALREADY-reachable code (a second pass, after the
// main worklist settles once) and, for each one that exactly matches
// some top-level function's own name, adds that function as an extra
// root. Caller re-drains the worklist to a fixpoint afterward — a
// newly-added handler can itself reference more calls/casts/handlers.
fn addDomHandlerRoots(
    allocator: std.mem.Allocator,
    graph: anytype,
    compiled: anytype,
    set: *ReachableSet,
    worklist: *std.ArrayList(ReachKey),
    handler_names: *std.ArrayList([]const u8),
) !void {
    for (graph.order.items) |module_index| {
        const resolution = if (compiled.modules[module_index].resolution) |*value| value else continue;
        const checked = if (compiled.modules[module_index].checked) |*value| value else continue;
        const tree = &graph.modules.items[module_index].tree;
        const program = tree.program orelse continue;
        try scanDomHandlerRootsInDecls(allocator, graph, compiled, tree, resolution, checked, set, worklist, handler_names, module_index, program.declarations);
    }
}

fn scanDomHandlerRootsInDecls(
    allocator: std.mem.Allocator,
    graph: anytype,
    compiled: anytype,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
    set: *ReachableSet,
    worklist: *std.ArrayList(ReachKey),
    handler_names: *std.ArrayList([]const u8),
    module_index: usize,
    declarations: []const ast.DeclId,
) !void {
    for (declarations) |decl_id| {
        const body: []const ast.StmtId = switch (tree.decl(decl_id).*) {
            .function => |function| function.body,
            .impl => |implementation| blk: {
                for (implementation.methods) |method_decl_id| try scanDomHandlerRootsInDecls(allocator, graph, compiled, tree, resolution, checked, set, worklist, handler_names, module_index, &.{method_decl_id});
                break :blk &.{};
            },
            .interface_decl => |interface| blk: {
                for (interface.default_methods) |method_decl_id| try scanDomHandlerRootsInDecls(allocator, graph, compiled, tree, resolution, checked, set, worklist, handler_names, module_index, &.{method_decl_id});
                break :blk &.{};
            },
            else => &.{},
        };
        const symbol = resolution.decl_symbols.get(decl_id);
        // Only scan a declaration reachable via the main worklist — the
        // whole point is finding string-literal roots inside code that's
        // ALREADY known to run, not resurrecting dead code via its own
        // handler-registration calls.
        if (symbol == null or !set.contains(.{ .module_index = module_index, .symbol = symbol.? })) continue;
        try scanDomHandlerRootsInStmts(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, body);
    }
}

fn scanDomHandlerRootsInStmts(
    allocator: std.mem.Allocator,
    graph: anytype,
    compiled: anytype,
    tree: *const ast.Ast,
    set: *ReachableSet,
    worklist: *std.ArrayList(ReachKey),
    handler_names: *std.ArrayList([]const u8),
    module_index: usize,
    statements: []const ast.StmtId,
) !void {
    for (statements) |statement| {
        switch (tree.stmt(statement).*) {
            .return_stmt => |v| if (v.value) |value| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, value),
            .let => |v| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.value),
            .expr => |v| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.value),
            .for_in => |v| try scanDomHandlerRootsInStmts(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.body),
            .for_range => |v| try scanDomHandlerRootsInStmts(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.body),
            .continue_stmt, .break_stmt, .error_node => {},
        }
    }
}

fn scanDomHandlerRootsInExpr(
    allocator: std.mem.Allocator,
    graph: anytype,
    compiled: anytype,
    tree: *const ast.Ast,
    set: *ReachableSet,
    worklist: *std.ArrayList(ReachKey),
    handler_names: *std.ArrayList([]const u8),
    module_index: usize,
    expression: ast.ExprId,
) anyerror!void {
    switch (tree.expr(expression).*) {
        .call => |call| {
            if (tree.expr(call.callee).* == .property) {
                const property = tree.expr(call.callee).property;
                const is_handler_call = std.mem.eql(u8, property.property, "на_клик") or
                    std.mem.eql(u8, property.property, "после_кадра");
                if (is_handler_call) {
                    for (call.arguments) |argument| {
                        if (tree.expr(argument).* != .string) continue;
                        const handler_name = tree.expr(argument).string.value;
                        try addRootByName(allocator, graph, compiled, set, worklist, handler_name);
                        try handler_names.append(allocator, handler_name);
                    }
                }
            }
            try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, call.callee);
            for (call.arguments) |argument| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, argument);
        },
        .unary => |v| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.operand),
        .cast => |v| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.operand),
        .binary => |v| {
            try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.left);
            try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.right);
        },
        .spawn => |v| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.call),
        .select_wait => |v| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.source),
        .property => |v| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.object),
        .if_expr => |v| {
            try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.condition);
            try scanDomHandlerRootsInStmts(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.then_branch);
            try scanDomHandlerRootsInStmts(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.else_branch);
        },
        .while_expr => |v| {
            try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.condition);
            try scanDomHandlerRootsInStmts(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.body);
        },
        .tuple => |v| for (v.elements) |element| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, element),
        .lambda => |v| try scanDomHandlerRootsInStmts(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.body),
        .array => |v| for (v.elements) |element| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, element),
        .map => |v| for (v.entries) |entry| {
            try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, entry.key);
            try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, entry.value);
        },
        .index => |v| {
            try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.object);
            try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.index);
        },
        .try_expr => |v| try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.value),
        .match_expr => |v| {
            try scanDomHandlerRootsInExpr(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, v.subject);
            for (v.arms) |arm| try scanDomHandlerRootsInStmts(allocator, graph, compiled, tree, set, worklist, handler_names, module_index, arm.body);
        },
        .number, .boolean, .string, .ident, .error_node => {},
    }
}

// A DOM-handler name is always a plain top-level `функ`, never a method
// (see `dom_on_click_context`'s own doc comment in `aot-dom-loader.js`:
// "name remains a static exported function") — search every module's
// top-level function declarations for a name match, add the FIRST one
// found (handler names are meant to be unambiguous top-level entry
// points; a genuine collision across modules would already be a
// same-module-shadowing question the resolver itself handles elsewhere,
// out of scope here).
fn addRootByName(allocator: std.mem.Allocator, graph: anytype, compiled: anytype, set: *ReachableSet, worklist: *std.ArrayList(ReachKey), name: []const u8) !void {
    for (graph.order.items) |module_index| {
        const resolution = if (compiled.modules[module_index].resolution) |*value| value else continue;
        const tree = &graph.modules.items[module_index].tree;
        const program = tree.program orelse continue;
        for (program.declarations) |decl_id| {
            const function = switch (tree.decl(decl_id).*) {
                .function => |value| value,
                else => continue,
            };
            if (!std.mem.eql(u8, function.name, name)) continue;
            const symbol = resolution.decl_symbols.get(decl_id) orelse continue;
            try markReachable(allocator, set, worklist, module_index, symbol);
            return;
        }
    }
}

pub const ReachabilityResult = struct {
    reachable: ReachableSet,
    // Generic symbols with a bare `.generic_parameter` return/parameter
    // type, called with BOTH i32-category and f64-category concrete
    // arguments somewhere in reachable code — see `MixedMap`'s own doc
    // comment. Empty in the overwhelmingly common case; `lowerGraph`
    // reports these as a clear diagnostic instead of silently
    // miscompiling one of the two instantiations.
    conflicts: std.ArrayList(ReachKey),
    // Every function name found registered as a `на_клик`/
    // `.после_кадра` handler during `addDomHandlerRoots` — see
    // `mir.Module.dom_handler_names`'s own doc comment for why
    // `wasm_gc_arena.zig` needs this. Borrowed slices into AST memory
    // (`graph`/`compiled`'s lifetime) — `lowerGraph` dupes them into
    // `mir.Module`'s own arena before this result is torn down.
    dom_handler_names: std.ArrayList([]const u8),

    pub fn deinit(self: *ReachabilityResult, allocator: std.mem.Allocator) void {
        self.reachable.deinit();
        self.conflicts.deinit(allocator);
        self.dom_handler_names.deinit(allocator);
    }
};

// A symbol's own top-level function/method NAME (for the mixed-generic-
// instantiation diagnostic message) — same linear-scan shape as
// `findSymbolBody`, kept separate rather than combined since most
// callers (the reachability walk itself) only ever need the body.
fn findSymbolName(tree: *const ast.Ast, resolution: *const resolver.Resolution, symbol: symbols.SymbolId) ?[]const u8 {
    const program = tree.program orelse return null;
    for (program.declarations) |decl_id| {
        switch (tree.decl(decl_id).*) {
            .function => |function| {
                if ((resolution.decl_symbols.get(decl_id) orelse continue) == symbol) return function.name;
            },
            .impl => |implementation| for (implementation.methods) |method_decl_id| {
                if ((resolution.decl_symbols.get(method_decl_id) orelse continue) == symbol) return tree.decl(method_decl_id).function.name;
            },
            .interface_decl => |interface| for (interface.default_methods) |method_decl_id| {
                if ((resolution.decl_symbols.get(method_decl_id) orelse continue) == symbol) return tree.decl(method_decl_id).function.name;
            },
            else => {},
        }
    }
    return null;
}

pub fn computeReachableSymbols(allocator: std.mem.Allocator, graph: anytype, compiled: anytype) !ReachabilityResult {
    var set: ReachableSet = .init(allocator);
    errdefer set.deinit();
    var worklist: std.ArrayList(ReachKey) = .empty;
    defer worklist.deinit(allocator);
    var mixed: MixedMap = .init(allocator);
    defer mixed.deinit();

    // Module index 0 is ALWAYS the entry module — `graph.load(...)` (the
    // very first call, before `appendPreludeModule`/any import) assigns
    // it, and `cli/main.zig` itself relies on this exact convention
    // (`compiled.modules[0]`) — NOT `graph.order.items[len - 1]` (that
    // ordering is dependency-topological, and the prelude — appended
    // separately, no explicit import edges pointing AT it — actually
    // sorts FIRST, not last; confirmed by `module_loader.zig`'s own test
    // `expectEqual(prelude_index, graph.order.items[0])`).
    if (graph.modules.items.len == 0) return .{ .reachable = set, .conflicts = .empty, .dom_handler_names = .empty };
    const entry_module_index: usize = 0;
    const entry_resolution = if (compiled.modules[entry_module_index].resolution) |*value| value else return .{ .reachable = set, .conflicts = .empty, .dom_handler_names = .empty };
    const entry_tree = &graph.modules.items[entry_module_index].tree;
    const entry_program = entry_tree.program orelse return .{ .reachable = set, .conflicts = .empty, .dom_handler_names = .empty };
    for (entry_program.declarations) |decl_id| {
        const function = switch (entry_tree.decl(decl_id).*) {
            .function => |value| value,
            else => continue,
        };
        if (!std.mem.eql(u8, function.name, "старт")) continue;
        const symbol = entry_resolution.decl_symbols.get(decl_id) orelse continue;
        try markReachable(allocator, &set, &worklist, entry_module_index, symbol);
        break;
    }

    while (worklist.pop()) |item| {
        const resolution = if (compiled.modules[item.module_index].resolution) |*value| value else continue;
        const checked = if (compiled.modules[item.module_index].checked) |*value| value else continue;
        const tree = &graph.modules.items[item.module_index].tree;
        const body = findSymbolBody(tree, resolution, item.symbol) orelse continue;
        try walkStmts(allocator, compiled, tree, resolution, checked, &set, &worklist, &mixed, item.module_index, body);
    }

    var dom_handler_names: std.ArrayList([]const u8) = .empty;
    errdefer dom_handler_names.deinit(allocator);
    try addDomHandlerRoots(allocator, graph, compiled, &set, &worklist, &dom_handler_names);
    while (worklist.pop()) |item| {
        const resolution = if (compiled.modules[item.module_index].resolution) |*value| value else continue;
        const checked = if (compiled.modules[item.module_index].checked) |*value| value else continue;
        const tree = &graph.modules.items[item.module_index].tree;
        const body = findSymbolBody(tree, resolution, item.symbol) orelse continue;
        try walkStmts(allocator, compiled, tree, resolution, checked, &set, &worklist, &mixed, item.module_index, body);
    }

    var conflicts: std.ArrayList(ReachKey) = .empty;
    errdefer conflicts.deinit(allocator);
    var mixed_iter = mixed.iterator();
    while (mixed_iter.next()) |entry| {
        if (entry.value_ptr.count() > 1) try conflicts.append(allocator, entry.key_ptr.*);
    }

    return .{ .reachable = set, .conflicts = conflicts, .dom_handler_names = dom_handler_names };
}

// Link the already resolved/type-checked module graph into one AOT MIR
// module. The bytecode compiler has its own linker; this deliberately keeps
// an AOT-specific, small equivalent so WASM does not inherit bytecode VM
// assumptions. The initial slice supports plain non-generic functions and
// direct local-file imports — exactly the Phase-1 MIR surface.
pub fn lowerGraph(
    allocator: std.mem.Allocator,
    graph: anytype,
    compiled: anytype,
) !mir.Module {
    var module = mir.Module.init(allocator);
    errdefer module.deinit(allocator);

    // Tree-shaking — see `computeReachableSymbols`'s own doc comment for
    // why this MUST run before any lowering happens, not as a dead-code-
    // eliminate pass afterward.
    var reachability = try computeReachableSymbols(allocator, graph, compiled);
    defer reachability.deinit(allocator);
    if (reachability.conflicts.items.len > 0) {
        const first = reachability.conflicts.items[0];
        const tree = &graph.modules.items[first.module_index].tree;
        if (compiled.modules[first.module_index].resolution) |*resolution| {
            const name = findSymbolName(tree, resolution, first.symbol) orelse "<аноним>";
            std.debug.print("panos build: generic-функция/метод '{s}' вызвана и с числовым, и со структурным/массивным T без специализации\n", .{name});
        }
        return unsupported("generic-функция/метод с несовместимыми инстанциациями T (число и структура/массив в одном скомпилированном теле — не монoморфизировано, см. project_panos_wasm_no_monomorphization_needed)");
    }
    const reachable = &reachability.reachable;

    var function_maps: std.ArrayList(std.AutoHashMap(symbols.SymbolId, mir.FunctionId)) = .empty;
    defer {
        for (function_maps.items) |*map| map.deinit();
        function_maps.deinit(allocator);
    }
    try function_maps.ensureTotalCapacity(allocator, graph.modules.items.len);
    for (0..graph.modules.items.len) |_| try function_maps.append(allocator, .init(allocator));

    // Reserve every local function before lowering any body. This gives
    // forward references, recursion and cross-module direct calls stable
    // global FunctionIds in the resulting WASM module.
    for (graph.order.items) |module_index| {
        const resolution = if (compiled.modules[module_index].resolution) |*value| value else continue;
        const checked = if (compiled.modules[module_index].checked) |*value| value else continue;
        const tree = &graph.modules.items[module_index].tree;
        const program = tree.program orelse continue;
        for (program.declarations) |decl_id| {
            const function = switch (tree.decl(decl_id).*) {
                .function => |value| value,
                else => continue,
            };
            const symbol = resolution.decl_symbols.get(decl_id) orelse continue;
            if (!isReachable(reachable, module_index, symbol)) continue;
            const result_type = functionReturnType(checked, symbol);
            const function_id = try mir_builder.newFunction(&module, allocator, function.name, symbol, result_type, function.span);
            module.functions.items[@intFromEnum(function_id)].type_store = &checked.types;
            try function_maps.items[module_index].put(symbol, function_id);
        }
        try reserveMethods(&module, allocator, tree, resolution, checked, program, &function_maps.items[module_index], reachable, module_index);
    }

    // Imported symbols are freshly minted in the importing Resolution. Map
    // each one back to the reserved FunctionId of its exporting declaration.
    for (graph.order.items) |module_index| {
        const resolution = if (compiled.modules[module_index].resolution) |*value| value else continue;
        var imports = resolution.imported_symbols.iterator();
        while (imports.next()) |entry| {
            const origin = entry.value_ptr.*;
            const target_resolution = if (compiled.modules[origin.module].resolution) |*value| value else continue;
            const target_symbol = target_resolution.decl_symbols.get(origin.declaration) orelse continue;
            const target_function = function_maps.items[origin.module].get(target_symbol) orelse continue;
            try function_maps.items[module_index].put(entry.key_ptr.*, target_function);
        }
    }

    for (graph.order.items) |module_index| {
        const resolution = if (compiled.modules[module_index].resolution) |*value| value else continue;
        const checked = if (compiled.modules[module_index].checked) |*value| value else continue;
        const tree = &graph.modules.items[module_index].tree;
        const program = tree.program orelse continue;
        for (program.declarations) |decl_id| {
            const function = switch (tree.decl(decl_id).*) {
                .function => |value| value,
                else => continue,
            };
            const symbol = resolution.decl_symbols.get(decl_id) orelse continue;
            const function_id = function_maps.items[module_index].get(symbol) orelse continue;
            try lowerFunctionBody(allocator, tree, resolution, checked, &module, function_id, decl_id, function.body, &function_maps.items[module_index]);
        }
        try lowerMethods(&module, allocator, tree, resolution, checked, program, &function_maps.items[module_index]);
    }

    // `reachability.dom_handler_names` holds borrowed slices into AST
    // memory (`graph`'s lifetime) — dupe into `module.arena` (dedup by
    // the same name possibly registered from more than one call site)
    // so `wasm_gc_arena.zig` can rely on them staying valid for as long
    // as the module itself does, without needing `graph`/`compiled`
    // still around.
    var seen_handler_names: std.StringHashMap(void) = .init(allocator);
    defer seen_handler_names.deinit();
    var handler_names_owned: std.ArrayList([]const u8) = .empty;
    const module_arena = module.arena.allocator();
    for (reachability.dom_handler_names.items) |name| {
        if (seen_handler_names.contains(name)) continue;
        try seen_handler_names.put(name, {});
        try handler_names_owned.append(module_arena, try module_arena.dupe(u8, name));
    }
    // `DOM.на_клик_замыкание`'s trampoline (Stage B) isn't found by the
    // string-literal-name scan above at all — closures have no literal
    // name — but it's still a genuine JS-invoked entry point (on every
    // click) needing `wasm_gc_arena.zig`'s checkpoint/restore wrap, same
    // as any name-based handler. A presence check is enough (fixed name,
    // built at most once per module by `findOrBuildInvokeClosureClickTrampoline`).
    if (wasm_heap.findFunctionByName(&module, invoke_closure_click_trampoline_name) != null) {
        try handler_names_owned.append(module_arena, invoke_closure_click_trampoline_name);
    }
    module.dom_handler_names = try handler_names_owned.toOwnedSlice(module_arena);

    return module;
}

fn lowerFunctionBody(
    allocator: std.mem.Allocator,
    tree: *const ast.Ast,
    resolution: *const resolver.Resolution,
    checked: *const type_checker.CheckResult,
    module: *mir.Module,
    function_id: mir.FunctionId,
    decl_id: ast.DeclId,
    body: []const ast.StmtId,
    symbol_to_function: *const std.AutoHashMap(symbols.SymbolId, mir.FunctionId),
) !void {
    var ctx = LoweringContext{
        .allocator = allocator,
        .tree = tree,
        .resolution = resolution,
        .checked = checked,
        .builder = try mir_builder.Builder.beginFunction(module, allocator, function_id),
        .symbol_to_local = .init(allocator),
        .symbol_to_function = symbol_to_function,
    };
    defer ctx.deinit();

    const parameter_symbols = resolution.function_parameters.get(decl_id) orelse &.{};
    var param_locals: std.ArrayList(mir.LocalId) = .empty;
    for (parameter_symbols) |symbol| {
        const type_id = checked.symbol_types.get(symbol) orelse checked.types.builtins.void;
        const local = try ctx.builder.newLocal(symbol, "", type_id);
        try ctx.symbol_to_local.put(symbol, local);
        try param_locals.append(allocator, local);
    }
    ctx.builder.currentFunction().parameters = try param_locals.toOwnedSlice(allocator);

    const result_type = ctx.builder.currentFunction().result_type;
    const want_value = !checked.types.eql(result_type, checked.types.builtins.void);
    const outcome = try lowerBlock(&ctx, body, want_value);
    if (outcome.flow == .continues) {
        ctx.builder.terminate(.{ .return_value = .{ .value = if (want_value) outcome.value else null } });
    }
}

// Block as a value (same principle as `compileBlockValue` today): the last
// expression-statement, in value context, yields its value as the block's
// result instead of being discarded; earlier statements are effect-only.
// An empty block, in value context, is a 0.0 placeholder — same as today.
fn lowerBlock(ctx: *LoweringContext, statements: []const ast.StmtId, want_value: bool) anyerror!ExprOutcome {
    if (statements.len == 0) {
        if (!want_value) return continuesWith(mir.invalid_value);
        return continuesWith(try emitConstNumber(ctx, 0));
    }
    for (statements, 0..) |statement, index| {
        const is_last = index == statements.len - 1;
        if (is_last and want_value) {
            const expression = switch (ctx.tree.stmt(statement).*) {
                .expr => |expr_stmt| expr_stmt.value,
                else => {
                    const flow = try lowerStmt(ctx, statement);
                    if (flow == .terminates) return terminated;
                    return continuesWith(try emitConstNumber(ctx, 0));
                },
            };
            return lowerExpr(ctx, expression);
        }
        const flow = try lowerStmt(ctx, statement);
        if (flow == .terminates) return terminated;
    }
    // Only reachable when `want_value == false` — the last statement, in a
    // value-requesting context, always returns from within the loop above
    // (either via the extracted-expression path or the early-return for a
    // non-expression last statement).
    return continuesWith(mir.invalid_value);
}

fn emitConstNumber(ctx: *LoweringContext, value: f64) !mir.ValueId {
    const dst = try ctx.builder.newValue(ctx.checked.types.builtins.number);
    try ctx.builder.emit(.{ .const_value = .{ .dst = dst, .value = .{ .number = value } } });
    return dst;
}

fn lowerStmt(ctx: *LoweringContext, statement: ast.StmtId) anyerror!FlowResult {
    switch (ctx.tree.stmt(statement).*) {
        .let => |let| {
            if (let.destructure_type != null) return unsupported("деструктурирующее объявление");
            const outcome = try lowerExpr(ctx, let.value);
            if (outcome.flow == .terminates) return .terminates;
            const bindings = ctx.resolution.stmt_bindings.get(statement) orelse &.{};
            if (bindings.len != 1) return unsupported("деструктурирующее объявление");
            const symbol = bindings[0];
            const local_type = ctx.checked.expression_types.get(let.value) orelse ctx.checked.types.builtins.void;
            const local = try ctx.builder.newLocal(symbol, let.name orelse "", local_type);
            try ctx.symbol_to_local.put(symbol, local);
            try ctx.builder.emit(.{ .store_local = .{ .local = local, .src = outcome.value } });
            return .continues;
        },
        .return_stmt => |return_statement| {
            const return_value = return_statement.value orelse {
                ctx.builder.terminate(.{ .return_value = .{ .value = null } });
                return .terminates;
            };
            const outcome = try lowerExpr(ctx, return_value);
            if (outcome.flow == .terminates) return .terminates;
            ctx.builder.terminate(.{ .return_value = .{ .value = outcome.value } });
            return .terminates;
        },
        .expr => |expr_statement| {
            // `если` as a bare statement: lowerIfExpr always lowers with
            // want_value=true when called from expression context (needed
            // for если-as-value), but here (Expr_Stmt — value is ALWAYS
            // discarded) that would create a synthetic merge slot and try
            // to Store_Local an invalid value in any branch with no real
            // value (e.g. `если ... тогда сумма = сумма + i конец` — an
            // assignment produces no value). Real bug Odin's own
            // differential testing caught this exact way — lower with
            // want_value=false explicitly here instead of going through
            // lowerExpr's hardcoded true.
            if (ctx.tree.expr(expr_statement.value).* == .if_expr) {
                const if_expr = ctx.tree.expr(expr_statement.value).if_expr;
                const outcome = try lowerIfExpr(ctx, expr_statement.value, if_expr, false);
                return outcome.flow;
            }
            const outcome = try lowerExpr(ctx, expr_statement.value);
            return outcome.flow;
        },
        .for_range => |range| return lowerForRange(ctx, statement, range),
        .for_in => |loop| return lowerForIn(ctx, statement, loop),
        .continue_stmt => {
            if (ctx.loops.items.len == 0) return unsupported("продолжить вне цикла");
            const target = ctx.loops.items[ctx.loops.items.len - 1].continue_target;
            ctx.builder.terminate(.{ .jump = .{ .target = target } });
            return .terminates;
        },
        .break_stmt => {
            if (ctx.loops.items.len == 0) return unsupported("прервать вне цикла");
            const target = ctx.loops.items[ctx.loops.items.len - 1].break_target;
            ctx.builder.terminate(.{ .jump = .{ .target = target } });
            return .terminates;
        },
        else => return unsupported("вид statement"),
    }
}

fn lowerForRange(ctx: *LoweringContext, statement: ast.StmtId, range: anytype) anyerror!FlowResult {
    const start = try lowerExpr(ctx, range.start);
    if (start.flow == .terminates) return .terminates;
    const end = try lowerExpr(ctx, range.end);
    if (end.flow == .terminates) return .terminates;
    const bindings = ctx.resolution.stmt_bindings.get(statement) orelse return unsupported("для без символа переменной");
    if (bindings.len != 1) return unsupported("для с несколькими переменными");
    const index_type = ctx.checked.expression_types.get(range.start) orelse ctx.checked.types.builtins.number;
    const index_local = try ctx.builder.newLocal(bindings[0], range.name, index_type);
    try ctx.symbol_to_local.put(bindings[0], index_local);
    const end_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$for_end", index_type);
    try ctx.builder.emit(.{ .store_local = .{ .local = end_local, .src = end.value } });
    try ctx.builder.emit(.{ .store_local = .{ .local = index_local, .src = start.value } });
    const header = try ctx.builder.newBlock();
    const body = try ctx.builder.newBlock();
    const step = try ctx.builder.newBlock();
    const exit = try ctx.builder.newBlock();
    ctx.builder.terminate(.{ .jump = .{ .target = header } });
    ctx.builder.setCurrentBlock(header);
    const index_value = try ctx.builder.newValue(index_type);
    const end_value = try ctx.builder.newValue(index_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = index_value, .local = index_local } });
    try ctx.builder.emit(.{ .load_local = .{ .dst = end_value, .local = end_local } });
    const cond = try emitCompare(ctx, .less_equal, index_value, end_value);
    ctx.builder.terminate(.{ .branch = .{ .cond = cond, .then_block = body, .else_block = exit } });
    ctx.builder.setCurrentBlock(body);
    try ctx.loops.append(ctx.allocator, .{ .continue_target = step, .break_target = exit });
    const body_outcome = try lowerBlock(ctx, range.body, false);
    _ = ctx.loops.pop();
    if (body_outcome.flow == .continues) ctx.builder.terminate(.{ .jump = .{ .target = step } });
    ctx.builder.setCurrentBlock(step);
    const current = try ctx.builder.newValue(index_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = current, .local = index_local } });
    const one = try emitConstNumber(ctx, 1);
    const next = try ctx.builder.newValue(index_type);
    try ctx.builder.emit(.{ .binary = .{ .dst = next, .op = .add, .lhs = current, .rhs = one } });
    try ctx.builder.emit(.{ .store_local = .{ .local = index_local, .src = next } });
    ctx.builder.terminate(.{ .jump = .{ .target = header } });
    ctx.builder.setCurrentBlock(exit);
    return .continues;
}

// `для x в массив цикл` — `.array`-shaped iteration only (see
// `type_checker.ForInInfo.kind`, `checked.for_in_infos`); mirrors
// `lowerForRange`'s CFG (header/body/step/exit blocks, index local,
// `.jump` back-edge) with an extra `get_index` per iteration instead of
// yielding the raw counter, matching the native bytecode reference
// (`compiler.zig`'s `compileArrayForIn`). `.iterator`-shaped for-in
// (`следующее()`/`Опция`-based) has no MIR opcodes yet anywhere in this
// file (no `match_enum`/`call_interface`-equivalent instruction exists
// for Phase 1) — stays `unsupported`, a genuinely separate, larger
// follow-up, not a small gap.
fn lowerForIn(ctx: *LoweringContext, statement: ast.StmtId, loop: anytype) anyerror!FlowResult {
    const info = ctx.checked.for_in_infos.get(statement) orelse return unsupported("для..в без определённой формы цикла");
    if (info.kind != .array) return unsupported("для..в по итератору (Фаза 2)");

    const bindings = ctx.resolution.stmt_bindings.get(statement) orelse return unsupported("для..в без символа переменной");
    if (bindings.len != 1) return unsupported("для..в с несколькими переменными");

    const iterable = try lowerExpr(ctx, loop.iterable);
    if (iterable.flow == .terminates) return .terminates;

    const array_type = ctx.checked.expression_types.get(loop.iterable) orelse return unsupported("для..в: массив без типа");
    const array_entry = ctx.checked.types.get(array_type) orelse return unsupported("для..в: массив с неизвестным типом");
    const element_type = switch (array_entry.*) {
        .array => |value| value,
        else => return unsupported("для..в: не массив"),
    };

    const array_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$for_in_array", array_type);
    try ctx.builder.emit(.{ .store_local = .{ .local = array_local, .src = iterable.value } });
    const index_type = ctx.checked.types.builtins.number;
    const index_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$for_in_index", index_type);
    const zero = try emitConstNumber(ctx, 0);
    try ctx.builder.emit(.{ .store_local = .{ .local = index_local, .src = zero } });
    const element_local = try ctx.builder.newLocal(bindings[0], loop.names[0], element_type);
    try ctx.symbol_to_local.put(bindings[0], element_local);

    const header = try ctx.builder.newBlock();
    const body = try ctx.builder.newBlock();
    const step = try ctx.builder.newBlock();
    const exit = try ctx.builder.newBlock();
    ctx.builder.terminate(.{ .jump = .{ .target = header } });
    ctx.builder.setCurrentBlock(header);
    // Operand order here matters for MORE than readability: `wasm_emit.zig`
    // re-materializes each MIR value in CREATION order when it lowers a
    // comparison, not strictly by the `lhs`/`rhs` argument order passed to
    // `emitCompare` below — `index_value` must therefore be created BEFORE
    // `length` (mirroring `lowerForRange`'s exact index-then-bound order),
    // or the two operands land on the WASM stack swapped and `.less`
    // silently computes `length < index` instead of `index < length`.
    // Found by running the compiled program and comparing wasm2wat output
    // against `lowerForRange`'s (working) codegen — the loop body simply
    // never executed, no compile-time signal of the mistake at all.
    const index_value = try ctx.builder.newValue(index_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = index_value, .local = index_local } });
    const array_value = try ctx.builder.newValue(array_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = array_value, .local = array_local } });
    const length = try ctx.builder.newValue(index_type);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = length, .name = "@runtime::array_length", .args = try valuesInArena(ctx, &.{array_value}) } });
    const cond = try emitCompare(ctx, .less, index_value, length);
    ctx.builder.terminate(.{ .branch = .{ .cond = cond, .then_block = body, .else_block = exit } });
    ctx.builder.setCurrentBlock(body);
    const array_for_index = try ctx.builder.newValue(array_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = array_for_index, .local = array_local } });
    const index_for_get = try ctx.builder.newValue(index_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = index_for_get, .local = index_local } });
    const element = try ctx.builder.newValue(element_type);
    try ctx.builder.emit(.{ .get_index = .{ .dst = element, .object = array_for_index, .index = index_for_get } });
    try ctx.builder.emit(.{ .store_local = .{ .local = element_local, .src = element } });
    try ctx.loops.append(ctx.allocator, .{ .continue_target = step, .break_target = exit });
    const body_outcome = try lowerBlock(ctx, loop.body, false);
    _ = ctx.loops.pop();
    if (body_outcome.flow == .continues) ctx.builder.terminate(.{ .jump = .{ .target = step } });
    ctx.builder.setCurrentBlock(step);
    const current = try ctx.builder.newValue(index_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = current, .local = index_local } });
    const one = try emitConstNumber(ctx, 1);
    const next = try ctx.builder.newValue(index_type);
    try ctx.builder.emit(.{ .binary = .{ .dst = next, .op = .add, .lhs = current, .rhs = one } });
    try ctx.builder.emit(.{ .store_local = .{ .local = index_local, .src = next } });
    ctx.builder.terminate(.{ .jump = .{ .target = header } });
    ctx.builder.setCurrentBlock(exit);
    return .continues;
}

// Wraps every expression lowering with the SAME "was this expression's
// value just cast to an interface type?" check the native bytecode
// compiler applies universally (`compiler.zig`'s `compileExpression`/
// `emitInterfaceCast` — called after EVERY expression, not just
// call-shaped ones, since a cast can happen at a let-binding, return,
// array/map element, or plain function argument just as easily as at a
// call). `lowerExprInner` is the real per-kind dispatch; this wrapper
// is the one thing every recursive `lowerExpr` call site already goes
// through, so hooking here reaches every cast site for free.
fn lowerExpr(ctx: *LoweringContext, expression: ast.ExprId) anyerror!ExprOutcome {
    const outcome = try lowerExprInner(ctx, expression);
    if (outcome.flow == .terminates) return outcome;
    return try applyInterfaceCast(ctx, expression, outcome);
}

// Mirrors `compiler.zig`'s `emitInterfaceCast` exactly (same resolution
// call, same error conditions) — reuses `type_checker.
// findInterfaceImplementation` (compile-time exact-match-then-generic-
// pattern-fallback resolution, already proven correct by the native
// backend) rather than re-deriving vtable-matching logic here. Builds
// `mir.InterfaceMethodBinding{method_name, function}` pairs by zipping
// the interface's OWN declared method order (`InterfaceDefinition.
// methods[i].name`) with the implementation's method symbols (`entry.
// methods[i]`, SAME index — `defineInterfaceImplementation` guarantees
// this pairing) — `wasm_interfaces.zig` (the WASM-specific expansion of
// `.cast_interface`) is what turns FunctionIds into WASM table indices;
// this stays target-agnostic.
fn applyInterfaceCast(ctx: *LoweringContext, expression: ast.ExprId, outcome: ExprOutcome) anyerror!ExprOutcome {
    const cast = ctx.checked.interface_casts.get(expression) orelse return outcome;
    // `mir.Instruction.cast_interface`'s `vtable` is ONE flat list (no
    // `vtable_index`-style nesting the way the bytecode backend's
    // `interface_vtables` constant supports multiple simultaneous
    // interfaces per cast) — `checked.interface_calls`'s own
    // `vtable_index` field is unused below as a result. A value cast to
    // MULTIPLE interfaces at once (e.g. satisfying two bounds
    // simultaneously) would need `method_index` reinterpreted per-entry,
    // which this flat scheme can't represent; explicitly rejected rather
    // than silently invoking the wrong method. Not hit by anything this
    // plan's own verification cases (prelude iterators) exercise — a
    // real, scoped Phase-2 gap, not a silent correctness risk.
    if (cast.entries.len > 1) return unsupported("значение приведено сразу к нескольким интерфейсам (Phase 2)");
    var vtable: std.ArrayList(mir.InterfaceMethodBinding) = .empty;
    for (cast.entries) |entry| {
        var ambiguous = false;
        const implementation = type_checker.findInterfaceImplementation(
            ctx.checked,
            entry.interface,
            entry.arguments,
            entry.target,
            entry.target_arguments,
            &ambiguous,
        ) orelse return unsupported("не удалось найти реализацию интерфейса");
        if (ambiguous) return unsupported("неоднозначная реализация интерфейса — несколько подходящих 'реализация' блоков");
        const definition = ctx.checked.interface_definitions.get(entry.interface) orelse return unsupported("интерфейс без определения");
        if (definition.methods.len != implementation.methods.len) return unsupported("несоответствие количества методов интерфейса");
        for (definition.methods, implementation.methods) |method, method_symbol| {
            const function_id = ctx.symbol_to_function.get(method_symbol) orelse return unsupported("не удалось найти метод интерфейса");
            const is_default = method.default_symbol != null and method.default_symbol.? == method_symbol;
            try vtable.append(ctx.builder.module.arena.allocator(), .{ .method_name = method.name, .function = function_id, .is_default = is_default });
        }
    }
    // Same WASM representation (opaque i32 handle) either way — the
    // source expression's own type is reused rather than the (not
    // separately tracked at this stage — see `type_checker.zig`'s own
    // "NO implicit wrapping at type-checker level" design note)
    // interface type itself.
    const dst = try ctx.builder.newValue(ctx.builder.currentFunction().valueType(outcome.value));
    try ctx.builder.emit(.{ .cast_interface = .{ .dst = dst, .src = outcome.value, .vtable = try vtable.toOwnedSlice(ctx.builder.module.arena.allocator()) } });
    return continuesWith(dst);
}

fn lowerExprInner(ctx: *LoweringContext, expression: ast.ExprId) anyerror!ExprOutcome {
    return switch (ctx.tree.expr(expression).*) {
        .number => |number| continuesWith(try emitConstNumber(ctx, number.value)),
        .boolean => |boolean| blk: {
            const dst = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
            try ctx.builder.emit(.{ .const_value = .{ .dst = dst, .value = .{ .boolean = boolean.value } } });
            break :blk continuesWith(dst);
        },
        .string => |string| blk: {
            const dst = try ctx.builder.newValue(ctx.checked.types.builtins.string);
            try ctx.builder.emit(.{ .const_value = .{ .dst = dst, .value = .{ .string = string.value } } });
            break :blk continuesWith(dst);
        },
        .array => |array| lowerArrayLiteral(ctx, expression, array),
        .spawn => |spawn| lowerSpawn(ctx, expression, spawn),
        .index => |index| lowerIndex(ctx, expression, index),
        .ident => blk: {
            const symbol = ctx.resolution.expr_symbols.get(expression) orelse return unsupported("неразрешённый идентификатор");
            break :blk continuesWith(try lowerSymbolValueRef(ctx, symbol, expressionSpan(ctx.tree, expression)));
        },
        .unary => |unary| lowerUnary(ctx, expression, unary),
        .cast => |cast| lowerCast(ctx, expression, cast),
        .binary => |binary| lowerBinary(ctx, expression, binary),
        .call => |call| lowerCall(ctx, expression, call),
        .property => |property| lowerProperty(ctx, expression, property),
        .if_expr => |conditional| lowerIfExpr(ctx, expression, conditional, true),
        .match_expr => |match| lowerMatchExpr(ctx, expression, match),
        .while_expr => |loop| blk: {
            const flow = try lowerWhile(ctx, loop);
            if (flow == .terminates) break :blk terminated;
            break :blk continuesWith(try emitConstNumber(ctx, 0));
        },
        .lambda => |lambda| lowerLambda(ctx, expression, lambda),
        else => return unsupported("вид выражения"),
    };
}

// Keep actor creation explicit in MIR. CPS lowering consumes this before the
// WASM emitter; representing it as an ordinary call would lose the child
// frame and make a later `получить()` impossible to resume correctly.
fn lowerSpawn(ctx: *LoweringContext, expression: ast.ExprId, spawn: anytype) anyerror!ExprOutcome {
    const call = switch (ctx.tree.expr(spawn.call).*) {
        .call => |value| value,
        else => return unsupported("запусти не-вызов"),
    };
    const symbol = ctx.resolution.expr_symbols.get(call.callee) orelse return unsupported("запусти неразрешённую функцию");
    const function_id = ctx.symbol_to_function.get(symbol) orelse return unsupported("запусти не-статическую функцию");
    const callee = try emitFunctionRef(ctx, function_id);
    const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
    const result_type = ctx.checked.expression_types.get(expression) orelse return unsupported("запусти без типа");
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .spawn = .{ .dst = dst, .callee = callee, .args = args } });
    return continuesWith(dst);
}

fn lowerMatchExpr(ctx: *LoweringContext, expression: ast.ExprId, match: anytype) anyerror!ExprOutcome {
    const subject = try lowerExpr(ctx, match.subject);
    if (subject.flow == .terminates) return terminated;
    const subject_type = ctx.checked.expression_types.get(match.subject) orelse return unsupported("выбор без типа subject");
    const subject_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$match", subject_type);
    try ctx.builder.emit(.{ .store_local = .{ .local = subject_local, .src = subject.value } });
    const result_type = ctx.checked.expression_types.get(expression) orelse ctx.checked.types.builtins.void;
    const has_result = !ctx.checked.types.eql(result_type, ctx.checked.types.builtins.void);
    const result_local: ?mir.LocalId = if (has_result) try ctx.builder.newLocal(symbols.invalid_symbol, "$match_result", result_type) else null;
    const merge = try ctx.builder.newBlock();

    for (match.arms, 0..) |arm, arm_index| {
        const next = if (arm_index + 1 < match.arms.len) try ctx.builder.newBlock() else mir.invalid_block;
        const variant = ctx.checked.pattern_variants.get(arm.pattern);
        if (variant) |variant_symbol| {
            const definition = ctx.checked.enum_definitions.get((ctx.resolution.symbols.get(variant_symbol) orelse unreachable).owner_type) orelse return unsupported("вариант без enum definition");
            var tag: u32 = 0;
            for (definition.variants, 0..) |candidate, index| if (candidate.symbol == variant_symbol) {
                tag = @intCast(index);
                break;
            };
            const condition = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
            const loaded_subject = try ctx.builder.newValue(subject_type);
            try ctx.builder.emit(.{ .load_local = .{ .dst = loaded_subject, .local = subject_local } });
            try ctx.builder.emit(.{ .match_tag = .{ .dst = condition, .subject = loaded_subject, .tag = tag } });
            const body = try ctx.builder.newBlock();
            if (next == mir.invalid_block) {
                const impossible = try ctx.builder.newBlock();
                ctx.builder.terminate(.{ .branch = .{ .cond = condition, .then_block = body, .else_block = impossible } });
                ctx.builder.setCurrentBlock(impossible);
                ctx.builder.terminate(.{ .unreachable_term = .{ .reason = "неисчерпывающий выбор" } });
            } else ctx.builder.terminate(.{ .branch = .{ .cond = condition, .then_block = body, .else_block = next } });
            ctx.builder.setCurrentBlock(body);
            try bindVariantPattern(ctx, arm.pattern, subject_local, subject_type);
        } else {
            try bindCatchAllPattern(ctx, arm.pattern, subject_local, subject_type);
        }
        const outcome = try lowerBlock(ctx, arm.body, has_result);
        if (outcome.flow == .continues) {
            if (result_local) |local| try ctx.builder.emit(.{ .store_local = .{ .local = local, .src = outcome.value } });
            ctx.builder.terminate(.{ .jump = .{ .target = merge } });
        }
        if (next != mir.invalid_block) ctx.builder.setCurrentBlock(next);
    }
    ctx.builder.setCurrentBlock(merge);
    if (!has_result) return continuesWith(mir.invalid_value);
    const result = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = result, .local = result_local.? } });
    return continuesWith(result);
}

fn bindCatchAllPattern(ctx: *LoweringContext, pattern: ast.PatternId, subject_local: mir.LocalId, subject_type: types.TypeId) !void {
    const binding = ctx.resolution.pattern_symbols.get(pattern) orelse return;
    const local = try ctx.builder.newLocal(binding, "$pattern", subject_type);
    try ctx.symbol_to_local.put(binding, local);
    const value = try ctx.builder.newValue(subject_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = value, .local = subject_local } });
    try ctx.builder.emit(.{ .store_local = .{ .local = local, .src = value } });
}

fn bindVariantPattern(ctx: *LoweringContext, pattern: ast.PatternId, subject_local: mir.LocalId, subject_type: types.TypeId) !void {
    const constructor = switch (ctx.tree.pattern(pattern).*) {
        .constructor => |value| value,
        else => return,
    };
    for (constructor.arguments, 0..) |argument, index| {
        const binding = ctx.resolution.pattern_symbols.get(argument) orelse continue;
        const field_type = ctx.checked.pattern_types.get(argument) orelse blk: {
            // `получить()` deliberately has poison as its static subject
            // type. The checker still resolved the constructor variant, so
            // recover its positional field type from that enum definition.
            const variant_symbol = ctx.checked.pattern_variants.get(pattern) orelse return unsupported("payload pattern без типа");
            const entry = ctx.resolution.symbols.get(variant_symbol) orelse return unsupported("payload variant без symbol");
            const definition = ctx.checked.enum_definitions.get(entry.owner_type) orelse return unsupported("payload variant без enum definition");
            for (definition.variants) |variant| {
                if (variant.symbol != variant_symbol) continue;
                if (index >= variant.fields.len) return unsupported("payload pattern вне variant fields");
                break :blk variant.fields[index];
            }
            return unsupported("payload variant не найден");
        };
        const local = try ctx.builder.newLocal(binding, "$payload", field_type);
        try ctx.symbol_to_local.put(binding, local);
        const loaded_subject = try ctx.builder.newValue(subject_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = loaded_subject, .local = subject_local } });
        const field = try ctx.builder.newValue(field_type);
        try ctx.builder.emit(.{ .get_variant_field = .{ .dst = field, .subject = loaded_subject, .field_index = @intCast(index) } });
        try ctx.builder.emit(.{ .store_local = .{ .local = local, .src = field } });
    }
}

fn valuesInArena(ctx: *LoweringContext, values: []const mir.ValueId) ![]const mir.ValueId {
    const out = try ctx.builder.module.arena.allocator().alloc(mir.ValueId, values.len);
    @memcpy(out, values);
    return out;
}

fn lowerArrayLiteral(ctx: *LoweringContext, expression: ast.ExprId, array: anytype) anyerror!ExprOutcome {
    const array_type = ctx.checked.expression_types.get(expression) orelse return unsupported("массив без типа");
    const entry = ctx.checked.types.get(array_type) orelse return unsupported("массив с неизвестным типом");
    const element_type = switch (entry.*) {
        .array => |value| value,
        else => return unsupported("литерал не-массива"),
    };
    const array_value = try ctx.builder.newValue(array_type);
    try ctx.builder.emit(.{ .new_array = .{ .dst = array_value, .elements = &.{} } });
    const local = try ctx.builder.newLocal(symbols.invalid_symbol, "$array", array_type);
    try ctx.builder.emit(.{ .store_local = .{ .local = local, .src = array_value } });
    const append_name = if (wasm_module.wasmValTypeForStore(&ctx.checked.types, element_type) == wasm_module.wasm_i32) "@runtime::array_append_i32" else "@runtime::array_append_f64";
    for (array.elements) |element| {
        const receiver = try ctx.builder.newValue(array_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = receiver, .local = local } });
        const value = try lowerExpr(ctx, element);
        if (value.flow == .terminates) return terminated;
        try ctx.builder.emit(.{ .call_builtin = .{ .dst = null, .name = append_name, .args = try valuesInArena(ctx, &.{ receiver, value.value }) } });
    }
    const result = try ctx.builder.newValue(array_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = result, .local = local } });
    return continuesWith(result);
}

fn lowerIndex(ctx: *LoweringContext, expression: ast.ExprId, index: anytype) anyerror!ExprOutcome {
    const object = try lowerExpr(ctx, index.object);
    if (object.flow == .terminates) return terminated;
    const subscript = try lowerExpr(ctx, index.index);
    if (subscript.flow == .terminates) return terminated;
    const result_type = ctx.checked.expression_types.get(expression) orelse return unsupported("индексирование без типа результата");
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .get_index = .{ .dst = dst, .object = object.value, .index = subscript.value } });
    return continuesWith(dst);
}

// `nominal_fields` only has entries for CONCRETE (non-generic) struct
// declarations — a generic one (`тип X[T] = структура ...`, e.g. the
// prelude's own `МассивИтератор[T]`, hit by every plain `для x в
// массив` loop) only has an entry in `generic_nominal_fields`, keyed the
// same way. Field LOOKUP here only needs each field's NAME and ordinal
// POSITION (`field_index`, used by `.get_property`/`.set_property` at
// the MIR level) — never its type-parameter-substituted type (the
// result type instead comes from `ctx.checked.expression_types`,
// already resolved earlier by the type checker) — so the generic
// declaration's own unsubstituted `.fields` list is exactly as usable
// as a concrete struct's, no substitution needed at this stage. Mirrors
// `type_checker.zig`'s own `fieldsForNominal` fallback (that one DOES
// substitute, because it needs to type-check field access expressions;
// this one only needs positions).
fn fieldsForNominalSymbol(ctx: *LoweringContext, symbol: symbols.SymbolId) ?[]const type_checker.NominalField {
    if (ctx.checked.nominal_fields.get(symbol)) |fields| return fields;
    if (ctx.checked.generic_nominal_fields.get(symbol)) |generic_nominal| return generic_nominal.fields;
    return null;
}

fn lowerProperty(ctx: *LoweringContext, expression: ast.ExprId, property: anytype) anyerror!ExprOutcome {
    // Module members and enum variants are resolved symbols and are handled
    // by their callers. A remaining property expression is a struct field.
    if (ctx.resolution.expr_symbols.contains(expression)) return unsupported("свойство-модуль или вариант перечисления вне вызова");
    const object = try lowerExpr(ctx, property.object);
    if (object.flow == .terminates) return terminated;
    const object_type = ctx.checked.expression_types.get(property.object) orelse return unsupported("свойство без типа объекта");
    const type_entry = ctx.checked.types.get(object_type) orelse return unsupported("свойство с неизвестным типом объекта");
    const nominal = switch (type_entry.*) {
        .nominal => |value| value,
        else => return unsupported("свойство не-структуры"),
    };
    const fields = fieldsForNominalSymbol(ctx, nominal.symbol) orelse return unsupported("поле generic-структуры");
    for (fields, 0..) |field, index| {
        if (!std.mem.eql(u8, field.name, property.property)) continue;
        const result_type = ctx.checked.expression_types.get(expression) orelse field.typ;
        const dst = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .get_property = .{ .dst = dst, .object = object.value, .field_index = @intCast(index) } });
        return continuesWith(dst);
    }
    return unsupported("неизвестное поле структуры");
}

fn lowerSymbolValueRef(ctx: *LoweringContext, symbol: symbols.SymbolId, span: source.Span) !mir.ValueId {
    // Captured symbol, resolved INSIDE a lambda body — see `CaptureEnv`'s
    // own doc comment. Checked BEFORE `symbol_to_local`: a capture and an
    // ordinary lambda-body local can never collide (captures never get a
    // `symbol_to_local` entry in the inner `LoweringContext` at all, see
    // `lowerLambda`), but checking first keeps the precedence explicit
    // rather than accidental.
    if (ctx.capture_env) |*env| {
        if (env.index_of.get(symbol)) |slot| {
            const type_id = ctx.checked.symbol_types.get(symbol) orelse ctx.checked.types.builtins.void;
            const env_ptr = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
            try ctx.builder.emit(.{ .load_local = .{ .dst = env_ptr, .local = env.env_local } });
            const dst = try ctx.builder.newValue(type_id);
            try ctx.builder.emit(.{ .frame_load = .{ .dst = dst, .frame = env_ptr, .slot = slot } });
            return dst;
        }
    }
    if (ctx.symbol_to_local.get(symbol)) |local| {
        const dst = try ctx.builder.newValue(ctx.builder.currentFunction().locals.items[@intFromEnum(local)].type_id);
        try ctx.builder.emit(.{ .load_local = .{ .dst = dst, .local = local } });
        return dst;
    }
    if (ctx.symbol_to_function.get(symbol)) |function_id| {
        // A plain named function used as an ordinary VALUE (not
        // immediately called — `lowerCall`'s OWN ident-callee fast path
        // never reaches this function at all, see this file's own
        // closure design notes) — uniform closure representation, zero
        // captures, `already_env_aware = false` since the ORIGINAL
        // function's signature has no `env_ptr` param and must stay
        // untouched for its own direct-call sites. `wasm_interfaces.zig`
        // synthesizes a thin ignored-`env_ptr` wrapper for this case.
        const dst = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
        try ctx.builder.emit(.{ .build_closure = .{ .dst = dst, .function = function_id, .captured = &.{}, .already_env_aware = false } });
        return dst;
    }
    _ = span;
    return unsupported("символ не является локалью или функцией");
}

fn lambdaReturnType(checked: *const type_checker.CheckResult, expression: ast.ExprId) types.TypeId {
    const signature_id = checked.expression_types.get(expression) orelse return checked.types.builtins.void;
    const entry = checked.types.get(signature_id) orelse return checked.types.builtins.void;
    return switch (entry.*) {
        .function => |value| value.return_type,
        else => checked.types.builtins.void,
    };
}

// WASM AOT closure support, Stage A (see the `project_panos_wasm_aot_closures`
// design notes) — real `.lambda` lowering. Captures are BY VALUE, taken
// at closure-CONSTRUCTION time (matches the bytecode VM's own
// `.build_closure`/`compileLambda` semantics exactly, `compiler.zig`) —
// each captured symbol is read via the OUTER `ctx`'s ordinary
// `lowerSymbolValueRef` (so a capture can itself be a parameter, a
// local, or — recursively — another OUTER capture, as long as that
// outer scope isn't ITSELF a lambda body, see the nesting restriction
// below) and stored into a fresh environment allocation; the lambda
// BODY is lowered as a genuinely separate MIR function whose captured-
// symbol lookups are redirected through `CaptureEnv` instead of
// `symbol_to_local`.
//
// Explicit scoping restriction for this stage: NON-NESTED lambdas only.
// A lambda body containing another `.lambda` that itself needs to reach
// the OUTER lambda's own captures (not just the outer ORDINARY
// function's locals) would need the inner closure's environment to
// chain through the outer one — real, deferred gap, not silently wrong
// codegen: `ctx.capture_env != null` at lowering time means we are
// ALREADY inside a lambda body, so hitting a nested `.lambda` here
// reports a clear diagnostic instead of miscompiling.
fn lowerLambda(ctx: *LoweringContext, expression: ast.ExprId, lambda: anytype) anyerror!ExprOutcome {
    if (ctx.capture_env != null) return unsupported("вложенные замыкания (Stage A поддерживает только один уровень)");

    const captures = ctx.resolution.lambda_captures.get(expression) orelse &.{};
    if (captures.len > std.math.maxInt(u16)) return unsupported("лямбда захватывает слишком много значений");

    const arena = ctx.builder.module.arena.allocator();
    var captured_values: std.ArrayList(mir.ValueId) = .empty;
    for (captures) |capture_symbol| {
        const value = try lowerSymbolValueRef(ctx, capture_symbol, expressionSpan(ctx.tree, expression));
        try captured_values.append(arena, value);
    }
    const captured_slice = try captured_values.toOwnedSlice(arena);

    const lambda_result_type = lambdaReturnType(ctx.checked, expression);
    const lambda_name = try std.fmt.allocPrint(arena, "@lambda_{d}", .{ctx.builder.module.functions.items.len});
    const lambda_function_id = try mir_builder.newFunction(ctx.builder.module, ctx.allocator, lambda_name, dummy_symbol, lambda_result_type, expressionSpan(ctx.tree, expression));
    ctx.builder.module.functions.items[@intFromEnum(lambda_function_id)].type_store = &ctx.checked.types;

    var inner_ctx = LoweringContext{
        .allocator = ctx.allocator,
        .tree = ctx.tree,
        .resolution = ctx.resolution,
        .checked = ctx.checked,
        .builder = try mir_builder.Builder.beginFunction(ctx.builder.module, ctx.allocator, lambda_function_id),
        .symbol_to_local = .init(ctx.allocator),
        .symbol_to_function = ctx.symbol_to_function,
    };
    defer inner_ctx.deinit();

    const parameter_symbols = ctx.resolution.lambda_parameters.get(expression) orelse &.{};
    var param_locals: std.ArrayList(mir.LocalId) = .empty;
    for (parameter_symbols) |symbol| {
        const type_id = ctx.checked.symbol_types.get(symbol) orelse ctx.checked.types.builtins.void;
        const local = try inner_ctx.builder.newLocal(symbol, "", type_id);
        try inner_ctx.symbol_to_local.put(symbol, local);
        try param_locals.append(ctx.allocator, local);
    }
    // `env_ptr` is a TRAILING parameter, uniformly, matching the "append
    // env_ptr as a trailing call_indirect argument" convention on the
    // CALLING side (`wasm_interfaces.zig`'s `.call_value` expansion) —
    // one calling convention everywhere a `.function`-typed value is
    // invoked, no branching between "closure" and "plain function"
    // shapes at the call site.
    const env_param = try inner_ctx.builder.newLocal(dummy_symbol, "@env", ctx.checked.types.builtins.boolean);
    try param_locals.append(ctx.allocator, env_param);
    inner_ctx.builder.currentFunction().parameters = try param_locals.toOwnedSlice(ctx.allocator);
    inner_ctx.builder.currentFunction().type_store = &ctx.checked.types;

    var index_of: std.AutoHashMap(symbols.SymbolId, u32) = .init(ctx.allocator);
    for (captures, 0..) |capture_symbol, i| try index_of.put(capture_symbol, @intCast(i));
    inner_ctx.capture_env = .{ .env_local = env_param, .index_of = index_of };

    const want_value = !ctx.checked.types.eql(lambda_result_type, ctx.checked.types.builtins.void);
    const outcome = try lowerBlock(&inner_ctx, lambda.body, want_value);
    if (outcome.flow == .continues) {
        inner_ctx.builder.terminate(.{ .return_value = .{ .value = if (want_value) outcome.value else null } });
    }

    const dst = try ctx.builder.newValue(ctx.checked.expression_types.get(expression) orelse ctx.checked.types.builtins.boolean);
    try ctx.builder.emit(.{ .build_closure = .{ .dst = dst, .function = lambda_function_id, .captured = captured_slice, .already_env_aware = true } });
    return continuesWith(dst);
}

fn emitFunctionRef(ctx: *LoweringContext, function_id: mir.FunctionId) !mir.ValueId {
    // A function reference is a genuine first-class VALUE (storable in a
    // local/field, passable as an argument, callable through
    // `call_value`) — typed `boolean` here purely as a stand-in for "i32
    // opaque handle" (see `wasm_module.wasmValTypeForStore`'s `.function`
    // case: any function-typed value maps to i32, same category as
    // nominal/array/process). The exact declared type doesn't matter
    // beyond that WASM-type-category selection.
    const dst = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
    try ctx.builder.emit(.{ .function_ref = .{ .dst = dst, .function = function_id } });
    return dst;
}

// `.call_value`'s callee must be the LAST-produced operand by the time
// WASM codegen turns it into `call_indirect` (`[args..., table_index]`,
// index popped topmost) — but every call site here computes the callee
// BEFORE its arguments (matching the language's own left-to-right
// evaluation order, callee-before-args, mirrored from `compiler.zig`'s
// `compileCall`). Routes the callee through an ordinary Local
// (target-agnostic MIR, no WASM-specific knowledge needed here) so it
// can be re-produced fresh, after every argument, right at the call
// site — same "buried value" fix shape as `wasm_interfaces.zig`'s own
// `.cast_interface`/`.invoke_interface` expansions, just done here at
// the MIR level since ordinary Locals are backend-agnostic.
fn storeCalleeLocal(ctx: *LoweringContext, callee: mir.ValueId) !mir.LocalId {
    const callee_type = ctx.builder.currentFunction().valueType(callee);
    const local = try ctx.builder.newLocal(dummy_symbol, "@callee", callee_type);
    try ctx.builder.emit(.{ .store_local = .{ .local = local, .src = callee } });
    return local;
}

fn reloadCalleeLocal(ctx: *LoweringContext, local: mir.LocalId) !mir.ValueId {
    const callee_type = ctx.builder.currentFunction().locals.items[@intFromEnum(local)].type_id;
    const dst = try ctx.builder.newValue(callee_type);
    try ctx.builder.emit(.{ .load_local = .{ .dst = dst, .local = local } });
    return dst;
}

fn lowerUnary(ctx: *LoweringContext, expression: ast.ExprId, unary: anytype) anyerror!ExprOutcome {
    const src = try lowerExpr(ctx, unary.operand);
    if (src.flow == .terminates) return terminated;
    const op: mir.UnOp = switch (unary.operator) {
        .minus => .negate_number,
        .negate => .negate_bool,
        .tilde => .bit_not,
        else => return unsupported("унарный оператор"),
    };
    const result_type = ctx.checked.expression_types.get(expression) orelse ctx.checked.types.builtins.void;
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .unary = .{ .dst = dst, .op = op, .src = src.value } });
    return continuesWith(dst);
}

fn lowerBinary(ctx: *LoweringContext, expression: ast.ExprId, binary: anytype) anyerror!ExprOutcome {
    if (binary.operator == .assign) return lowerAssign(ctx, binary);
    if (binary.operator == .and_expr or binary.operator == .or_expr) return lowerShortCircuit(ctx, binary);

    const lhs = try lowerExpr(ctx, binary.left);
    if (lhs.flow == .terminates) return terminated;
    const rhs = try lowerExpr(ctx, binary.right);
    if (rhs.flow == .terminates) return terminated;

    const result_type = ctx.checked.expression_types.get(expression) orelse ctx.checked.types.builtins.void;
    const bin_op: mir.BinOp = switch (binary.operator) {
        .plus => .add,
        .minus => .subtract,
        .star => .multiply,
        .slash => if (ctx.checked.types.eql(ctx.checked.expression_types.get(binary.left) orelse ctx.checked.types.builtins.void, ctx.checked.types.builtins.integer)) mir.BinOp.int_divide else mir.BinOp.divide,
        .percent => .modulo,
        .ampersand => .bit_and,
        .pipe => .bit_or,
        .caret => .bit_xor,
        .less_less => .shift_left,
        .greater_greater => .shift_right,
        .less, .less_equal, .greater, .greater_equal, .equal, .not_equal => return continuesWith(try emitCompare(ctx, binary.operator, lhs.value, rhs.value)),
        else => return unsupported("бинарный оператор"),
    };
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .binary = .{ .dst = dst, .op = bin_op, .lhs = lhs.value, .rhs = rhs.value } });
    return continuesWith(dst);
}

// Assignment produces NO value
// (matches Odin's `INVALID_VALUE`/`.Continues` and the bytecode compiler's
// own `y = (x = 1)` restriction) — a well-typed program can never observe
// this, since the type checker requires an if-expression's branches to share
// a common value type before this lowering ever runs.
fn lowerAssign(ctx: *LoweringContext, binary: anytype) anyerror!ExprOutcome {
    switch (ctx.tree.expr(binary.left).*) {
        .ident => {
            const symbol = ctx.resolution.expr_symbols.get(binary.left) orelse return unsupported("неразрешённый идентификатор в присваивании");
            const target = ctx.symbol_to_local.get(symbol) orelse return unsupported("присваивание не-локали (Фаза 3+)");
            const rhs = try lowerExpr(ctx, binary.right);
            if (rhs.flow == .terminates) return terminated;
            try ctx.builder.emit(.{ .store_local = .{ .local = target, .src = rhs.value } });
        },
        .property => |property| {
            const object = try lowerExpr(ctx, property.object);
            if (object.flow == .terminates) return terminated;
            const object_type = ctx.checked.expression_types.get(property.object) orelse return unsupported("присваивание свойства без типа");
            const entry = ctx.checked.types.get(object_type) orelse return unsupported("присваивание свойства с неизвестным типом");
            const nominal = switch (entry.*) {
                .nominal => |value| value,
                else => return unsupported("присваивание свойства не-структуры"),
            };
            const fields = fieldsForNominalSymbol(ctx, nominal.symbol) orelse return unsupported("присваивание поля generic-структуры");
            var field_index: ?u32 = null;
            for (fields, 0..) |field, index| {
                if (std.mem.eql(u8, field.name, property.property)) {
                    field_index = @intCast(index);
                    break;
                }
            }
            const index = field_index orelse return unsupported("присваивание неизвестному полю структуры");
            const rhs = try lowerExpr(ctx, binary.right);
            if (rhs.flow == .terminates) return terminated;
            try ctx.builder.emit(.{ .set_property = .{ .object = object.value, .field_index = index, .value = rhs.value } });
        },
        .index => |index| {
            const object = try lowerExpr(ctx, index.object);
            if (object.flow == .terminates) return terminated;
            const subscript = try lowerExpr(ctx, index.index);
            if (subscript.flow == .terminates) return terminated;
            const rhs = try lowerExpr(ctx, binary.right);
            if (rhs.flow == .terminates) return terminated;
            try ctx.builder.emit(.{ .set_index = .{ .object = object.value, .index = subscript.value, .value = rhs.value } });
        },
        else => return unsupported("цель присваивания (Фаза 3+)"),
    }
    return continuesWith(mir.invalid_value);
}

fn emitCompare(ctx: *LoweringContext, operator: anytype, lhs: mir.ValueId, rhs: mir.ValueId) !mir.ValueId {
    const cmp_op: mir.CmpOp = switch (operator) {
        .less => .less,
        .less_equal => .less_equal,
        .greater => .greater,
        .greater_equal => .greater_equal,
        .equal => .equal,
        .not_equal => .not_equal,
        else => unreachable,
    };
    const dst = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
    try ctx.builder.emit(.{ .compare = .{ .dst = dst, .op = cmp_op, .lhs = lhs, .rhs = rhs } });
    return dst;
}

// `и`/`или` — same non-SSA "merge through a temp local" trick `lowerIfExpr`
// uses for a branch's result value, via `lowerCondition` building real CFG
// edges instead of computing a bool eagerly.
fn lowerShortCircuit(ctx: *LoweringContext, binary: anytype) anyerror!ExprOutcome {
    const result_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$logic", ctx.checked.types.builtins.boolean);
    const rhs_block = try ctx.builder.newBlock();
    const short_block = try ctx.builder.newBlock();
    const merge_block = try ctx.builder.newBlock();
    const short_value = binary.operator == .or_expr;

    if (binary.operator == .and_expr) {
        try lowerCondition(ctx, binary.left, rhs_block, short_block);
    } else {
        try lowerCondition(ctx, binary.left, short_block, rhs_block);
    }

    ctx.builder.setCurrentBlock(short_block);
    const short_dst = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
    try ctx.builder.emit(.{ .const_value = .{ .dst = short_dst, .value = .{ .boolean = short_value } } });
    try ctx.builder.emit(.{ .store_local = .{ .local = result_local, .src = short_dst } });
    ctx.builder.terminate(.{ .jump = .{ .target = merge_block } });

    ctx.builder.setCurrentBlock(rhs_block);
    const rhs_outcome = try lowerExpr(ctx, binary.right);
    if (rhs_outcome.flow == .continues) {
        try ctx.builder.emit(.{ .store_local = .{ .local = result_local, .src = rhs_outcome.value } });
        ctx.builder.terminate(.{ .jump = .{ .target = merge_block } });
    }

    ctx.builder.setCurrentBlock(merge_block);
    const result = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
    try ctx.builder.emit(.{ .load_local = .{ .dst = result, .local = result_local } });
    return continuesWith(result);
}

// Branch-context lowering — builds CFG edges directly instead of computing
// a bool value, needed for short-circuit `и`/`или` (above) and for
// `если`/`пока` conditions. `a и b` lowers as: lowerCondition(a, rhs_block,
// false_target), inside rhs_block — lowerCondition(b, true_target,
// false_target); `a или b` is symmetric.
fn lowerCondition(ctx: *LoweringContext, expression: ast.ExprId, true_target: mir.BlockId, false_target: mir.BlockId) anyerror!void {
    if (ctx.tree.expr(expression).* == .binary) {
        const binary = ctx.tree.expr(expression).binary;
        if (binary.operator == .and_expr) {
            const rhs_block = try ctx.builder.newBlock();
            try lowerCondition(ctx, binary.left, rhs_block, false_target);
            ctx.builder.setCurrentBlock(rhs_block);
            try lowerCondition(ctx, binary.right, true_target, false_target);
            return;
        }
        if (binary.operator == .or_expr) {
            const rhs_block = try ctx.builder.newBlock();
            try lowerCondition(ctx, binary.left, true_target, rhs_block);
            ctx.builder.setCurrentBlock(rhs_block);
            try lowerCondition(ctx, binary.right, true_target, false_target);
            return;
        }
    }
    const outcome = try lowerExpr(ctx, expression);
    if (outcome.flow == .terminates) return;
    ctx.builder.terminate(.{ .branch = .{ .cond = outcome.value, .then_block = true_target, .else_block = false_target } });
}

// Non-SSA "temp slot" merge (Store_Local in each LIVE — non-terminating —
// branch, Load_Local in the merge block), not a phi node — MIR Phase 1 is
// deliberately not SSA.
fn lowerIfExpr(ctx: *LoweringContext, expression: ast.ExprId, conditional: anytype, want_value: bool) anyerror!ExprOutcome {
    const cond = try lowerExpr(ctx, conditional.condition);
    if (cond.flow == .terminates) return terminated;

    const then_block = try ctx.builder.newBlock();
    const else_block = try ctx.builder.newBlock();
    const merge_block = try ctx.builder.newBlock();
    ctx.builder.terminate(.{ .branch = .{ .cond = cond.value, .then_block = then_block, .else_block = else_block } });

    const result_type = ctx.checked.expression_types.get(expression) orelse ctx.checked.types.builtins.void;
    var result_local: mir.LocalId = undefined;
    if (want_value) result_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$if", result_type);

    ctx.builder.setCurrentBlock(then_block);
    const then_outcome = try lowerBlock(ctx, conditional.then_branch, want_value);
    const then_continues = then_outcome.flow == .continues;
    if (then_continues) {
        if (want_value) try ctx.builder.emit(.{ .store_local = .{ .local = result_local, .src = then_outcome.value } });
        ctx.builder.terminate(.{ .jump = .{ .target = merge_block } });
    }

    ctx.builder.setCurrentBlock(else_block);
    const else_outcome = try lowerBlock(ctx, conditional.else_branch, want_value);
    const else_continues = else_outcome.flow == .continues;
    if (else_continues) {
        if (want_value) try ctx.builder.emit(.{ .store_local = .{ .local = result_local, .src = else_outcome.value } });
        ctx.builder.terminate(.{ .jump = .{ .target = merge_block } });
    }

    if (!then_continues and !else_continues) {
        ctx.builder.setCurrentBlock(merge_block);
        ctx.builder.terminate(.{ .unreachable_term = .{ .reason = "обе ветки если завершают выполнение (возврат/прервать/продолжить)" } });
        return terminated;
    }

    ctx.builder.setCurrentBlock(merge_block);
    if (want_value) {
        const result = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = result, .local = result_local } });
        return continuesWith(result);
    }
    return continuesWith(mir.invalid_value);
}

// Only ever lowered as a statement (Phase 1: no scenario needs a пока-as-
// value — the one caller in `lowerExpr` above just supplies a constant 0
// placeholder, same treatment as an empty block in value context).
fn lowerWhile(ctx: *LoweringContext, loop: anytype) anyerror!FlowResult {
    const header_block = try ctx.builder.newBlock();
    const body_block = try ctx.builder.newBlock();
    const exit_block = try ctx.builder.newBlock();

    ctx.builder.terminate(.{ .jump = .{ .target = header_block } });
    ctx.builder.setCurrentBlock(header_block);
    const cond = try lowerExpr(ctx, loop.condition);
    if (cond.flow == .terminates) return .terminates;
    ctx.builder.terminate(.{ .branch = .{ .cond = cond.value, .then_block = body_block, .else_block = exit_block } });

    ctx.builder.setCurrentBlock(body_block);
    try ctx.loops.append(ctx.allocator, .{ .continue_target = header_block, .break_target = exit_block });
    const body_outcome = try lowerBlock(ctx, loop.body, false);
    _ = ctx.loops.pop();
    if (body_outcome.flow == .continues) {
        ctx.builder.terminate(.{ .jump = .{ .target = header_block } });
    }

    ctx.builder.setCurrentBlock(exit_block);
    return .continues;
}

// Scope note: only two shapes are lowered — a statically-known top-level
// function called by bare identifier (the fast path — Odin's own
// equivalent), and the fully generic fallback (callee lowered as an
// ORDINARY expression, called through `Call_Value_Instr` — covers a
// closure/higher-order-function value, resolved by the backend, not
// lowering). Builtins, methods, constructors, `внешний`, `получить`/
// `получить_сигнал`, generics — all explicitly `unsupported` here (Phase
// 2 in the Odin original too).
fn lowerCall(ctx: *LoweringContext, expression: ast.ExprId, call: anytype) anyerror!ExprOutcome {
    const result_type = ctx.checked.expression_types.get(expression) orelse ctx.checked.types.builtins.void;

    if (ctx.tree.expr(call.callee).* == .ident) {
        const callee_symbol = ctx.resolution.expr_symbols.get(call.callee) orelse null;
        if (callee_symbol) |symbol| {
            if (ctx.symbol_to_function.get(symbol)) |function_id| {
                const function_ref = try emitFunctionRef(ctx, function_id);
                const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
                return emitCallValue(ctx, function_ref, args, result_type);
            }
            if (try lowerEnumConstructor(ctx, symbol, call, result_type)) |outcome| return outcome;
            if (try lowerStructConstructor(ctx, expression, symbol, call, result_type)) |outcome| return outcome;
            if (try lowerLengthBuiltinCall(ctx, symbol, call, result_type)) |outcome| return outcome;
            if (try lowerPanicBuiltinCall(ctx, symbol, call)) |outcome| return outcome;
            if (try lowerProcessBuiltinCall(ctx, symbol, call, result_type)) |outcome| return outcome;
        }
    }

    if (ctx.tree.expr(call.callee).* == .property) {
        // `значение.метод(...)` where `значение`'s static type is an
        // INTERFACE (not a concrete struct — that's `checked.
        // method_calls` below, resolved to a fixed `Symbol_Id`).
        // `checked.interface_calls` gives `method_index` (the interface's
        // OWN declared method order — matches `applyInterfaceCast`'s
        // `vtable` construction, same order, same source:
        // `InterfaceDefinition.methods`) — the concrete function is only
        // known at RUNTIME (read from whichever cast produced this
        // particular receiver value), hence `.invoke_interface`, not an
        // ordinary `.call`/`.call_value`. `wasm_interfaces.zig` (WASM-
        // specific expansion, mirrors `wasm_objects.zig`'s own generic-
        // MIR → target-specific-codegen split) turns this into the
        // box-unwrap + `call_indirect` chain.
        if (ctx.checked.interface_calls.get(expression)) |interface_call| {
            const property = ctx.tree.expr(call.callee).property;
            const receiver = try lowerExpr(ctx, property.object);
            if (receiver.flow == .terminates) return terminated;
            const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
            const dst = if (ctx.checked.types.eql(result_type, ctx.checked.types.builtins.void)) null else try ctx.builder.newValue(result_type);
            try ctx.builder.emit(.{ .invoke_interface = .{ .dst = dst, .receiver = receiver.value, .method_name = "", .method_index = interface_call.method_index, .args = args } });
            return .{ .value = dst orelse mir.invalid_value, .flow = .continues };
        }
        // `значение.метод(...)` where `значение`'s static type is a
        // concrete struct — the type checker already resolved this to
        // the method's own `Symbol_Id` in `method_calls` (`type_checker.
        // zig:4437`), the exact same map the native bytecode compiler
        // reads (`compiler.zig`'s `Method_Struct` case) instead of
        // re-deriving struct-field lookup here. `это` is just
        // `parameters[0]` on the method's own side (see
        // `reserveMethods`/`lowerMethods`) — the receiver (`property.
        // object`) is lowered as an ordinary argument and placed FIRST,
        // matching that.
        if (ctx.checked.method_calls.get(expression)) |method_symbol| {
            if (ctx.symbol_to_function.get(method_symbol)) |function_id| {
                const function_ref = try emitFunctionRef(ctx, function_id);
                const property = ctx.tree.expr(call.callee).property;
                const receiver = try lowerExpr(ctx, property.object);
                if (receiver.flow == .terminates) return terminated;
                const rest = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
                const arena = ctx.builder.module.arena.allocator();
                var args: std.ArrayList(mir.ValueId) = .empty;
                try args.append(arena, receiver.value);
                try args.appendSlice(arena, rest);
                return emitCallValue(ctx, function_ref, try args.toOwnedSlice(arena), result_type);
            }
        }
        // A function imported from a local file is represented in the AST
        // as `модуль.функция`, not as a bare identifier. Resolution has
        // already associated that property expression with the importer-side
        // symbol; lowerGraph rebinds that symbol to the exporter's global
        // MIR FunctionId.
        if (ctx.resolution.expr_symbols.get(call.callee)) |symbol| {
            if (ctx.symbol_to_function.get(symbol)) |function_id| {
                const function_ref = try emitFunctionRef(ctx, function_id);
                const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
                return emitCallValue(ctx, function_ref, args, result_type);
            }
            if (try lowerEnumConstructor(ctx, symbol, call, result_type)) |outcome| return outcome;
        }
        if (try lowerTimeBuiltinCall(ctx, call, result_type)) |outcome| return outcome;
        if (try lowerNetworkBuiltinCall(ctx, call, result_type)) |outcome| return outcome;
        if (try lowerStringBuiltinCall(ctx, call, result_type)) |outcome| return outcome;
        if (try lowerDomBuiltinCall(ctx, call, result_type)) |outcome| return outcome;
        if (try lowerStateBuiltinCall(ctx, call, result_type)) |outcome| return outcome;
        if (try lowerArrayMethodCall(ctx, call, result_type)) |outcome| return outcome;
        if (try lowerOptionMethodCall(ctx, call, result_type)) |outcome| return outcome;
        if (try lowerResultMethodCall(ctx, call, result_type)) |outcome| return outcome;
    }

    const callee_outcome = try lowerExpr(ctx, call.callee);
    if (callee_outcome.flow == .terminates) return terminated;
    const callee_local = try storeCalleeLocal(ctx, callee_outcome.value);
    const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
    const callee = try reloadCalleeLocal(ctx, callee_local);
    return emitCallValue(ctx, callee, args, result_type);
}

fn lowerEnumConstructor(ctx: *LoweringContext, symbol: symbols.SymbolId, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .enum_variant) return null;
    const definition = ctx.checked.enum_definitions.get(entry.owner_type) orelse return null;
    var tag: ?u32 = null;
    for (definition.variants, 0..) |variant, index| {
        if (variant.symbol == symbol) {
            tag = @intCast(index);
            break;
        }
    }
    const variant_tag = tag orelse return null;
    if (call.arguments.len > 3) return unsupported("вариант с более чем 3 полями");
    const fields = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .build_variant = .{ .dst = dst, .type_name = "", .variant_name = entry.name, .tag = variant_tag, .fields = fields } });
    return continuesWith(dst);
}

fn lowerArrayMethodCall(ctx: *LoweringContext, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const property = ctx.tree.expr(call.callee).property;
    const object_type = ctx.checked.expression_types.get(property.object) orelse return null;
    const entry = ctx.checked.types.get(object_type) orelse return null;
    const element_type = switch (entry.*) {
        .array => |value| value,
        else => return null,
    };
    const is_i32 = wasm_module.wasmValTypeForStore(&ctx.checked.types, element_type) == wasm_module.wasm_i32;
    const name = if (std.mem.eql(u8, property.property, "длина") and call.arguments.len == 0)
        "@runtime::array_length"
    else if (std.mem.eql(u8, property.property, "добавить") and call.arguments.len == 1)
        if (is_i32) "@runtime::array_append_i32" else "@runtime::array_append_f64"
    else if (std.mem.eql(u8, property.property, "получить") and call.arguments.len == 2)
        if (is_i32) "@runtime::array_get_or_i32" else "@runtime::array_get_or_f64"
    else
        return null;

    const receiver = try lowerExpr(ctx, property.object);
    if (receiver.flow == .terminates) return terminated;
    var values: std.ArrayList(mir.ValueId) = .empty;
    defer values.deinit(ctx.allocator);
    try values.append(ctx.allocator, receiver.value);
    for (call.arguments) |argument| {
        const value = try lowerExpr(ctx, argument);
        if (value.flow == .terminates) return terminated;
        try values.append(ctx.allocator, value.value);
    }
    const is_void = ctx.checked.types.eql(result_type, ctx.checked.types.builtins.void);
    const dst = if (is_void) null else try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = dst, .name = name, .args = try valuesInArena(ctx, values.items) } });
    return continuesWith(dst orelse mir.invalid_value);
}

// `Опция` is a two-tag ADT from the prelude (`Нет = 0`, `Есть = 1`). These
// two accessors are sufficient for the conventional guarded pattern in the
// todo AOT demo and reuse the same variant ABI as explicit `выбор`.
fn lowerOptionMethodCall(ctx: *LoweringContext, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const property = ctx.tree.expr(call.callee).property;
    const object_type = ctx.checked.expression_types.get(property.object) orelse return null;
    const type_entry = ctx.checked.types.get(object_type) orelse return null;
    const nominal = switch (type_entry.*) {
        .nominal => |value| value,
        else => return null,
    };
    const owner = ctx.resolution.symbols.get(nominal.symbol) orelse return null;
    if (!std.mem.eql(u8, owner.name, "Опция")) return null;

    const receiver = try lowerExpr(ctx, property.object);
    if (receiver.flow == .terminates) return terminated;
    if (std.mem.eql(u8, property.property, "есть") and call.arguments.len == 0) {
        const dst = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .match_tag = .{ .dst = dst, .subject = receiver.value, .tag = 1 } });
        return continuesWith(dst);
    }
    if (std.mem.eql(u8, property.property, "получить") and call.arguments.len == 1) {
        // Both receiver and fallback are evaluated before selecting the
        // result, exactly as for an ordinary Panos method call.
        const option_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$option", object_type);
        try ctx.builder.emit(.{ .store_local = .{ .local = option_local, .src = receiver.value } });
        const fallback = try lowerExpr(ctx, call.arguments[0]);
        if (fallback.flow == .terminates) return terminated;
        const fallback_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$option_fallback", result_type);
        try ctx.builder.emit(.{ .store_local = .{ .local = fallback_local, .src = fallback.value } });
        const result_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$option_result", result_type);
        const condition = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
        const loaded_option = try ctx.builder.newValue(object_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = loaded_option, .local = option_local } });
        try ctx.builder.emit(.{ .match_tag = .{ .dst = condition, .subject = loaded_option, .tag = 1 } });
        const has_value = try ctx.builder.newBlock();
        const no_value = try ctx.builder.newBlock();
        const merge = try ctx.builder.newBlock();
        ctx.builder.terminate(.{ .branch = .{ .cond = condition, .then_block = has_value, .else_block = no_value } });

        ctx.builder.setCurrentBlock(has_value);
        const value_option = try ctx.builder.newValue(object_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = value_option, .local = option_local } });
        const value = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .get_variant_field = .{ .dst = value, .subject = value_option, .field_index = 0 } });
        try ctx.builder.emit(.{ .store_local = .{ .local = result_local, .src = value } });
        ctx.builder.terminate(.{ .jump = .{ .target = merge } });

        ctx.builder.setCurrentBlock(no_value);
        const default_value = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = default_value, .local = fallback_local } });
        try ctx.builder.emit(.{ .store_local = .{ .local = result_local, .src = default_value } });
        ctx.builder.terminate(.{ .jump = .{ .target = merge } });

        ctx.builder.setCurrentBlock(merge);
        const result = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = result, .local = result_local } });
        return continuesWith(result);
    }
    return null;
}

// `Результат(T,E)`'s sibling of `lowerOptionMethodCall` — same reason:
// `type_checker.zig`'s `inferPreludeEnumMethod` hard-codes the return
// TYPE for `.успех()`/`.ошибка()`/etc. by property-name string compare,
// entirely bypassing `checked.method_calls` (the map ordinary
// `реализация`-declared methods populate) — even though `prelude.zig`
// ALSO declares real `реализация Результат` bodies for these exact
// names. Those real bodies exist for the native bytecode backend
// (`compiler.zig` doesn't share this type-checker fast path the same
// way) but are effectively unreachable from THIS backend's call sites:
// `checked.method_calls.get(expression)` is null for every `.успех()`-
// shaped call, so `lowerCall` never finds them, regardless of whether
// the call is external user code OR (as found investigating this)
// `Результат::ошибка`'s OWN body calling `это.успех()` internally —
// hand-rolling the same `match_tag`/`get_variant_field` codegen here
// fixes BOTH at once, since `lowerCall` is used uniformly everywhere.
// `Успех`=tag 0, `Неудача`=tag 1 (`prelude.zig`'s own declaration
// order). Scope matches `lowerOptionMethodCall`'s own precedent —
// covers the methods actually needed so far, not the full 13-method
// surface `inferPreludeEnumMethod` type-checks (ожидать/ожидать_ошибку/
// запас/заменить_значение/заменить_ошибку/опция/ошибка_опция still fall
// through to the generic-property-access `unsupported` path — a known,
// narrower-scoped-on-purpose gap, not silently mishandled).
fn lowerResultMethodCall(ctx: *LoweringContext, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const property = ctx.tree.expr(call.callee).property;
    const object_type = ctx.checked.expression_types.get(property.object) orelse return null;
    const type_entry = ctx.checked.types.get(object_type) orelse return null;
    const nominal = switch (type_entry.*) {
        .nominal => |value| value,
        else => return null,
    };
    const owner = ctx.resolution.symbols.get(nominal.symbol) orelse return null;
    if (!std.mem.eql(u8, owner.name, "Результат")) return null;

    const receiver = try lowerExpr(ctx, property.object);
    if (receiver.flow == .terminates) return terminated;

    if (std.mem.eql(u8, property.property, "успех") and call.arguments.len == 0) {
        const dst = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .match_tag = .{ .dst = dst, .subject = receiver.value, .tag = 0 } });
        return continuesWith(dst);
    }
    if (std.mem.eql(u8, property.property, "ошибка") and call.arguments.len == 0) {
        const dst = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .match_tag = .{ .dst = dst, .subject = receiver.value, .tag = 1 } });
        return continuesWith(dst);
    }
    // `значение()`/`причина()`: extract the matching variant's field,
    // trap (`.unreachable_term`) on the wrong tag — matches
    // `prelude.zig`'s own `паника("нет значения")`/`паника("нет
    // ошибки")` bodies (message text lost under WASM AOT, same
    // documented gap as `lowerPanicBuiltinCall`).
    if ((std.mem.eql(u8, property.property, "значение") or std.mem.eql(u8, property.property, "причина")) and call.arguments.len == 0) {
        const want_success = std.mem.eql(u8, property.property, "значение");
        const receiver_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$result", object_type);
        try ctx.builder.emit(.{ .store_local = .{ .local = receiver_local, .src = receiver.value } });
        const condition = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
        const loaded = try ctx.builder.newValue(object_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = loaded, .local = receiver_local } });
        try ctx.builder.emit(.{ .match_tag = .{ .dst = condition, .subject = loaded, .tag = if (want_success) 0 else 1 } });
        const ok_block = try ctx.builder.newBlock();
        const panic_block = try ctx.builder.newBlock();
        ctx.builder.terminate(.{ .branch = .{ .cond = condition, .then_block = ok_block, .else_block = panic_block } });

        ctx.builder.setCurrentBlock(panic_block);
        ctx.builder.terminate(.{ .unreachable_term = .{ .reason = if (want_success) "нет значения" else "нет ошибки" } });

        ctx.builder.setCurrentBlock(ok_block);
        const ok_loaded = try ctx.builder.newValue(object_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = ok_loaded, .local = receiver_local } });
        const dst = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .get_variant_field = .{ .dst = dst, .subject = ok_loaded, .field_index = 0 } });
        return continuesWith(dst);
    }
    // `получить(запасное)`/`получить_ошибку(запасное)`: same branch-
    // extract-or-fallback shape as `lowerOptionMethodCall`'s own
    // `получить`.
    if ((std.mem.eql(u8, property.property, "получить") or std.mem.eql(u8, property.property, "получить_ошибку")) and call.arguments.len == 1) {
        const want_success = std.mem.eql(u8, property.property, "получить");
        const result_local_name = if (want_success) "$result" else "$result_err";
        const receiver_local = try ctx.builder.newLocal(symbols.invalid_symbol, result_local_name, object_type);
        try ctx.builder.emit(.{ .store_local = .{ .local = receiver_local, .src = receiver.value } });
        const fallback = try lowerExpr(ctx, call.arguments[0]);
        if (fallback.flow == .terminates) return terminated;
        const fallback_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$result_fallback", result_type);
        try ctx.builder.emit(.{ .store_local = .{ .local = fallback_local, .src = fallback.value } });
        const out_local = try ctx.builder.newLocal(symbols.invalid_symbol, "$result_out", result_type);
        const condition = try ctx.builder.newValue(ctx.checked.types.builtins.boolean);
        const loaded = try ctx.builder.newValue(object_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = loaded, .local = receiver_local } });
        try ctx.builder.emit(.{ .match_tag = .{ .dst = condition, .subject = loaded, .tag = if (want_success) 0 else 1 } });
        const matched = try ctx.builder.newBlock();
        const unmatched = try ctx.builder.newBlock();
        const merge = try ctx.builder.newBlock();
        ctx.builder.terminate(.{ .branch = .{ .cond = condition, .then_block = matched, .else_block = unmatched } });

        ctx.builder.setCurrentBlock(matched);
        const matched_loaded = try ctx.builder.newValue(object_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = matched_loaded, .local = receiver_local } });
        const value = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .get_variant_field = .{ .dst = value, .subject = matched_loaded, .field_index = 0 } });
        try ctx.builder.emit(.{ .store_local = .{ .local = out_local, .src = value } });
        ctx.builder.terminate(.{ .jump = .{ .target = merge } });

        ctx.builder.setCurrentBlock(unmatched);
        const default_value = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = default_value, .local = fallback_local } });
        try ctx.builder.emit(.{ .store_local = .{ .local = out_local, .src = default_value } });
        ctx.builder.terminate(.{ .jump = .{ .target = merge } });

        ctx.builder.setCurrentBlock(merge);
        const result = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .load_local = .{ .dst = result, .local = out_local } });
        return continuesWith(result);
    }
    return null;
}

fn lowerStructConstructor(ctx: *LoweringContext, expression: ast.ExprId, symbol: symbols.SymbolId, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .type) return null;
    const type_entry = ctx.checked.types.get(result_type) orelse return null;
    const nominal = switch (type_entry.*) {
        .nominal => |value| value,
        else => return null,
    };
    if (nominal.symbol != symbol) return null;
    const fields = fieldsForNominalSymbol(ctx, symbol) orelse return null;
    if (fields.len > 3) return unsupported("структура с более чем 3 полями");
    const arguments = ctx.checked.call_arguments.get(expression) orelse call.arguments;
    const args = try lowerCallArgs(ctx, arguments) orelse return terminated;
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .new_aggregate = .{ .dst = dst, .type_name = entry.name, .elements = args } });
    return continuesWith(dst);
}

// `x как Целое` / `x как Число` — same real gap `compiler.zig`'s
// `.cast` codegen fixes on the native/bytecode path (see its doc
// comment) — `mir_lowering.zig` needs the SAME handling independently
// since it never routes through `compiler.zig` at all. `Число` is a
// pure no-op (identity — both share one f64 MIR/WASM representation),
// `Целое` truncates toward zero via `UnOp.int_trunc`.
fn lowerCast(ctx: *LoweringContext, expression: ast.ExprId, cast: anytype) anyerror!ExprOutcome {
    const argument_outcome = try lowerExpr(ctx, cast.operand);
    if (argument_outcome.flow == .terminates) return terminated;
    const cast_type = ctx.checked.expression_types.get(expression) orelse return unsupported("не удалось определить тип каста");
    if (!ctx.checked.types.eql(cast_type, ctx.checked.types.builtins.integer)) return continuesWith(argument_outcome.value);

    const dst = try ctx.builder.newValue(ctx.checked.types.builtins.integer);
    try ctx.builder.emit(.{ .unary = .{ .dst = dst, .op = .int_trunc, .src = argument_outcome.value } });
    return continuesWith(dst);
}

fn lowerLengthBuiltinCall(ctx: *LoweringContext, symbol: symbols.SymbolId, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .builtin or entry.module_path != null or !std.mem.eql(u8, entry.name, "длина")) return null;
    if (call.arguments.len != 1) return unsupported("длина с числом аргументов != 1");

    const argument_type = ctx.checked.expression_types.get(call.arguments[0]) orelse return null;
    const type_entry = ctx.checked.types.get(argument_type) orelse return null;
    if (type_entry.* != .primitive or type_entry.primitive != .string) return null;

    const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = dst, .name = "строки::длина", .args = args } });
    return continuesWith(dst);
}

// `паника(текст)` — native compiler compiles the message expression
// then emits a `.panic` bytecode instruction that halts with that exact
// runtime string (`compiler.zig`'s `compilePanicBuiltin`). WASM has no
// analogous "trap with a runtime message" primitive — `unreachable`
// (opcode `0x00`, already used via `.unreachable_term` for non-
// exhaustive `выбор` at `mir_lowering.zig:719` and `wasm_strings.zig`'s
// own invalid-UTF-8/out-of-range panics) takes no operand at all. The
// message argument is still LOWERED (via `lowerCallArgs`, same as every
// other builtin here) so any `unsupported()` inside IT still surfaces
// correctly, but its VALUE is discarded — the message text itself is
// unrecoverably lost under WASM AOT, a known, accepted gap (matches
// this codebase's own established practice for this class of WASM-only
// divergence, e.g. `wasm_strings.zig`'s из_числа/в_число doc comments)
// rather than blocking on it.
fn lowerPanicBuiltinCall(ctx: *LoweringContext, symbol: symbols.SymbolId, call: anytype) anyerror!?ExprOutcome {
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .builtin or entry.module_path != null or !std.mem.eql(u8, entry.name, "паника")) return null;
    if (call.arguments.len != 1) return unsupported("паника ожидает 1 аргумент");

    const message = try lowerExpr(ctx, call.arguments[0]);
    if (message.flow == .terminates) return terminated;
    ctx.builder.terminate(.{ .unreachable_term = .{ .reason = "паника" } });
    return terminated;
}

fn lowerProcessBuiltinCall(ctx: *LoweringContext, symbol: symbols.SymbolId, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .builtin or entry.module_path != null) return null;
    if (std.mem.eql(u8, entry.name, "отправить") and call.arguments.len == 2) {
        const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
        try ctx.builder.emit(.{ .send = .{ .process = args[0], .message = args[1] } });
        return continuesWith(mir.invalid_value);
    }
    if (std.mem.eql(u8, entry.name, "получить") and call.arguments.len == 0) {
        const dst = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .receive = .{ .dst = dst } });
        return continuesWith(dst);
    }
    if (std.mem.eql(u8, entry.name, "получить_сигнал") and call.arguments.len == 0) {
        const dst = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .receive_signal = .{ .dst = dst } });
        return continuesWith(dst);
    }
    if (std.mem.eql(u8, entry.name, "себя") and call.arguments.len == 0) {
        const dst = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .call_builtin = .{ .dst = dst, .name = "@runtime::current_process", .args = &.{} } });
        return continuesWith(dst);
    }
    return null;
}

// The JS string runtime owns the actual UTF-16 storage; Panos string values
// remain opaque i32 handles in WASM. `строки.срез`/`.найти` deliberately use
// Unicode scalar indices, matching the VM contract, rather than JS UTF-16
// offsets. `в_число` constructs the standard Результат handle in that same
// host runtime, so ordinary Panos `выбор` handles both outcomes unchanged.
fn lowerStringBuiltinCall(ctx: *LoweringContext, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const symbol = ctx.resolution.expr_symbols.get(call.callee) orelse return null;
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "строки")) return null;

    const property = ctx.tree.expr(call.callee).property;
    const name = if (std.mem.eql(u8, property.property, "длина_байт"))
        "строки::длина_байт"
    else if (std.mem.eql(u8, property.property, "срез"))
        "строки::срез"
    else if (std.mem.eql(u8, property.property, "найти"))
        "строки::найти"
    else if (std.mem.eql(u8, property.property, "начинается_с"))
        "строки::начинается_с"
    else if (std.mem.eql(u8, property.property, "заменить"))
        "строки::заменить"
    else if (std.mem.eql(u8, property.property, "разбить"))
        "строки::разбить"
    else if (std.mem.eql(u8, property.property, "из_числа"))
        "строки::из_числа"
    else if (std.mem.eql(u8, property.property, "в_число"))
        "строки::в_число"
    else
        return unsupported("строки.свойство вызов (неподдерживаемая строковая операция в AOT WASM)");

    const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = dst, .name = name, .args = args } });
    return continuesWith(dst);
}

// AOT's deliberately narrow browser-network bridge. The host performs a
// same-origin synchronous XHR because the current WASM ABI has no suspension
// or continuation support; success is `Опция.Есть(тело)`, any failed request
// is `Опция.Нет()`.
fn lowerNetworkBuiltinCall(ctx: *LoweringContext, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const symbol = ctx.resolution.expr_symbols.get(call.callee) orelse return null;
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "сеть")) return null;

    const property = ctx.tree.expr(call.callee).property;
    if (!std.mem.eql(u8, property.property, "http_запрос_sync")) {
        return unsupported("сеть.свойство вызов (неподдерживаемая сетевая операция в AOT WASM)");
    }
    const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = dst, .name = "сеть::http_запрос_sync", .args = args } });
    return continuesWith(dst);
}

// `время.сейчас_мс`/`.монотонно_мс` — the only builtin-module calls this
// Phase-1a-plus slice lowers, matching exactly what `zig/wasm_runtime/
// runtime_wasi.zig`'s own doc comment already anticipated ("Phase-1a never
// lowers a string at all... no clock reads reachable from any lowered
// program yet EITHER" — this is that "either" becoming true). Emitted as
// `call_builtin` with the SAME "модуль::имя" name convention `target.zig`
// already uses for runtime availability checks, not a new naming scheme.
// `время.спать_мс` deliberately has no case here — it's native-only
// (`target.zig`'s `builtinAvailability`), and stays an `unsupported()`
// panic in AOT WASM, same failure mode every other native-only feature
// already gets in this file.
fn lowerTimeBuiltinCall(ctx: *LoweringContext, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const property = ctx.tree.expr(call.callee).property;
    const symbol = ctx.resolution.expr_symbols.get(call.callee) orelse return null;
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "время")) return null;

    if (std.mem.eql(u8, property.property, "спать_мс")) return unsupported("время.спать_мс (native-only builtin, недоступен в AOT WASM)");

    const name = if (std.mem.eql(u8, property.property, "сейчас_мс"))
        "время::сейчас_мс"
    else if (std.mem.eql(u8, property.property, "монотонно_мс"))
        "время::монотонно_мс"
    else
        return unsupported("модуль.свойство вызов (только время.сейчас_мс/монотонно_мс поддержаны в AOT WASM)");

    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = dst, .name = name, .args = &.{} } });
    return continuesWith(dst);
}

// DOM supports the compatible numeric methods plus textual content/input
// methods. The browser emitter transports every Panos `Строка` as an
// opaque JS-runtime handle; click callbacks are still named, zero-argument
// exports and cannot capture a Panos context yet.
// WASM AOT closures, Stage C — type-directed classification of a
// captured value, decided entirely at COMPILE TIME from the capture's
// own static type (no runtime type tag exists to drive real recursion
// in emitted code — same reasoning `.new_aggregate`'s per-field
// expansion in `wasm_objects.zig` already relies on).
//   `.scalar`        — Число/Булево/Целое: raw 8-byte copy, no
//                       pointer-chasing needed at all.
//   `.string`        — Строка: promote via the existing
//                       `wasm_heap.findOrBuildPromoteToPermanent`.
//   `.struct_simple`  — a nominal struct whose OWN fields are ALL
//                       `.scalar`/`.string` (one level only — a field
//                       that's itself a struct/array is `.unsupported`
//                       for now, a real deferred gap, not silently
//                       wrong: nested promotion would need genuine
//                       recursion through THIS SAME classification,
//                       which the current one-level implementation in
//                       `promoteSimpleStructToPermanent` doesn't do
//                       yet).
//   `.function_ref`   — a `.function`-typed capture. Real, common case
//                       found only by RUNNING this, not by reading the
//                       type system: `symbols.zig`'s `lookupTrackingCaptures`
//                       registers ANY `.function`-kind symbol referenced
//                       across a lambda boundary as a capture —
//                       including a plain top-level function called
//                       DIRECTLY inside the handler body (e.g.
//                       `обработать_переключить(id)`), even though
//                       `mir_lowering.zig`'s own direct-call fast path
//                       means that reference never actually needs a
//                       boxed closure value at the CALL site at all.
//                       `lowerLambda`'s env-building step doesn't know
//                       this either — it captures every symbol the
//                       resolver listed, unconditionally. Promoted via
//                       a RUNTIME check (`promoteFunctionRefCapture`):
//                       a plain function reference's box always has
//                       `env_ptr == 0` (nothing captured BY it), safe
//                       to copy as-is; a genuine closure-with-captures
//                       value (`env_ptr != 0`) traps instead of
//                       silently producing a dangling pointer — telling
//                       the two apart statically isn't possible (both
//                       share the same `.function` type).
//   `.unsupported`    — Массив (needs a RUNTIME loop over a dynamic
//                       element count — not a compile-time-unrolled
//                       shape like a struct's fixed field list, real
//                       deferred gap), `Процесс` (actors+closures
//                       interaction unexplored), or a struct with a
//                       non-simple field.
const CaptureKind = enum { scalar, string, struct_simple, function_ref, unsupported };

fn classifyCapture(checked: *const type_checker.CheckResult, type_id: types.TypeId) CaptureKind {
    if (checked.types.eql(type_id, checked.types.builtins.string)) return .string;
    const entry = checked.types.get(type_id) orelse return .scalar;
    return switch (entry.*) {
        .nominal => |nominal| blk: {
            const fields = checked.nominal_fields.get(nominal.symbol) orelse break :blk .unsupported;
            for (fields) |field| {
                const field_kind = classifyCapture(checked, field.typ);
                if (field_kind != .scalar and field_kind != .string) break :blk .unsupported;
            }
            break :blk .struct_simple;
        },
        .function => .function_ref,
        .array, .process => .unsupported,
        else => .scalar,
    };
}

pub const invoke_closure_click_trampoline_name = "@invoke_closure_click";

// One FIXED trampoline, shared by every `DOM.на_клик_замыкание`
// registration in the module — Stage B's handler shape is always
// `функ() -> Пусто` (captures carry all the state a handler needs, no
// event-argument passing yet), so exactly ONE shape is ever needed.
// Body is just `.call_value{callee: box_param, args: &.{}}` — deliberately
// NOT hand-unboxed here: `wasm_interfaces.zig`'s existing `expandCallValue`
// already does the unbox-then-`call_indirect` rewrite for ANY closure-typed
// `.call_value`, generically, later in the pipeline — reusing it here
// avoids duplicating that logic for a second time.
fn findOrBuildInvokeClosureClickTrampoline(allocator: std.mem.Allocator, module: *mir.Module, type_store: *const types.TypeStore, layout: wasm_heap.PtrLayout) !mir.FunctionId {
    if (wasm_heap.findFunctionByName(module, invoke_closure_click_trampoline_name)) |id| return id;
    const id = try mir_builder.newFunction(module, allocator, invoke_closure_click_trampoline_name, dummy_symbol, type_store.builtins.void, wasm_heap.dummy_span);
    var builder = try mir_builder.Builder.beginFunction(module, allocator, id);
    const box_local = try builder.newLocal(dummy_symbol, "box", layout.ptr_type);
    builder.currentFunction().parameters = try allocator.dupe(mir.LocalId, &.{box_local});
    builder.currentFunction().type_store = type_store;

    const box_val = try wasm_heap.loadLocal(&builder, box_local, layout.ptr_type);
    try builder.emit(.{ .call_value = .{ .dst = null, .callee = box_val, .args = &.{} } });
    builder.terminate(.{ .return_value = .{ .value = null } });
    return id;
}

// Promotes ONE already-loaded value (`old_value`, typed `value_type`)
// into the permanent region, per `classifyCapture`'s classification —
// the shared leaf operation both `promoteClosureBoxToPermanent` (env
// slots) and `promoteSimpleStructToPermanent` (struct fields) reduce
// to. `.scalar` is a no-op (the raw value IS already permanent-region-
// safe — it carries no pointer at all). `.unsupported` never reaches
// here — rejected earlier, before any lowering happens, by
// `lowerDomClickClosure`'s own pre-check.
fn promoteCaptureValue(ctx: *LoweringContext, layout: wasm_heap.PtrLayout, value_type: types.TypeId, old_value: mir.ValueId) !mir.ValueId {
    return switch (classifyCapture(ctx.checked, value_type)) {
        .scalar => old_value,
        .string => blk: {
            const promote_id = try wasm_heap.findOrBuildPromoteToPermanent(ctx.allocator, ctx.builder.module, &ctx.checked.types, layout);
            const promoted = try ctx.builder.newValue(layout.ptr_type);
            try ctx.builder.emit(.{ .call = .{ .dst = promoted, .callee = promote_id, .args = try wasm_heap.dupeOne(ctx.builder.module, old_value) } });
            break :blk promoted;
        },
        .struct_simple => try promoteSimpleStructToPermanent(ctx, layout, value_type, old_value),
        .function_ref => try promoteFunctionRefCapture(ctx, layout, old_value),
        .unsupported => unreachable,
    };
}

// A captured `.function`-typed value's box, copied into the permanent
// region — see `CaptureKind.function_ref`'s own doc comment for WHY
// this case exists at all (the resolver captures every function
// reference crossing a lambda boundary, even ones the lowering-time
// direct-call fast path never actually boxes). Only SAFE, in general,
// when the captured box's `env_ptr` is exactly 0 (a plain named
// function reference — the overwhelmingly common case, e.g. calling
// another top-level function from inside a DOM handler) — a non-zero
// `env_ptr` means the captured value is a genuine closure WITH ITS OWN
// captures, which would need recursive promotion of THAT environment
// too (closures-capturing-closures, out of scope here). Can't tell the
// two apart statically (both share the same `.function` type) — a
// RUNTIME check decides, trapping with a clear diagnostic instead of
// silently producing a dangling pointer if it's the unsupported case.
fn promoteFunctionRefCapture(ctx: *LoweringContext, layout: wasm_heap.PtrLayout, old_box: mir.ValueId) anyerror!mir.ValueId {
    const module = ctx.builder.module;
    const old_box_local = try wasm_heap.storeLocal(&ctx.builder, "@click_old_fn_box", layout.ptr_type, old_box);

    const old_box_for_table = try wasm_heap.loadLocal(&ctx.builder, old_box_local, layout.ptr_type);
    const table_index = try ctx.builder.newValue(layout.idx_type);
    try ctx.builder.emit(.{ .mem_load = .{ .dst = table_index, .addr = old_box_for_table } });
    const table_index_local = try wasm_heap.storeLocal(&ctx.builder, "@click_fn_table_index", layout.idx_type, table_index);

    const old_box_for_env = try wasm_heap.loadLocal(&ctx.builder, old_box_local, layout.ptr_type);
    const four = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, 4);
    const env_addr = try wasm_heap.binOp(&ctx.builder, layout.idx_type, .add, old_box_for_env, four);
    const env_ptr = try ctx.builder.newValue(layout.ptr_type);
    try ctx.builder.emit(.{ .mem_load = .{ .dst = env_ptr, .addr = env_addr } });

    const zero_check = try wasm_heap.addressConst(&ctx.builder, layout.ptr_type, 0);
    const is_plain = try wasm_heap.cmpOp(&ctx.builder, layout.bool_type, .equal, env_ptr, zero_check);

    const ok_block = try ctx.builder.newBlock();
    const trap_block = try ctx.builder.newBlock();
    ctx.builder.terminate(.{ .branch = .{ .cond = is_plain, .then_block = ok_block, .else_block = trap_block } });

    ctx.builder.setCurrentBlock(trap_block);
    ctx.builder.terminate(.{ .unreachable_term = .{ .reason = "DOM.на_клик_замыкание(): захват замыкания с собственными захватами пока не поддержан (Stage C ограничение)" } });

    ctx.builder.setCurrentBlock(ok_block);
    const alloc_permanent_id = try wasm_heap.findOrBuildAllocPermanent(ctx.allocator, module, &ctx.checked.types, layout);
    const box_size = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, 8);
    const new_box = try ctx.builder.newValue(layout.ptr_type);
    try ctx.builder.emit(.{ .call = .{ .dst = new_box, .callee = alloc_permanent_id, .args = try wasm_heap.dupeOne(module, box_size) } });
    const new_box_local = try wasm_heap.storeLocal(&ctx.builder, "@click_new_fn_box", layout.ptr_type, new_box);

    const table_index_for_store = try wasm_heap.loadLocal(&ctx.builder, table_index_local, layout.idx_type);
    const new_box_for_table = try wasm_heap.loadLocal(&ctx.builder, new_box_local, layout.ptr_type);
    try ctx.builder.emit(.{ .mem_store = .{ .addr = new_box_for_table, .src = table_index_for_store } });

    const zero_store = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, 0);
    const four2 = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, 4);
    const new_box_for_env_addr = try wasm_heap.loadLocal(&ctx.builder, new_box_local, layout.ptr_type);
    const new_env_addr = try wasm_heap.binOp(&ctx.builder, layout.idx_type, .add, new_box_for_env_addr, four2);
    try ctx.builder.emit(.{ .mem_store = .{ .addr = new_env_addr, .src = zero_store } });

    return try wasm_heap.loadLocal(&ctx.builder, new_box_local, layout.ptr_type);
}

// A "simple" struct (per `classifyCapture` — every field is
// `.scalar`/`.string`, exactly one level, no further nesting):
// allocate a same-field-count copy in the permanent region, promote or
// raw-copy each field individually. Same 8-byte-slot `frame_load`/
// `frame_store` layout `wasm_objects.zig` already established for
// plain structs (no tag slot — that's a variant-only convention).
fn promoteSimpleStructToPermanent(ctx: *LoweringContext, layout: wasm_heap.PtrLayout, struct_type: types.TypeId, old_struct_ptr: mir.ValueId) anyerror!mir.ValueId {
    const module = ctx.builder.module;
    const type_entry = ctx.checked.types.get(struct_type) orelse return unsupported("захват структуры неизвестного типа (Stage C)");
    const nominal = switch (type_entry.*) {
        .nominal => |value| value,
        else => return unsupported("захват не-структуры как структуры (Stage C)"),
    };
    const fields = ctx.checked.nominal_fields.get(nominal.symbol) orelse return unsupported("захват generic-структуры (Stage C)");

    const old_struct_local = try wasm_heap.storeLocal(&ctx.builder, "@click_old_struct", layout.ptr_type, old_struct_ptr);

    const alloc_permanent_id = try wasm_heap.findOrBuildAllocPermanent(ctx.allocator, module, &ctx.checked.types, layout);
    const struct_size = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, @intCast(fields.len * 8));
    const new_struct = try ctx.builder.newValue(layout.ptr_type);
    try ctx.builder.emit(.{ .call = .{ .dst = new_struct, .callee = alloc_permanent_id, .args = try wasm_heap.dupeOne(module, struct_size) } });
    const new_struct_local = try wasm_heap.storeLocal(&ctx.builder, "@click_new_struct", layout.ptr_type, new_struct);

    for (fields, 0..) |field, j| {
        const old_struct_for_load = try wasm_heap.loadLocal(&ctx.builder, old_struct_local, layout.ptr_type);
        const old_field_val = try ctx.builder.newValue(field.typ);
        try ctx.builder.emit(.{ .frame_load = .{ .dst = old_field_val, .frame = old_struct_for_load, .slot = @intCast(j) } });

        const promoted_field = try promoteCaptureValue(ctx, layout, field.typ, old_field_val);

        const new_struct_for_store = try wasm_heap.loadLocal(&ctx.builder, new_struct_local, layout.ptr_type);
        try ctx.builder.emit(.{ .frame_store = .{ .frame = new_struct_for_store, .slot = @intCast(j), .src = promoted_field } });
    }

    return try wasm_heap.loadLocal(&ctx.builder, new_struct_local, layout.ptr_type);
}

// Rebuilds a `.build_closure`-produced box (table_index + env_ptr,
// currently in the ordinary RESETTABLE arena) directly in the
// PERMANENT region — needed even for SCALAR-only captures (Stage B):
// the box+env ALLOCATIONS themselves are still pointers that JS holds
// raw across a separate later export call (the click), regardless of
// what's inside them. Stage C extends this from a flat byte copy (only
// correct when every slot is scalar) to a per-slot, TYPE-DIRECTED copy
// — a `Строка`/simple-struct slot gets its OWN pointed-to data promoted
// too (`promoteCaptureValue`), not just its raw pointer bit-pattern
// (which would otherwise dangle after the next arena reset — the exact
// bug this whole function exists to avoid, one level up the pointer
// chain from `на_клик_контекст`'s own context-string promotion).
fn promoteClosureBoxToPermanent(ctx: *LoweringContext, layout: wasm_heap.PtrLayout, box_value: mir.ValueId, captures: []const symbols.SymbolId) !mir.ValueId {
    const module = ctx.builder.module;
    const box_local = try wasm_heap.storeLocal(&ctx.builder, "@click_box", layout.ptr_type, box_value);

    const box_for_table = try wasm_heap.loadLocal(&ctx.builder, box_local, layout.ptr_type);
    const table_index = try ctx.builder.newValue(layout.idx_type);
    try ctx.builder.emit(.{ .mem_load = .{ .dst = table_index, .addr = box_for_table } });
    const table_index_local = try wasm_heap.storeLocal(&ctx.builder, "@click_table_index", layout.idx_type, table_index);

    const promoted_env_local = env_blk: {
        if (captures.len == 0) {
            const zero = try wasm_heap.addressConst(&ctx.builder, layout.ptr_type, 0);
            break :env_blk try wasm_heap.storeLocal(&ctx.builder, "@click_env", layout.ptr_type, zero);
        }
        const box_for_env = try wasm_heap.loadLocal(&ctx.builder, box_local, layout.ptr_type);
        const four = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, 4);
        const env_addr = try wasm_heap.binOp(&ctx.builder, layout.idx_type, .add, box_for_env, four);
        const old_env_ptr = try ctx.builder.newValue(layout.ptr_type);
        try ctx.builder.emit(.{ .mem_load = .{ .dst = old_env_ptr, .addr = env_addr } });
        const old_env_local = try wasm_heap.storeLocal(&ctx.builder, "@click_old_env", layout.ptr_type, old_env_ptr);

        const alloc_permanent_id = try wasm_heap.findOrBuildAllocPermanent(ctx.allocator, module, &ctx.checked.types, layout);
        const new_env_size = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, @intCast(captures.len * 8));
        const new_env = try ctx.builder.newValue(layout.ptr_type);
        try ctx.builder.emit(.{ .call = .{ .dst = new_env, .callee = alloc_permanent_id, .args = try wasm_heap.dupeOne(module, new_env_size) } });
        const new_env_local = try wasm_heap.storeLocal(&ctx.builder, "@click_new_env", layout.ptr_type, new_env);

        for (captures, 0..) |capture_symbol, i| {
            const capture_type = ctx.checked.symbol_types.get(capture_symbol) orelse ctx.checked.types.builtins.void;

            const old_env_for_load = try wasm_heap.loadLocal(&ctx.builder, old_env_local, layout.ptr_type);
            const old_slot_val = try ctx.builder.newValue(capture_type);
            try ctx.builder.emit(.{ .frame_load = .{ .dst = old_slot_val, .frame = old_env_for_load, .slot = @intCast(i) } });

            const promoted_val = try promoteCaptureValue(ctx, layout, capture_type, old_slot_val);

            const new_env_for_store = try wasm_heap.loadLocal(&ctx.builder, new_env_local, layout.ptr_type);
            try ctx.builder.emit(.{ .frame_store = .{ .frame = new_env_for_store, .slot = @intCast(i), .src = promoted_val } });
        }

        break :env_blk new_env_local;
    };

    const alloc_permanent_id = try wasm_heap.findOrBuildAllocPermanent(ctx.allocator, module, &ctx.checked.types, layout);
    const box_size = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, 8);
    const new_box = try ctx.builder.newValue(layout.ptr_type);
    try ctx.builder.emit(.{ .call = .{ .dst = new_box, .callee = alloc_permanent_id, .args = try wasm_heap.dupeOne(module, box_size) } });
    const new_box_local = try wasm_heap.storeLocal(&ctx.builder, "@click_new_box", layout.ptr_type, new_box);

    const table_index_for_store = try wasm_heap.loadLocal(&ctx.builder, table_index_local, layout.idx_type);
    const new_box_for_table = try wasm_heap.loadLocal(&ctx.builder, new_box_local, layout.ptr_type);
    try ctx.builder.emit(.{ .mem_store = .{ .addr = new_box_for_table, .src = table_index_for_store } });

    const env_for_store = try wasm_heap.loadLocal(&ctx.builder, promoted_env_local, layout.ptr_type);
    const four2 = try wasm_heap.addressConst(&ctx.builder, layout.idx_type, 4);
    const new_box_for_env_addr = try wasm_heap.loadLocal(&ctx.builder, new_box_local, layout.ptr_type);
    const env_field_addr = try wasm_heap.binOp(&ctx.builder, layout.idx_type, .add, new_box_for_env_addr, four2);
    try ctx.builder.emit(.{ .mem_store = .{ .addr = env_field_addr, .src = env_for_store } });

    return try wasm_heap.loadLocal(&ctx.builder, new_box_local, layout.ptr_type);
}

// `DOM.на_клик_замыкание(selector, замыкание)` — WASM AOT closures,
// Stage B. Deliberately requires the handler argument to be a literal
// `.lambda` expression AT THE CALL SITE (not an arbitrary closure-typed
// value from elsewhere) — this is what makes the capture list
// statically inspectable here via `lambda_captures`, needed for the
// scalar-only restriction below. See `project_panos_wasm_aot_closures`.
fn lowerDomClickClosure(ctx: *LoweringContext, call: anytype) anyerror!ExprOutcome {
    if (call.arguments.len != 2) return unsupported("DOM.на_клик_замыкание() ожидает 2 аргумента");
    const handler_expr = call.arguments[1];
    switch (ctx.tree.expr(handler_expr).*) {
        .lambda => {},
        else => return unsupported("DOM.на_клик_замыкание() ожидает лямбда-выражение непосредственно на месте вызова (Stage B)"),
    }
    const captures = ctx.resolution.lambda_captures.get(handler_expr) orelse &.{};
    for (captures) |capture_symbol| {
        const capture_type = ctx.checked.symbol_types.get(capture_symbol) orelse ctx.checked.types.builtins.void;
        if (classifyCapture(ctx.checked, capture_type) == .unsupported) {
            return unsupported("DOM.на_клик_замыкание(): захват массива/процесса/замыкания/структуры со вложенным указателем пока не поддержан (Stage C ограничение, project_panos_wasm_aot_closures)");
        }
    }

    const layout = wasm_heap.PtrLayout{
        .ptr_type = ctx.checked.types.builtins.string,
        .idx_type = ctx.checked.types.builtins.boolean,
        .bool_type = ctx.checked.types.builtins.boolean,
    };

    // Lowered in a DELIBERATELY non-source order: the handler/promotion
    // side first (which can open a WASM `if/else` block internally —
    // `promoteFunctionRefCapture`'s runtime env_ptr check, for a
    // captured plain-function reference), its result stashed in a
    // Local IMMEDIATELY; `selector` — always a trivial, non-branching
    // expression in practice (Stage B/C already require the handler to
    // be a literal lambda; a `DOM.на_клик_замыкание` call's selector is
    // realistically always a string literal) — computed LAST, right
    // before the call, so it never needs to survive anything.
    //
    // Real bug found via wasmtime, took several attempts to pin down:
    // a bare, un-Local-routed value computed BEFORE
    // `promoteClosureBoxToPermanent` does NOT reliably survive its
    // internal branch — but neither does naively wrapping it in a
    // Local and reloading it in EITHER position relative to
    // `promoteClosureBoxToPermanent`'s own call (both orderings tried,
    // both corrupted `promoted_box`'s own construction instead —
    // `call_builtin`'s codegen assumes args are pushed in ARRAY order
    // with NOTHING else interleaved, and squeezing an extra Local
    // reload of a value computed EARLIER into the middle of
    // `promoteClosureBoxToPermanent`'s own instruction stream broke
    // that invariant even when semantically "correct"). Restructuring
    // so NEITHER value's own danger window (branching, or being
    // computed early and reloaded late) overlaps the OTHER's
    // construction sidesteps the whole problem instead of fighting it.
    const handler_outcome = try lowerExpr(ctx, handler_expr);
    if (handler_outcome.flow == .terminates) return terminated;

    _ = try findOrBuildInvokeClosureClickTrampoline(ctx.allocator, ctx.builder.module, &ctx.checked.types, layout);
    const promoted_box = try promoteClosureBoxToPermanent(ctx, layout, handler_outcome.value, captures);
    const promoted_box_local = try wasm_heap.storeLocal(&ctx.builder, "@click_promoted_box", layout.ptr_type, promoted_box);

    const selector = try lowerExpr(ctx, call.arguments[0]);
    if (selector.flow == .terminates) return terminated;
    const promoted_box_for_call = try wasm_heap.loadLocal(&ctx.builder, promoted_box_local, layout.ptr_type);

    const arena = ctx.builder.module.arena.allocator();
    var args: std.ArrayList(mir.ValueId) = .empty;
    try args.append(arena, selector.value);
    try args.append(arena, promoted_box_for_call);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = null, .name = "DOM::на_клик_замыкание", .args = try args.toOwnedSlice(arena) } });
    return continuesWith(mir.invalid_value);
}

fn lowerDomBuiltinCall(ctx: *LoweringContext, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const symbol = ctx.resolution.expr_symbols.get(call.callee) orelse return null;
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "DOM")) return null;

    const property = ctx.tree.expr(call.callee).property;
    if (std.mem.eql(u8, property.property, "на_клик_замыкание")) {
        return try lowerDomClickClosure(ctx, call);
    }
    const name = if (std.mem.eql(u8, property.property, "текст"))
        "DOM::текст"
    else if (std.mem.eql(u8, property.property, "установить_текст"))
        "DOM::установить_текст"
    else if (std.mem.eql(u8, property.property, "на_клик"))
        if (call.arguments.len == 3) "DOM::на_клик_контекст" else "DOM::на_клик"
    else if (std.mem.eql(u8, property.property, "текст_строка"))
        "DOM::текст_строка"
    else if (std.mem.eql(u8, property.property, "установить_текст_строка"))
        "DOM::установить_текст_строка"
    else if (std.mem.eql(u8, property.property, "значение_поля"))
        "DOM::значение_поля"
    else if (std.mem.eql(u8, property.property, "установить_значение_поля"))
        "DOM::установить_значение_поля"
    else if (std.mem.eql(u8, property.property, "создать_и_добавить"))
        "DOM::создать_и_добавить"
    else if (std.mem.eql(u8, property.property, "после_кадра"))
        "DOM::после_кадра"
    else if (std.mem.eql(u8, property.property, "атрибут"))
        "DOM::атрибут"
    else if (std.mem.eql(u8, property.property, "установить_атрибут"))
        "DOM::установить_атрибут"
    else
        return unsupported("DOM.свойство вызов (неподдерживаемый DOM-метод)");

    var args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;

    // `на_клик_контекст`/`после_кадра`'s context argument is captured
    // RAW by the JS loader (`aot-dom-loader.js`'s `dom_on_click_context`/
    // `dom_after_frame`) and handed back UNCHANGED to a handler invoked
    // in a wholly SEPARATE, later export call — see
    // `project_panos_elm_architecture_dom_storage_design`/
    // `project_panos_wasm_aot_memory_growth_fix` for the full research.
    // `wasm_gc_arena.zig`'s per-call arena reset (Phase 1 GC) would free
    // this value out from under JS on the very next event if it stayed
    // in the ordinary arena. Promote (copy) it into the non-resettable
    // permanent region here, at the exact point it's about to be handed
    // to the host import — everything else keeps going through the
    // ordinary arena, no call-graph analysis needed (see
    // `wasm_heap.findOrBuildPromoteToPermanent`'s own doc comment).
    const context_arg_index: ?usize = if (std.mem.eql(u8, name, "DOM::на_клик_контекст"))
        2
    else if (std.mem.eql(u8, name, "DOM::после_кадра"))
        1
    else
        null;
    if (context_arg_index) |idx| {
        const layout = wasm_heap.PtrLayout{
            .ptr_type = ctx.checked.types.builtins.string,
            .idx_type = ctx.checked.types.builtins.boolean,
            .bool_type = ctx.checked.types.builtins.boolean,
        };
        const promote_id = try wasm_heap.findOrBuildPromoteToPermanent(ctx.allocator, ctx.builder.module, &ctx.checked.types, layout);
        const promoted = try ctx.builder.newValue(layout.ptr_type);
        try ctx.builder.emit(.{ .call = .{ .dst = promoted, .callee = promote_id, .args = try wasm_heap.dupeOne(ctx.builder.module, args[idx]) } });
        const arena = ctx.builder.module.arena.allocator();
        const new_args = try arena.dupe(mir.ValueId, args);
        new_args[idx] = promoted;
        args = new_args;
    }

    const is_void = ctx.checked.types.eql(result_type, ctx.checked.types.builtins.void);
    if (is_void) {
        try ctx.builder.emit(.{ .call_builtin = .{ .dst = null, .name = name, .args = args } });
        return continuesWith(mir.invalid_value);
    }
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = dst, .name = name, .args = args } });
    return continuesWith(dst);
}

// `состояние.прочитать`/`.записать` — the JS-loader-held Model
// (`aot-dom-loader.js`'s `heldModel` closure variable), NOT a DOM
// attribute — see `project_panos_elm_architecture_dom_storage_design`.
// Unlike `на_клик_контекст`/`после_кадра`'s context argument, NOTHING
// here needs `wasm_heap.findOrBuildPromoteToPermanent` — the value
// always flows as a full byte COPY through `readString`/`writeString`
// on the JS side (never a raw pointer JS holds onto across calls), so
// it's automatically safe under `wasm_gc_arena.zig`'s per-call arena
// reset with no special handling.
fn lowerStateBuiltinCall(ctx: *LoweringContext, call: anytype, result_type: types.TypeId) anyerror!?ExprOutcome {
    const symbol = ctx.resolution.expr_symbols.get(call.callee) orelse return null;
    const entry = ctx.resolution.symbols.get(symbol) orelse return null;
    if (entry.kind != .builtin or entry.module_path == null or !std.mem.eql(u8, entry.module_path.?, "состояние")) return null;

    const property = ctx.tree.expr(call.callee).property;
    const name = if (std.mem.eql(u8, property.property, "прочитать"))
        "состояние::прочитать"
    else if (std.mem.eql(u8, property.property, "записать"))
        "состояние::записать"
    else
        return unsupported("состояние.свойство вызов (неподдерживаемый метод)");

    const args = try lowerCallArgs(ctx, call.arguments) orelse return terminated;
    const is_void = ctx.checked.types.eql(result_type, ctx.checked.types.builtins.void);
    if (is_void) {
        try ctx.builder.emit(.{ .call_builtin = .{ .dst = null, .name = name, .args = args } });
        return continuesWith(mir.invalid_value);
    }
    const dst = try ctx.builder.newValue(result_type);
    try ctx.builder.emit(.{ .call_builtin = .{ .dst = dst, .name = name, .args = args } });
    return continuesWith(dst);
}

fn lowerCallArgs(ctx: *LoweringContext, expressions: []const ast.ExprId) anyerror!?[]const mir.ValueId {
    // Arena-backed (see `mir.Module.arena`'s doc comment) — this slice is
    // stored permanently inside a `call_value` instruction, unlike
    // `ctx.allocator`-backed temporaries that get freed within this call.
    const arena = ctx.builder.module.arena.allocator();
    var args: std.ArrayList(mir.ValueId) = .empty;
    for (expressions) |expression| {
        const outcome = try lowerExpr(ctx, expression);
        if (outcome.flow == .terminates) return null;
        try args.append(arena, outcome.value);
    }
    return try args.toOwnedSlice(arena);
}

fn emitCallValue(ctx: *LoweringContext, callee: mir.ValueId, args: []const mir.ValueId, result_type: types.TypeId) anyerror!ExprOutcome {
    if (!ctx.checked.types.eql(result_type, ctx.checked.types.builtins.void)) {
        const dst = try ctx.builder.newValue(result_type);
        try ctx.builder.emit(.{ .call_value = .{ .dst = dst, .callee = callee, .args = args } });
        return continuesWith(dst);
    }
    try ctx.builder.emit(.{ .call_value = .{ .dst = null, .callee = callee, .args = args } });
    return continuesWith(mir.invalid_value);
}

test "lowerModule lowers a recursive arithmetic function to a valid CFG" {
    const allocator = std.testing.allocator;
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const type_checker_mod = @import("type_checker.zig");
    const source_text =
        \\функ факториал(n: Число) -> Число
        \\    если n < 2.0 тогда
        \\        1.0
        \\    иначе
        \\        n * факториал(n - 1.0)
        \\    конец
        \\конец
    ;
    var lexed = try lexer.tokenize(allocator, source_text, 0);
    defer lexed.deinit();
    var parsed = try parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    var resolved = try resolver.resolve(allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker_mod.check(allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);

    var module = try lowerModule(allocator, &parsed.ast, &resolved, &checked);
    defer module.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), module.functions.items.len);
    const function = &module.functions.items[0];
    try std.testing.expectEqualStrings("факториал", function.name);
    // entry (condition) + then + else + merge — the if-expression's own
    // 4-block shape, nothing more (this function's body IS the if-expr).
    try std.testing.expectEqual(@as(usize, 4), function.blocks.items.len);

    var cfg = try @import("mir_cfg.zig").computeCfgInfo(allocator, function);
    defer cfg.deinit();
    for (cfg.reachable) |reachable| try std.testing.expect(reachable);
}

test "lowerModule lowers пока into header/body/exit blocks, no back-edge when the body always returns" {
    const allocator = std.testing.allocator;
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const type_checker_mod = @import("type_checker.zig");
    // Deliberately avoids assignment here to isolate header/body/exit block
    // wiring and a body that TERMINATES (return), which must suppress the
    // loop's back-edge jump — see the accumulator test below for the
    // assignment-driven back-edge case.
    const source_text =
        \\функ цикл_тест(n: Число) -> Число
        \\    пока n > 0.0 цикл
        \\        возврат n
        \\    конец
        \\    0.0
        \\конец
    ;
    var lexed = try lexer.tokenize(allocator, source_text, 0);
    defer lexed.deinit();
    var parsed = try parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    var resolved = try resolver.resolve(allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker_mod.check(allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);

    var module = try lowerModule(allocator, &parsed.ast, &resolved, &checked);
    defer module.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), module.functions.items.len);
    const function = &module.functions.items[0];
    // entry (jump to header) + header (condition) + body (returns) + exit
    // (falls through to the trailing `0`).
    try std.testing.expectEqual(@as(usize, 4), function.blocks.items.len);

    const header = function.blockConst(@enumFromInt(1));
    try std.testing.expect(header.terminator == .branch);
    const body = function.blockConst(@enumFromInt(2));
    try std.testing.expect(body.terminator == .return_value);
    const exit = function.blockConst(@enumFromInt(3));
    try std.testing.expect(exit.terminator == .return_value);
}

test "lowerModule lowers an accumulator пока loop with assignment, back-edge present" {
    const allocator = std.testing.allocator;
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const type_checker_mod = @import("type_checker.zig");
    const source_text =
        \\функ сумма_до(предел: Число) -> Число
        \\    пер итог: Число = 0.0
        \\    пер i: Число = 1.0
        \\    пока i < предел цикл
        \\        итог = итог + i
        \\        i = i + 1.0
        \\    конец
        \\    итог
        \\конец
    ;
    var lexed = try lexer.tokenize(allocator, source_text, 0);
    defer lexed.deinit();
    var parsed = try parser.parse(allocator, lexed.tokens.items);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.items.len);
    var resolved = try resolver.resolve(allocator, &parsed.ast);
    defer resolved.deinit();
    var checked = try type_checker_mod.check(allocator, &parsed.ast, &resolved);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.items.items.len);

    var module = try lowerModule(allocator, &parsed.ast, &resolved, &checked);
    defer module.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), module.functions.items.len);
    const function = &module.functions.items[0];
    // entry (jump to header) + header (condition) + body (falls off the end,
    // must jump BACK to header) + exit (falls through to trailing `итог`).
    try std.testing.expectEqual(@as(usize, 4), function.blocks.items.len);

    const body = function.blockConst(@enumFromInt(2));
    try std.testing.expect(body.terminator == .jump);
    try std.testing.expectEqual(@as(mir.BlockId, @enumFromInt(1)), body.terminator.jump.target);
}
