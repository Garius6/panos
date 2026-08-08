set shell := ["/bin/bash", "-c"]
set positional-arguments
debug-file file:
	odin run . -debug -vet -strict-style -vet-tabs  -warnings-as-errors -- $1

# T057 (specs/010-zig-migration): `build`/`build-lsp`/`build-wasm` now build
# the ZIG toolchain (`build.zig` at repo root), not Odin — this is the
# documented release/Pages path from here on (`.github/workflows/release-
# binaries.yml`/`deploy-pages.yml` both switched the same way). Each copies
# its `zig-out/bin/...` artifact to the SAME path the Odin recipes used to
# produce (`./panos`, `./panos-lsp`, `demo/panos.wasm`) — every existing
# consumer (editor LSP configs pointed at repo-root `./panos-lsp`, this
# Justfile's own `build-all`, deploy-pages' `cp -r demo/.`) keeps working
# unchanged. The Odin recipes are NOT deleted — Odin remains buildable
# on-demand for reference/comparison work (see `specs/010-zig-migration/
# tasks.md` T053's conformance-matrix use of a freshly built Odin binary),
# just renamed `*-odin` and no longer the default/release path.
build:
	zig build -Doptimize=ReleaseFast
	cp zig-out/bin/panos panos

build-lsp:
	zig build lsp
	cp zig-out/bin/panos-lsp panos-lsp

build-wasm:
	zig build browser
	mkdir -p demo
	cp zig-out/bin/panos-browser.wasm demo/panos.wasm

build-all: build build-lsp build-wasm

build-odin:
	odin build . -out:panos

build-lsp-odin:
	odin build ./lsp -out:panos-lsp

# DWARF-символы + без оптимизаций — для lldb-dap (см. nvim DAP-конфиг).
# Не заменяет build-lsp-odin: релизная сборка не должна тащить -debug/-o:none.
build-lsp-debug:
	odin build ./lsp -out:panos-lsp -debug -o:none

# -o:size обязателен: дефолтный -o:minimal даёт модуль, на котором падает
# JIT-компилятор Safari/WebKit (см. wasm/main.odin).
build-wasm-odin:
	odin build wasm -target:js_wasm32 -o:size -out:demo/panos.wasm

build-all-odin: build-odin build-lsp-odin build-wasm-odin

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
		--export=pw_map_delete_strkey --export=pw_map_delete_numkey \
		--export=pw_array_push_f64 --export=pw_array_push_i32 \
		--export=pw_map_set_strkey_f64 --export=pw_map_set_strkey_i32 \
		--export=pw_map_set_numkey_f64 --export=pw_map_set_numkey_i32 \
		--export=pw_string_length_runes --export=pw_string_slice_rune \
		--export=pw_string_find_rune --export=pw_string_byte_at \
		--export=pw_string_slice_byte --export=pw_string_from_bytes \
		--export=pw_string_to_bytes --export=pw_string_codepoint_at_start \
		--export=pw_string_to_runes --export=pw_string_from_runes \
		--export=pw_string_char_at \
		--export=pw_string_is_digit --export=pw_string_is_alpha \
		--export=pw_string_is_digit_or_alpha \
		--export=pw_string_to_upper --export=pw_string_to_lower \
		--export=pw_number_to_string --export=pw_string_to_number \
		--export=pw_string_trim --export=pw_string_split --export=pw_string_join \
		--export=pw_map_entries --export=pw_println_string --export=pw_url_encode \
		--export=pw_string_ptr --allow-undefined

# js_wasm32-вариант того же wasm_runtime, для DOM-загрузчика (docs/src/
# assets/aot-dom-loader.js) — В ОТЛИЧИЕ от wasi_wasm32 выше, ОДНА команда:
# js_wasm32 не нуждается в отдельном wasm-ld-шаге, Odin сам делает полное
# слинкованное .wasm — @(export) сам по себе достаточен (подтверждено
# спайком: все pw_*-экспорты видны в instance.exports без единого
# --export-флага). runtime_js.odin (#+build js) — реализация ввод_вывод::
# печать/строка и время::*, отличная от wasi-варианта (runtime_wasi.odin).
build-wasm-runtime-js:
	odin build wasm_runtime -target:js_wasm32 -out:wasm_runtime/runtime_js.wasm -no-entry-point

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
# T057: гейт теперь `zig build`/`zig build test` (Zig — релизный тулчейн),
# а не `odin build`/`odin test ./core`. Версия хранится в ДВУХ местах, пока
# обе реализации сосуществуют (см. `zig/core/vm.zig`'s `osVersion` doc
# comment — "there is no single source of truth shared between the two
# implementations during the migration") — оба обновляются одним рецептом,
# чтобы не разъезжались.
# zig build test падает ненулевым кодом на провале — just останавливает
# рецепт на первой упавшей строке, коммит/тег/push не происходят.
bump-and-push version:
	sed -i '' 's/PANOS_VERSION :: "[^"]*"/PANOS_VERSION :: "{{version}}"/' core/vm.odin
	sed -i '' 's/createString(try self.allocator.dupe(u8, "[^"]*"))/createString(try self.allocator.dupe(u8, "{{version}}"))/' zig/core/vm.zig
	zig build
	zig build test
	git add core/vm.odin zig/core/vm.zig
	git commit -m "chore: версия {{version}}"
	git tag v{{version}}
	git push origin main
	git push origin v{{version}}
