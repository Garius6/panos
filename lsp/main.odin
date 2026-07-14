package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

main :: proc() {
	// Отладочный хук: PANOS_LSP_DEBUG_WAIT=N (секунды) — пауза перед
	// стартом read-loop, чтобы успеть attach'нуть дебаггер к процессу,
	// запущенному editor'ом (stdio-транспорт — запустить процесс напрямую
	// под дебаггером нельзя, его stdio не подключён к editor'у).
	if delay_str, ok := os.lookup_env("PANOS_LSP_DEBUG_WAIT", context.allocator); ok {
		delay, parsed := strconv.parse_int(delay_str)
		if parsed {
			fmt.eprintfln("panos-lsp: ждём %d сек. для attach отладчика (PID %d)...", delay, os.get_pid())
			time.sleep(time.Duration(delay) * time.Second)
		}
	}
	run_lsp_server()
}
