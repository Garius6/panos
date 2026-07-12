# Panos LSP для Neovim

Минимальная интеграция: filetype-детект `.ps` → `panos` + запуск отдельного
LSP-бинарника `panos-lsp` через встроенный `vim.lsp` (Neovim 0.8+, без
зависимостей вроде `nvim-lspconfig`).

Panos собирается как 2 независимых бинарника из общего пакета `core`:
интерпретатор (`panos`) и LSP-сервер (`panos-lsp`).

## Установка

1. Соберите LSP-бинарник и положите его в PATH (или укажите полный путь в `cmd`):

   ```sh
   just build-lsp   # или: odin build ./lsp -out:panos-lsp
   ```

2. Добавьте `editors/nvim` в runtimepath и вызовите `setup()`.

   **lazy.nvim:**

   ```lua
   {
     dir = "/путь/до/panos/editors/nvim",
     name = "panos-lsp",
     ft = "panos",
     config = function()
       require("panos").setup()
       -- или с явным путём к бинарнику:
       -- require("panos").setup({ cmd = { "/путь/до/panos/panos-lsp" } })
     end,
   }
   ```

   **Голый init.lua:**

   ```lua
   vim.opt.runtimepath:append("/путь/до/panos/editors/nvim")
   require("panos").setup()
   ```

## Что работает (MVP)

- `textDocument/publishDiagnostics` — ошибки типизации подсвечиваются
  через стандартный `vim.diagnostic` (ничего дополнительно настраивать
  не надо, если diagnostics уже включены в вашем конфиге).
- `K` (`vim.lsp.buf.hover`) — тип выражения под курсором.
- `gd` (`vim.lsp.buf.definition`) — переход к объявлению (только внутри
  текущего файла — see "Известные ограничения").
- Полный `full-reparse` при каждом изменении (Neovim шлёт весь текст,
  сервер типизирует заново) — задержка на маленьких файлах незаметна,
  на больших может быть заметна (incremental — задел на будущее).

Стандартные keymaps (`K`, `gd`) обычно уже настроены, если у вас включён
`vim.lsp` в принципе (например через `nvim-lspconfig` для других языков).
Если нет — добавьте вручную:

```lua
vim.keymap.set("n", "K", vim.lsp.buf.hover)
vim.keymap.set("n", "gd", vim.lsp.buf.definition)
```

## Известные ограничения (MVP)

- **Синтаксическая/resolve-ошибка роняет сервер.** Только type-checker
  (`type_cheker.odin`) мигрирован на diagnostic accumulation (Стадия 2) —
  parser/resolver всё ещё `fmt.panicf`. Опечатка на уровне синтаксиса
  во время правки временно убьёт LSP-процесс; Neovim's `vim.lsp` сам не
  перезапускает клиент — понадобится `:LspRestart` (или `:e` файла).
- **go-to-definition только внутри одного файла.** Сервер типизирует
  каждый документ независимо (`resolve_program`, без графа импортов) —
  межмодульный переход не работает.
- **`.ps` конфликтует с PostScript.** `ftdetect/panos.lua` переопределяет
  расширение глобально. Если вы реально работаете с `.ps`-PostScript —
  сузьте паттерн под свой проект вместо `extension = { ps = "panos" }`.
- Нет syntax highlighting (`.ps` файлы подсвечиваются как plain text,
  если у вас нет отдельного tree-sitter/syntax файла для panos).
