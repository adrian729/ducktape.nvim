-- Resolve keymap names so messages and help overlays stay honest after a remap.

local M = {}

---@return table
local function keymaps()
	return require("ducktape.config").get().keymaps or {}
end

---Left-hand side for an action, or nil if unknown. Falls back to the shipped default so a
---suppressed keymap still has a name to show in messages.
---@param action string
---@return string|nil
function M.lhs(action)
	local entry = keymaps()[action]
	if type(entry) == "table" then
		return entry[1]
	end
	if type(entry) == "string" then
		return entry
	end
	local shipped = require("ducktape.config").defaults.keymaps[action]
	return type(shipped) == "table" and shipped[1] or nil
end

---@param action string
---@return string
function M.label(action)
	return M.lhs(action) or "?"
end

---@param action string
---@return string[]
function M.modes(action)
	local entry = keymaps()[action]
	local from = type(entry) == "table" and entry.mode or nil
	return from or { "n" }
end

---@param action string
---@return string|nil
function M.desc(action)
	local entry = keymaps()[action]
	return type(entry) == "table" and entry.desc or nil
end

---@return boolean
function M.globals_enabled()
	return keymaps().globals ~= false
end

---Every global action except the buffer-local diff set. Identified by shape (`[1]` is the lhs);
---`panels` is a nested table and would otherwise be counted.
---@return string[]
function M.global_actions()
	local out = {}
	for action, entry in pairs(keymaps()) do
		local is_spec = type(entry) == "table" and type(entry[1]) == "string"
		if is_spec and not vim.startswith(action, "diff_") then
			table.insert(out, action)
		end
	end
	table.sort(out)
	return out
end

---Keys bound to an action inside one of this plugin's own windows. A user table replaces the
---shipped list for that action only.
---@param panel string
---@param action string
---@return string[]
function M.panel(panel, action)
	local configured = vim.tbl_get(keymaps(), "panels", panel, action)
	if type(configured) == "string" then
		return { configured }
	end
	if type(configured) == "table" then
		return configured
	end
	local shipped = vim.tbl_get(require("ducktape.config").defaults.keymaps, "panels", panel, action)
	return type(shipped) == "table" and shipped or {}
end

---@param panel string
---@param buf number
---@param map table<string, fun()>
---@param opts? table
function M.bind_panel(panel, buf, map, opts)
	for action, fn in pairs(map) do
		for _, lhs in ipairs(M.panel(panel, action)) do
			vim.keymap.set("n", lhs, fn, vim.tbl_extend("force", { buffer = buf, nowait = true }, opts or {}))
		end
	end
end

---@param panel string
---@param action string
---@return string
function M.panel_label(panel, action)
	return M.panel(panel, action)[1] or "?"
end

return M
