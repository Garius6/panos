package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

main :: proc() {
	// Отладочный хук: PANOS_LSP_DEBUG_WAIT=N (секунды) — пауза перед
	// стартом read-loop, чтобы успеть attach'нуть дебаггер к уже
	// запущенному editor'ом процессу (stdio-транспорт, см.
	// lsp_transport.odin — launch "напрямую под дебаггером" бесполезен
	// для интерактивной сессии, у свежего процесса будет отдельный,
	// не подключенный к editor'у stdio). Без переменной — no-op, обычный
	// старт без задержки.
	if delay_str, ok := os.lookup_env("PANOS_LSP_DEBUG_WAIT", context.allocator); ok {
		delay, parsed := strconv.parse_int(delay_str)
		if parsed {
			fmt.eprintfln("panos-lsp: ждём %d сек. для attach отладчика (PID %d)...", delay, os.get_pid())
			time.sleep(time.Duration(delay) * time.Second)
		}
	}
	run_lsp_server()
}
