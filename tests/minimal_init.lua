-- Minimal harness: plugin and hard deps on the runtimepath, nothing else. Suites that secretly
-- need another plugin fail here instead of on a colleague's machine. Deps are reused from an
-- existing lazy.nvim install or cloned into tests/.deps for CI.

local repo = vim.fn.fnamemodify(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h"), ":h")

local DEPS = {
	["plenary.nvim"] = "https://github.com/nvim-lua/plenary.nvim",
	["codecompanion.nvim"] = "https://github.com/olimorris/codecompanion.nvim",
}

---Path to an existing dependency, if found.
---@param name string
---@return string|nil
local function existing(name)
	for _, base in ipairs({
		vim.env.DUCKTAPE_DEPS_DIR,
		vim.fn.stdpath("data") .. "/lazy",
		vim.fn.expand("~/.local/share/nvim/lazy"),
	}) do
		if base and vim.fn.isdirectory(base .. "/" .. name) == 1 then
			return base .. "/" .. name
		end
	end
	return nil
end

local function dep_path(name, url)
	local found = existing(name)
	if found then
		return found
	end
	local dir = repo .. "/tests/.deps/" .. name
	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(vim.fn.fnamemodify(dir, ":h"), "p")
		local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--depth=1", url, dir })
		if vim.v.shell_error ~= 0 then
			error(("could not clone %s: %s"):format(name, out))
		end
	end
	return dir
end

vim.opt.runtimepath:prepend(repo)
for name, url in pairs(DEPS) do
	vim.opt.runtimepath:prepend(dep_path(name, url))
end

-- Pin terminal size so suites measure consistent rendered widths and command-line output.
vim.o.columns = 120
vim.o.lines = 40
vim.o.laststatus = 2
vim.o.swapfile = false
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"
