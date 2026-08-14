const std = @import("std");

pub const ast = @import("ast.zig");
pub const bundle = @import("bundle.zig");
pub const bytecode = @import("bytecode.zig");
pub const compiler = @import("compiler.zig");
pub const diagnostic = @import("diagnostic.zig");
pub const gc = @import("gc.zig");
pub const lexer = @import("lexer.zig");
pub const lsp = @import("lsp.zig");
pub const lsp_graph = @import("lsp_graph.zig");
pub const mir = @import("mir.zig");
pub const mir_builder = @import("mir_builder.zig");
pub const mir_cfg = @import("mir_cfg.zig");
pub const mir_lowering = @import("mir_lowering.zig");
pub const mir_cps = @import("mir_cps.zig");
pub const mir_validate = @import("mir_validate.zig");
pub const wasm_stackify = @import("wasm_stackify.zig");
pub const wasm_module = @import("wasm_module.zig");
pub const wasm_emit = @import("wasm_emit.zig");
pub const wasm_actors = @import("wasm_actors.zig");
pub const wasm_objects = @import("wasm_objects.zig");
pub const wasm_strings = @import("wasm_strings.zig");
pub const wasm_interfaces = @import("wasm_interfaces.zig");
pub const wasm_heap = @import("wasm_heap.zig");
pub const module_loader = @import("module_loader.zig");
pub const module_linker = @import("module_linker.zig");
pub const module_compiler = @import("module_compiler.zig");
pub const parser = @import("parser.zig");
pub const prelude = @import("prelude.zig");
pub const resolver = @import("resolver.zig");
pub const runner = @import("runner.zig");
pub const semantic_tokens = @import("semantic_tokens.zig");
pub const source = @import("source.zig");
pub const symbols = @import("symbols.zig");
pub const target = @import("target.zig");
pub const token = @import("token.zig");
pub const type_checker = @import("type_checker.zig");
pub const types = @import("types.zig");
pub const value = @import("value.zig");
pub const vm = @import("vm.zig");

pub const migration_stage = "phase-0";

pub fn version() []const u8 {
    return "0.0.0-dev";
}

test "migration core reports its initial stage" {
    try std.testing.expectEqualStrings("phase-0", migration_stage);
}
