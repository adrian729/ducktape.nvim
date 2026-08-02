-- Replies that cannot be applied: prose and failures are registered rather than thrown at the
-- screen, marked in the buffer, listed, retryable, and counted in the statusline.
local pass, fail = 0, 0
local REPORT = "/tmp/inline_waiting.out"
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

local api = vim.api

local sent = {}
package.loaded["ducktape.inline.http"] = {
	send = function(opts, cb)
		table.insert(sent, { prompt = opts.prompt, cb = cb })
		return { cancel = function() end }
	end,
}
-- The prompt float, stubbed so `e` can be driven and its pre-filled text inspected.
local prompts = {}
package.loaded["codecompanion.interactions.shared.input"] = {
	open = function(opts)
		table.insert(prompts, { title = opts.title, initial = opts.initial_content, on_submit = opts.on_submit })
	end,
}
-- Chat hand-off, stubbed: opening a real chat needs an adapter.
local chats = {}
package.loaded["ducktape.chat"] = {
	open_with_context = function(o)
		table.insert(chats, o)
	end,
	stop = function() end,
}

package.loaded["ducktape.inline"] = nil
local inline = require("ducktape.inline")
local list = require("ducktape.inline.list")
local statusline = require("ducktape.statusline")

local notes = {}
require("ducktape.ui").say = function(msg)
	table.insert(notes, tostring(msg))
end
local function last_note()
	return notes[#notes] or ""
end

vim.o.columns = 170
vim.o.lines = 40

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

local function float_win()
	for _, win in ipairs(api.nvim_list_wins()) do
		if api.nvim_win_get_config(win).relative ~= "" then
			return win, api.nvim_win_get_buf(win)
		end
	end
end

local function drain()
	for _, e in ipairs(inline.list()) do
		if e.kind == "request" then
			inline.cancel_request(e.request)
		elseif e.kind == "diff" then
			inline.reject(e.bufnr, e.diff)
		else
			inline.dismiss(e.waiting)
		end
	end
	vim.wait(200)
end

local NS = api.nvim_get_namespaces()["ducktape_ui"]
local function marks_on(bufnr)
	local signs, labels, tints = {}, {}, {}
	for _, m in ipairs(api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })) do
		local d = m[4] or {}
		if d.sign_text then
			table.insert(signs, { row = m[2], text = vim.trim(d.sign_text), hl = d.sign_hl_group })
		end
		if d.virt_lines then
			local t = {}
			for _, chunk in ipairs(d.virt_lines[1]) do
				table.insert(t, chunk[1])
			end
			table.insert(labels, { row = m[2], text = table.concat(t) })
		end
		if d.hl_group == "DucktapeInlineRange" or d.hl_group == "DucktapeInlineWaiting" then
			table.insert(tints, { row = m[2], end_row = d.end_row, hl = d.hl_group })
		end
	end
	return signs, labels, tints
end

say("\n=== a running request is signed as well as labelled ===")

local run = target("running.lua", { "r0", "r1", "r2" })
inline.submit({ bufnr = run, range = { s0 = 0, e0 = 2, has_selection = true }, instruction = "do a thing" })
local signs = marks_on(run)
ok(#signs == 1, "one sign, not one per line", #signs)
ok(
	signs[1] and signs[1].row == 0 and signs[1].text == "↻",
	"on the first row of the range",
	signs[1] and (signs[1].row .. signs[1].text)
)

say("\n=== a prose reply is registered, not floated ===")

notes = {}
sent[#sent].cb.on_done("I can't safely rewrite this without seeing how backoff is defined.")
vim.wait(200)

ok(float_win() == nil, "no float opened over the user's work")
local entries = inline.list()
ok(#entries == 1 and entries[1].kind == "prose", "it is listed as a prose reply", entries[1] and entries[1].kind)
ok(entries[1].resolve() == 0, "anchored where the request was", entries[1].resolve())
ok(entries[1].instruction == "do a thing", "carrying the instruction, for a retry", entries[1].instruction)
ok(last_note():find("<leader>cL", 1, true) ~= nil, "and the notify points at the list", last_note())

local psigns, plabels, ptints = marks_on(run)
ok(#psigns == 1 and psigns[1].text == "◆", "the sign changed to the waiting marker", psigns[1] and psigns[1].text)
ok(psigns[1].hl == "DucktapeListReady", "in the waiting colour", psigns[1] and psigns[1].hl)
ok(
	plabels[1] and plabels[1].text:find("answered", 1, true) ~= nil,
	"the label says answered",
	plabels[1] and plabels[1].text
)
ok(#ptints == 1, "and the range is still tinted", #ptints)
-- Warm while it runs, cool once the reply is parked: the two states are told apart by colour and
-- not only by the label, so a marked range read at a glance says which it is.
ok(ptints[1].hl == "DucktapeInlineWaiting", "in the waiting colour, not the running one", ptints[1].hl)

say("\n=== the statusline says so from anywhere ===")

local rendered = statusline.render()
ok(rendered:find("1◆", 1, true) ~= nil, "the segment counts it", rendered)
ok(rendered:find("DucktapeListReady", 1, true) ~= nil, "with a highlight group", rendered)
-- Rendered through nvim itself, since a bad statusline expression breaks the whole bar.
vim.o.statusline = "%<%f%=%{%v:lua.require'ducktape.statusline'.render()%}%P"
local evaluated = api.nvim_eval_statusline(vim.o.statusline, { winid = 0, maxwidth = 120 })
ok(evaluated.str:find("1◆", 1, true) ~= nil, "and nvim evaluates it without error", evaluated.str)

say("\n=== reading it is what opens the float ===")

list.open()
local lwin, lbuf = float_win()
ok(lbuf ~= nil, "the list opened")
local rows = api.nvim_buf_get_lines(lbuf, 0, -1, false)
ok(rows[1]:find("answered", 1, true) ~= nil, "showing the row as answered", rows[1])
ok(rows[1]:find("<CR> read", 1, true) ~= nil, "and how to read it", rows[1])
local cfg = api.nvim_win_get_config(lwin)
local title = type(cfg.title) == "table" and cfg.title[1][1] or tostring(cfg.title)
ok(title:find("to read", 1, true) ~= nil, "the title counts it separately", title)

press(lbuf, "<CR>")
vim.wait(100)
local rwin, rbuf = float_win()
ok(rwin ~= nil, "a float opened when asked for")
ok(api.nvim_get_current_win() == rwin, "and took focus, because it was asked for")
local body = table.concat(api.nvim_buf_get_lines(rbuf, 0, -1, false), "\n")
ok(body:find("without seeing how backoff", 1, true) ~= nil, "showing the reply", body)
press(rbuf, "q")
vim.wait(50)
ok(#inline.list() == 1, "dismissing the float does not throw the reply away", #inline.list())

say("\n=== a on a prose row takes it into a chat ===")

chats = {}
list.open()
local _, cbuf = float_win()
press(cbuf, "a")
vim.wait(100)
ok(#chats == 1, "a chat was opened with it", #chats)
ok(
	chats[1] and chats[1].messages[1].content:find("do a thing", 1, true) ~= nil,
	"carrying the instruction",
	chats[1] and chats[1].messages[1].content
)
ok(
	chats[1] and chats[1].messages[2].content:find("without seeing how backoff", 1, true) ~= nil,
	"and the reply",
	chats[1] and chats[1].messages[2].content
)
ok(#inline.list() == 0, "and the entry is settled", #inline.list())
ok(#(marks_on(run)) == 0, "with its marks cleared", #(marks_on(run)))

say("\n=== a failed request is kept, not dropped ===")

drain()
local bad = target("failing.lua", { "f0", "f1", "f2" })
inline.submit({ bufnr = bad, range = { s0 = 1, e0 = 2, has_selection = true }, instruction = "the one that breaks" })
notes = {}
sent[#sent].cb.on_error("no opencode-llm on PATH")
vim.wait(200)

entries = inline.list()
ok(#entries == 1 and entries[1].kind == "failed", "it stays in the list as failed", entries[1] and entries[1].kind)
ok(entries[1].resolve() == 1, "with the range still anchored", entries[1].resolve())
ok(last_note():find("retry", 1, true) ~= nil, "and the notify mentions retrying", last_note())
local fsigns = marks_on(bad)
ok(fsigns[1] and fsigns[1].text == "✖", "the sign says it failed", fsigns[1] and fsigns[1].text)

say("\n=== e asks the same thing again ===")

prompts = {}
list.open()
local _, ebuf = float_win()
press(ebuf, "r")
vim.wait(100)
ok(#prompts == 1, "the prompt float opened", #prompts)
ok(prompts[1].initial == "the one that breaks", "pre-filled with the original instruction", prompts[1].initial)
ok(prompts[1].title:find("Ask again", 1, true) ~= nil, "and titled as a retry", prompts[1].title)

local before_sent = #sent
prompts[1].on_submit("the one that breaks")
vim.wait(150)
ok(#sent == before_sent + 1, "a new request went out", #sent - before_sent)
entries = inline.list()
ok(
	#entries == 1 and entries[1].kind == "request",
	"the failed row became a running one",
	entries[1] and entries[1].kind
)
ok(entries[1].resolve() == 1, "over the same lines", entries[1].resolve())
ok(
	sent[#sent].prompt:find("<selection>\nf1\n</selection>", 1, true) ~= nil,
	"asking about the same text",
	sent[#sent].prompt:match("<selection>.-</selection>")
)

-- And a reworded retry sends the new wording.
sent[#sent].cb.on_error("again")
vim.wait(200)
prompts = {}
list.open()
local _, wbuf = float_win()
press(wbuf, "r")
prompts[1].on_submit("try it differently this time")
vim.wait(150)
ok(
	sent[#sent].prompt:find("try it differently this time", 1, true) ~= nil,
	"a reworded retry sends the new wording",
	sent[#sent].prompt:match("Instruction: [^\n]*")
)

say("\n=== r asks again about a diff, rejecting it first ===")

drain()
local dret = target("diff_retry.lua", { "d0", "d1", "d2" })
inline.submit({ bufnr = dret, range = { s0 = 1, e0 = 2, has_selection = true }, instruction = "make it better" })
sent[#sent].cb.on_done("```lua\nWRONG ANSWER\n```")
vim.wait(200)
ok(inline.list()[1].kind == "diff", "a diff is waiting", inline.list()[1] and inline.list()[1].kind)

prompts = {}
list.open()
local _, drbuf = float_win()
press(drbuf, "r")
vim.wait(100)
ok(#prompts == 1, "the prompt opened", #prompts)
ok(prompts[1].initial == "make it better", "pre-filled from the diff's own instruction", prompts[1].initial)

local n_before = #sent
prompts[1].on_submit("make it better, differently")
vim.wait(300)
ok(#sent == n_before + 1, "a new request went out", #sent - n_before)
ok(
	#inline.list() == 1 and inline.list()[1].kind == "request",
	"and it is the only thing in play",
	inline.list()[1] and inline.list()[1].kind
)
-- The rejection has to land before the new prompt is built, or the model is asked about the reply
-- being thrown away instead of the code.
ok(
	sent[#sent].prompt:find("<selection>\nd1\n</selection>", 1, true) ~= nil,
	"asking about the restored original, not the rejected reply",
	sent[#sent].prompt:match("<selection>.-</selection>")
)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(dret, 0, -1, false), { "d0", "d1", "d2" }),
	"with the buffer back as it was",
	vim.inspect(api.nvim_buf_get_lines(dret, 0, -1, false))
)

say("\n=== r asks again about a request still running, cancelling it ===")

local running_entry = inline.list()[1]
ok(running_entry.kind == "request", "one is running", running_entry.kind)
prompts = {}
list.open()
local _, rrbuf = float_win()
press(rrbuf, "r")
vim.wait(100)
ok(
	prompts[1] and prompts[1].initial == "make it better, differently",
	"pre-filled from the running request",
	prompts[1] and prompts[1].initial
)
n_before = #sent
prompts[1].on_submit("third time lucky")
vim.wait(200)
ok(#sent == n_before + 1, "a replacement request went out", #sent - n_before)
ok(#inline.list() == 1, "and only one is in play", #inline.list())
ok(
	inline.list()[1].instruction == "third time lucky",
	"the new one, not the cancelled one",
	inline.list()[1].instruction
)

say("\n=== <leader>cR asks again about whatever the cursor is on ===")

drain()
local ch = target("cursor_retry.lua", { "h0", "h1", "h2", "h3" })
inline.submit({ bufnr = ch, range = { s0 = 2, e0 = 3, has_selection = true }, instruction = "from the buffer" })
sent[#sent].cb.on_error("boom")
vim.wait(200)
api.nvim_win_set_cursor(0, { 3, 0 })
prompts = {}
inline.ask_again_here()
vim.wait(100)
ok(#prompts == 1, "the prompt opened from the buffer key", #prompts)
ok(prompts[1].initial == "from the buffer", "pre-filled", prompts[1].initial)
prompts[1].on_submit("from the buffer")
vim.wait(200)
ok(
	#inline.list() == 1 and inline.list()[1].kind == "request",
	"and a request went out",
	inline.list()[1] and inline.list()[1].kind
)

-- Off the row, with nothing else in the buffer, it still knows what was meant.
drain()
inline.submit({ bufnr = ch, range = { s0 = 0, e0 = 1, has_selection = true }, instruction = "the only one" })
sent[#sent].cb.on_error("boom again")
vim.wait(200)
api.nvim_win_set_cursor(0, { 4, 0 })
prompts = {}
inline.ask_again_here()
ok(
	prompts[1] and prompts[1].initial == "the only one",
	"the only thing in the buffer needs no cursor precision",
	prompts[1] and prompts[1].initial
)

drain()
notes = {}
inline.ask_again_here()
ok(last_note():find("nothing here", 1, true) ~= nil, "and says so when there is nothing", last_note())

say("\n=== bulk keys leave unread replies alone ===")

drain()
local mix = target("mix.lua", { "m0", "m1", "m2", "m3", "m4" })
-- One diff waiting, one prose reply.
inline.submit({ bufnr = mix, range = { s0 = 0, e0 = 1, has_selection = true }, instruction = "becomes a diff" })
sent[#sent].cb.on_done("```lua\nDIFFED\n```")
vim.wait(150)
inline.submit({ bufnr = mix, range = { s0 = 3, e0 = 4, has_selection = true }, instruction = "becomes prose" })
sent[#sent].cb.on_done("I will not change this without seeing the caller.")
vim.wait(200)
local kinds = {}
for _, e in ipairs(inline.list()) do
	kinds[e.kind] = (kinds[e.kind] or 0) + 1
end
ok(kinds.diff == 1 and kinds.prose == 1, "one of each", vim.inspect(kinds))

list.open()
local _, bbuf = float_win()
notes = {}
press(bbuf, "A")
vim.wait(250)
local left = inline.list()
ok(#left == 1 and left[1].kind == "prose", "A settled the diff and spared the reply", left[1] and left[1].kind)
ok(last_note():find("still to read", 1, true) ~= nil, "saying what it left for later", last_note())

-- x on its own row dismisses one.
notes = {}
press(bbuf, "x")
vim.wait(150)
ok(#inline.list() == 0, "x on its own row dismisses it", #inline.list())
ok(last_note():find("dismissed", 1, true) ~= nil, "saying so", last_note())
press(bbuf, "q")

-- And X empties the list outright, unread replies included.
drain()
local xa = target("x_all.lua", { "q0", "q1", "q2", "q3", "q4" })
inline.submit({ bufnr = xa, range = { s0 = 0, e0 = 1, has_selection = true }, instruction = "will diff" })
sent[#sent].cb.on_done("```lua\nDIFFED\n```")
vim.wait(150)
inline.submit({ bufnr = xa, range = { s0 = 2, e0 = 3, has_selection = true }, instruction = "will prose" })
sent[#sent].cb.on_done("I cannot help with that one.")
vim.wait(200)
inline.submit({ bufnr = xa, range = { s0 = 4, e0 = 5, has_selection = true }, instruction = "still going" })
local xkinds = {}
for _, e in ipairs(inline.list()) do
	xkinds[e.kind] = (xkinds[e.kind] or 0) + 1
end
ok(xkinds.diff == 1 and xkinds.prose == 1 and xkinds.request == 1, "one of each in play", vim.inspect(xkinds))

list.open()
local _, xbuf = float_win()
notes = {}
press(xbuf, "X")
vim.wait(300)
ok(#inline.list() == 0, "X emptied the list, unread reply included", #inline.list())
ok(last_note():find("cancelled 1 request", 1, true) ~= nil, "reporting the cancellation", last_note())
ok(last_note():find("rejected 1 diff", 1, true) ~= nil, "the rejection", last_note())
ok(last_note():find("dismissed 1 unread reply", 1, true) ~= nil, "and the dismissal, named as unread", last_note())
ok(
	vim.deep_equal(api.nvim_buf_get_lines(xa, 0, -1, false), { "q0", "q1", "q2", "q3", "q4" }),
	"with the buffer as it started",
	vim.inspect(api.nvim_buf_get_lines(xa, 0, -1, false))
)
ok(#(marks_on(xa)) == 0, "and no marks left behind", #(marks_on(xa)))
press(xbuf, "q")

-- <leader>cX does the same, scoped to the buffer.
drain()
local cxa = target("cx_all.lua", { "z0", "z1", "z2" })
inline.submit({ bufnr = cxa, range = { s0 = 0, e0 = 1, has_selection = true }, instruction = "prose again" })
sent[#sent].cb.on_done("Sorry, I will not do that.")
vim.wait(200)
ok(#inline.list() == 1, "a reply is waiting", #inline.list())
notes = {}
inline.cancel_all()
vim.wait(200)
ok(#inline.list() == 0, "<leader>cX dismissed it too", #inline.list())
ok(last_note():find("dismissed 1 unread reply", 1, true) ~= nil, "and said so", last_note())

say("\n=== asking again over the same lines supersedes the old reply ===")

drain()
local again = target("again.lua", { "a0", "a1", "a2" })
inline.submit({ bufnr = again, range = { s0 = 1, e0 = 2, has_selection = true }, instruction = "first ask" })
sent[#sent].cb.on_done("I cannot do that without more context.")
vim.wait(200)
ok(#inline.list() == 1, "a reply is waiting", #inline.list())
-- A prose reply holds no lines, so a fresh request over them is allowed and replaces it.
notes = {}
local re =
	inline.submit({ bufnr = again, range = { s0 = 1, e0 = 2, has_selection = true }, instruction = "second ask" })
vim.wait(100)
ok(re ~= nil, "a new request over the same lines is allowed", last_note())
entries = inline.list()
ok(
	#entries == 1 and entries[1].kind == "request",
	"and the old reply is gone",
	vim.inspect(vim.tbl_map(function(e)
		return e.kind
	end, entries))
)

say("\n=== <leader>cx dismisses a reply under the cursor ===")

drain()
local cx = target("cx.lua", { "c0", "c1", "c2" })
inline.submit({ bufnr = cx, range = { s0 = 2, e0 = 3, has_selection = true }, instruction = "prose please" })
sent[#sent].cb.on_done("Unfortunately that is ambiguous as written.")
vim.wait(200)
api.nvim_win_set_cursor(0, { 3, 0 })
notes = {}
inline.cancel()
vim.wait(100)
ok(#inline.list() == 0, "dismissed", #inline.list())
ok(last_note():find("dismissed", 1, true) ~= nil, "saying so", last_note())
ok(#(marks_on(cx)) == 0, "and cleared its marks", #(marks_on(cx)))

say("\n=== the buffer going away takes the reply with it ===")

local doomed = target("doomed.lua", { "d0", "d1" })
inline.submit({ bufnr = doomed, range = { s0 = 0, e0 = 1, has_selection = true }, instruction = "orphan" })
sent[#sent].cb.on_done("I am unable to answer that one.")
vim.wait(200)
ok(#inline.list() == 1, "waiting on a buffer", #inline.list())
api.nvim_buf_delete(doomed, { force = true })
vim.wait(200)
ok(#inline.list() == 0, "gone with the buffer", #inline.list())

say("\n=== counts, and an empty segment when there is nothing ===")

drain()
ok(
	statusline.render() == "",
	"the statusline segment is empty when nothing is in play",
	("%q"):format(statusline.render())
)
local counts = inline.counts()
ok(counts.total == 0, "and the counts agree", vim.inspect(counts))

local c1 = target("counts.lua", { "x0", "x1", "x2", "x3", "x4", "x5" })
inline.submit({ bufnr = c1, range = { s0 = 0, e0 = 1, has_selection = true }, instruction = "running" })
inline.submit({ bufnr = c1, range = { s0 = 2, e0 = 3, has_selection = true }, instruction = "will diff" })
sent[#sent].cb.on_done("```lua\nD\n```")
vim.wait(150)
inline.submit({ bufnr = c1, range = { s0 = 4, e0 = 5, has_selection = true }, instruction = "will prose" })
sent[#sent].cb.on_done("Sorry, this needs a decision I cannot make.")
vim.wait(200)
counts = inline.counts()
ok(
	counts.running == 1 and counts.review == 1 and counts.answered == 1 and counts.total == 3,
	"one of each is counted",
	vim.inspect(counts)
)
local seg = statusline.render()
ok(seg:find("1↻", 1, true) and seg:find("1◆", 1, true), "and the segment shows them", seg:gsub("%%#", "#"))
drain()

say(("\n%d passed, %d failed\n"):format(pass, fail))
flush()
vim.cmd("qa!")
