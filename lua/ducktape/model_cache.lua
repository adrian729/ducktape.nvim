-- The model lists this machine can actually reach, written down so they survive an nvim restart.
--
-- Every list here is discovered by asking the provider — `opencode models`, ollama's `/api/tags` —
-- so nothing about it is machine-specific except the machine it was generated on. That is the point:
-- the plugin used to read a hand-maintained `opencode-models.json` from its author's dotfiles, which
-- meant a colleague's first paint was empty and their `auto` had nothing to resolve against.
--
-- Written on first discovery and re-read on the next start. `:Ducktape models` throws it away and
-- asks again, which is the only thing that picks up a model added since.
--
-- Kept apart from ducktape.providers on purpose: that module is what every other one reads, and it
-- stays free of load-time dependencies. This is required from inside its functions.

local M = {}

local VERSION = 1

---@return string
local function path()
	return vim.fs.joinpath(vim.fn.stdpath("state"), "ducktape", "models.json")
end

M.path = path

---What was written last time, or nil if there is nothing usable there.
---
---A version mismatch is treated as absent rather than migrated: the file is a cache of something
---the providers can be asked for again, so throwing it away costs one query.
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

---Persist a list under `key`, merging with whatever is already on disk.
---
---Merged rather than replaced because the lists arrive one query at a time — opencode from a
---subprocess, each ollama endpoint from its own request — and a write per arrival would otherwise
---drop the ones that answered earlier.
---@param key string
---@param models string[]
function M.write(key, models)
	local data = M.read() or { version = VERSION, lists = {} }
	data.lists = data.lists or {}
	data.lists[key] = models
	-- Stamped so `:checkhealth` can say how old this is. Not used to expire anything: a list that
	-- is out of date is still better than an empty picker, and refreshing is one command.
	data.generated_at = os.time()

	local file = path()
	vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
	pcall(vim.fn.writefile, { vim.json.encode(data) }, file)
end

---Every persisted list, keyed as the in-memory cache keys them.
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

---Throw the file away. The next query rewrites it.
function M.clear()
	pcall(vim.fn.delete, path())
end

return M
