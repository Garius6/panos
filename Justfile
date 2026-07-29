set shell := ["/bin/bash", "-c"]
set positional-arguments
debug-file file:
	odin run . -debug -vet -strict-style -vet-tabs  -warnings-as-errors -- $1

build:
	odin build . -out:panos

build-lsp:
	odin build ./lsp -out:panos-lsp

# DWARF-символы + без оптимизаций — для lldb-dap (см. nvim DAP-конфиг).
# Не заменяет build-lsp: релизная сборка не должна тащить -debug/-o:none.
build-lsp-debug:
	odin build ./lsp -out:panos-lsp -debug -o:none

# -o:size обязателен: дефолтный -o:minimal даёт модуль, на котором падает
# JIT-компилятор Safari/WebKit (см. wasm/main.odin).
build-wasm:
	odin build wasm -target:js_wasm32 -o:size -out:demo/panos.wasm

build-all: build build-lsp build-wasm

sync-lsp-protocol:
	curl -sL https://raw.githubusercontent.com/Garius6/odin-lsp-protocol/v0.1.1/generated/lsp_types.odin \
		| sed 's/^package lsp$/package lsp_protocol/' \
		> lsp/protocol/lsp_types.odin

# track-memory=false: компилятор (parser/resolver/type_cheker/compiler)
# нигде не освобождает свои AST/Type-графы — тем же образом, что и
# рантайм-бинарь panos, рассчитанный на однократный процесс, память
# которого забирает ОС при выходе. Без этого флага тест-раннер репортит
# КАЖДЫЙ такой alloc как "+++ leak" (не баг, не влияет на память
# реального бинаря) — только шум в выводе `just test`.
test:
	odin test ./core -define:ODIN_TEST_TRACK_MEMORY=false

# wasm_runtime/runtime.wasm — линкуемый рантайм для heap-значений
# AOT-скомпилированных программ (Фаза 1.5, см. wasm_runtime/runtime.odin) —
# отдельный маленький пакет, НЕ package core (не разделяет судьбу с
# core/gc.odin — см. план/память проекта, почему). -build-mode:obj +
# wasm-ld — тот же двухшаговый процесс, что верифицирован Шагом 0-спайком
# Фазы 1: релокуемый объект, слинкованный в самостоятельный модуль,
# экспортирующий свою память + функции для composition через
# `wasmtime run --preload` (см. core/wasm_backend_wasmtime_test.odin).
build-wasm-runtime:
	odin build wasm_runtime -target:wasi_wasm32 -build-mode:obj -out:wasm_runtime/runtime.o -no-entry-point
	wasm-ld wasm_runtime/runtime.o -o wasm_runtime/runtime.wasm --no-entry \
		--export=pw_scratch_set --export=pw_alloc_from_scratch --export=pw_string_len \
		--export=pw_concat_strings --export=pw_string_equal \
		--export=pw_alloc_aggregate --export=pw_set_field_f64 --export=pw_get_field_f64 \
		--export=pw_set_field_i32 --export=pw_get_field_i32 --export=pw_print_string \
		--export=pw_string_starts_with --export=pw_string_ends_with --export=pw_string_contains \
		--export=pw_int_to_string --export=pw_string_compare --export=pw_string_replace_all \
		--export=pw_monotonic_ms --export=pw_now_ms \
		--export=pw_build_variant --export=pw_match_tag \
		--export=pw_array_length --export=pw_array_in_bounds \
		--export=pw_array_get_f64 --export=pw_array_get_i32 \
		--export=pw_array_contains_f64 --export=pw_array_contains_i32 \
		--export=pw_array_slice \
		--export=pw_map_length --export=pw_map_has_strkey --export=pw_map_has_numkey \
		--export=pw_map_get_strkey_f64 --export=pw_map_get_strkey_i32 \
		--export=pw_map_get_numkey_f64 --export=pw_map_get_numkey_i32 \
		--export=pw_map_delete_strkey --export=pw_map_delete_numkey --allow-undefined

# Дифференциальные тесты WASM AOT-бэкенда (Фаза 1/1.5, core/wasm_backend_
# wasmtime_test.odin) — за #config(PANOS_WASM_BACKEND_TESTS), НЕ входят в
# обычный `just test`: требуют установленный `wasmtime`+`wasm-ld` в PATH
# (dev/test-only зависимость, см. специфику вендоринга в проекте — это НЕ
# то же самое, что зависимости самого бинаря panos).
test-wasm-backend: build-wasm-runtime
	odin test ./core -define:ODIN_TEST_TRACK_MEMORY=false -define:PANOS_WASM_BACKEND_TESTS=true

# Обновляет PANOS_VERSION (core/vm.odin), собирает+тестирует, коммитит
# "chore: версия X.Y.Z", тегирует vX.Y.Z, пушит main и тег — тот же
# ручной semver, что описан в комментарии у PANOS_VERSION. Версию
# передавать БЕЗ "v": just bump-and-push 0.2.9
# odin test ./core падает ненулевым кодом на провале — just останавливает
# рецепт на первой упавшей строке, коммит/тег/push не происходят.
bump-and-push version:
	sed -i '' 's/PANOS_VERSION :: "[^"]*"/PANOS_VERSION :: "{{version}}"/' core/vm.odin
	odin build . -out:panos
	odin test ./core
	git add core/vm.odin
	git commit -m "chore: версия {{version}}"
	git tag v{{version}}
	git push origin main
	git push origin v{{version}}
