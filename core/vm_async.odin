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

Async_Result :: struct {
	ticket_id: int,
	// id процесса-получателя, НЕ указатель — процесс мог завершиться/быть
	// убит, пока I/O было в полёте (см. deliver_async_result — тот же
	// silent-drop-на-мёртвый-процесс паттерн, что у отправить()).
	target_id: int,
	payload:   union {
		Http_Result_Data,
	},
}
