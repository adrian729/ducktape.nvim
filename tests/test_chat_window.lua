-- ducktape.chat_window: the chat's lifetime as a window.
--
-- The bug this exists for: closing the file the chat was opened next to used to leave a session
-- that was nothing but chat, and toggling that chat away raised `E444: Cannot close last window`
-- from inside codecompanion's `:hide`. The rule is that the chat is a sidecar — it does not outlive
-- the last file, and it does not keep a session alive on its own.
--
-- `verdict()` is asserted rather than the quitting it drives, because a suite that let the rule
-- fire would be quitting the nvim running it. The end-to-end paths (`:q` in a file window, `:q` in
-- the chat) are driven against a real chat by hand; what is mechanised here is the decision.

local REPORT = "/tmp/chat_window.out"
local passed, failed, lines = 0, 0, {}
local function flush()
	local f = io.open(REPORT, "w")
	f:write(table.concat(lines, "\n"), "\n\n", ("%d passed, %d failed\n"):format(passed, failed))
	f:close()
end
local function section(t)
	table.insert(lines, "\n=== " .. t .. " ===")
end
local function ok(cond, what, detail)
	if cond then
		passed = passed + 1
		table.insert(lines, "  ok   " .. what)
	else
		failed = failed + 1
		table.insert(lines, "  FAIL " .. what .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
	end
	flush()
end
local function eq(what, got, want)
	ok(got == want, what, ("got %q want %q"):format(tostring(got), tostring(want)))
end

require("codecompanion").setup({ extensions = { ducktape = { opts = {} } } })
local window = require("ducktape.chat_window")
local api = vim.api

---A stand-in chat: `is_chat_buf` falls back to the filetype for a buffer codecompanion has not
---registered, which is exactly what this is. Creating a real one would need a live agent.
---@return number
local function chat_buf()
	local buf = api.nvim_create_buf(false, true)
	vim.bo[buf].filetype = "codecompanion"
	return buf
end

---Back to one tab holding one ordinary window, whatever the previous case left behind.
local function reset()
	vim.cmd("silent! tabonly")
	vim.cmd("silent! only")
	vim.cmd("enew")
	vim.bo.filetype = "text"
end

section("registered")
local group = api.nvim_get_autocmds({ group = "DucktapeChatWindow" })
local events = {}
for _, au in ipairs(group) do
	events[au.event] = true
end
ok(events.WinClosed, "WinClosed is watched")
ok(events.QuitPre, "QuitPre is watched")

section("defaults")
local cfg = require("ducktape.config").get().chat
eq("close_with_last_file", cfg.close_with_last_file, true)
eq("quit_closes_session", cfg.quit_closes_session, true)
eq("chat_focus key", require("ducktape.keys").lhs("chat_focus"), "<leader>cf")
-- The suite runs under --noplugin, so the plugin script has to be asked for by name, the way
-- test_wiring does.
vim.cmd("runtime plugin/ducktape.lua")
ok(vim.fn.maparg("<Plug>(DucktapeChatFocus)", "n") ~= "", "<Plug>(DucktapeChatFocus) exists")
ok(vim.fn.maparg("<leader>cf", "n") ~= "", "<leader>cf is bound")

section("verdict")
reset()
eq("no chat, nothing to decide", (window.verdict()), nil)

reset()
vim.cmd("vsplit")
api.nvim_win_set_buf(0, chat_buf())
eq("chat beside a file: leave it", (window.verdict()), nil)

reset()
api.nvim_win_set_buf(0, chat_buf())
eq("chat alone: quit", (window.verdict()), "quit")

-- A float is not what a session exists for, so one open over a chat-only layout must not read as
-- a file still being there.
reset()
api.nvim_win_set_buf(0, chat_buf())
local float = api.nvim_open_win(api.nvim_create_buf(false, true), false, {
	relative = "editor",
	row = 1,
	col = 1,
	width = 10,
	height = 3,
})
eq("a float does not count as a file", (window.verdict()), "quit")
api.nvim_win_close(float, true)

-- Another tab still holds files, so the emptied tab is what goes, not the session.
reset()
api.nvim_win_set_buf(0, chat_buf())
vim.cmd("tabnew")
vim.bo.filetype = "text"
local verdict, orphans = window.verdict()
eq("chat alone in its tab, files in another", verdict, "orphaned")
eq("and one window is named", #orphans, 1)

section("report, for :checkhealth")
reset()
local report = window.report()
ok(report.registered, "reports the autocmds as registered")
eq("counts the chats on screen", report.chats, 0)
vim.cmd("vsplit")
api.nvim_win_set_buf(0, chat_buf())
eq("and again with one up", window.report().chats, 1)
reset()
-- The unsaved list is what explains a `:q` that was refused rather than ignored.
vim.cmd("enew")
api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved" })
ok(#window.report().unsaved > 0, "names buffers that would have nvim refuse the quit")
vim.bo.modified = false
reset()

section("QuitPre stands the chat down")
-- `nvim_exec_autocmds` runs the handler without running the `:q` behind it, so the decision can be
-- asserted from inside the session it would otherwise have quit.
local function fire_quitpre()
	api.nvim_exec_autocmds("QuitPre", { buffer = api.nvim_get_current_buf() })
end

reset()
local file = api.nvim_get_current_win()
vim.cmd("vsplit")
local cbuf = chat_buf()
api.nvim_win_set_buf(0, cbuf)
api.nvim_set_current_win(file)
fire_quitpre()
eq("the last file window: chat is put away", #vim.fn.win_findbuf(cbuf), 0)
ok(api.nvim_buf_is_valid(cbuf), "and its buffer survives, so VimLeavePre can still save it")
-- It must stay away even though the `:q` behind this never ran, which is the refused-quit case.
-- Restoring it was tried and reverted: reopening a chat focuses it, which left a refused `:q` with
-- the cursor in the chat instead of in the file it was refused over.
vim.wait(100, function()
	return false
end)
eq("and stays away when the quit does not happen", #vim.fn.win_findbuf(cbuf), 0)
eq("leaving only the file window", #api.nvim_tabpage_list_wins(0), 1)

-- The reason this is hidden rather than quit: `:q` over an unsaved file is refused, `:q!` is not,
-- `:wq` writes first. Standing the chat down leaves every one of those to nvim.
reset()
vim.cmd("vsplit")
local second = api.nvim_get_current_win()
vim.cmd("vsplit")
local kept = chat_buf()
api.nvim_win_set_buf(0, kept)
api.nvim_set_current_win(second)
fire_quitpre()
eq("another file still open: chat stays", #vim.fn.win_findbuf(kept), 1)

section("is_last_window")
reset()
eq("the only window is the last one", window.is_last_window(api.nvim_get_current_win()), true)
local alone = api.nvim_get_current_win()
vim.cmd("vsplit")
eq("not once there are two", window.is_last_window(alone), false)
reset()
local only = api.nvim_get_current_win()
local over = api.nvim_open_win(api.nvim_create_buf(false, true), false, {
	relative = "editor",
	row = 1,
	col = 1,
	width = 10,
	height = 3,
})
-- The predicate behind the toggle guard: `:hide` raises E444 with a float open, because a float
-- cannot be the only window left either.
eq("a float does not save it from E444", window.is_last_window(only), true)
api.nvim_win_close(over, true)

reset()
