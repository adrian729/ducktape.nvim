-- Minimal repro config. Uses ./.repro so it won't touch your real install.
--
--   nvim --clean -u minimal.lua

local root = vim.fn.fnamemodify("./.repro", ":p")

for _, name in ipairs({ "config", "data", "state", "cache" }) do
	vim.env[("XDG_%s_HOME"):format(name:upper())] = root .. "/" .. name
end

-- Set leader before lazy.setup; plugin/ducktape.lua creates mappings during that call.
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"
vim.o.termguicolors = true

local lazypath = root .. "/plugins/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
	vim.fn.system({
		"git",
		"clone",
		"--filter=blob:none",
		"https://github.com/folke/lazy.nvim.git",
		lazypath,
	})
end
vim.opt.runtimepath:prepend(lazypath)

require("lazy").setup({
	root = root .. "/plugins",
	spec = {
		-- Test the working copy. Point at "adrian729/ducktape.nvim" to reproduce a release.
		{ dir = vim.fn.fnamemodify(".", ":p"), lazy = false },

		{
			"olimorris/codecompanion.nvim",
			-- Keep codecompanion deferred so ducktape loads it on first action.
			event = "VeryLazy",
			dependencies = { "nvim-lua/plenary.nvim" },
			opts = {
				extensions = {
					-- Empty opts reproduce the defaults this plugin was extracted from.
					ducktape = { opts = {} },
				},
			},
		},

		{
			"nvim-treesitter/nvim-treesitter",
			branch = "main",
			lazy = false,
			build = ":TSUpdate",
			config = function()
				-- Required parsers; Neovim ships neither.
				require("nvim-treesitter").install({ "markdown", "markdown_inline" })
			end,
		},

		-- Optional. Drop one to verify graceful degradation.
		{ "nvim-telescope/telescope.nvim", dependencies = { "nvim-lua/plenary.nvim" }, lazy = false },
		{ "catppuccin/nvim", name = "catppuccin", priority = 1000 },
	},
})
