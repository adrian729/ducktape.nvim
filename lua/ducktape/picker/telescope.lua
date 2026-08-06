-- The telescope backend.
--
-- Layout comes from the user's own telescope config, deliberately unset here, so a ducktape picker
-- reads the same way as every other picker they have: prompt where they put it, closest match
-- nearest the prompt.

local M = {}

---@return boolean
function M.available()
	return (pcall(require, "telescope"))
end

---@param spec table See ducktape.picker
---@return table handle
function M.open(spec)
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local sorters = require("telescope.sorters")
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	local picker
	local handle = {}

	local function finder()
		return finders.new_table({
			results = spec.entries(),
			-- The entries are already in telescope's own shape — `display` returning text plus
			-- highlights — so there is nothing to convert.
			entry_maker = function(entry)
				-- Telescope calls `entry:display(self)` with the picker as the argument, so the
				-- rendered text is captured rather than read off the argument.
				entry.display = function()
					return entry.text, entry.highlights
				end
				return entry
			end,
		})
	end

	function handle.is_open()
		return picker ~= nil and picker.prompt_bufnr ~= nil and vim.api.nvim_buf_is_valid(picker.prompt_bufnr)
	end

	function handle.refresh()
		-- The picker is gone as soon as its prompt buffer is, and refreshing a dead one throws from
		-- inside telescope rather than returning an error.
		if not handle.is_open() then
			picker = nil
			return
		end
		picker:refresh(finder(), { reset_prompt = false })
	end

	function handle.close()
		if handle.is_open() then
			actions.close(picker.prompt_bufnr)
		end
		picker = nil
	end

	picker = pickers.new({}, {
		prompt_title = spec.title,
		results_title = spec.results_title,
		finder = finder(),
		sorter = sorters.get_substr_matcher(),
		attach_mappings = function(prompt_bufnr, map)
			if spec.on_select then
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					if not selection then
						return
					end
					actions.close(prompt_bufnr)
					spec.on_select(selection)
				end)
			end

			require("ducktape.picker").bind_actions(spec, {
				-- Both modes: telescope starts in insert, and the documented keys have to work
				-- without leaving it.
				map = function(lhs, fn)
					map({ "i", "n" }, lhs, fn)
				end,
				selected = action_state.get_selected_entry,
				ctx = {
					refresh = handle.refresh,
					close = function()
						actions.close(prompt_bufnr)
					end,
				},
			})

			if spec.on_attach then
				spec.on_attach(prompt_bufnr, map, handle)
			end
			return true
		end,
	})

	picker:find()
	return handle
end

return M
