-- Range marking, one-edit-per-region, and the edit guard on lines with a request in flight.
local pass, fail = 0, 0
local REPORT = "/tmp/inline_guard.out"
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
-- This suite stubs `ducktape.inline.http`, which only the ollama provider routes through — pinned
-- explicitly rather than relying on the shipped default, which is opencode's relay.
require("ducktape.providers").set_provider("inline", "ollama")
local ui = require("ducktape.ui")

local notes, recorded = {}, {}
require("ducktape.ui").say = function(msg, _, opts)
	table.insert(notes, tostring(msg))
	table.insert(recorded, not (opts ~= nil and opts.history == false))
end
local function last_note()
	return notes[#notes] or ""
end

local function target(name, lines)
	local buf = api.nvim_create_buf(true, false)
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	api.nvim_buf_set_name(buf, name)
	vim.bo[buf].filetype = "lua"
	api.nvim_set_current_buf(buf)
	return buf
end

local NS = api.nvim_get_namespaces()["ducktape_ui"]

---Every ducktape_ui extmark on a buffer, with details.
local function marks_on(bufnr)
	return api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })
end

local function header_of(bufnr)
	for _, m in ipairs(marks_on(bufnr)) do
		if m[4] and m[4].virt_lines then
			local text = {}
			for _, chunk in ipairs(m[4].virt_lines[1]) do
				table.insert(text, chunk[1])
			end
			return { row = m[2], above = m[4].virt_lines_above, text = table.concat(text) }
		end
	end
end

local function tint_of(bufnr)
	for _, m in ipairs(marks_on(bufnr)) do
		if m[4] and m[4].hl_group == "DucktapeInlineRange" then
			return { row = m[2], end_row = m[4].end_row, hl_eol = m[4].hl_eol }
		end
	end
end

local function drain(bufnr)
	for _, entry in ipairs(inline.list()) do
		if not bufnr or entry.bufnr == bufnr then
			if entry.kind == "request" then
				inline.cancel_request(entry.request)
			else
				inline.reject(entry.bufnr, entry.diff)
			end
		end
	end
	vim.wait(100)
end

say("\n=== a multiline range is marked over its whole extent ===")

local buf = target("marked.lua", { "one", "two", "three", "four", "five" })
inline.submit({ bufnr = buf, range = { s0 = 1, e0 = 4, has_selection = true }, instruction = "rewrite the middle" })

local head = header_of(buf)
ok(head ~= nil, "the progress label is a line of its own")
ok(head and head.row == 1, "placed on the range's first row", head and head.row)
ok(head and head.above == true, "and above it, not below", head and head.above)
ok(head and head.text:find("rewrite the middle", 1, true) ~= nil, "it says what was asked", head and head.text)
ok(head and head.text:find("3 lines", 1, true) ~= nil, "and how many lines are in play", head and head.text)

local tint = tint_of(buf)
ok(tint ~= nil, "the range itself is tinted")
ok(
	tint and tint.row == 1 and tint.end_row == 3,
	"over exactly the selected rows",
	tint and (tint.row .. ".." .. tint.end_row)
)
ok(tint and tint.hl_eol == true, "as a block rather than a ragged edge", tint and tint.hl_eol)

say("\n=== the marks follow edits above them ===")

api.nvim_buf_set_lines(buf, 0, 0, false, { "inserted" })
vim.wait(150)
head, tint = header_of(buf), tint_of(buf)
ok(head and head.row == 2, "the label moved down with the range", head and head.row)
ok(tint and tint.row == 2 and tint.end_row == 4, "so did the tint", tint and (tint.row .. ".." .. tint.end_row))
ok(#api.nvim_buf_get_lines(buf, 0, -1, false) == 6, "and the edit above was left alone", nil)

say("\n=== an insertion point says so, and is not tinted ===")

drain(buf)
local point = target("point.lua", { "a = 1", "b = 2" })
inline.submit({ bufnr = point, range = { s0 = 1, e0 = 1, has_selection = false }, instruction = "add c" })
head, tint = header_of(point), tint_of(point)
ok(head and head.text:find("insert", 1, true) ~= nil, "the label reads insert", head and head.text)
ok(tint == nil, "nothing is tinted, because nothing was selected")

say("\n=== a caller marking a point keeps end-of-line text (the chat spinner) ===")

local chat = target("chat_like.lua", { "x", "y" })
local spinner = ui.progress(chat, function()
	return 1
end, "thinking…")
vim.wait(50)
ok(header_of(chat) == nil, "no line is added above")
local eol
for _, m in ipairs(marks_on(chat)) do
	if m[4] and m[4].virt_text then
		eol = m[4].virt_text[1][1]
	end
end
ok(eol ~= nil and eol:find("thinking…", 1, true) ~= nil, "the label is end-of-line text", eol)
spinner.stop()

say("\n=== one edit per region ===")

drain()
local one = target("one.lua", { "l1", "l2", "l3", "l4", "l5", "l6" })
local first = inline.submit({ bufnr = one, range = { s0 = 1, e0 = 4, has_selection = true }, instruction = "first" })
ok(first ~= nil, "the first request started")

notes = {}
local clash =
	inline.submit({ bufnr = one, range = { s0 = 3, e0 = 5, has_selection = true }, instruction = "overlaps by one" })
ok(clash == nil, "an overlapping request is refused")
ok(last_note():find("lines 2%-4") ~= nil, "naming the lines already taken", last_note())
ok(last_note():find("first", 1, true) ~= nil, "and what is running on them", last_note())
ok(last_note():find("<leader>cx", 1, true) ~= nil, "and how to get rid of it", last_note())

notes = {}
local inside =
	inline.submit({ bufnr = one, range = { s0 = 2, e0 = 3, has_selection = true }, instruction = "wholly inside" })
ok(inside == nil, "so is one wholly inside it")

notes = {}
local point_inside =
	inline.submit({ bufnr = one, range = { s0 = 2, e0 = 2, has_selection = false }, instruction = "insert inside" })
ok(point_inside == nil, "and an insertion point on one of its lines")

notes = {}
local after =
	inline.submit({ bufnr = one, range = { s0 = 4, e0 = 6, has_selection = true }, instruction = "the lines below" })
ok(after ~= nil, "an adjacent range is allowed", last_note())
ok(#inline.list() == 2, "two in flight in the same buffer", #inline.list())

local elsewhere = target("elsewhere.lua", { "l1", "l2", "l3" })
ok(
	inline.submit({ bufnr = elsewhere, range = { s0 = 1, e0 = 3, has_selection = true }, instruction = "other buffer" })
		~= nil,
	"the same rows in another buffer are fine"
)

say("\n=== a pending diff holds its lines too ===")

drain()
local settled = target("settled.lua", { "return {", "  a = 1,", "}" })
inline.submit({ bufnr = settled, range = { s0 = 1, e0 = 2, has_selection = true }, instruction = "add b" })
captured[#captured].on_done("```lua\n  a = 1,\n  b = 2,\n```")
vim.wait(150)
local pending = inline.list()
ok(#pending == 1 and pending[1].kind == "diff", "the reply is waiting on a decision", pending[1] and pending[1].kind)

notes = {}
local over_diff =
	inline.submit({ bufnr = settled, range = { s0 = 1, e0 = 3, has_selection = true }, instruction = "another go" })
ok(over_diff == nil, "a request over it is refused")
ok(last_note():find("waiting on you", 1, true) ~= nil, "saying it is waiting on you", last_note())
ok(last_note():find("g2", 1, true) ~= nil, "and which keys settle it", last_note())
drain()

say("\n=== edits on lines with a request in flight ===")

local held = target("held.lua", { "keep0", "hold1", "hold2", "hold3", "keep4" })
local original = api.nvim_buf_get_lines(held, 0, -1, false)
inline.submit({ bufnr = held, range = { s0 = 1, e0 = 4, has_selection = true }, instruction = "rewrite the block" })

notes = {}
api.nvim_buf_set_lines(held, 2, 3, false, { "TYPED OVER" })
vim.wait(150)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(held, 0, -1, false), original),
	"a line replaced inside the range is put back",
	vim.inspect(api.nvim_buf_get_lines(held, 0, -1, false))
)
ok(last_note():find("put those lines back", 1, true) ~= nil, "and the user is told what happened", last_note())
ok(last_note():find("<leader>cx", 1, true) ~= nil, "and how to get the lines released", last_note())

notes = {}
api.nvim_buf_set_lines(held, 2, 2, false, { "inserted into the middle" })
vim.wait(150)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(held, 0, -1, false), original),
	"so is a line inserted into it",
	vim.inspect(api.nvim_buf_get_lines(held, 0, -1, false))
)

-- An insertion at the range's top edge is the same position as one below the line above it, and
-- the guarded lines come through untouched either way, so it is left alone rather than reverted.
notes = {}
api.nvim_buf_set_lines(held, 1, 1, false, { "inserted at the top edge" })
vim.wait(150)
ok(
	api.nvim_buf_get_lines(held, 1, 2, false)[1] == "inserted at the top edge",
	"a line inserted at the range's top edge stays",
	vim.inspect(api.nvim_buf_get_lines(held, 0, -1, false))
)
ok(inline.list()[1].resolve() == 2, "the range moved down onto its own lines", inline.list()[1].resolve())
ok(
	vim.deep_equal(api.nvim_buf_get_lines(held, 2, 5, false), { "hold1", "hold2", "hold3" }),
	"which are intact",
	vim.inspect(api.nvim_buf_get_lines(held, 2, 5, false))
)
api.nvim_buf_set_lines(held, 1, 2, false, {})
vim.wait(150)

notes = {}
api.nvim_buf_set_lines(held, 0, 1, false, { "changed" })
vim.wait(150)
ok(
	api.nvim_buf_get_lines(held, 0, 1, false)[1] == "changed",
	"an edit above the range is left alone",
	api.nvim_buf_get_lines(held, 0, 1, false)[1]
)
ok(#notes == 0, "and says nothing", vim.inspect(notes))
ok(
	vim.deep_equal(api.nvim_buf_get_lines(held, 1, 4, false), { "hold1", "hold2", "hold3" }),
	"with the range still intact",
	vim.inspect(api.nvim_buf_get_lines(held, 1, 4, false))
)

-- The other half of the same anchoring bug: a right-gravity end mark is pushed *down* by an edit
-- on the line below, so the range grew over it and the guard reverted an edit it did not own.
notes = {}
api.nvim_buf_set_lines(held, 4, 5, false, { "changed below" })
vim.wait(150)
ok(
	api.nvim_buf_get_lines(held, 4, 5, false)[1] == "changed below",
	"an edit below the range is left alone too",
	vim.inspect(api.nvim_buf_get_lines(held, 0, -1, false))
)
ok(#notes == 0, "also silently", vim.inspect(notes))
ok(
	vim.deep_equal(api.nvim_buf_get_lines(held, 1, 4, false), { "hold1", "hold2", "hold3" }),
	"and the range is still exactly its own lines",
	vim.inspect(api.nvim_buf_get_lines(held, 1, 4, false))
)

say("\n=== the whole range deleted ===")

notes = {}
api.nvim_buf_set_lines(held, 1, 4, false, {})
vim.wait(150)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(held, 1, 4, false), { "hold1", "hold2", "hold3" }),
	"the deleted lines come straight back",
	vim.inspect(api.nvim_buf_get_lines(held, 0, -1, false))
)
local entry = inline.list()[1]
ok(entry ~= nil and entry.resolve() == 1, "and the request is re-anchored to them", entry and entry.resolve())
ok(#inline.list() == 1, "it was not cancelled", #inline.list())

-- Re-anchored means the answer still lands: the whole point of putting the lines back.
captured[#captured].on_done("```lua\nrewritten1\nrewritten2\nrewritten3\n```")
vim.wait(200)
ok(
	#inline.list() == 1 and inline.list()[1].kind == "diff",
	"its reply arrives as a diff",
	inline.list()[1] and inline.list()[1].kind
)
inline.accept(held, inline.list()[1].diff)
vim.wait(150)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(held, 1, 4, false), { "rewritten1", "rewritten2", "rewritten3" }),
	"over the right lines",
	vim.inspect(api.nvim_buf_get_lines(held, 0, -1, false))
)

say("\n=== a one-line range, replaced wholesale ===")

drain()
-- The case no extmark configuration gets right: the range is entirely its own first line, so
-- every edit to it replaces the row the start mark sits on.
local one_line = target("one_line.lua", { "a", "b", "c", "d" })
inline.submit({ bufnr = one_line, range = { s0 = 1, e0 = 2, has_selection = true }, instruction = "just this line" })
notes = {}
api.nvim_buf_set_lines(one_line, 1, 2, false, { "TYPED" })
vim.wait(150)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(one_line, 0, -1, false), { "a", "b", "c", "d" }),
	"the line goes back where it was, and nothing is inserted",
	vim.inspect(api.nvim_buf_get_lines(one_line, 0, -1, false))
)
ok(inline.list()[1].resolve() == 1, "still anchored to it", inline.list()[1].resolve())

-- Again, after a benign edit above has shifted it: the row has to stay exact across both.
api.nvim_buf_set_lines(one_line, 0, 1, false, { "a1", "a2", "a3" })
vim.wait(150)
ok(inline.list()[1].resolve() == 3, "shifted by an edit above", inline.list()[1].resolve())
notes = {}
api.nvim_buf_set_lines(one_line, 3, 4, false, { "TYPED AGAIN" })
vim.wait(150)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(one_line, 0, -1, false), { "a1", "a2", "a3", "b", "c", "d" }),
	"and still restored exactly, with the edit above kept",
	vim.inspect(api.nvim_buf_get_lines(one_line, 0, -1, false))
)

say("\n=== a whole multi-line range replaced in one go ===")

drain()
local whole = target("whole.lua", { "w0", "w1", "w2", "w3", "w4" })
inline.submit({ bufnr = whole, range = { s0 = 1, e0 = 4, has_selection = true }, instruction = "all three" })
notes = {}
api.nvim_buf_set_lines(whole, 1, 4, false, { "ONE LINE NOW" })
vim.wait(150)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(whole, 0, -1, false), { "w0", "w1", "w2", "w3", "w4" }),
	"all three come back",
	vim.inspect(api.nvim_buf_get_lines(whole, 0, -1, false))
)
ok(
	#inline.list() == 1 and inline.list()[1].resolve() == 1,
	"and it is still anchored",
	inline.list()[1] and inline.list()[1].resolve()
)

say("\n=== a line inserted between the guarded lines ===")

notes = {}
api.nvim_buf_set_lines(whole, 2, 2, false, { "WEDGED IN" })
vim.wait(150)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(whole, 0, -1, false), { "w0", "w1", "w2", "w3", "w4" }),
	"the run of lines is put back",
	vim.inspect(api.nvim_buf_get_lines(whole, 0, -1, false))
)
-- The same request warned about a moment ago. Still said — a second attempt answered with nothing
-- is what confusion is — but not recorded again, since the guard can fire once per keystroke and
-- would otherwise bury every other message.
ok(#notes == 1, "the warning is repeated on screen", vim.inspect(notes))
ok(recorded[#recorded] == false, "but not written to :messages twice", vim.inspect(recorded))

vim.wait(2100)
notes = {}
api.nvim_buf_set_lines(whole, 2, 3, false, { "AGAIN" })
vim.wait(150)
ok(
	last_note():find("put those lines back", 1, true) ~= nil,
	"it speaks again once two seconds have passed",
	last_note()
)
ok(recorded[#recorded] == true, "and records that one", vim.inspect(recorded))
ok(
	vim.deep_equal(api.nvim_buf_get_lines(whole, 0, -1, false), { "w0", "w1", "w2", "w3", "w4" }),
	"having restored the lines either way",
	vim.inspect(api.nvim_buf_get_lines(whole, 0, -1, false))
)

say("\n=== a change that sweeps past the range cancels the request ===")

notes = {}
-- Rows 0-4 replaced: the range's own lines plus the ones either side. Only the range's former text
-- is known, so guessing at the rest would be worse than stopping.
api.nvim_buf_set_lines(whole, 0, 5, false, { "SWEPT" })
vim.wait(200)
ok(#inline.list() == 0, "the request was cancelled", #inline.list())
ok(last_note():find("spanned an inline request", 1, true) ~= nil, "saying why", last_note())
ok(
	vim.deep_equal(api.nvim_buf_get_lines(whole, 0, -1, false), { "SWEPT" }),
	"and the user's change was left alone",
	vim.inspect(api.nvim_buf_get_lines(whole, 0, -1, false))
)

say("\n=== two guarded requests, an edit on each ===")

drain()
local two = target("two.lua", { "t0", "t1", "t2", "t3", "t4", "t5" })
inline.submit({ bufnr = two, range = { s0 = 0, e0 = 2, has_selection = true }, instruction = "upper" })
inline.submit({ bufnr = two, range = { s0 = 4, e0 = 6, has_selection = true }, instruction = "lower" })
ok(#inline.list() == 2, "both guarded", #inline.list())

notes = {}
api.nvim_buf_set_lines(two, 4, 5, false, { "LOWER TOUCHED" })
vim.wait(150)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(two, 0, -1, false), { "t0", "t1", "t2", "t3", "t4", "t5" }),
	"the lower one is restored",
	vim.inspect(api.nvim_buf_get_lines(two, 0, -1, false))
)
notes = {}
api.nvim_buf_set_lines(two, 0, 1, false, { "UPPER TOUCHED" })
vim.wait(150)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(two, 0, -1, false), { "t0", "t1", "t2", "t3", "t4", "t5" }),
	"and so is the upper one",
	vim.inspect(api.nvim_buf_get_lines(two, 0, -1, false))
)
ok(#inline.list() == 2, "with both still in flight", #inline.list())
-- An edit between them touches neither.
notes = {}
api.nvim_buf_set_lines(two, 2, 4, false, { "FREE", "TO", "EDIT" })
vim.wait(150)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(two, 0, -1, false), { "t0", "t1", "FREE", "TO", "EDIT", "t4", "t5" }),
	"an edit between them stands",
	vim.inspect(api.nvim_buf_get_lines(two, 0, -1, false))
)
ok(#notes == 0, "silently", vim.inspect(notes))
ok(inline.list()[2].resolve() == 5, "and the lower one moved with it", inline.list()[2].resolve())

say("\n=== a diff settled next to a guarded request ===")

drain()
local both = target("both.lua", { "a1", "a2", "b1", "b2", "tail" })
inline.submit({ bufnr = both, range = { s0 = 0, e0 = 2, has_selection = true }, instruction = "first block" })
local first_cb = captured[#captured]
inline.submit({ bufnr = both, range = { s0 = 2, e0 = 4, has_selection = true }, instruction = "second block" })

-- Three lines where there were two, so everything below shifts under the second request's feet.
first_cb.on_done("```lua\nA1\nA2\nA3\n```")
vim.wait(200)
local waiting
for _, e in ipairs(inline.list()) do
	if e.kind == "diff" then
		waiting = e
	end
end
ok(waiting ~= nil, "the first request landed as a diff")

notes = {}
inline.accept(both, waiting and waiting.diff)
vim.wait(200)
ok(#notes == 0, "accepting it does not trip the guard next door", vim.inspect(notes))
local left = inline.list()
ok(#left == 1 and left[1].kind == "request", "the second request is still in flight", #left)
ok(left[1] and left[1].resolve() == 3, "re-anchored past the lines the diff added", left[1] and left[1].resolve())
ok(
	vim.deep_equal(api.nvim_buf_get_lines(both, 0, -1, false), { "A1", "A2", "A3", "b1", "b2", "tail" }),
	"and the buffer holds both blocks",
	vim.inspect(api.nvim_buf_get_lines(both, 0, -1, false))
)

say("\n=== insert mode inside a protected range ===")

drain()
local typing = target("typing.lua", { "t0", "t1", "t2", "t3" })
inline.submit({ bufnr = typing, range = { s0 = 1, e0 = 3, has_selection = true }, instruction = "no typing here" })

-- Driven by the autocmd rather than by a keypress, because headless nvim cannot enter insert mode
-- at all: startinsert, nvim_input("i") and feedkeys all leave mode() == "n" with no UI attached, so
-- the InsertEnter handler would never run. That the scheduled stopinsert actually leaves insert mode
-- — it does nothing when called straight from InsertEnter — is verified interactively instead.
notes = {}
api.nvim_win_set_cursor(0, { 2, 0 })
api.nvim_exec_autocmds("InsertEnter", { buffer = typing })
vim.wait(120)
ok(
	last_note():find("held by an inline request", 1, true) ~= nil,
	"entering insert on a held line is refused",
	last_note()
)
ok(recorded[#recorded] == true, "and the refusal is recorded", vim.inspect(recorded))

notes = {}
api.nvim_win_set_cursor(0, { 4, 0 })
api.nvim_exec_autocmds("InsertEnter", { buffer = typing })
vim.wait(120)
ok(#notes == 0, "but not on a line outside the range", vim.inspect(notes))

say("\n=== undo is held off while lines are held ===")

drain()
local undone = target("undoing.lua", { "u0", "u1", "u2", "u3" })
-- A buffer-local `u` of someone else's, to check the lock gives it back rather than eating it.
local mine, redone = 0, 0
vim.keymap.set("n", "u", function()
	mine = mine + 1
end, { buffer = undone })
-- Reported by nvim as `<C-R>`, which is the case the keycode comparison exists for.
vim.keymap.set("n", "<C-r>", function()
	redone = redone + 1
end, { buffer = undone })

local function mapping_for(bufnr, lhs)
	for _, m in ipairs(api.nvim_buf_get_keymap(bufnr, "n")) do
		if m.lhs == lhs then
			return m
		end
	end
end

inline.submit({ bufnr = undone, range = { s0 = 1, e0 = 3, has_selection = true }, instruction = "hold these" })

local before = api.nvim_buf_get_lines(undone, 0, -1, false)
for _, key in ipairs({ "u", "U", "<C-R>", "g-", "g+" }) do
	local m = mapping_for(undone, key)
	ok(
		m ~= nil and m.desc ~= nil and m.desc:find("inline request") ~= nil,
		key .. " is taken over while lines are held",
		m and m.desc
	)
	notes = {}
	if m and m.callback then
		m.callback()
	end
	vim.wait(60)
	ok(last_note():find("undo is held off", 1, true) ~= nil, "and says why when pressed", last_note())
end
ok(mine == 0, "the mapping it replaced did not run", mine)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(undone, 0, -1, false), before),
	"and nothing moved",
	vim.inspect(api.nvim_buf_get_lines(undone, 0, -1, false))
)

-- Undo is the one edit the guard cannot answer: a step of it can take the whole run of lines away,
-- which used to cancel the request outright. Measured before the lock: two `u` presses did it.
drain()
local back = mapping_for(undone, "u")
ok(
	back ~= nil and (back.desc == nil or back.desc:find("inline request") == nil),
	"the lock comes off with the request",
	back and back.desc
)
if back and back.callback then
	back.callback()
end
ok(mine == 1, "handing the key back to whoever had it", mine)
local redo_back = mapping_for(undone, "<C-R>")
ok(redo_back ~= nil, "including one written in the other case")
if redo_back and redo_back.callback then
	redo_back.callback()
end
ok(redone == 1, "which still runs what it used to", redone)
for _, key in ipairs({ "U", "g-", "g+" }) do
	ok(mapping_for(undone, key) == nil, key .. " is unmapped again")
end
pcall(vim.keymap.del, "n", "u", { buffer = undone })
pcall(vim.keymap.del, "n", "<C-r>", { buffer = undone })

say("\n=== nothing in flight, nothing guarded ===")

drain()
notes = {}
api.nvim_buf_set_lines(typing, 1, 3, false, { "free", "to", "edit" })
vim.wait(150)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(typing, 0, -1, false), { "t0", "free", "to", "edit", "t3" }),
	"once the request is gone the lines are editable again",
	vim.inspect(api.nvim_buf_get_lines(typing, 0, -1, false))
)
ok(#notes == 0, "silently", vim.inspect(notes))

say("\n=== the marks go when the request does ===")

local cleared = target("cleared.lua", { "c0", "c1", "c2" })
inline.submit({ bufnr = cleared, range = { s0 = 0, e0 = 2, has_selection = true }, instruction = "mark me" })
ok(header_of(cleared) ~= nil and tint_of(cleared) ~= nil, "marked while in flight")
drain()
vim.wait(200)
ok(header_of(cleared) == nil, "the label is gone once cancelled")
ok(tint_of(cleared) == nil, "and so is the tint")

say(("\n%d passed, %d failed\n"):format(pass, fail))
flush()
vim.cmd("qa!")
