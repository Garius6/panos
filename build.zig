const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_module = b.addModule("panos_core", .{
        .root_source_file = b.path("zig/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const panos = b.addExecutable(.{
        .name = "panos",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    b.installArtifact(panos);

    const run_step = b.step("run", "Run the native Panos CLI");
    const run_command = b.addRunArtifact(panos);
    run_command.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_command.addArgs(args);
    run_step.dependOn(&run_command.step);

    const lsp = b.addExecutable(.{
        .name = "panos-lsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/lsp/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    const install_lsp = b.addInstallArtifact(lsp, .{});
    const lsp_step = b.step("lsp", "Build the Panos LSP server");
    lsp_step.dependOn(&install_lsp.step);

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const browser = b.addExecutable(.{
        .name = "panos-browser",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/browser/main.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    browser.entry = .disabled;
    browser.rdynamic = true;
    browser.export_memory = true;
    const install_browser = b.addInstallArtifact(browser, .{});
    const browser_step = b.step("browser", "Build the browser interpreter WASM scaffold");
    browser_step.dependOn(&install_browser.step);

    const wasi_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });
    const runtime_js = addWasmRuntime(b, "panos-aot-runtime-js", "zig/wasm_runtime/runtime_js.zig", wasm_target);
    const runtime_wasi = addWasmRuntime(b, "panos-aot-runtime-wasi", "zig/wasm_runtime/runtime_wasi.zig", wasi_target);

    const runtime_js_step = b.step("aot-runtime-js", "Build the JS AOT runtime scaffold");
    runtime_js_step.dependOn(&b.addInstallArtifact(runtime_js, .{}).step);
    const runtime_wasi_step = b.step("aot-runtime-wasi", "Build the WASI AOT runtime scaffold");
    runtime_wasi_step.dependOn(&b.addInstallArtifact(runtime_wasi, .{}).step);

    const core_tests = b.addTest(.{ .root_module = core_module });
    const frontend_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/parser.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const target_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/target.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const symbols_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/symbols.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const types_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/types.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const resolver_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/resolver.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const type_checker_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/type_checker.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const bytecode_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/bytecode.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const compiler_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/compiler.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const value_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/value.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const vm_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/vm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const cli_tests = b.addTest(.{ .root_module = panos.root_module });
    const lsp_tests = b.addTest(.{ .root_module = lsp.root_module });
    const browser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/browser/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    const conformance_module = b.addModule("panos_conformance", .{
        .root_source_file = b.path("zig/conformance/manifest.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "panos_core", .module = core_module }},
    });
    const manifest_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/conformance/manifest_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "panos_conformance", .module = conformance_module }},
        }),
    });
    const reference_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/conformance/reference.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const outcome_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/conformance/outcome.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    const lexer_conformance_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/conformance/lexer_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    const parser_conformance_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/conformance/parser_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    const demo_parser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_ps_parser_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });

    const run_core_tests = b.addRunArtifact(core_tests);
    const run_frontend_unit_tests = b.addRunArtifact(frontend_unit_tests);
    const run_target_unit_tests = b.addRunArtifact(target_unit_tests);
    const run_symbols_unit_tests = b.addRunArtifact(symbols_unit_tests);
    const run_types_unit_tests = b.addRunArtifact(types_unit_tests);
    const run_resolver_unit_tests = b.addRunArtifact(resolver_unit_tests);
    const run_type_checker_unit_tests = b.addRunArtifact(type_checker_unit_tests);
    const run_bytecode_unit_tests = b.addRunArtifact(bytecode_unit_tests);
    const run_compiler_unit_tests = b.addRunArtifact(compiler_unit_tests);
    const run_value_unit_tests = b.addRunArtifact(value_unit_tests);
    const run_vm_unit_tests = b.addRunArtifact(vm_unit_tests);
    const run_cli_tests = b.addRunArtifact(cli_tests);
    const run_lsp_tests = b.addRunArtifact(lsp_tests);
    const run_browser_tests = b.addRunArtifact(browser_tests);
    const run_manifest_tests = b.addRunArtifact(manifest_tests);
    const run_reference_tests = b.addRunArtifact(reference_tests);
    const run_outcome_tests = b.addRunArtifact(outcome_tests);
    const run_lexer_conformance_tests = b.addRunArtifact(lexer_conformance_tests);
    const run_parser_conformance_tests = b.addRunArtifact(parser_conformance_tests);
    const run_demo_parser_tests = b.addRunArtifact(demo_parser_tests);
    const test_step = b.step("test", "Run Zig unit tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_frontend_unit_tests.step);
    test_step.dependOn(&run_target_unit_tests.step);
    test_step.dependOn(&run_symbols_unit_tests.step);
    test_step.dependOn(&run_types_unit_tests.step);
    test_step.dependOn(&run_resolver_unit_tests.step);
    test_step.dependOn(&run_type_checker_unit_tests.step);
    test_step.dependOn(&run_bytecode_unit_tests.step);
    test_step.dependOn(&run_compiler_unit_tests.step);
    test_step.dependOn(&run_value_unit_tests.step);
    test_step.dependOn(&run_vm_unit_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_lsp_tests.step);
    test_step.dependOn(&run_browser_tests.step);
    test_step.dependOn(&run_manifest_tests.step);
    test_step.dependOn(&run_reference_tests.step);
    test_step.dependOn(&run_outcome_tests.step);
    test_step.dependOn(&run_lexer_conformance_tests.step);
    test_step.dependOn(&run_parser_conformance_tests.step);
    test_step.dependOn(&run_demo_parser_tests.step);

    const conformance_step = b.step("conformance", "Validate the local conformance manifest");
    conformance_step.dependOn(&run_manifest_tests.step);
    conformance_step.dependOn(&run_lexer_conformance_tests.step);
    conformance_step.dependOn(&run_parser_conformance_tests.step);
    conformance_step.dependOn(&run_demo_parser_tests.step);
}

fn addWasmRuntime(
    b: *std.Build,
    name: []const u8,
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
) *std.Build.Step.Compile {
    const runtime = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_source_file),
            .target = target,
            .optimize = .ReleaseSmall,
        }),
    });
    runtime.entry = .disabled;
    return runtime;
}
