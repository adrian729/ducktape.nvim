-- One list-picking interface, several backends.
--
-- The chat list and both model pickers used to call telescope directly, which made it a hard
-- requirement for three features: without it they reported a clear error and did nothing. That is
-- graceful, but it is still three features a user cannot have.
--
-- Codecompanion solves the same problem in `providers/action_palette/` with one module per backend
-- behind a shared interface, and this mirrors it. `opts.ui.picker` chooses:
--
--   "auto"       the first installed backend, then `default`
--   "telescope"  telescope.nvim
--   "default"    a float this plugin draws itself — no dependency, always available
--   fun(spec)    your own, taking the spec below and returning a handle
--
-- The spec a backend receives:
--
--   title          string, the prompt title
--   results_title  string|nil, shown where the backend has a place for it
--   entries        fun(): entry[] — called to build and to rebuild
--   on_select      fun(entry) — <CR>
--   panel          string|nil, which `keymaps.panels` table extra actions are read from
--   actions        table<string, fun(entry, ctx)> — ctx is { refresh, close }
--
-- An entry:
--
--   value        anything the caller wants back
--   text         the rendered line
--   highlights   {{ {start_col, end_col}, group }, …} from `ui.render`
--   ordinal      what a filter matches against
--   kind         optional caller-side tag, carried through untouched
--
-- A handle: { refresh = fun(), close = fun(), is_open = fun(): boolean }

local M = {}

-- Ordered by how good the experience is, not alphabetically: the first one installed wins under
-- "auto". `default` is last because it is the fallback, and always available.
local BACKENDS = { "telescope", "default" }

---Is a backend's dependency present?
---@param name string
---@return boolean
local function available(name)
	if name == "default" then
		return true
	end
	local ok, backend = pcall(require, "ducktape.picker." .. name)
	return ok and backend.available()
end

---Which backend to use, and why. The reason is reported by `:checkhealth`.
---@return string name, string reason
function M.resolve()
	local configured = require("ducktape.config").get().ui.picker

	if type(configured) == "function" then
		return "custom", "opts.ui.picker is a function"
	end
	if configured and configured ~= "auto" then
		if available(configured) then
			return configured, "opts.ui.picker"
		end
		-- Named explicitly and not installed: say so rather than silently substituting, since the
		-- fallback looks different enough that a user would wonder what happened.
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

---Open a picker.
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

---Bind a panel's extra actions in a backend-agnostic way.
---
---Shared because both backends need the same thing: for each action in the spec, look up its keys in
---`keymaps.panels.<panel>` and bind them to a callback that is handed the selected entry and a
---context. A backend supplies how to read the selection and how to map a key, since those are the
---two things that genuinely differ between them.
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
