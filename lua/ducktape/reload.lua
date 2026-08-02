-- Keeps open buffers in step with the files the agent edits.
--
-- The chat agent edits files on disk, not through nvim. It has an ACP path that would
-- reach the buffer instead — CodeCompanion implements fs/write_text_file, and its handler
-- writes into an open buffer when it finds one (interactions/chat/acp/fs.lua) — but
-- claude-agent-acp only ever defines writeTextFile on its client proxy and never calls it,
-- so that path is dead no matter what clientCapabilities advertise. The agent's own
-- Edit/Write tools go straight to the filesystem.
--
-- Nothing in nvim notices that on its own: `autoread` is off by default and only acts when
-- something calls `checktime`. So the buffer kept serving the pre-edit text while the file
-- underneath it had moved on — two versions of the same file, and whichever you saved won.

local M = {}

local api = vim.api
local ui = require("ducktape.ui")

---The listed buffer holding a path, if one is open.
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

---Pull a buffer back in line with the file on disk.
---
---Reloading moves the cursor to line 1 and scrolls every window showing the buffer, which
---is jarring when the agent edits the file you are reading, so the view is saved and put
---back per window.
---@param bufnr number
local function reload(bufnr)
	local views = {}
	for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
		views[win] = api.nvim_win_call(win, vim.fn.winsaveview)
	end

	-- Buffer-local: `checktime` asks "file changed, [O]K / (L)oad File?" unless autoread is
	-- set, and this should not be a prompt. Kept off the global option so the rest of the
	-- editor behaves the way the user configured it.
	vim.bo[bufnr].autoread = true
	pcall(vim.cmd, ("checktime %d"):format(bufnr))

	for win, view in pairs(views) do
		if api.nvim_win_is_valid(win) then
			api.nvim_win_call(win, function()
				vim.fn.winrestview(view)
			end)
		end
	end
end

---Bring a single edited path back into its buffer.
---@param path string
local function sync(path)
	local bufnr = bufnr_for(path)
	if not bufnr then
		return -- not open, so there is no stale copy to worry about
	end

	-- Unsaved local edits plus a changed file is a genuine conflict, and picking a winner
	-- here would silently throw away one side. Neither is touched: say so, name the file,
	-- and leave it to the user — `:e!` takes the agent's version, `:w` takes theirs.
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

---Catch-all for edits that arrive without a path: the agent reports locations for its
---Edit/Write tools, but a shell redirect or a script it ran has no tool_call location to
---read, so a turn can change files nobody told us about.
local function sync_all()
	for _, bufnr in ipairs(api.nvim_list_bufs()) do
		if
			api.nvim_buf_is_valid(bufnr)
			and api.nvim_buf_is_loaded(bufnr)
			and vim.bo[bufnr].buftype == "" -- real files only; not the chat buffer or a terminal
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
			-- Scheduled because the event is fired from the ACP stream handler, and a fast
			-- event context cannot touch buffers.
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
