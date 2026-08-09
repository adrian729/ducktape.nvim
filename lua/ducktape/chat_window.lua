-- The chat as a window rather than as a conversation: what the rest of the session does when the
-- chat is the last thing standing, and how to get out of it with the keyboard.
--
-- The chat is a sidecar to the file it was opened next to. Nvim has no way to know that — to it the
-- chat window is an ordinary window — so closing the file leaves a session that is nothing but
-- chat. That state cannot even be toggled away: codecompanion hides the chat with `:hide`, and
-- `:hide` on the last window is E444. What follows gives the chat the lifetime it should have had.

local M = {}

local api = vim.api

---@return table
local function opts()
	return require("ducktape.config").get().chat or {}
end

---Is this buffer one of codecompanion's chats?
---
---Asked of codecompanion rather than of the filetype, because a buffer can wear `codecompanion`
---without being a chat — the debug window and the action palette both do. The filetype stays as a
---fallback for the window between `nvim_buf_set_option` and the chat registering itself.
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

---A window holding something the session exists for: a file, a terminal, anything that is not a
---chat. Floats are not counted — a picker, or one of this plugin's own panels, is not what keeps a
---session alive, and counting them would make a dismissed picker read as the last file going away.
---@param win number
---@return boolean
local function is_ordinary_win(win)
	return api.nvim_win_is_valid(win)
		and api.nvim_win_get_config(win).relative == ""
		and not is_chat_buf(api.nvim_win_get_buf(win))
end

---Every live window across every tab, split into the chats and the ones the session exists for.
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

---Set while this module is the one quitting, so the QuitPre our own `:quitall` fires does not come
---back round here and start a second one.
local quitting = false

---Take the session down, the way `:q` in the last file window would have.
local function quit_session()
	if quitting then
		return
	end
	quitting = true
	local ok, err = pcall(vim.cmd, "quitall")
	quitting = false
	if not ok then
		-- `:qall` refuses on an unsaved buffer, and that refusal is the right answer — it is the
		-- one `:q` would have given. Say why, because the chat window staying put otherwise looks
		-- like this simply did not fire.
		require("ducktape.ui").say(
			("[ducktape] only the chat is left, but the session will not quit: %s"):format(
				(tostring(err):gsub("^.-:%s*", ""))
			),
			vim.log.levels.WARN
		)
	end
end

---What the layout says should become of the chat now that a file window has gone. Separated from
---the acting on it so a suite can ask the question without quitting the session that asked.
---@return "quit"|"orphaned"|nil verdict, number[] orphans Chat windows in a tab with no files left
function M.verdict()
	local chats, ordinary = survey()
	if #chats == 0 then
		return nil, {}
	end
	if #ordinary == 0 then
		return "quit", {}
	end
	-- Files are still open, just not in this tab. Emptying one tab is the same rule applied
	-- locally, and beats quitting a session whose other tabs are still being worked in.
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

---A file window has gone. If the chat is all that is left, it goes too.
local function reap()
	local verdict, orphans = M.verdict()
	if verdict == "quit" then
		return quit_session()
	end
	for _, win in ipairs(orphans) do
		-- Hide rather than close: the conversation survives, and `<leader>cc` brings it back.
		pcall(api.nvim_win_hide, win)
	end
end

---Would closing this window leave nvim with nothing? The question codecompanion's `:hide` does not
---ask before raising E444.
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

---The window `<C-w>p` would go to when that is a file window, and the first file window in the tab
---otherwise.
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

---Jump between the chat and the file. From the chat it goes back to where you came from; from
---anywhere else it puts the cursor in the chat, opening it first if it was hidden.
---
---`<C-w>h` / `<C-w>l` / `<C-w>p` do the first half of this already, since the chat is a plain
---split. This exists for the second half: one key that reaches the chat whether or not it is on
---screen, and comes back from it.
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

---Register the lifetime rules. Called from `ducktape.setup`, so a session that never sets the
---plugin up is left exactly as nvim shipped it.
function M.setup()
	local group = api.nvim_create_augroup("DucktapeChatWindow", { clear = true })

	-- WinClosed rather than QuitPre: a file window can go by `:q`, `<C-w>c`, `:close`, `:bd` or a
	-- plugin, and only WinClosed sees all of them. It fires with the window still in the list, so
	-- the survey waits a tick for the layout the user is actually left with.
	api.nvim_create_autocmd("WinClosed", {
		group = group,
		callback = function(args)
			if not opts().close_with_last_file then
				return
			end
			local closing = tonumber(args.match)
			-- Only a file window closing can strand the chat. Without this, a picker float
			-- dismissed over a chat-only layout would count as the last file going away.
			if not closing or not is_ordinary_win(closing) then
				return
			end
			vim.schedule(reap)
		end,
	})

	-- `:q` in the chat. The chat has a show/hide of its own on `<leader>cc`, so `:q` is free to
	-- mean there what it means in a file window: quit.
	api.nvim_create_autocmd("QuitPre", {
		group = group,
		callback = function(args)
			if quitting or not opts().quit_closes_session then
				return
			end
			-- QuitPre also fires per window on `:qall`, where the buffer it names need not be the
			-- focused one. Requiring both keeps this to a `:q` typed in the chat.
			if api.nvim_get_current_buf() ~= args.buf or not is_chat_buf(args.buf) then
				return
			end
			-- After the window this `:q` is already closing rather than instead of it: quitting
			-- from inside QuitPre runs while nvim is mid-close.
			vim.schedule(quit_session)
		end,
	})
end

return M
