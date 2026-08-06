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
---
---Identified by shape rather than by exclusion list: an action's entry is a keymap spec, so it
---carries its left-hand side at `[1]`. `panels` is a table of tables and would otherwise be counted
---as a nineteenth action, which is how this went wrong once already.
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

--=============================================================================
-- Panel keys
--=============================================================================

---The keys bound to an action inside one of this plugin's own windows.
---
---`:h lua-plugin-keymaps` calls buffer-local maps in plugin-owned floats uncontroversial, and they
---are — but `a`, `r` and `x` sit on strong muscle memory, so they resolve through here. A user table
---replaces the shipped list for that action only; everything they did not name keeps its default.
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

---Bind every key an action has, in one window.
---@param panel string
---@param buf number
---@param map table<string, fun()> action name → callback
---@param opts? table Extra options for vim.keymap.set
function M.bind_panel(panel, buf, map, opts)
	for action, fn in pairs(map) do
		for _, lhs in ipairs(M.panel(panel, action)) do
			vim.keymap.set("n", lhs, fn, vim.tbl_extend("force", { buffer = buf, nowait = true }, opts or {}))
		end
	end
end

---The first key an action is bound to in a panel, for prose that names it.
---@param panel string
---@param action string
---@return string
function M.panel_label(panel, action)
	return M.panel(panel, action)[1] or "?"
end

return M
