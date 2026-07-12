-- Минимальный клиент для LSP-сервера panos (отдельный бинарник panos-lsp).
-- Использование — см. editors/nvim/README.md.
local M = {}

M.config = {
	-- Полный путь к бинарнику, если panos-lsp не в PATH — например
	-- cmd = { "/Users/you/dev/panos/panos-lsp" }.
	cmd = { "panos-lsp" },
	filetypes = { "panos" },
	-- Маркеры корня проекта — тот же Justfile, что использует сам panos.
	root_markers = { "Justfile", ".git" },
}

function M.setup(opts)
	opts = vim.tbl_deep_extend("force", M.config, opts or {})

	vim.api.nvim_create_autocmd("FileType", {
		pattern = opts.filetypes,
		callback = function(args)
			local root_dir = vim.fs.root(args.buf, opts.root_markers) or vim.fn.getcwd()
			vim.lsp.start({
				name = "panos",
				cmd = opts.cmd,
				root_dir = root_dir,
			})
		end,
	})
end

return M
