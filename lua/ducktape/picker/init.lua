-- One list-picking interface with several backends. `opts.ui.picker` chooses:
--   "auto"       first installed backend, then default
--   "telescope"  telescope.nvim
--   "default"    this plugin's built-in float
--   fun(spec)    custom backend
--
-- Spec:
--   title          prompt title
--   results_title  shown where the backend supports it
--   entries        fun(): entry[], build and rebuild
--   on_select      fun(entry), <CR>
--   panel          keymaps.panels group for extra actions
--   actions        table<string, fun(entry, ctx)>, ctx is { refresh, close }
--
-- Entry:
--   value        returned to caller
--   text         rendered line
--   highlights   from ui.render
--   ordinal      filter target
--   kind         caller-side tag
--
-- Handle: { refresh = fun(), close = fun(), is_open = fun(): boolean }

local M = {}

-- Ordered by preference; default is the fallback.
local BACKENDS = { "telescope", "default" }

---@param name string
---@return boolean
local function available(name)
	if name == "default" then
		return true
	end
	local ok, backend = pcall(require, "ducktape.picker." .. name)
	return ok and backend.available()
end

---@return string name, string reason reported by :checkhealth
function M.resolve()
	local configured = require("ducktape.config").get().ui.picker

	if type(configured) == "function" then
		return "custom", "opts.ui.picker is a function"
	end
	if configured and configured ~= "auto" then
		if available(configured) then
			return configured, "opts.ui.picker"
		end
		-- Warn when an explicitly named backend is unavailable; the fallback looks different.
		require("ducktape.ui").say(
			("[ducktape] picker %q is not available, falling back to the built-in float"):format(tostring(configured)),
			vim.log.levels.WARN
		)
		return "default", ("%s is not installed"):format(tostring(configured))
	end

	for _, name in ipairs(BACKENDS) do
		if available(name) then
			return name, name == "default" and "no picker plugin found" or ("auto: %s is installed"):format(name)
		end
	end
	return "default", "no picker plugin found"
end

---@param spec table
---@return table handle
function M.open(spec)
	local configured = require("ducktape.config").get().ui.picker
	if type(configured) == "function" then
		return configured(spec)
	end
	local name = M.resolve()
	return require("ducktape.picker." .. name).open(spec)
end

---Bind a panel's extra actions in a backend-agnostic way. The backend supplies how to read the
---selection and how to map a key; the rest is shared.
---@param spec table
---@param opts { map: fun(lhs: string, fn: fun()), selected: fun(): table|nil, ctx: table }
function M.bind_actions(spec, opts)
	if not spec.panel or not spec.actions then
		return
	end
	local keys = require("ducktape.keys")
	for action, fn in pairs(spec.actions) do
		for _, lhs in ipairs(keys.panel(spec.panel, action)) do
			opts.map(lhs, function()
				local entry = opts.selected()
				if entry then
					fn(entry, opts.ctx)
				end
			end)
		end
	end
end

return M
