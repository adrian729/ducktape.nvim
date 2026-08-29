-- Persist discovered model lists across nvim restarts so pickers are not empty on first open.
-- `:Ducktape models` clears the cache and re-queries.

local M = {}

local VERSION = 1

---@return string
local function path()
	return vim.fs.joinpath(vim.fn.stdpath("state"), "ducktape", "models.json")
end

M.path = path

---Last written cache, or nil if missing/unusable. Version mismatches are treated as absent.
---@return table|nil
function M.read()
	local file = path()
	if vim.fn.filereadable(file) == 0 then
		return nil
	end
	local ok, content = pcall(vim.fn.readfile, file)
	if not ok then
		return nil
	end
	local decoded, data = pcall(vim.json.decode, table.concat(content, "\n"))
	if not decoded or type(data) ~= "table" or data.version ~= VERSION then
		return nil
	end
	return data
end

---Persist a list under `key`, merging with what is already on disk. Lists arrive one query at a
---time, so replacing would drop earlier answers.
---@param key string
---@param models string[]
function M.write(key, models)
	local data = M.read() or { version = VERSION, lists = {} }
	data.lists = data.lists or {}
	data.lists[key] = models
	data.generated_at = os.time()

	local file = path()
	vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
	pcall(vim.fn.writefile, { vim.json.encode(data) }, file)
end

---@return table<string, string[]>
function M.lists()
	local data = M.read()
	return (data and type(data.lists) == "table") and data.lists or {}
end

---@return number|nil epoch seconds
function M.generated_at()
	local data = M.read()
	return data and data.generated_at or nil
end

function M.clear()
	pcall(vim.fn.delete, path())
end

return M
