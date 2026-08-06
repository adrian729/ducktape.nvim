-- What counts as "this project".
--
-- Two things need an answer and used to give different ones. Resumable agent sessions are filtered
-- by repository root, while saved chats key on the working directory — so `:cd` inside one nvim
-- session could leave the two disagreeing about which chats belong here. Both now come through
-- this module, and `opts.session.scope` picks the strategy.
--
-- The default is still `git rev-parse --show-toplevel`, and deliberately: it resolves symlinks, and
-- the agent-reported `cwd` a session list is filtered against is a resolved path. `vim.fs.root`
-- needs no subprocess but does not resolve symlinks, so on a symlinked checkout it would silently
-- filter every session out — which looks exactly like having no sessions at all.

local M = {}

---@type table<string, string|false>
local cache = {}

---`git rev-parse --show-toplevel`, run in the working directory.
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

---The nearest ancestor holding a `.git`, which is a file rather than a directory in a worktree.
---@param cwd string
---@return string|nil
local function fs_root(cwd)
	return vim.fs.root(cwd, ".git")
end

---The project root under a strategy, or nil when there is none.
---
---Cached per working directory *and* per strategy: the two callers ask different questions of the
---same directory, so one cache slot would answer the second with the first's result. Per directory
---rather than once per session because the old version memoised a single answer including the
---negative one, so a `:cd` into a repository still reported "not a repository" for the rest of the
---session.
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

---The key saved state is filed under. Always a string, so a directory outside any repository still
---has somewhere to keep its chats rather than sharing one bucket with every other such directory.
---@param strategy? string|fun(cwd: string): string|nil
---@return string
function M.key(strategy)
	return M.root(strategy) or vim.fn.getcwd()
end

---Does a path belong to the current project?
---
---Used to filter an agent's session list, where `cwd` is whatever the agent recorded. Compared
---after resolving both sides, so a symlinked checkout on one side and a real path on the other
---still match.
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

---Forget what has been worked out, so the next call re-derives it. For tests and for `:cd` handling
---if it ever needs to be explicit.
function M.clear()
	cache = {}
end

return M
