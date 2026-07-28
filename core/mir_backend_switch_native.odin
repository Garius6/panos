#+build !js
package core

import "core:os"

// use_mir_backend — dev-only переключатель: PANOS_MIR_BACKEND=1 велит
// run_file (main.odin)/wasm_run (никогда — см. mir_backend_switch_wasm.
// odin) собирать программу через lower_program_graph/lower_module_to_
// bytecode вместо ensure_prelude_compiled+compile_program. НЕ стабильный
// CLI-флаг (план Стадии 2.5) — просто env var, читается заново на каждый
// вызов (дешёво: один раз на запуск программы, не в горячем пути).
// Default (флаг не выставлен) — старый путь, без изменений.
use_mir_backend :: proc() -> bool {
	value := os.get_env_alloc("PANOS_MIR_BACKEND", context.temp_allocator)
	return value == "1"
}
