package main

import "base:runtime"
import core "../core"
import "core:fmt"

// Спайк-демо: JS пишет исходник panos-скрипта в этот статический буфер
// (через WasmMemoryInterface.storeString на адрес из panos_source_ptr()),
// затем зовёт panos_run(len). Простое, но достаточное решение для v1 —
// без динамической аллокации со стороны JS (никакой malloc-обвязки).
SOURCE_BUF_SIZE :: 65536
@(private)
source_buf: [SOURCE_BUF_SIZE]byte

@(export)
panos_source_ptr :: proc "c" () -> ^byte {
	return &source_buf[0]
}

@(export)
panos_source_capacity :: proc "c" () -> int {
	return SOURCE_BUF_SIZE
}

// Запускает panos-скрипт длиной source_len байт из source_buf. Вывод идёт
// через fmt.print*/fmt.eprint* — на js_wasm32 core:fmt сам пишет в
// odin_env.write (см. fmt_js.odin в тулчейне Odin), рантайм-обвязка
// odin.js рендерит это в consoleElement страницы — без единой строчки
// собственного JS-парсинга WASM-памяти под каждый print.
@(export)
panos_run :: proc "c" (source_len: int) {
	context = runtime.default_context()

	// odin.js's writeToConsole копит вывод в закрытый (не доступный извне)
	// массив infoConsoleLines и перерисовывает ВЕСЬ #console из него на
	// каждый print — JS-сторона не может ни очистить, ни узнать про это
	// состояние снаружи (не exposed на window.odin). Раз "очистить между
	// запусками" architecturally недоступно, разделитель печатаем прямо
	// отсюда — то же самое API, тот же поток, без гонки с внутренним
	// состоянием рантайма.
	fmt.println("── запуск ──")

	if source_len < 0 || source_len > SOURCE_BUF_SIZE {
		fmt.eprintln("Ошибка спайка: исходник длиннее буфера демо")
		return
	}
	source := string(source_buf[:source_len])

	result, has_result, diags := core.run_source(source)
	if len(diags) > 0 {
		for d in diags {
			fmt.eprintln(d.message)
		}
		return
	}
	if has_result {
		// ^Panos_String печатается как Odin-структура через голый %v (см.
		// print_vm в vm.odin — тот же unwrap там, для той же причины) —
		// достаём .data явно, иначе результат-строка попадает на страницу
		// как "&Panos_String{header = ..., data = \"текст\"}".
		if ps, ok := result.(^core.Panos_String); ok {
			fmt.println(ps.data)
		} else {
			fmt.println(result)
		}
	}
}

main :: proc() {}
