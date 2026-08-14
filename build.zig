const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_module = b.addModule("panos_core", .{
        .root_source_file = b.path("zig/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // `бд.*` (`zig/core/sqlite3_bindings.zig`, referenced from `vm.zig`)
    // needs `external/sqlite3/sqlite3.c` linked in — built into its own
    // small static library rather than added directly to `core_module`,
    // because `core_module` is ALSO imported by the `wasm32-freestanding`
    // `browser` executable below, which can't compile/link a real C
    // amalgamation (no libc there) — this library, and `.link_libc =
    // true`/`.linkLibrary(sqlite_lib)`, are only ever attached to
    // NATIVE-target `Compile` steps that actually exercise `vm.zig`.
    const sqlite_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sqlite_module.addCSourceFile(.{ .file = b.path("external/sqlite3/sqlite3.c"), .flags = &.{} });
    const sqlite_lib = b.addLibrary(.{ .name = "sqlite3", .root_module = sqlite_module });

    // `внешний` (`zig/core/ffi_bindings.zig`, referenced from `vm.zig`) —
    // unlike sqlite3, libffi ships here as a PREBUILT per-platform static
    // archive (no source to compile), so it's added directly to each
    // consuming module via `addObjectFile` rather than wrapped in its own
    // `addLibrary` step. Same native-only-target restriction as sqlite —
    // never attached to `core_module`/`browser`.
    const libffi_archive = libffiArchivePath(b, target);

    const panos = b.addExecutable(.{
        .name = "panos",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    panos.root_module.linkLibrary(sqlite_lib);
    panos.root_module.addObjectFile(libffi_archive);
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
            .link_libc = true,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    lsp.root_module.linkLibrary(sqlite_lib);
    lsp.root_module.addObjectFile(libffi_archive);
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
    const install_runtime_js = b.addInstallArtifact(runtime_js, .{});
    const install_runtime_wasi = b.addInstallArtifact(runtime_wasi, .{});

    const runtime_js_step = b.step("aot-runtime-js", "Build the JS AOT runtime scaffold");
    runtime_js_step.dependOn(&install_runtime_js.step);
    const runtime_wasi_step = b.step("aot-runtime-wasi", "Build the WASI AOT runtime scaffold");
    runtime_wasi_step.dependOn(&install_runtime_wasi.step);

    // A SEPARATE module from `core_module` (same source, same target) —
    // `core_module` is shared with the wasm32-freestanding `browser`
    // executable above and must not gain `.link_libc`/`сsqlite`; this one
    // exists only so `core_tests` (which needs both, to exercise `бд.*`)
    // doesn't mutate the shared module.
    const core_test_module = b.createModule(.{
        .root_source_file = b.path("zig/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const core_tests = b.addTest(.{ .root_module = core_test_module });
    core_tests.root_module.linkLibrary(sqlite_lib);
    core_tests.root_module.addObjectFile(libffi_archive);
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
    const mir_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/mir.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const mir_builder_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/mir_builder.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const mir_cfg_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/mir_cfg.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const mir_lowering_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/mir_lowering.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const mir_validate_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/mir_validate.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const semantic_tokens_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/semantic_tokens.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const wasm_stackify_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/wasm_stackify.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const wasm_module_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/wasm_module.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const wasm_emit_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/wasm_emit.zig"),
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
            .link_libc = true,
        }),
    });
    vm_unit_tests.root_module.linkLibrary(sqlite_lib);
    vm_unit_tests.root_module.addObjectFile(libffi_archive);
    const module_loader_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/module_loader.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const module_linker_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/module_linker.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const module_compiler_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/module_compiler.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    module_compiler_unit_tests.root_module.linkLibrary(sqlite_lib);
    module_compiler_unit_tests.root_module.addObjectFile(libffi_archive);
    const lsp_graph_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/lsp_graph.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lsp_graph_unit_tests.root_module.linkLibrary(sqlite_lib);
    lsp_graph_unit_tests.root_module.addObjectFile(libffi_archive);
    const runner_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/core/runner.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    runner_unit_tests.root_module.linkLibrary(sqlite_lib);
    runner_unit_tests.root_module.addObjectFile(libffi_archive);
    const cli_tests = b.addTest(.{ .root_module = panos.root_module });
    const lsp_tests = b.addTest(.{ .root_module = lsp.root_module });
    const browser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/browser/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    browser_tests.root_module.linkLibrary(sqlite_lib);
    browser_tests.root_module.addObjectFile(libffi_archive);
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
    const outcome_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/conformance/outcome.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    // Split by manifest `tier` into 4 SEPARATE build artifacts (was one
    // `matrix_test.zig` looping over the whole manifest sequentially in a
    // single `test` block) — Zig's build graph only parallelizes across
    // separate `addTest`/`Run` steps, never across `test` declarations
    // inside one binary, so this is what actually lets `semantic`/
    // `runtime`/`native` run concurrently. See `zig/conformance/
    // matrix_runner.zig`'s module doc comment for the full rationale
    // (also: why `runtime`, which embeds the slow benchmark fixtures, is
    // no longer anywhere near `zig build test`).
    // All four link libc/sqlite/libffi, even though only the `native` tier
    // actually EXERCISES those code paths at runtime — they all import the
    // same `panos_core` module, which pulls in `vm.zig`'s FFI/SQLite
    // bindings unconditionally at compile time (same reason
    // `runner_unit_tests`/`vm_unit_tests` below need the same linking).
    const matrix_semantic_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/conformance/matrix_semantic_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    matrix_semantic_tests.root_module.linkLibrary(sqlite_lib);
    matrix_semantic_tests.root_module.addObjectFile(libffi_archive);
    const matrix_runtime_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/conformance/matrix_runtime_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    matrix_runtime_tests.root_module.linkLibrary(sqlite_lib);
    matrix_runtime_tests.root_module.addObjectFile(libffi_archive);
    const matrix_native_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/conformance/matrix_native_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    matrix_native_tests.root_module.linkLibrary(sqlite_lib);
    matrix_native_tests.root_module.addObjectFile(libffi_archive);
    // Multi-file cases (`импорт`) — `runTier`/`computeOutcome` reject any
    // `импорт` outright (see `runner.zig`'s `reportUnsupportedImports`),
    // so every genuinely multi-file fixture needs this SEPARATE tier
    // (`computeOutcomeGraph`, real `module_loader.Graph` + `module_compiler.
    // compileGraph`) instead — see `matrix_runner.zig`'s doc comment there.
    const matrix_graph_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/conformance/matrix_graph_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    matrix_graph_tests.root_module.linkLibrary(sqlite_lib);
    matrix_graph_tests.root_module.addObjectFile(libffi_archive);
    const matrix_aot_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/conformance/matrix_aot_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    matrix_aot_tests.root_module.linkLibrary(sqlite_lib);
    matrix_aot_tests.root_module.addObjectFile(libffi_archive);
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
    const modules_conformance_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/conformance/modules_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    modules_conformance_tests.root_module.linkLibrary(sqlite_lib);
    modules_conformance_tests.root_module.addObjectFile(libffi_archive);
    // Every ```panos block in docs/src/**/*.md, run through the same
    // `runner.runSource` path `panos run` uses — see the test file's own
    // doc comment for why this exists (a whole class of bug this session
    // only ever surfaced via a manual, one-off sweep).
    const docs_examples_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/conformance/docs_examples_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    docs_examples_tests.root_module.linkLibrary(sqlite_lib);
    docs_examples_tests.root_module.addObjectFile(libffi_archive);
    const demo_parser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_ps_parser_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    // Native-resource fixtures (`tests/integration/native/*.ps`) exercise
    // `бд.*`/`внешний` — needs the same sqlite/libffi linking as
    // `core_tests` above, on a module SEPARATE from the shared
    // `core_module` for the same reason (must not gain `.link_libc` on the
    // module the wasm32-freestanding `browser` executable also imports).
    const native_integration_test_module = b.createModule(.{
        .root_source_file = b.path("tests/integration/native_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "panos_core", .module = core_module }},
    });
    const native_integration_tests = b.addTest(.{ .root_module = native_integration_test_module });
    native_integration_tests.root_module.linkLibrary(sqlite_lib);
    native_integration_tests.root_module.addObjectFile(libffi_archive);

    const run_core_tests = b.addRunArtifact(core_tests);
    const run_frontend_unit_tests = b.addRunArtifact(frontend_unit_tests);
    const run_target_unit_tests = b.addRunArtifact(target_unit_tests);
    const run_symbols_unit_tests = b.addRunArtifact(symbols_unit_tests);
    const run_mir_unit_tests = b.addRunArtifact(mir_unit_tests);
    const run_mir_builder_unit_tests = b.addRunArtifact(mir_builder_unit_tests);
    const run_mir_cfg_unit_tests = b.addRunArtifact(mir_cfg_unit_tests);
    const run_mir_lowering_unit_tests = b.addRunArtifact(mir_lowering_unit_tests);
    const run_mir_validate_unit_tests = b.addRunArtifact(mir_validate_unit_tests);
    const run_semantic_tokens_unit_tests = b.addRunArtifact(semantic_tokens_unit_tests);
    const run_wasm_stackify_unit_tests = b.addRunArtifact(wasm_stackify_unit_tests);
    const run_wasm_module_unit_tests = b.addRunArtifact(wasm_module_unit_tests);
    const run_wasm_emit_unit_tests = b.addRunArtifact(wasm_emit_unit_tests);
    const run_types_unit_tests = b.addRunArtifact(types_unit_tests);
    const run_resolver_unit_tests = b.addRunArtifact(resolver_unit_tests);
    const run_type_checker_unit_tests = b.addRunArtifact(type_checker_unit_tests);
    const run_bytecode_unit_tests = b.addRunArtifact(bytecode_unit_tests);
    const run_compiler_unit_tests = b.addRunArtifact(compiler_unit_tests);
    const run_value_unit_tests = b.addRunArtifact(value_unit_tests);
    const run_vm_unit_tests = b.addRunArtifact(vm_unit_tests);
    const run_module_loader_unit_tests = b.addRunArtifact(module_loader_unit_tests);
    const run_module_linker_unit_tests = b.addRunArtifact(module_linker_unit_tests);
    const run_module_compiler_unit_tests = b.addRunArtifact(module_compiler_unit_tests);
    const run_lsp_graph_unit_tests = b.addRunArtifact(lsp_graph_unit_tests);
    const run_runner_unit_tests = b.addRunArtifact(runner_unit_tests);
    const run_cli_tests = b.addRunArtifact(cli_tests);
    const run_lsp_tests = b.addRunArtifact(lsp_tests);
    const run_browser_tests = b.addRunArtifact(browser_tests);
    const run_manifest_tests = b.addRunArtifact(manifest_tests);
    const run_outcome_tests = b.addRunArtifact(outcome_tests);
    const run_matrix_semantic_tests = b.addRunArtifact(matrix_semantic_tests);
    const run_matrix_runtime_tests = b.addRunArtifact(matrix_runtime_tests);
    const run_matrix_native_tests = b.addRunArtifact(matrix_native_tests);
    const run_matrix_graph_tests = b.addRunArtifact(matrix_graph_tests);
    const run_matrix_aot_tests = b.addRunArtifact(matrix_aot_tests);
    const run_lexer_conformance_tests = b.addRunArtifact(lexer_conformance_tests);
    const run_parser_conformance_tests = b.addRunArtifact(parser_conformance_tests);
    const run_modules_conformance_tests = b.addRunArtifact(modules_conformance_tests);
    const run_demo_parser_tests = b.addRunArtifact(demo_parser_tests);
    const run_docs_examples_tests = b.addRunArtifact(docs_examples_tests);
    const run_native_integration_tests = b.addRunArtifact(native_integration_tests);
    const aot_runtime_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/wasm/aot_runtime_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_aot_runtime_tests = b.addRunArtifact(aot_runtime_tests);
    // The runtime `.wasm` files must exist in `zig-out/bin/` before this
    // test runs — it shells out to `wasmtime` against them, it doesn't
    // compile them itself.
    run_aot_runtime_tests.step.dependOn(&install_runtime_wasi.step);
    run_aot_runtime_tests.step.dependOn(&install_runtime_js.step);
    // Struct/array/variant and actor host-import elimination — these
    // build a real `.wasm` module in-process (lowering -> wasm_objects/
    // wasm_actors expansion -> wasm_emit) and run it under `wasmtime`,
    // unlike aot_runtime_tests above which only shells out against
    // ALREADY-built runtime `.wasm` files — no install-step dependency
    // needed.
    const aot_objects_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/wasm/aot_objects_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    const run_aot_objects_tests = b.addRunArtifact(aot_objects_tests);
    const aot_actors_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/wasm/aot_actors_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    const run_aot_actors_tests = b.addRunArtifact(aot_actors_tests);
    const aot_actors_multiarg_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/wasm/aot_actors_multiarg_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    const run_aot_actors_multiarg_tests = b.addRunArtifact(aot_actors_multiarg_tests);
    const aot_strings_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/wasm/aot_strings_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    const run_aot_strings_tests = b.addRunArtifact(aot_strings_tests);
    const aot_interfaces_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/wasm/aot_interfaces_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    const run_aot_interfaces_tests = b.addRunArtifact(aot_interfaces_tests);
    const aot_generic_bound_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/wasm/aot_generic_bound_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    const run_aot_generic_bound_tests = b.addRunArtifact(aot_generic_bound_tests);
    const aot_tree_shaking_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/wasm/aot_tree_shaking_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    const run_aot_tree_shaking_tests = b.addRunArtifact(aot_tree_shaking_tests);
    const aot_gc_arena_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/wasm/aot_gc_arena_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "panos_core", .module = core_module }},
        }),
    });
    const run_aot_gc_arena_tests = b.addRunArtifact(aot_gc_arena_tests);

    // `zig build test` — the everyday dev-loop step: pure per-file unit
    // tests only. Real gap found auditing this project's own test suite
    // (codex review, 2026-08-09): this step used to also depend on the
    // WHOLE conformance matrix (including the slow `runtime`-tier
    // benchmark fixtures — `фиб(30)` under a Debug bytecode VM didn't
    // finish in 20s), native SQLite/FFI/HTTP integration, AND the
    // WASM/wasmtime AOT suite — all bundled into ONE sequential step,
    // defeating Zig's own build-graph parallelism and making the
    // "just run the tests" loop minutes slower than it needed to be for
    // no benefit during normal development. Each of those now has its
    // own step below (`conformance`/`integration`/`aot`/`bench`) — run
    // them explicitly, or let CI run all of them.
    const test_step = b.step("test", "Run fast per-file unit tests only");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_frontend_unit_tests.step);
    test_step.dependOn(&run_target_unit_tests.step);
    test_step.dependOn(&run_symbols_unit_tests.step);
    test_step.dependOn(&run_mir_unit_tests.step);
    test_step.dependOn(&run_mir_builder_unit_tests.step);
    test_step.dependOn(&run_mir_cfg_unit_tests.step);
    test_step.dependOn(&run_mir_lowering_unit_tests.step);
    test_step.dependOn(&run_mir_validate_unit_tests.step);
    test_step.dependOn(&run_semantic_tokens_unit_tests.step);
    test_step.dependOn(&run_wasm_stackify_unit_tests.step);
    test_step.dependOn(&run_wasm_module_unit_tests.step);
    test_step.dependOn(&run_wasm_emit_unit_tests.step);
    test_step.dependOn(&run_types_unit_tests.step);
    test_step.dependOn(&run_resolver_unit_tests.step);
    test_step.dependOn(&run_type_checker_unit_tests.step);
    test_step.dependOn(&run_bytecode_unit_tests.step);
    test_step.dependOn(&run_compiler_unit_tests.step);
    test_step.dependOn(&run_value_unit_tests.step);
    test_step.dependOn(&run_vm_unit_tests.step);
    test_step.dependOn(&run_module_loader_unit_tests.step);
    test_step.dependOn(&run_module_linker_unit_tests.step);
    test_step.dependOn(&run_module_compiler_unit_tests.step);
    test_step.dependOn(&run_lsp_graph_unit_tests.step);
    test_step.dependOn(&run_runner_unit_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_lsp_tests.step);
    test_step.dependOn(&run_browser_tests.step);

    // `zig build conformance` — the language conformance surface: manifest
    // harness + semantic/native tiers of the matrix (fast — small fixed
    // fixtures, no benchmarks) + lexer/parser/modules conformance fixtures.
    // Deliberately EXCLUDES the `runtime` tier (benchmark fixtures — see
    // `bench` below) and the `aot`/native-integration tiers (see `aot`/
    // `integration` below) — each has a different cost profile and doesn't
    // belong in the same "did I break the language" everyday check.
    const conformance_step = b.step("conformance", "Validate language conformance (manifest + lexer/parser/modules fixtures + docs/src examples)");
    conformance_step.dependOn(&run_manifest_tests.step);
    conformance_step.dependOn(&run_outcome_tests.step);
    conformance_step.dependOn(&run_matrix_semantic_tests.step);
    conformance_step.dependOn(&run_matrix_native_tests.step);
    conformance_step.dependOn(&run_matrix_graph_tests.step);
    conformance_step.dependOn(&run_lexer_conformance_tests.step);
    conformance_step.dependOn(&run_parser_conformance_tests.step);
    conformance_step.dependOn(&run_modules_conformance_tests.step);
    conformance_step.dependOn(&run_demo_parser_tests.step);
    conformance_step.dependOn(&run_docs_examples_tests.step);

    // `zig build integration` — native-only resources (SQLite/FFI/HTTP),
    // exercising real files/sockets/dynamic libraries, not mocks.
    const integration_step = b.step("integration", "Run native integration tests (SQLite, FFI, HTTP)");
    integration_step.dependOn(&run_native_integration_tests.step);

    // `zig build aot` — MIR → WASM → `wasmtime` pipeline. Each case here
    // does a FULL separate compile (lex/parse/resolve/typecheck/lower/
    // emit) plus a real `wasmtime` subprocess spawn — heavier than the
    // bytecode-VM tiers above by a wide margin, and needs `wasmtime` on
    // PATH; kept out of `test`/`conformance` for exactly that reason.
    const aot_step = b.step("aot", "Run the WASM/wasmtime AOT test suite");
    aot_step.dependOn(&run_matrix_aot_tests.step);
    aot_step.dependOn(&run_aot_runtime_tests.step);
    aot_step.dependOn(&run_aot_objects_tests.step);
    aot_step.dependOn(&run_aot_actors_tests.step);
    aot_step.dependOn(&run_aot_actors_multiarg_tests.step);
    aot_step.dependOn(&run_aot_strings_tests.step);
    aot_step.dependOn(&run_aot_interfaces_tests.step);
    aot_step.dependOn(&run_aot_generic_bound_tests.step);
    aot_step.dependOn(&run_aot_tree_shaking_tests.step);
    aot_step.dependOn(&run_aot_gc_arena_tests.step);

    // `zig build bench` — the `runtime`-tier manifest cases, which embed
    // `tests/conformance/benchmarks/*.ps` (`фиб(30)` recursion, a
    // 5-million-iteration loop, 20k string concatenations — see
    // `tests/conformance/benchmarks.md`). Still asserts exact correctness
    // (not just timing), but is slow enough in Debug that it doesn't
    // belong in the everyday loop — run with `-Doptimize=ReleaseFast` for
    // a real performance read, matching `benchmarks.md`'s own documented
    // methodology.
    const bench_step = b.step("bench", "Run the benchmark-fixture correctness/perf suite (prefer -Doptimize=ReleaseFast)");
    bench_step.dependOn(&run_matrix_runtime_tests.step);

    // `zig build fuzz` — the crash-oracle fuzz tests (`lexer`/`parser`/
    // `runner`, see each file's own "never panics" tests) already run
    // their single-pass seed corpus as part of `zig build test` (cheap,
    // no slowdown) — this step exists so CONTINUOUS fuzzing targets just
    // these binaries: `zig build fuzz --fuzz` (libFuzzer-style coverage-
    // guided mutation, runs until interrupted), instead of pulling in the
    // rest of the unit-test suite too.
    const fuzz_step = b.step("fuzz", "Run (or, with --fuzz, continuously fuzz) the crash-oracle fuzz tests");
    fuzz_step.dependOn(&run_frontend_unit_tests.step);
    fuzz_step.dependOn(&run_runner_unit_tests.step);
}

fn libffiArchivePath(b: *std.Build, resolved_target: std.Build.ResolvedTarget) std.Build.LazyPath {
    const os_tag = resolved_target.result.os.tag;
    const arch = resolved_target.result.cpu.arch;
    if (os_tag == .macos and arch == .aarch64) return b.path("external/libffi/lib/darwin-arm64/libffi.a");
    if (os_tag == .linux and arch == .x86_64) return b.path("external/libffi/lib/linux-amd64/libffi.a");
    if (os_tag == .windows and arch == .x86_64) return b.path("external/libffi/lib/windows-amd64/libffi.lib");
    @panic("libffi: unsupported platform for vendored archive");
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
    // Without this, wasm-ld strips every `pub export fn` that nothing in
    // this same compilation unit calls — which is ALL of them here, since
    // the whole point of this module is to be called FROM the outside (a
    // separately emitted `panos build --target=wasm` module, or wasmtime/
    // the browser loader directly). Confirmed empirically: before this
    // flag, the built `.wasm` had a `memory` export and NOTHING else — see
    // `tests/wasm/aot_runtime_test.zig`.
    runtime.rdynamic = true;
    return runtime;
}
