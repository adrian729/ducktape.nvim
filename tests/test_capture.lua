-- What M.run captures as the range, driven through the real keymap entry point with the input
-- float stubbed out.
local pass, fail = 0, 0
local REPORT = "/tmp/inline_capture.out"
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

-- Both of ducktape.inline's collaborators are captured in locals at load time, so they have to be in
-- place before it is first required.
local sent = {}
package.loaded["ducktape.inline.http"] = {
	send = function(opts, cb)
		table.insert(sent, { prompt = opts.prompt, cb = cb })
		return { cancel = function() end }
	end,
}
local prompts = {}
package.loaded["codecompanion.interactions.shared.input"] = {
	open = function(opts)
		table.insert(prompts, opts.title)
		opts.on_submit("do the thing")
	end,
}

package.loaded["ducktape.inline"] = nil
local inline = require("ducktape.inline")

local notes = {}
require("ducktape.ui").say = function(msg)
	table.insert(notes, tostring(msg))
end

vim.o.columns = 160
vim.o.lines = 40

local function numbered(name, count)
	local lines = {}
	for i = 1, count or 10 do
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

---The <selection> block of the last prompt sent.
local function last_selection()
	local prompt = sent[#sent] and sent[#sent].prompt or ""
	return prompt:match("<selection>\n(.-)\n</selection>")
end

say("\n=== no visual selection: the cursor's line is the selection ===")

local buf = numbered("cursor.lua")
api.nvim_win_set_cursor(0, { 4, 2 })
inline.run(false)
vim.wait(100)

local entry = inline.list()[1]
ok(entry ~= nil, "a request was started")
ok(entry and entry.resolve() == 3, "anchored to the cursor's own row", entry and entry.resolve())
ok(last_selection() == "line 4", "and the prompt's selection is that line", last_selection())
ok(
	sent[#sent].prompt:find("The selected region is empty", 1, true) == nil,
	"so the insert-here instruction is not sent"
)
ok(
	sent[#sent].prompt:find("lines=4-4", 1, true) ~= nil,
	"the file header names the one line",
	sent[#sent].prompt:match("<file[^>]*>")
)

-- It has to behave as a selection in every other respect too: guarded, and marked with an extent.
local NS = api.nvim_get_namespaces()["ducktape_ui"]
local tinted, labelled
for _, m in ipairs(api.nvim_buf_get_extmarks(buf, NS, 0, -1, { details = true })) do
	if m[4] and m[4].hl_group == "DucktapeInlineRange" then
		tinted = m[2]
	end
	if m[4] and m[4].virt_lines then
		labelled = m[4].virt_lines[1][1][1] .. (m[4].virt_lines[1][2] and m[4].virt_lines[1][2][1] or "")
	end
end
ok(tinted == 3, "the line is tinted like any other range", tinted)
ok(labelled and labelled:find("1 line", 1, true) ~= nil, "and the label says one line, not insert", labelled)

notes = {}
api.nvim_buf_set_lines(buf, 3, 4, false, { "typed over it" })
vim.wait(150)
ok(
	api.nvim_buf_get_lines(buf, 3, 4, false)[1] == "line 4",
	"editing it is refused, as with a selection",
	api.nvim_buf_get_lines(buf, 3, 4, false)[1]
)

say("\n=== the reply replaces that line rather than being inserted above it ===")

sent[#sent].cb.on_done("```lua\nREPLACED\n```")
vim.wait(250)
inline.accept(buf, inline.list()[1].diff)
vim.wait(200)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(buf, 2, 5, false), { "line 3", "REPLACED", "line 5" }),
	"one line in, one line out",
	vim.inspect(api.nvim_buf_get_lines(buf, 0, -1, false))
)
ok(
	#api.nvim_buf_get_lines(buf, 0, -1, false) == 10,
	"the buffer did not grow",
	#api.nvim_buf_get_lines(buf, 0, -1, false)
)

say("\n=== a second request on the same line is refused ===")

drain()
local twice = numbered("twice.lua")
api.nvim_win_set_cursor(0, { 6, 0 })
inline.run(false)
vim.wait(100)
ok(#inline.list() == 1, "the first one started", #inline.list())
notes = {}
inline.run(false)
vim.wait(100)
ok(#inline.list() == 1, "the second is refused", #inline.list())
ok(notes[1] and notes[1]:find("line 6", 1, true) ~= nil, "naming the line it is on", notes[1])
ok(#prompts == 2, "and without opening a prompt for it", #prompts)

say("\n=== the last line of the buffer ===")

drain()
local last = numbered("last.lua", 5)
api.nvim_win_set_cursor(0, { 5, 0 })
inline.run(false)
vim.wait(100)
ok(last_selection() == "line 5", "the final line captures as itself", last_selection())
sent[#sent].cb.on_done("```lua\nFINAL\n```")
vim.wait(250)
inline.accept(last, inline.list()[1].diff)
vim.wait(200)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(last, 0, -1, false), { "line 1", "line 2", "line 3", "line 4", "FINAL" }),
	"and is replaced, not appended to",
	vim.inspect(api.nvim_buf_get_lines(last, 0, -1, false))
)

say("\n=== an empty buffer ===")

drain()
local empty = api.nvim_create_buf(true, false)
api.nvim_buf_set_name(empty, "empty.lua")
vim.bo[empty].filetype = "lua"
api.nvim_set_current_buf(empty)
api.nvim_win_set_cursor(0, { 1, 0 })
notes = {}
inline.run(false)
vim.wait(100)
ok(#inline.list() == 1, "a request still starts on an empty buffer", #inline.list())
sent[#sent].cb.on_done("```lua\nFROM NOTHING\n```")
vim.wait(250)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(empty, 0, -1, false), { "FROM NOTHING" }),
	"and its reply lands",
	vim.inspect(api.nvim_buf_get_lines(empty, 0, -1, false))
)

say("\n=== a visual selection is unchanged ===")

drain()
local vis = numbered("visual.lua")
api.nvim_set_current_buf(vis)
api.nvim_win_set_cursor(0, { 3, 0 })
vim.cmd("normal! Vjj")
inline.run(false)
vim.wait(100)
local ventry = inline.list()[1]
ok(ventry ~= nil and ventry.resolve() == 2, "anchored at the top of the selection", ventry and ventry.resolve())
ok(last_selection() == "line 3\nline 4\nline 5", "with all three lines in the prompt", last_selection())

say("\n=== M.submit can still be asked to insert ===")

drain()
local ins = numbered("insert.lua")
inline.submit({ bufnr = ins, range = { s0 = 2, e0 = 2, has_selection = false }, instruction = "insert" })
vim.wait(100)
ok(
	sent[#sent].prompt:find("The selected region is empty", 1, true) ~= nil,
	"the empty-range contract is still there for callers that want it"
)
sent[#sent].cb.on_done("```lua\nADDED\n```")
vim.wait(250)
inline.accept(ins, inline.list()[1].diff)
vim.wait(200)
ok(
	vim.deep_equal(api.nvim_buf_get_lines(ins, 1, 4, false), { "line 2", "ADDED", "line 3" }),
	"and inserts without replacing",
	vim.inspect(api.nvim_buf_get_lines(ins, 0, -1, false))
)

say(("\n%d passed, %d failed\n"):format(pass, fail))
flush()
vim.cmd("qa!")
