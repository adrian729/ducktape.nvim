-- ducktape.chat_window: the chat is a sidecar that does not outlive the last file window.
-- Closing that file used to leave a chat-only session, and toggling it away raised E444 from
-- codecompanion's `:hide`. `verdict()` is asserted instead of letting it quit the test nvim.

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

---A stand-in chat buffer. `is_chat_buf` falls back to filetype for unregistered buffers.
---@return number
local function chat_buf()
	local buf = api.nvim_create_buf(false, true)
	vim.bo[buf].filetype = "codecompanion"
	return buf
end

---Reset to one tab with one ordinary window.
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
-- --noplugin means the plugin script has to be sourced explicitly, as test_wiring does.
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

-- A float over a chat-only layout must not count as a file still being there.
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

reset()
api.nvim_win_set_buf(0, chat_buf())
vim.cmd("tabnew")
vim.bo.filetype = "text"
-- Another tab holds files, so the emptied tab goes, not the session.
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
vim.cmd("enew")
api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved" })
ok(#window.report().unsaved > 0, "names buffers that would have nvim refuse the quit")
vim.bo.modified = false
reset()

section("QuitPre stands the chat down")
-- `nvim_exec_autocmds` runs the handler without the `:q`, so the decision can be asserted safely.
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
-- It must stay away even when the `:q` is refused; restoring it moved the cursor into the chat.
vim.wait(100, function()
	return false
end)
eq("and stays away when the quit does not happen", #vim.fn.win_findbuf(cbuf), 0)
eq("leaving only the file window", #api.nvim_tabpage_list_wins(0), 1)

-- Hide rather than quit so `:q`, `:q!`, and `:wq` on unsaved files behave normally.
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
-- `:hide` raises E444 with a float open because a float cannot be the only window left either.
eq("a float does not save it from E444", window.is_last_window(only), true)
api.nvim_win_close(over, true)

reset()
