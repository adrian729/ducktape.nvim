-- Project scope: saved chats key on cwd, resumable sessions on repository root. Default is
-- `git rev-parse --show-toplevel` because it resolves symlinks, matching agent-reported paths.

local M = {}

---@type table<string, string|false>
local cache = {}

---@param cwd string
---@return string|nil
local function git_toplevel(cwd)
	local out = vim.system({ "git", "-C", cwd, "rev-parse", "--show-toplevel" }, { text = true }):wait()
	if out.code ~= 0 then
		return nil
	end
	local root = vim.trim(out.stdout or "")
	return root ~= "" and root or nil
end

---@param cwd string
---@return string|nil
local function fs_root(cwd)
	return vim.fs.root(cwd, ".git")
end

---Project root under a strategy, or nil. Cached per cwd and per strategy because the two callers
---ask different questions of the same directory.
---@param strategy? string|fun(cwd: string): string|nil Defaults to `opts.session.scope`
---@return string|nil
function M.root(strategy)
	strategy = strategy or require("ducktape.config").get().session.scope
	local cwd = vim.fn.getcwd()
	local slot = cwd .. "\0" .. (type(strategy) == "function" and "fn" or tostring(strategy))
	if cache[slot] ~= nil then
		return cache[slot] or nil
	end

	local root
	if type(strategy) == "function" then
		local ok, value = pcall(strategy, cwd)
		root = ok and type(value) == "string" and value or nil
	elseif strategy == "cwd" then
		root = cwd
	elseif strategy == "root" then
		root = fs_root(cwd)
	else
		root = git_toplevel(cwd)
	end

	cache[slot] = root or false
	return root
end

---@param strategy? string|fun(cwd: string): string|nil
---@return string
function M.key(strategy)
	return M.root(strategy) or vim.fn.getcwd()
end

---Whether a path belongs to the current project. Resolves both sides so symlinked checkouts match
---agent-reported real paths.
---@param path string|nil
---@return boolean
function M.contains(path)
	if type(path) ~= "string" or path == "" then
		return false
	end
	local root = M.root()
	if not root then
		return false
	end
	local function resolve(p)
		return vim.fs.normalize(vim.uv.fs_realpath(p) or p)
	end
	return vim.startswith(resolve(path), resolve(root))
end

function M.clear()
	cache = {}
end

return M
