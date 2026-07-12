-- Автозагрузка при старте Neovim, если пакет лежит в pack/*/start/ —
-- plugin/*.lua из start-пакетов sourcятся автоматически, без require()
-- в пользовательском init.lua. Для opt-пакетов (:packadd) сработает
-- ровно так же, сразу после :packadd panos.
require("panos").setup()
