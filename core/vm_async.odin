package core

// Неблокирующий I/O (см. специфицированный план): чистые данные, которыми
// фоновый воркер-поток обменивается с главным потоком VM через
// core:sync/chan. НИ ОДНО из полей здесь не Value/GC-managed указатель —
// воркер никогда не трогает vm.gc/Value напрямую (см. core/gc.odin —
// mark_roots/sweep/gc_new не имеют ни одной блокировки, предполагают
// эксклюзивный однопоточный доступ). Value строится из этих данных ТОЛЬКО
// на главном потоке, в момент дренирования (deliver_async_result, vm.odin).
Http_Result_Data :: struct {
	status:  int,
	headers: [dynamic][2]string,
	body:    string,
	err:     Maybe(string),
}

File_Read_Result_Data :: struct {
	content: string,
	err:     Maybe(string),
}

File_Write_Result_Data :: struct {
	bytes_written: int,
	err:           Maybe(string),
}

// Tcp_Connect_Result_Data — ЕДИНСТВЕННЫЙ payload-вариант, тип которого
// отличается по платформе (поле socket: net.TCP_Socket на native, rawptr-
// заглушка на wasm — сам импорт core:net падает под js_wasm32, см.
// file_value_wasm.odin) — объявлен в vm_async_io_native.odin/
// vm_async_io_wasm.odin (та же пара, что File_Value/Socket_Value), а не
// здесь, чтобы этот файл (без #+build) не тянул core:net ни для одной
// платформы. Ссылка на имя типа ниже разрешается тем определением, которое
// реально попало в сборку для текущей цели.
Async_Result :: struct {
	ticket_id: int,
	// id процесса-получателя, НЕ указатель — процесс мог завершиться/быть
	// убит, пока I/O было в полёте (см. deliver_async_result — тот же
	// silent-drop-на-мёртвый-процесс паттерн, что у отправить()).
	target_id: int,
	payload:   union {
		Http_Result_Data,
		File_Read_Result_Data,
		File_Write_Result_Data,
		Tcp_Connect_Result_Data,
	},
}
