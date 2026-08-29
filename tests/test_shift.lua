-- Editing above an in-flight inline request moves its target; the reply lands there and the cursor stays put.
local pass, fail = 0, 0
local REPORT = "/tmp/inline_shift.out"
local log_lines = {}
local function flush()
	local f = io.open(REPORT, "w")
	f:write(table.concat(log_lines, "\n") .. "\n")
	f:close()
end
local function say(s)
	table.insert(log_lines, tostring(s))
	flush()
end
local function ok(cond, what, detail)
	if cond then
		pass = pass + 1
		say(("  ok   %s"):format(what))
	else
		fail = fail + 1
		say(("  FAIL %s%s"):format(what, detail ~= nil and ("  → " .. tostring(detail)) or ""))
	end
end

pcall(function()
	require("lazy").load({ plugins = { "codecompanion.nvim", "plenary.nvim" } })
end)

local captured = {}
package.loaded["ducktape.inline.http"] = {
	send = function(_, cb)
		table.insert(captured, cb)
		return { cancel = function() end }
	end,
}

local api = vim.api
local inline = require("ducktape.inline")
-- Stub ducktape.inline.http, which only the ollama provider routes through; pin it explicitly.
require("ducktape.providers").set_provider("inline", "ollama")

local notes = {}
require("ducktape.ui").say = function(msg)
	table.insert(notes, tostring(msg))
end

vim.o.columns = 160
vim.o.lines = 40

---A 40-line file where every line names its own number, so a shift is unmistakable.
local function numbered(name)
	local lines = {}
	for i = 1, 40 do
		table.insert(lines, ("line %d"):format(i))
	end
	local buf = api.nvim_create_buf(true, false)
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	api.nvim_buf_set_name(buf, name)
	vim.bo[buf].filetype = "lua"
	api.nvim_set_current_buf(buf)
	return buf
end

local function drain()
	for _, e in ipairs(inline.list()) do
		if e.kind == "request" then
			inline.cancel_request(e.request)
		else
			inline.reject(e.bufnr, e.diff)
		end
	end
	vim.wait(200)
end

say("\n=== a selection on line 20, then five lines added above it ===")

local buf = numbered("shift.lua")
inline.submit({
	bufnr = buf,
	range = { s0 = 19, e0 = 20, has_selection = true },
	instruction = "rewrite line 20",
})
local entry = inline.list()[1]
ok(entry.resolve() == 19, "anchored to row 19 to begin with", entry.resolve())

api.nvim_buf_set_lines(buf, 4, 4, false, { "added a", "added b", "added c", "added d", "added e" })
vim.wait(150)
ok(
	#api.nvim_buf_get_lines(buf, 0, -1, false) == 45,
	"the buffer grew by five",
	#api.nvim_buf_get_lines(buf, 0, -1, false)
)
ok(entry.resolve() == 24, "the request followed its line down", entry.resolve())
ok(
	api.nvim_buf_get_lines(buf, 24, 25, false)[1] == "line 20",
	"which is still the line the user picked",
	api.nvim_buf_get_lines(buf, 24, 25, false)[1]
)

captured[#captured].on_done("```lua\nREWRITTEN\n```")
vim.wait(250)
local diff = inline.list()[1]
ok(diff and diff.kind == "diff", "the reply arrived", diff and diff.kind)
inline.accept(buf, diff.diff)
vim.wait(200)
ok(
	api.nvim_buf_get_lines(buf, 24, 25, false)[1] == "REWRITTEN",
	"the edit landed on the line as it had moved to",
	api.nvim_buf_get_lines(buf, 24, 25, false)[1]
)
ok(
	api.nvim_buf_get_lines(buf, 19, 20, false)[1] == "line 15",
	"and not on the row it was originally on",
	api.nvim_buf_get_lines(buf, 19, 20, false)[1]
)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(buf, 4, 9, false), { "added a", "added b", "added c", "added d", "added e" }),
	"with the lines added above untouched",
	vim.inspect(api.nvim_buf_get_lines(buf, 4, 9, false))
)

say("\n=== lines deleted above ===")

drain()
local up = numbered("up.lua")
inline.submit({ bufnr = up, range = { s0 = 19, e0 = 21, has_selection = true }, instruction = "two lines" })
local up_entry = inline.list()[1]
api.nvim_buf_set_lines(up, 2, 5, false, {})
vim.wait(150)
ok(up_entry.resolve() == 16, "the request moved up by three", up_entry.resolve())
captured[#captured].on_done("```lua\nA\nB\n```")
vim.wait(250)
inline.accept(up, inline.list()[1].diff)
vim.wait(200)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(up, 16, 18, false), { "A", "B" }),
	"and the edit landed where it had moved to",
	vim.inspect(api.nvim_buf_get_lines(up, 14, 20, false))
)

say("\n=== an insertion point, with lines added above ===")

drain()
local ins = numbered("insert.lua")
inline.submit({ bufnr = ins, range = { s0 = 19, e0 = 19, has_selection = false }, instruction = "insert here" })
local ins_entry = inline.list()[1]
api.nvim_buf_set_lines(ins, 0, 0, false, { "new first line" })
vim.wait(150)
ok(ins_entry.resolve() == 20, "the insertion point moved down one", ins_entry.resolve())
captured[#captured].on_done("```lua\nINSERTED\n```")
vim.wait(250)
inline.accept(ins, inline.list()[1].diff)
vim.wait(200)
ok(
	api.nvim_buf_get_lines(ins, 20, 21, false)[1] == "INSERTED",
	"and the text went in there",
	vim.inspect(api.nvim_buf_get_lines(ins, 18, 23, false))
)
ok(
	api.nvim_buf_get_lines(ins, 21, 22, false)[1] == "line 20",
	"pushing the line it was anchored above down",
	api.nvim_buf_get_lines(ins, 21, 22, false)[1]
)

say("\n=== the cursor stays put when a reply lands ===")

drain()
local work = numbered("working.lua")
local win = api.nvim_get_current_win()
inline.submit({ bufnr = work, range = { s0 = 29, e0 = 31, has_selection = true }, instruction = "far away" })

api.nvim_win_set_cursor(win, { 3, 4 })
vim.cmd("normal! zt")
local before_cursor = api.nvim_win_get_cursor(win)
local before_view = api.nvim_win_call(win, vim.fn.winsaveview)

captured[#captured].on_done("```lua\nX\nY\nZ\n```")
vim.wait(400) -- past DiffUI's own scheduled scroll

local after_cursor = api.nvim_win_get_cursor(win)
ok(
	after_cursor[1] == before_cursor[1] and after_cursor[2] == before_cursor[2],
	"the cursor did not move",
	("was %d,%d now %d,%d"):format(before_cursor[1], before_cursor[2], after_cursor[1], after_cursor[2])
)
local after_view = api.nvim_win_call(win, vim.fn.winsaveview)
ok(
	after_view.topline == before_view.topline,
	"and the window did not scroll",
	("was %d now %d"):format(before_view.topline, after_view.topline)
)

say("\n=== the cursor keeps its text when the diff lands above it ===")

drain()
local above = numbered("above.lua")
win = api.nvim_get_current_win()
inline.submit({ bufnr = above, range = { s0 = 4, e0 = 6, has_selection = true }, instruction = "grow above the cursor" })
api.nvim_win_set_cursor(win, { 20, 0 })
local text_under_cursor = api.nvim_buf_get_lines(above, 19, 20, false)[1]
captured[#captured].on_done("```lua\nP\nQ\nR\nS\n```")
vim.wait(400)
local row = api.nvim_win_get_cursor(win)[1]
ok(
	api.nvim_buf_get_lines(above, row - 1, row, false)[1] == text_under_cursor,
	"the cursor is still on the same text, wherever that line now is",
	("expected %q, cursor row %d holds %q"):format(
		text_under_cursor,
		row,
		api.nvim_buf_get_lines(above, row - 1, row, false)[1] or ""
	)
)

say("\n=== a stale prompt is the one thing editing above does affect ===")

-- The prompt is built when the request is sent, so later edits are invisible to the model.
drain()
local stale = numbered("stale.lua")
local sent = {}
package.loaded["ducktape.inline.http"] = {
	send = function(opts, cb)
		table.insert(sent, opts.prompt)
		table.insert(captured, cb)
		return { cancel = function() end }
	end,
}
package.loaded["ducktape.inline"] = nil
inline = require("ducktape.inline")
inline.submit({ bufnr = stale, range = { s0 = 19, e0 = 20, has_selection = true }, instruction = "x" })
api.nvim_buf_set_lines(stale, 18, 19, false, { "CHANGED BEFORE THE REPLY" })
vim.wait(150)
ok(
	sent[1] ~= nil and sent[1]:find("line 19", 1, true) ~= nil,
	"the prompt still holds the old surrounding line",
	sent[1] and "yes"
)
ok(
	sent[1] ~= nil and sent[1]:find("CHANGED BEFORE THE REPLY", 1, true) == nil,
	"and cannot know about the edit made after it was sent"
)

say(("\n%d passed, %d failed\n"):format(pass, fail))
flush()
vim.cmd("qa!")
