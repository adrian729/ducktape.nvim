-- Bulk settling in buffers and the list; x absorbed reject, r went to ask-again.
local pass, fail = 0, 0
local REPORT = "/tmp/settle_all.out"
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
-- Stub ducktape.inline.http, which only the ollama provider routes through; pin it explicitly.
require("ducktape.providers").set_provider("inline", "ollama")
local list = require("ducktape.inline.list")

local notes = {}
require("ducktape.ui").say = function(msg)
	table.insert(notes, tostring(msg))
end
local function last_note()
	return notes[#notes] or ""
end

-- Two windows so replies to off-screen buffers still land; wide enough that rows are not squeezed.
vim.o.columns = 160
vim.cmd("split")
local win_a, win_b = api.nvim_list_wins()[1], api.nvim_list_wins()[2]

local function target(name, lines, win)
	local buf = api.nvim_create_buf(true, false)
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	api.nvim_buf_set_name(buf, name)
	vim.bo[buf].filetype = "lua"
	api.nvim_win_set_buf(win, buf)
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

local function float_buf()
	for _, win in ipairs(api.nvim_list_wins()) do
		if api.nvim_win_get_config(win).relative ~= "" then
			return api.nvim_win_get_buf(win)
		end
	end
end

---One request per row, answered with `reply_for(i)`, leaving several pending diffs in `buf`.
local function fill(buf, win, rows, reply_for)
	api.nvim_set_current_win(win)
	local cbs = {}
	for _, row in ipairs(rows) do
		inline.submit({
			bufnr = buf,
			range = { s0 = row, e0 = row + 1, has_selection = true },
			instruction = ("edit row %d"):format(row),
		})
		table.insert(cbs, captured[#captured])
	end
	for i, cb in ipairs(cbs) do
		cb.on_done(reply_for(i))
		vim.wait(80)
	end
end

---Leave nothing in play so each section's counts are its own.
local function drain()
	for _, e in ipairs(inline.list()) do
		if e.kind == "request" then
			inline.cancel_request(e.request)
		else
			inline.reject(e.bufnr, e.diff)
		end
	end
	vim.wait(150)
end

local function kinds()
	local req, diff = 0, 0
	for _, e in ipairs(inline.list()) do
		if e.kind == "request" then
			req = req + 1
		else
			diff = diff + 1
		end
	end
	return req, diff
end

say("\n=== accept all in one buffer ===")

local acc = target("accept_all.lua", { "a0", "a1", "a2", "a3" }, win_a)
fill(acc, win_a, { 0, 2, 3 }, function(i)
	return ("```lua\nACCEPTED%d\n```"):format(i)
end)
local _, pending = kinds()
ok(pending == 3, "three diffs waiting in the buffer", pending)

notes = {}
inline.accept_all()
vim.wait(200)
ok(select(2, kinds()) == 0, "accept_all settled every one", select(2, kinds()))
ok(last_note():find("accepted 3", 1, true) ~= nil, "and said how many", last_note())
ok(
	vim.deep_equal(api.nvim_buf_get_lines(acc, 0, -1, false), { "ACCEPTED1", "a1", "ACCEPTED2", "ACCEPTED3" }),
	"each edit landed on its own lines",
	vim.inspect(api.nvim_buf_get_lines(acc, 0, -1, false))
)

say("\n=== reject all in one buffer ===")

local rej = target("reject_all.lua", { "r0", "r1", "r2", "r3" }, win_a)
local before = api.nvim_buf_get_lines(rej, 0, -1, false)
fill(rej, win_a, { 0, 1, 3 }, function(i)
	return ("```lua\nREJECTED%d\n```"):format(i)
end)
ok(select(2, kinds()) == 3, "three diffs waiting again", select(2, kinds()))

notes = {}
inline.reject_all()
vim.wait(300)
ok(select(2, kinds()) == 0, "reject_all settled every one", select(2, kinds()))
ok(last_note():find("rejected 3", 1, true) ~= nil, "and said how many", last_note())
ok(
	vim.deep_equal(api.nvim_buf_get_lines(rej, 0, -1, false), before),
	"every original line came back",
	vim.inspect(api.nvim_buf_get_lines(rej, 0, -1, false))
)

say("\n=== rejecting a mix of one- and multi-line replies ===")

local mix = target("mix.lua", { "m0", "m1", "m2", "m3", "m4" }, win_a)
local mix_before = api.nvim_buf_get_lines(mix, 0, -1, false)
api.nvim_set_current_win(win_a)
-- Row 0 grows to three lines, shifting everything below before the later diffs settle.
inline.submit({ bufnr = mix, range = { s0 = 0, e0 = 1, has_selection = true }, instruction = "grow" })
local grow_cb = captured[#captured]
inline.submit({ bufnr = mix, range = { s0 = 2, e0 = 4, has_selection = true }, instruction = "shrink" })
local shrink_cb = captured[#captured]
grow_cb.on_done("```lua\nG1\nG2\nG3\n```")
vim.wait(100)
shrink_cb.on_done("```lua\nS1\n```")
vim.wait(100)
ok(select(2, kinds()) == 2, "both landed as diffs", select(2, kinds()))

inline.reject_all()
vim.wait(300)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(mix, 0, -1, false), mix_before),
	"the buffer is byte-for-byte what it was",
	vim.inspect(api.nvim_buf_get_lines(mix, 0, -1, false))
)

say("\n=== a request still in flight is left alone ===")

local partial = target("partial.lua", { "p0", "p1", "p2", "p3" }, win_a)
api.nvim_set_current_win(win_a)
inline.submit({ bufnr = partial, range = { s0 = 0, e0 = 1, has_selection = true }, instruction = "answers" })
local answering = captured[#captured]
inline.submit({ bufnr = partial, range = { s0 = 2, e0 = 3, has_selection = true }, instruction = "still going" })
answering.on_done("```lua\nDONE\n```")
vim.wait(150)

notes = {}
inline.accept_all()
vim.wait(200)
local req, diff = kinds()
ok(diff == 0 and req == 1, "the diff settled, the request kept running", ("req=%d diff=%d"):format(req, diff))
ok(last_note():find("accepted 1", 1, true) ~= nil, "counting only what it settled", last_note())
ok(
	api.nvim_buf_get_lines(partial, 0, 1, false)[1] == "DONE",
	"the accepted edit stuck",
	api.nvim_buf_get_lines(partial, 0, 1, false)[1]
)

say("\n=== nothing to settle ===")

drain()
notes = {}
inline.accept_all()
ok(last_note():find("no diffs waiting in this buffer", 1, true) ~= nil, "says so plainly", last_note())

-- A diff in another buffer is reachable, just not from here.
local other = target("other.lua", { "o0", "o1" }, win_b)
fill(other, win_b, { 0 }, function()
	return "```lua\nO\n```"
end)
api.nvim_set_current_win(win_a)
notes = {}
inline.reject_all()
ok(last_note():find("in others", 1, true) ~= nil, "and points at the ones elsewhere", last_note())
ok(last_note():find("<leader>cL", 1, true) ~= nil, "naming the key that reaches them", last_note())
ok(select(2, kinds()) == 1, "without touching them", select(2, kinds()))

say("\n=== A accepts every diff everywhere ===")

local here = target("here.lua", { "h0", "h1" }, win_a)
fill(here, win_a, { 0 }, function()
	return "```lua\nH\n```"
end)
ok(select(2, kinds()) == 2, "one diff in each of two buffers", select(2, kinds()))

list.open()
local lbuf = float_buf()
ok(lbuf ~= nil, "the list opened")
notes = {}
press(lbuf, "A")
vim.wait(250)
ok(select(2, kinds()) == 0, "A settled both, across buffers", select(2, kinds()))
ok(last_note():find("accepted 2", 1, true) ~= nil, "reporting the count", last_note())
ok(
	last_note():find("here.lua", 1, true) ~= nil and last_note():find("other.lua", 1, true) ~= nil,
	"and naming both files, since one was off screen",
	last_note()
)
ok(
	api.nvim_buf_get_lines(here, 0, 1, false)[1] == "H",
	"the focused buffer took its edit",
	api.nvim_buf_get_lines(here, 0, 1, false)[1]
)
ok(
	api.nvim_buf_get_lines(other, 0, 1, false)[1] == "O",
	"so did the other one",
	api.nvim_buf_get_lines(other, 0, 1, false)[1]
)
press(lbuf, "q")

say("\n=== X rejects every diff everywhere, and R is not a bulk key ===")

local r1 = target("r1.lua", { "x0", "x1" }, win_a)
local r2 = target("r2.lua", { "y0", "y1" }, win_b)
fill(r1, win_a, { 0 }, function()
	return "```lua\nNOPE1\n```"
end)
fill(r2, win_b, { 1 }, function()
	return "```lua\nNOPE2\n```"
end)
ok(select(2, kinds()) == 2, "two diffs waiting", select(2, kinds()))

list.open()
lbuf = float_buf()

-- R used to reject everything; now it says so, since silence reads as a dropped keypress.
notes = {}
press(lbuf, "R")
vim.wait(100)
ok(select(2, kinds()) == 2, "R settles nothing", select(2, kinds()))
ok(last_note():find("no ask-again-for-everything", 1, true) ~= nil, "and says why", last_note())

notes = {}
press(lbuf, "X")
vim.wait(300)
ok(select(2, kinds()) == 0, "X settled both", select(2, kinds()))
ok(last_note():find("rejected 2", 1, true) ~= nil, "reporting the count", last_note())
ok(
	vim.deep_equal(api.nvim_buf_get_lines(r1, 0, -1, false), { "x0", "x1" }),
	"the first buffer is back to normal",
	vim.inspect(api.nvim_buf_get_lines(r1, 0, -1, false))
)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(r2, 0, -1, false), { "y0", "y1" }),
	"and so is the second",
	vim.inspect(api.nvim_buf_get_lines(r2, 0, -1, false))
)

say("\n=== A with nothing but running requests ===")

drain()
local running = target("running.lua", { "n0", "n1" }, win_a)
api.nvim_set_current_win(win_a)
inline.submit({ bufnr = running, range = { s0 = 0, e0 = 1, has_selection = true }, instruction = "in flight" })
list.open()
lbuf = float_buf()
notes = {}
press(lbuf, "A")
ok(last_note():find("nothing to settle yet", 1, true) ~= nil, "says nothing is ready", last_note())
ok(last_note():find("1 still running", 1, true) ~= nil, "counting what is still going", last_note())
ok(last_note():find("cancels", 1, true) ~= nil, "and pointing at the key that stops it", last_note())
ok(select(1, kinds()) == 1, "the request was not cancelled", select(1, kinds()))
press(lbuf, "q")

say("\n=== the list stays usable after settling everything ===")

drain()
local left = target("left.lua", { "z0", "z1", "z2" }, win_a)
fill(left, win_a, { 0 }, function()
	return "```lua\nZ\n```"
end)
api.nvim_set_current_win(win_a)
inline.submit({ bufnr = left, range = { s0 = 2, e0 = 3, has_selection = true }, instruction = "keeps going" })
list.open()
lbuf = float_buf()
press(lbuf, "A")
vim.wait(250)
ok(list.is_open(), "the list is still open, with the request left on it")
local rows = api.nvim_buf_get_lines(lbuf, 0, -1, false)
ok(#rows == 1 and rows[1]:find("thinking", 1, true) ~= nil, "showing just the one still running", vim.inspect(rows))
press(lbuf, "q")

say("\n=== x on a finished entry rejects it ===")

drain()
local xd = target("x_diff.lua", { "d0", "d1", "d2" }, win_a)
fill(xd, win_a, { 0 }, function()
	return "```lua\nGONE\n```"
end)
api.nvim_set_current_win(win_a)
inline.submit({ bufnr = xd, range = { s0 = 2, e0 = 3, has_selection = true }, instruction = "still thinking" })
list.open()
lbuf = float_buf()
local rows = api.nvim_buf_get_lines(lbuf, 0, -1, false)
ok(#rows == 2, "a finished row and a running one", #rows)

notes = {}
press(lbuf, "x") -- the cursor starts on the first row, which is the finished one
vim.wait(250)
local xreq, xdiff = kinds()
ok(xdiff == 0, "x rejected the finished one", xdiff)
ok(xreq == 1, "and left the running one alone", xreq)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(xd, 0, -1, false), { "d0", "d1", "d2" }),
	"restoring its original line",
	vim.inspect(api.nvim_buf_get_lines(xd, 0, -1, false))
)
ok(last_note():find("rejected", 1, true) ~= nil, "and saying it rejected rather than cancelled", last_note())

notes = {}
press(lbuf, "x") -- now on the running one
vim.wait(150)
ok(select(1, kinds()) == 0, "x on the running one cancels it", select(1, kinds()))
ok(last_note():find("cancelled", 1, true) ~= nil, "saying so in the other words", last_note())
press(lbuf, "q")

say("\n=== X on a mix cancels the running and rejects the finished ===")

drain()
local mx1 = target("mixed1.lua", { "u0", "u1", "u2", "u3" }, win_a)
local mx2 = target("mixed2.lua", { "v0", "v1", "v2" }, win_b)
-- Two answered, two still going, spread over two buffers.
fill(mx1, win_a, { 0 }, function()
	return "```lua\nX1\n```"
end)
fill(mx2, win_b, { 0 }, function()
	return "```lua\nX2\n```"
end)
api.nvim_set_current_win(win_a)
inline.submit({ bufnr = mx1, range = { s0 = 2, e0 = 3, has_selection = true }, instruction = "running here" })
api.nvim_set_current_win(win_b)
inline.submit({ bufnr = mx2, range = { s0 = 2, e0 = 3, has_selection = true }, instruction = "running there" })
local mreq, mdiff = kinds()
ok(mreq == 2 and mdiff == 2, "two of each in play", ("req=%d diff=%d"):format(mreq, mdiff))

list.open()
lbuf = float_buf()
notes = {}
local cancels_before = captured.cancels
press(lbuf, "X")
vim.wait(300)
ok(select(1, kinds()) == 0 and select(2, kinds()) == 0, "X cleared the list out", ("req=%d diff=%d"):format(kinds()))
ok(captured.cancels == cancels_before + 2, "both transports were told to stop", captured.cancels - cancels_before)
ok(last_note():find("cancelled 2 request", 1, true) ~= nil, "reporting the cancellations", last_note())
ok(last_note():find("rejected 2 diff", 1, true) ~= nil, "and the rejections, in one message", last_note())
ok(
	vim.deep_equal(api.nvim_buf_get_lines(mx1, 0, -1, false), { "u0", "u1", "u2", "u3" }),
	"the first buffer is untouched",
	vim.inspect(api.nvim_buf_get_lines(mx1, 0, -1, false))
)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(mx2, 0, -1, false), { "v0", "v1", "v2" }),
	"and so is the second",
	vim.inspect(api.nvim_buf_get_lines(mx2, 0, -1, false))
)
press(lbuf, "q")

say("\n=== A on a mix takes the finished and leaves the running ===")

for _, action in ipairs({ "A" }) do
	drain()
	local b1 = target(("m_%s_1.lua"):format(action), { "w0", "w1", "w2" }, win_a)
	local b2 = target(("m_%s_2.lua"):format(action), { "s0", "s1", "s2" }, win_b)
	fill(b1, win_a, { 0 }, function()
		return "```lua\nKEEP1\n```"
	end)
	fill(b2, win_b, { 0 }, function()
		return "```lua\nKEEP2\n```"
	end)
	api.nvim_set_current_win(win_a)
	inline.submit({ bufnr = b1, range = { s0 = 2, e0 = 3, has_selection = true }, instruction = "left running" })
	ok(
		select(1, kinds()) == 1 and select(2, kinds()) == 2,
		("%s: one running, two finished"):format(action),
		("req=%d diff=%d"):format(kinds())
	)

	list.open()
	lbuf = float_buf()
	notes = {}
	press(lbuf, action)
	vim.wait(300)
	local areq, adiff = kinds()
	ok(adiff == 0, ("%s: settled both finished ones"):format(action), adiff)
	ok(areq == 1, ("%s: left the running one in flight"):format(action), areq)
	local expected = action == "A" and "KEEP1" or "w0"
	ok(
		api.nvim_buf_get_lines(b1, 0, 1, false)[1] == expected,
		("%s: the first buffer holds what it should"):format(action),
		api.nvim_buf_get_lines(b1, 0, 1, false)[1]
	)
	ok(
		api.nvim_buf_get_lines(b2, 0, 1, false)[1] == (action == "A" and "KEEP2" or "s0"),
		("%s: and so does the off-screen one"):format(action),
		api.nvim_buf_get_lines(b2, 0, 1, false)[1]
	)
	-- The row left behind must still be the running one, and still be usable.
	local left_rows = api.nvim_buf_get_lines(lbuf, 0, -1, false)
	ok(
		#left_rows == 1 and left_rows[1]:find("thinking", 1, true) ~= nil,
		("%s: the list shows just it"):format(action),
		vim.inspect(left_rows)
	)
	press(lbuf, "q")
end

say("\n=== <leader>cx and <leader>cX on a mix ===")

drain()
local bk = target("bufkeys.lua", { "k0", "k1", "k2", "k3" }, win_a)
fill(bk, win_a, { 0 }, function()
	return "```lua\nB1\n```"
end)
api.nvim_set_current_win(win_a)
inline.submit({ bufnr = bk, range = { s0 = 2, e0 = 3, has_selection = true }, instruction = "running" })

-- <leader>cx on a finished edit rejects it, not "nothing in flight".
api.nvim_win_set_cursor(win_a, { 1, 0 })
notes = {}
inline.cancel()
vim.wait(250)
ok(select(2, kinds()) == 0, "<leader>cx on a finished edit rejects it", select(2, kinds()))
ok(last_note():find("rejected", 1, true) ~= nil, "and says so", last_note())
ok(api.nvim_buf_get_lines(bk, 0, 1, false)[1] == "k0", "restoring the line", api.nvim_buf_get_lines(bk, 0, 1, false)[1])
ok(select(1, kinds()) == 1, "the running one is still going", select(1, kinds()))

fill(bk, win_a, { 0 }, function()
	return "```lua\nB2\n```"
end)
ok(select(1, kinds()) == 1 and select(2, kinds()) == 1, "one of each in the buffer", ("req=%d diff=%d"):format(kinds()))
notes = {}
inline.cancel_all()
vim.wait(300)
ok(select(1, kinds()) == 0 and select(2, kinds()) == 0, "<leader>cX cleared both", ("req=%d diff=%d"):format(kinds()))
ok(last_note():find("cancelled 1 request", 1, true) ~= nil, "reporting the cancellation", last_note())
ok(last_note():find("rejected 1 diff", 1, true) ~= nil, "and the rejection", last_note())
ok(
	vim.deep_equal(api.nvim_buf_get_lines(bk, 0, -1, false), { "k0", "k1", "k2", "k3" }),
	"with the buffer as it started",
	vim.inspect(api.nvim_buf_get_lines(bk, 0, -1, false))
)

notes = {}
inline.cancel_all()
ok(last_note():find("nothing in play", 1, true) ~= nil, "and says so when there is nothing left", last_note())

say("\n=== rejecting two adjacent regions at once ===")

drain()
-- Neighbouring diffs used to lose a line when restoring the lower one pushed the upper end mark down.
local adj = target("adjacent.lua", { "j0", "j1", "j2", "j3" }, win_a)
fill(adj, win_a, { 0, 1, 2, 3 }, function(i)
	return ("```lua\nNEW%d\n```"):format(i)
end)
ok(select(2, kinds()) == 4, "four diffs, one per line", select(2, kinds()))
inline.reject_all()
vim.wait(400)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(adj, 0, -1, false), { "j0", "j1", "j2", "j3" }),
	"every line came back, none eaten",
	vim.inspect(api.nvim_buf_get_lines(adj, 0, -1, false))
)

say("\n=== the footer still fits ===")

drain()
for _, columns in ipairs({ 200, 120, 90, 60, 30 }) do
	vim.o.columns = columns
	local f = target(("f_%d.lua"):format(columns), { "q0", "q1" }, win_a)
	api.nvim_set_current_win(win_a)
	inline.submit({ bufnr = f, range = { s0 = 0, e0 = 1, has_selection = true }, instruction = "footer check" })
	list.open()
	local win
	for _, w in ipairs(api.nvim_list_wins()) do
		if api.nvim_win_get_config(w).relative ~= "" then
			win = w
		end
	end
	local cfg = api.nvim_win_get_config(win)
	local footer = type(cfg.footer) == "table" and cfg.footer[1][1] or tostring(cfg.footer)
	ok(
		vim.fn.strdisplaywidth(footer) <= cfg.width,
		("columns=%d: the footer is not clipped"):format(columns),
		("%q is %d wide, window is %d"):format(footer, vim.fn.strdisplaywidth(footer), cfg.width)
	)
	press(api.nvim_win_get_buf(win), "q")
	for _, e in ipairs(inline.list()) do
		inline.cancel_request(e.request)
	end
end
vim.o.columns = 160

say(("\n%d passed, %d failed\n"):format(pass, fail))
flush()
vim.cmd("qa!")
