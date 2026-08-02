-- Minimal config for reproducing an issue, and the one the plugin's own parity testing runs
-- against. Nothing here beyond ducktape and what it needs, so a problem that shows up is the
-- plugin's rather than some other plugin's.
--
--   nvim --clean -u minimal.lua
--
-- Plugins and state land in ./.repro, so this cannot touch your real install.

local root = vim.fn.fnamemodify("./.repro", ":p")

for _, name in ipairs({ "config", "data", "state", "cache" }) do
	vim.env[("XDG_%s_HOME"):format(name:upper())] = root .. "/" .. name
end

-- Before lazy.setup, always: `<leader>` is resolved when a mapping is created, and
-- plugin/ducktape.lua creates its mappings during that call.
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
		-- `dir` so this tests the working copy. Point it at "adrian-daedalus/ducktape.nvim" to
		-- reproduce against a release instead.
		{ dir = vim.fn.fnamemodify(".", ":p"), lazy = false },

		{
			"olimorris/codecompanion.nvim",
			-- Kept deferred. Dropping this makes codecompanion a start plugin, which pulls its whole
			-- setup into the startup path; ducktape's first action loads it instead.
			event = "VeryLazy",
			dependencies = { "nvim-lua/plenary.nvim" },
			opts = {
				extensions = {
					-- Empty opts on purpose: the defaults are the configuration this plugin was
					-- extracted from, so this reproduces it exactly.
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
				-- Required, not cosmetic: Neovim ships neither parser, and the chat cannot render
				-- without them.
				require("nvim-treesitter").install({ "markdown", "markdown_inline" })
			end,
		},

		-- Optional. Drop either one to check that ducktape degrades the way it says it does: the
		-- chat list and model pickers report a clear error without telescope, and the highlights
		-- fall back to a stand-in palette without catppuccin.
		{ "nvim-telescope/telescope.nvim", dependencies = { "nvim-lua/plenary.nvim" }, lazy = false },
		{ "catppuccin/nvim", name = "catppuccin", priority = 1000 },
	},
})
