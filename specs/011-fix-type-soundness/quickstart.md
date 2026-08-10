# Quickstart: Validate Sound Type Checking

## Focused development loop

1. Add the focused type checker, compiler, VM, runner, and module tests named by the implementation task.
2. Run the narrow tests while iterating:

   ```sh
   zig test zig/core/type_checker.zig
   zig test zig/core/compiler.zig
   zig test zig/core/vm.zig
   ```

3. Verify these e2e scenarios:

   - incompatible function signatures fail before execution;
   - string-index assignment fails before execution, array/map assignment succeeds;
   - `T: A + B` calls methods from both bounds;
   - `T: Сравниваемое + A` compares and calls `A`;
   - reversed named concrete-method arguments work locally and across an import;
   - unsupported named enum/interface calls are Type Errors.

## Required regression checks

```sh
zig build test
zig build conformance
zig build lsp
zig build browser
```

Run relevant AOT coverage as well, especially named struct construction:

```sh
zig build aot
```
