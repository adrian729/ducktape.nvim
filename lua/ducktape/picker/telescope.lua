-- Telescope backend. Layout comes from the user's telescope config.

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
			entry_maker = function(entry)
				-- Telescope passes the picker as self to display(), so capture text directly.
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
		-- Refreshing a dead picker throws inside telescope.
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
