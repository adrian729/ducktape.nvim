-- Chat window lifetime rules. The chat is a sidecar to the file it opened next to, but nvim
-- treats it as an ordinary window, so closing the last file leaves a chat-only session that
-- cannot even be hidden (E444 on `:hide`).

local M = {}

local api = vim.api

---@return table
local function opts()
	return require("ducktape.config").get().chat or {}
end

---@param buf number|nil
---@return boolean
local function is_chat_buf(buf)
	if not buf or not api.nvim_buf_is_valid(buf) then
		return false
	end
	local loaded, Chat = pcall(require, "codecompanion.interactions.chat")
	if loaded then
		local got, chat = pcall(Chat.buf_get_chat, buf)
		if got and chat then
			return true
		end
	end
	return vim.bo[buf].filetype == "codecompanion"
end

---@param win number
---@return boolean
local function is_chat_win(win)
	return api.nvim_win_is_valid(win) and is_chat_buf(api.nvim_win_get_buf(win))
end

---A window holding something the session exists for. Floats are excluded so a dismissed picker
---does not read as the last file going away.
---@param win number
---@return boolean
local function is_ordinary_win(win)
	return api.nvim_win_is_valid(win)
		and api.nvim_win_get_config(win).relative == ""
		and not is_chat_buf(api.nvim_win_get_buf(win))
end

---@return number[] chats, number[] ordinary
local function survey()
	local chats, ordinary = {}, {}
	for _, win in ipairs(api.nvim_list_wins()) do
		if is_chat_win(win) then
			table.insert(chats, win)
		elseif is_ordinary_win(win) then
			table.insert(ordinary, win)
		end
	end
	return chats, ordinary
end

local quitting = false

---Hide chat windows without closing their buffers, so `VimLeavePre` can still save session IDs.
---@param chats number[]
local function stand_down(chats)
	for _, win in ipairs(chats) do
		pcall(api.nvim_win_hide, win)
	end
end

local function quit_session()
	if quitting then
		return
	end
	quitting = true
	local ok, err = pcall(vim.cmd, "quitall")
	quitting = false
	if not ok then
		require("ducktape.ui").say(
			("[ducktape] only the chat is left, but the session will not quit: %s"):format(
				(tostring(err):gsub("^.-:%s*", ""))
			),
			vim.log.levels.WARN
		)
	end
end

---What the layout says should become of the chat after a file window closes. Separated from the
---action so tests can ask the question without quitting.
---@return "quit"|"orphaned"|nil verdict, number[] orphans Chat windows in a tab with no files left
function M.verdict()
	local chats, ordinary = survey()
	if #chats == 0 then
		return nil, {}
	end
	if #ordinary == 0 then
		return "quit", {}
	end
	local working = {}
	for _, win in ipairs(ordinary) do
		working[api.nvim_win_get_tabpage(win)] = true
	end
	local orphans = {}
	for _, win in ipairs(chats) do
		if not working[api.nvim_win_get_tabpage(win)] then
			table.insert(orphans, win)
		end
	end
	return #orphans > 0 and "orphaned" or nil, orphans
end

local function reap()
	local verdict, orphans = M.verdict()
	if verdict == "quit" then
		return quit_session()
	end
	stand_down(orphans)
end

---@return { registered: boolean, chats: number, unsaved: string[] }
function M.report()
	local got, autocmds = pcall(api.nvim_get_autocmds, { group = "DucktapeChatWindow" })
	local events = {}
	for _, au in ipairs(got and autocmds or {}) do
		events[au.event] = true
	end

	local unsaved = {}
	for _, buf in ipairs(api.nvim_list_bufs()) do
		if api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified and vim.bo[buf].buftype == "" then
			local name = api.nvim_buf_get_name(buf)
			table.insert(
				unsaved,
				name ~= "" and vim.fn.fnamemodify(name, ":~:.") or ("[No Name] (buffer %d)"):format(buf)
			)
		end
	end

	return {
		registered = (events.QuitPre and events.WinClosed) or false,
		chats = #(select(1, survey())),
		unsaved = unsaved,
	}
end

---@param win number
---@return boolean
function M.is_last_window(win)
	if not api.nvim_win_is_valid(win) then
		return false
	end
	for _, other in ipairs(api.nvim_list_wins()) do
		if other ~= win and api.nvim_win_is_valid(other) and api.nvim_win_get_config(other).relative == "" then
			return false
		end
	end
	return true
end

---@return number|nil
local function editor_win()
	local previous = vim.fn.win_getid(vim.fn.winnr("#"))
	if previous ~= 0 and previous ~= api.nvim_get_current_win() and is_ordinary_win(previous) then
		return previous
	end
	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		if is_ordinary_win(win) then
			return win
		end
	end
end

---Jump between the chat and the file.
function M.focus()
	if is_chat_win(api.nvim_get_current_win()) then
		local win = editor_win()
		if not win then
			return require("ducktape.ui").say("[ducktape] no file window to go back to", vim.log.levels.INFO)
		end
		return api.nvim_set_current_win(win)
	end
	require("ducktape.chat").focus()
end

function M.setup()
	local group = api.nvim_create_augroup("DucktapeChatWindow", { clear = true })

	-- WinClosed catches every way a file window can go (`:q`, `<C-w>c`, `:bd`, plugins).
	-- It fires with the window still in the list, so the survey waits a tick for the real layout.
	api.nvim_create_autocmd("WinClosed", {
		group = group,
		callback = function(args)
			if not opts().close_with_last_file then
				return
			end
			local closing = tonumber(args.match)
			-- Only a file window closing can strand the chat; ignore float closes.
			if not closing or not is_ordinary_win(closing) then
				return
			end
			vim.schedule(reap)
		end,
	})

	api.nvim_create_autocmd("QuitPre", {
		group = group,
		callback = function(args)
			if quitting then
				return
			end
			local current = api.nvim_get_current_win()

			-- `:q` in the chat quits the session; `<leader>cc` is the show/hide key.
			if opts().quit_closes_session and is_chat_win(current) and api.nvim_get_current_buf() == args.buf then
				-- QuitPre runs mid-close, so schedule the quit for after the current close.
				return vim.schedule(quit_session)
			end

			-- `:q` in the last file window: hide the chat and let nvim finish the quit.
			if not opts().close_with_last_file or not is_ordinary_win(current) then
				return
			end
			local chats, ordinary = survey()
			if #chats == 0 or #ordinary > 1 then
				return
			end
			stand_down(chats)
		end,
	})
end

return M
