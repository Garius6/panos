# Установка

## Готовые бинарники

Каждый [релиз](https://github.com/Garius6/panos/releases) собирает два
бинарника — `panos` (CLI-интерпретатор) и `panos-lsp` (LSP-сервер) — под три
платформы:

| Платформа       | Архив/файл                    |
|-----------------|--------------------------------|
| Linux (amd64)   | `panos-linux-amd64`, `panos-lsp-linux-amd64` |
| macOS (arm64)   | `panos-macos-arm64`, `panos-lsp-macos-arm64` |
| Windows (amd64) | `panos-windows-amd64.exe`, `panos-lsp-windows-amd64.exe` |

Скачайте нужные файлы со страницы [последнего релиза](https://github.com/Garius6/panos/releases/latest),
переименуйте (или оставьте как есть) и положите куда-нибудь в `PATH`. На
macOS/Linux не забудьте выставить бит исполнения:

```sh
chmod +x panos-macos-arm64
mv panos-macos-arm64 /usr/local/bin/panos
```

> Готовых сборок под Intel-Mac (`macos-13`) и arm64-Linux пока нет — только
> собрать из исходников (ниже).

## Сборка из исходников

Нужен установленный [Odin](https://odin-lang.org/docs/install/) — тот же
тулчейн, что использует CI (`dev-2026-06`, см.
`.github/workflows/*.yml`; более новые dev-сборки Odin, скорее всего, тоже
подойдут, но не гарантировано — API `core:` иногда меняется между
dev-релизами).

```sh
git clone https://github.com/Garius6/panos.git
cd panos

# CLI-интерпретатор
odin build . -out:panos
# или, если установлен just (https://github.com/casey/just):
just build

# LSP-сервер
odin build ./lsp -out:panos-lsp
just build-lsp

# WASM-сборка для браузера (демо в demo/)
odin build wasm -target:js_wasm32 -o:size -out:demo/panos.wasm
just build-wasm
```

`just build-all` собирает все три сразу. Полный список команд — в
`Justfile` в корне репозитория.

## Проверка

```sh
echo 'функ старт() -> Число
    10 + 20
конец' > hello.ps
./panos hello.ps
```

Должно напечатать `30`.
