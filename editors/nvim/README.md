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
- `gd` (`vim.lsp.buf.definition`) — переход к объявлению, включая символы
  из импортированных модулей (граф импортов резолвится целиком).
- `gr` (`vim.lsp.buf.references`) / rename — по ВСЕМУ графу импортов, не
  только текущему открытому документу.
- Автокомплит после `.` (`receiver.`) — поля/методы/варианты
  РЕЗОЛВЛЕННОГО типа receiver'а (структуры/перечисления/generic-типы —
  как пользовательские, так и `Опция`/`Результат`), плюс builtin-методы
  `Массив`/`Соответствие`. Без точки — плоский scope-дамп (глобальные
  символы модуля + локали объемлющей функции), как раньше.
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

- **`.ps` конфликтует с PostScript.** `ftdetect/panos.lua` переопределяет
  расширение глобально. Если вы реально работаете с `.ps`-PostScript —
  сузьте паттерн под свой проект вместо `extension = { ps = "panos" }`.
- **Нет tree-sitter грамматики** — `syntax/panos.vim` даёт классическую
  regex-based подсветку (ключевые слова, типы/конструкторы по заглавной
  букве, строки с escape-последовательностями, числа, операторы), но не
  умеет то, что даёт tree-sitter (структурная навигация, инкрементальные
  правки, textobjects). Список ключевых слов в `syntax/panos.vim`
  синхронизирован вручную с `core/lexer.odin::lookup_ident` — держать в
  курсе при добавлении новых слов в язык.
