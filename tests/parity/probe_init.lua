-- Parametrised variant of the throwaway config, for the cases that need a different spec than the
-- parity one. $DT_VARIANT picks the case; the plugin tree is the one already installed under the
-- test XDG roots, so nothing is cloned again.
local variant = os.getenv("DT_VARIANT") or "default"

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"
vim.o.termguicolors = true

if variant == "keymaps_false" then
	vim.g.ducktape = { keymaps = false }
elseif variant == "globals_false" then
	vim.g.ducktape = { keymaps = { globals = false } }
elseif variant == "wrong_route" then
	vim.g.ducktape = { providers = {}, nonsense = true }
elseif variant == "taken_key" then
	-- Set before lazy.setup, i.e. before plugin/ducktape.lua runs: the maparg path.
	vim.keymap.set("n", "<leader>ci", "<cmd>echo 'mine'<cr>", { desc = "mine" })
elseif variant == "own_plug" then
	-- The hasmapto path: their own key already points at the action.
	vim.keymap.set("n", "<leader>zi", "<Plug>(DucktapeInline)", { remap = true })
end

if variant == "late_throw" then
	-- A throw *after* install_adapters, which is the case a "are the adapters registered?" check
	-- would wave through. config.lua's own vim.validate cannot produce it: it runs first, before
	-- the adapters go in.
	package.loaded["ducktape.reload"] = {
		setup = function()
			error("probe: a later setup step failed")
		end,
	}
end

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
vim.opt.runtimepath:prepend(lazypath)

local cc_opts = { extensions = { ducktape = { opts = {} } } }
if variant == "no_extension" then
	cc_opts = {}
elseif variant == "setup_throws" then
	-- Trips config.lua's vim.validate part-way through setup, after the adapters went in.
	cc_opts = { extensions = { ducktape = { opts = { providers = "not a table" } } } }
end

local spec = {
	{ dir = vim.fn.expand("~/projects/ducktape.nvim"), lazy = false },
	{
		"olimorris/codecompanion.nvim",
		event = "VeryLazy",
		dependencies = { "nvim-lua/plenary.nvim" },
		opts = cc_opts,
	},
	{ "nvim-treesitter/nvim-treesitter", branch = "main", lazy = false },
}
-- `enabled = false` rather than leaving it out of the spec: ducktape's own lazy.lua declares
-- telescope as a dependency, so omitting it here does not remove it.
table.insert(spec, {
	"nvim-telescope/telescope.nvim",
	dependencies = { "nvim-lua/plenary.nvim" },
	lazy = false,
	enabled = variant ~= "no_telescope",
})
if variant ~= "no_catppuccin" then
	table.insert(spec, { "catppuccin/nvim", name = "catppuccin", priority = 1000 })
end

require("lazy").setup(spec, { install = { missing = false }, checker = { enabled = false } })
