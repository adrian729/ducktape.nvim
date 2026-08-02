-- Edge cases for ducktape.inline.list: narrow windows, deleted ranges, keys on the wrong row,
-- teardown, and more entries than fit.
local pass, fail = 0, 0
local REPORT = "/tmp/inline_edges.out"
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
		say(("  FAIL %s%s"):format(what, detail and ("  → " .. tostring(detail)) or ""))
	end
end

pcall(function()
	require("lazy").load({ plugins = { "codecompanion.nvim", "plenary.nvim" } })
end)

local captured = { cancels = 0 }
package.loaded["ducktape.inline.http"] = {
	send = function(_, cb)
		table.insert(captured, cb)
		return {
			cancel = function()
				captured.cancels = captured.cancels + 1
			end,
		}
	end,
}

local api = vim.api
local inline = require("ducktape.inline")
local list = require("ducktape.inline.list")

-- Every notification, so guidance given instead of a wrong action can be checked.
local notes = {}
require("ducktape.ui").say = function(msg)
	table.insert(notes, tostring(msg))
end

local function target(name, lines)
	local buf = api.nvim_create_buf(true, false)
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	api.nvim_buf_set_name(buf, name)
	vim.bo[buf].filetype = "lua"
	api.nvim_set_current_buf(buf)
	return buf
end

local function press(bufnr, lhs)
	for _, m in ipairs(api.nvim_buf_get_keymap(bufnr, "n")) do
		if m.lhs == lhs and m.callback then
			return m.callback()
		end
	end
	error("no mapping for " .. lhs)
end

local function float()
	for _, win in ipairs(api.nvim_list_wins()) do
		local cfg = api.nvim_win_get_config(win)
		if cfg.relative ~= "" then
			return win, api.nvim_win_get_buf(win), cfg
		end
	end
end

local function widest_row(buf)
	local w = 0
	for _, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
		w = math.max(w, vim.fn.strdisplaywidth(line))
	end
	return w
end

say("\n=== narrow terminals ===")

for _, columns in ipairs({ 120, 80, 60, 40, 24 }) do
	vim.o.columns = columns
	local buf = target(("narrow_%d.lua"):format(columns), { "x = 1", "y = 2" })
	inline.submit({
		bufnr = buf,
		range = { s0 = 0, e0 = 1, has_selection = true },
		instruction = "rename x to something considerably longer than the window",
	})
	list.open()
	local _, lbuf, cfg = float()
	if not cfg then
		ok(false, ("columns=%d: the list opened"):format(columns))
	else
		ok(
			widest_row(lbuf) <= cfg.width,
			("columns=%d: no row overflows the window"):format(columns),
			("%d > %d"):format(widest_row(lbuf), cfg.width)
		)
		ok(
			cfg.width <= columns - 4,
			("columns=%d: the window fits the screen"):format(columns),
			("%d > %d"):format(cfg.width, columns - 4)
		)
		local footer = type(cfg.footer) == "table" and cfg.footer[1][1] or tostring(cfg.footer)
		ok(
			vim.fn.strdisplaywidth(footer) <= cfg.width,
			("columns=%d: the footer is not clipped"):format(columns),
			("%q is %d wide, window is %d"):format(footer, vim.fn.strdisplaywidth(footer), cfg.width)
		)
		local title = type(cfg.title) == "table" and cfg.title[1][1] or tostring(cfg.title)
		ok(
			vim.fn.strdisplaywidth(title) <= cfg.width,
			("columns=%d: the title is not clipped"):format(columns),
			("%q is %d wide, window is %d"):format(title, vim.fn.strdisplaywidth(title), cfg.width)
		)
		press(lbuf, "q")
	end
	press = press -- keep luacheck quiet
	inline.cancel_all_everywhere = nil
	for _, entry in ipairs(inline.list()) do
		inline.cancel_request(entry.request)
	end
end
vim.o.columns = 120

say("\n=== a range deleted under a running request ===")

local buf = target("gone.lua", { "keep = 0", "doomed = 1", "doomed = 2", "keep = 3" })
inline.submit({ bufnr = buf, range = { s0 = 1, e0 = 3, has_selection = true }, instruction = "fix these" })
api.nvim_buf_set_lines(buf, 1, 3, false, {})
vim.wait(150)
-- The guard puts them back rather than letting the request lose its anchor, so "range gone" is
-- no longer a state the list can be caught in for more than a tick.
local entries = inline.list()
ok(#entries == 1 and entries[1].resolve() == 1, "the range is put back and still anchored", entries[1].resolve())
ok(
	vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), { "keep = 0", "doomed = 1", "doomed = 2", "keep = 3" }),
	"with the buffer as it was",
	vim.inspect(api.nvim_buf_get_lines(buf, 0, -1, false))
)
list.open()
local _, lbuf = float()
ok(
	api.nvim_buf_get_lines(lbuf, 0, -1, false)[1]:find("gone.lua:2", 1, true) ~= nil,
	"and the row pointing at it",
	api.nvim_buf_get_lines(lbuf, 0, -1, false)[1]
)

say("\n=== keys on a row they do not apply to ===")

notes = {}
press(lbuf, "a")
ok(
	#notes == 1 and notes[1]:find("still running", 1, true) ~= nil,
	"accept on a running request explains itself",
	notes[1]
)
ok(#inline.list() == 1, "and settled nothing", #inline.list())
-- g3 is an alias for discard, not for a reject that no longer exists, so on a running row it
-- cancels rather than explaining itself.
notes = {}
press(lbuf, "g3")
ok(#notes == 1 and notes[1]:find("cancelled", 1, true) ~= nil, "g3 discards, cancelling the request", notes[1])
ok(#inline.list() == 0, "which did settle it", #inline.list())
press(lbuf, "q")

say("\n=== teardown ===")

inline.submit({ bufnr = buf, range = { s0 = 1, e0 = 3, has_selection = true }, instruction = "something to list" })
vim.cmd("split")
local other = api.nvim_list_wins()[1]
list.open()
ok(list.is_open(), "reopened")
api.nvim_set_current_win(other)
vim.wait(200)
ok(not list.is_open(), "leaving the window closed it")
-- If the redraw timer had outlived the window, this is where it would throw.
vim.wait(300)
ok(true, "and the redraw timer went with it")

for _, entry in ipairs(inline.list()) do
	inline.cancel_request(entry.request)
end

say("\n=== more entries than fit on screen ===")

local many = target("many.lua", { unpack(vim.fn["repeat"]({ "line" }, 60)) })
for i = 1, 40 do
	inline.submit({
		bufnr = many,
		range = { s0 = i, e0 = i + 1, has_selection = true },
		instruction = ("edit number %d"):format(i),
	})
end
ok(#inline.list() == 40, "forty in flight", #inline.list())
list.open()
local win, lbuf2, cfg = float()
ok(cfg ~= nil and cfg.height <= vim.o.lines - 6, "the window is capped to the screen", cfg and cfg.height)
ok(#api.nvim_buf_get_lines(lbuf2, 0, -1, false) == 40, "every entry is still a row, scrolled", nil)
-- The cursor has to be able to reach a row past the window's height.
for _ = 1, 39 do
	press(lbuf2, "j")
end
ok(api.nvim_win_get_cursor(win)[1] == 40, "j reaches the last row", api.nvim_win_get_cursor(win)[1])
press(lbuf2, "j")
ok(api.nvim_win_get_cursor(win)[1] == 1, "and wraps round to the first", api.nvim_win_get_cursor(win)[1])
notes = {}
press(lbuf2, "X")
ok(#inline.list() == 0, "X cleared all forty", #inline.list())
ok(notes[1] and notes[1]:find("40", 1, true) ~= nil, "and said how many", notes[1])
press(lbuf2, "q")

say("\n=== the terminal shrinking under an open list ===")

vim.o.columns = 200
vim.o.lines = 40
local shrink = target("shrink.lua", { "a = 1", "b = 2" })
inline.submit({
	bufnr = shrink,
	range = { s0 = 0, e0 = 1, has_selection = true },
	instruction = "a long instruction so the window opens wide enough to matter",
})
list.open()
local _, sbuf, scfg = float()
ok(scfg.width > 60, "opened wide", scfg.width)
vim.o.columns = 50
vim.o.lines = 12
vim.wait(250)
ok(list.is_open(), "a resize does not close the list")
local swin, sbuf2, scfg2 = float()
ok(scfg2 ~= nil and scfg2.width <= 46, "narrowed to fit the new screen", scfg2 and scfg2.width)
ok(scfg2 ~= nil and scfg2.row + scfg2.height + 3 <= vim.o.lines, "and moved back onto it", scfg2 and scfg2.row)
ok(widest_row(sbuf2) <= scfg2.width, "rows still fit", ("%d > %d"):format(widest_row(sbuf2), scfg2.width))
press(sbuf2, "X")
press(sbuf2, "q")
vim.o.columns = 120
vim.o.lines = 40

say("\n=== the keys live under ? rather than on the border ===")

if list.is_open() then
	list.close()
end
local hbuf = target("helped.lua", { "h0", "h1", "h2" })
inline.submit({ bufnr = hbuf, range = { s0 = 1, e0 = 2, has_selection = true }, instruction = "short" })
list.open()
local hwin, hlistbuf, hcfg = float()
local hfooter = hcfg and type(hcfg.footer) == "table" and hcfg.footer[1][1] or tostring(hcfg and hcfg.footer)
-- The footer used to spell out all six keys, which cost 94 cells and, since the window is sized to
-- fit its footer, made every list at least 96 wide — wider than its own rows need.
ok(
	vim.fn.strdisplaywidth(hfooter) <= 43,
	"the footer is short enough not to set the width",
	("%d: %s"):format(vim.fn.strdisplaywidth(hfooter), hfooter)
)
ok(hfooter:find("? keys", 1, true) ~= nil, "and points at ?", hfooter)

local function overlay()
	for _, w in ipairs(api.nvim_list_wins()) do
		local cfg = api.nvim_win_get_config(w)
		if cfg.relative ~= "" and w ~= hwin then
			return w, api.nvim_win_get_buf(w), cfg
		end
	end
end

ok(overlay() == nil, "nothing is up before ? is pressed")
press(hlistbuf, "?")
local owin, obuf, ocfg = overlay()
ok(owin ~= nil, "? opens the overlay")
local otext = obuf and table.concat(api.nvim_buf_get_lines(obuf, 0, -1, false), "\n") or ""
for _, needle in ipairs({ "<CR>", "accept every diff", "still running", "j k" }) do
	ok(otext:find(needle, 1, true) ~= nil, ("it lists %q"):format(needle))
end
ok(ocfg ~= nil and ocfg.focusable == false, "unfocusable, so keys keep reaching the list", ocfg and ocfg.focusable)
ok(list.is_open(), "and the list is still up behind it")

press(hlistbuf, "?")
ok(overlay() == nil, "? closes it again")
press(hlistbuf, "?")
press(hlistbuf, "q")
ok(overlay() == nil and list.is_open(), "q dismisses the overlay first, keeping the list")
press(hlistbuf, "q")
ok(not list.is_open(), "and closes the list on the next press")

-- Closing the list has to take the overlay with it: it is a float of its own, so nothing else would.
list.open()
local hlistbuf2 = select(2, float())
press(hlistbuf2, "?")
ok(overlay() ~= nil, "with the overlay up again")
list.close()
ok(overlay() == nil, "closing the list takes the overlay with it")
for _, entry in ipairs(inline.list()) do
	if entry.kind == "request" then
		inline.cancel_request(entry.request)
	else
		inline.reject(entry.bufnr, entry.diff)
	end
end
vim.wait(100)

say("\n=== the list opens with nothing in it ===")

if list.is_open() then
	list.close()
end
for _, entry in ipairs(inline.list()) do
	if entry.kind == "request" then
		inline.cancel_request(entry.request)
	else
		inline.reject(entry.bufnr, entry.diff)
	end
end
vim.wait(100)
ok(#inline.list() == 0, "with nothing in play anywhere", #inline.list())

notes = {}
list.open()
local ewin, ebuf, ecfg = float()
-- The point of the change: answering a keypress with a command-line message reads as "nothing
-- happened". The window is where the answer was expected, so the window opens and says it.
ok(ewin ~= nil, "the window still opens")
ok(#notes == 0, "instead of a message on the command line", vim.inspect(notes))
local body = ebuf and api.nvim_buf_get_lines(ebuf, 0, -1, false) or {}
ok(#body == 1 and body[1]:find("nothing in flight", 1, true) ~= nil, "saying so in the body", vim.inspect(body))
local etitle = ecfg and type(ecfg.title) == "table" and ecfg.title[1][1] or tostring(ecfg and ecfg.title)
ok(etitle:find("settled", 1, true) ~= nil, "and in the title", etitle)
ok(ecfg ~= nil and ecfg.height == 1, "one row tall, not an empty box", ecfg and ecfg.height)

-- Every key, on a list with no row under the cursor
for _, key in ipairs({ "j", "k", "a", "r", "x", "A", "R", "X", "g2", "g3", "<CR>" }) do
	local pressed = pcall(press, ebuf, key)
	ok(pressed, ("pressing %q on an empty list is harmless"):format(key))
end
ok(list.is_open(), "and none of them closed it")
press(ebuf, "q")
ok(not list.is_open(), "q still closes it")

say(("\n%d passed, %d failed\n"):format(pass, fail))
flush()
vim.cmd("qa!")
