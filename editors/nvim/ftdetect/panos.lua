-- .ps по умолчанию в Vim/Neovim — PostScript. Переопределяем под panos:
-- если это ломает реальную работу с .ps-PostScript-файлами, можно вместо
-- этого сузить паттерн (например завязаться на директорию проекта) —
-- см. :help vim.filetype.add.
vim.filetype.add({
	extension = {
		ps = "panos",
	},
})
