-- The one place that knows what a key is called.
--
-- Messages name keys — "<leader>cx cancels it", "<leader>cL lists them all", the diff banner, the
-- chat footer, the chat list's help overlay. Those strings used to hardcode the defaults, which
-- was true until someone remapped, at which point the help lied. They resolve through here now, so
-- a remap carries into everything that mentions it.

local M = {}

---@return table
local function keymaps()
	return require("ducktape.config").get().keymaps or {}
end

---The left-hand side configured for an action, or nil when the action is unknown.
---
---Falls back to the shipped default rather than returning nil for a known action that a user set
---to `false`: a suppressed keymap still has a name, and a message interpolating `nil` would be
---worse than one naming a key that happens not to be bound.
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

---What to print for an action. Same as `lhs`, and named separately so call sites read as prose
---rather than as lookups.
---@param action string
---@return string
function M.label(action)
	return M.lhs(action) or "?"
end

---The modes an action is bound in.
---@param action string
---@return string[]
function M.modes(action)
	local entry = keymaps()[action]
	local from = type(entry) == "table" and entry.mode or nil
	return from or { "n" }
end

---The description an action carries in `:map`.
---@param action string
---@return string|nil
function M.desc(action)
	local entry = keymaps()[action]
	return type(entry) == "table" and entry.desc or nil
end

---Are the global `<leader>c*` defaults wanted at all?
---@return boolean
function M.globals_enabled()
	return keymaps().globals ~= false
end

---Every action that is a global keymap, i.e. everything except the buffer-local diff set.
---@return string[]
function M.global_actions()
	local out = {}
	for action, entry in pairs(keymaps()) do
		if action ~= "globals" and type(entry) == "table" and not vim.startswith(action, "diff_") then
			table.insert(out, action)
		end
	end
	table.sort(out)
	return out
end

return M
