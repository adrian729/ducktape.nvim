-- Reload open buffers when the chat agent edits files on disk. The ACP fs/write_text_file path
-- is not used by claude-agent-acp, so edits land on disk and `autoread` alone will not notice.

local M = {}

local api = vim.api
local ui = require("ducktape.ui")

---@param path string
---@return number|nil
local function bufnr_for(path)
	if type(path) ~= "string" or path == "" then
		return nil
	end
	local target = vim.fn.fnamemodify(path, ":p")
	for _, bufnr in ipairs(api.nvim_list_bufs()) do
		if api.nvim_buf_is_valid(bufnr) and api.nvim_buf_is_loaded(bufnr) then
			if vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":p") == target then
				return bufnr
			end
		end
	end
	return nil
end

---Reload a buffer from disk, preserving the view in each window.
---@param bufnr number
local function reload(bufnr)
	local views = {}
	for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
		views[win] = api.nvim_win_call(win, vim.fn.winsaveview)
	end

	-- Buffer-local autoread avoids the "load file?" prompt without changing the global option.
	local prev_autoread = vim.bo[bufnr].autoread
	vim.bo[bufnr].autoread = true
	pcall(vim.cmd, ("checktime %d"):format(bufnr))
	vim.bo[bufnr].autoread = prev_autoread

	for win, view in pairs(views) do
		if api.nvim_win_is_valid(win) then
			api.nvim_win_call(win, function()
				vim.fn.winrestview(view)
			end)
		end
	end
end

---@param path string
local function sync(path)
	local bufnr = bufnr_for(path)
	if not bufnr then
		return
	end

	-- Do not silently pick a winner when the buffer has unsaved changes.
	if vim.bo[bufnr].modified then
		return ui.say(
			("[ducktape] %s was edited by the agent but has unsaved changes here — :e! to take the agent's version, :w to keep yours"):format(
				vim.fn.fnamemodify(path, ":~:.")
			),
			vim.log.levels.WARN
		)
	end

	reload(bufnr)
end

---Catch edits that arrive without a path (shell redirects, scripts, etc.).
local function sync_all()
	for _, bufnr in ipairs(api.nvim_list_bufs()) do
		if
			api.nvim_buf_is_valid(bufnr)
			and api.nvim_buf_is_loaded(bufnr)
			and vim.bo[bufnr].buftype == ""
			and not vim.bo[bufnr].modified
			and api.nvim_buf_get_name(bufnr) ~= ""
		then
			reload(bufnr)
		end
	end
end

function M.setup()
	local augroup = api.nvim_create_augroup("DucktapeBufferReload", { clear = true })

	api.nvim_create_autocmd("User", {
		group = augroup,
		pattern = "CodeCompanionFileEdited",
		desc = "Reload a buffer the AI agent has edited on disk",
		callback = function(args)
			local path = args.data and args.data.path
			if not path then
				return
			end
			-- The event fires from the ACP stream handler, which is fast-event context.
			vim.schedule(function()
				sync(path)
			end)
		end,
	})

	api.nvim_create_autocmd("User", {
		group = augroup,
		pattern = "CodeCompanionRequestFinished",
		desc = "Catch any file the agent changed without reporting a location",
		callback = function()
			vim.schedule(sync_all)
		end,
	})
end

return M
