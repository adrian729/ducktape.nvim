-- Drives ducktape.inline + ducktape.inline.list headlessly.
local pass, fail = 0, 0
local REPORT = "/tmp/inline_list.out"
local log_lines = {}
local function flush()
	local f = io.open(REPORT, "w")
	f:write(table.concat(log_lines, "\n") .. "\n")
	f:close()
end
local function print(s)
	table.insert(log_lines, tostring(s))
	flush()
end
local function ok(cond, what, detail)
	if cond then
		pass = pass + 1
		print(("  ok   %s"):format(what))
	else
		fail = fail + 1
		print(("  FAIL %s%s"):format(what, detail and ("  → " .. tostring(detail)) or ""))
	end
end

pcall(function()
	require("lazy").load({ plugins = { "codecompanion.nvim", "plenary.nvim" } })
end)

-- Stub the ollama HTTP transport so requests stay in flight until we say otherwise.
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

local function target(name, lines, win)
	local buf = api.nvim_create_buf(true, false)
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	api.nvim_buf_set_name(buf, name)
	vim.bo[buf].filetype = "lua"
	if win then
		api.nvim_win_set_buf(win, buf)
	else
		api.nvim_set_current_buf(buf)
	end
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

local function float_lines()
	local buf
	for _, win in ipairs(api.nvim_list_wins()) do
		if api.nvim_win_get_config(win).relative ~= "" then
			buf = api.nvim_win_get_buf(win)
		end
	end
	if not buf then
		return {}, nil
	end
	return api.nvim_buf_get_lines(buf, 0, -1, false), buf
end

print("\n=== registry: fields, ordering, state ===")

-- A realistic terminal: at headless's 80 columns the row has to choose between the prompt and
-- the tool name, which is its own test (see the narrow-terminal suite).
vim.o.columns = 160

-- Both targets stay on screen: show_diff drops a reply whose buffer is no longer visible, so an
-- off-screen target never reaches the review state this is about.
vim.cmd("split")
local win_a, win_b = api.nvim_list_wins()[1], api.nvim_list_wins()[2]

local buf_a = target("alpha.lua", { "local function f()", "  return 1", "end" }, win_a)
local req_a = inline.submit({
	bufnr = buf_a,
	range = { s0 = 1, e0 = 2, has_selection = true },
	instruction = "return 2 instead",
})
ok(req_a ~= nil, "submit returned a request")
ok(req_a.instruction == "return 2 instead", "request carries its instruction", req_a.instruction)
ok(type(req_a.started) == "number", "request carries a start time", req_a.started)
ok(req_a.model ~= nil and req_a.model ~= "nil", "request carries its model", req_a.model)

local buf_b = target("beta.lua", { "return {", "  a = 1,", "}" }, win_b)
local req_b = inline.submit({
	bufnr = buf_b,
	range = { s0 = 1, e0 = 2, has_selection = true },
	instruction = "add b = 2",
})

local entries = inline.list()
ok(#entries == 2, "both buffers' requests are listed", #entries)
ok(entries[1].order < entries[2].order, "ordered by the request they came from")
ok(entries[1].file == "alpha.lua", "file is the relative path", entries[1].file)
ok(entries[1].kind == "request", "an in-flight request reads as a request")
local s0 = entries[1].resolve()
ok(s0 == 1, "resolve gives the anchored start row", s0)
ok(entries[1].since >= 0, "since is a duration", entries[1].since)

print("\n=== a request turning into a diff keeps its place ===")

api.nvim_set_current_win(win_a)
local order_a = entries[1].order
captured[1].on_done("```lua\n  return 2\n```")
vim.wait(50)

entries = inline.list()
local by_order = {}
for _, e in ipairs(entries) do
	by_order[e.order] = e
end
ok(#entries == 2, "still two entries after one landed", #entries)
ok(by_order[order_a] ~= nil, "the finished one kept its order", vim.inspect(vim.tbl_keys(by_order)))
ok(by_order[order_a] and by_order[order_a].kind == "diff", "and now reads as a diff")
ok(by_order[order_a] and by_order[order_a].instruction == "return 2 instead", "the diff carries the instruction")
ok(by_order[order_a] and by_order[order_a].hunks ~= nil, "the diff reports its hunk count", by_order[order_a].hunks)
ok(entries[1].order == order_a, "and is still first in the list")

print("\n=== the list window ===")

list.open()
ok(list.is_open(), "the list opened")
local lines, list_buf = float_lines()
ok(#lines == 2, "one row per entry", #lines)
ok(
	lines[1]:find("review", 1, true) ~= nil or lines[1]:find("finished", 1, true) ~= nil,
	"the diff row names its state",
	lines[1]
)
ok(lines[1]:find("alpha.lua:2", 1, true) ~= nil, "the row says where the edit is", lines[1])
ok(lines[1]:find("return 2 instead", 1, true) ~= nil, "and what was asked", lines[1])
ok(lines[2]:find("thinking", 1, true) ~= nil, "the in-flight row says thinking", lines[2])
ok(lines[2]:find("beta.lua", 1, true) ~= nil, "and which buffer it belongs to", lines[2])
ok(lines[1]:find("▶", 1, true) ~= nil, "the cursor marker is on the first row", lines[1])

-- Every row must fit inside the window, or the border clips it silently.
local width
for _, win in ipairs(api.nvim_list_wins()) do
	local cfg = api.nvim_win_get_config(win)
	if cfg.relative ~= "" then
		width = cfg.width
	end
end
local widest = 0
for _, line in ipairs(lines) do
	widest = math.max(widest, vim.fn.strdisplaywidth(line))
end
ok(widest <= width, "no row is wider than the window", ("%d > %d"):format(widest, width or -1))

print("\n=== a running request reports what it is doing ===")

captured[2].on_tool("read_file")
vim.wait(200)
lines = float_lines()
ok(lines[2] and lines[2]:find("read_file", 1, true) ~= nil, "the tool a request is running shows on its row", lines[2])

print("\n=== live: a request that lands while the list is open says so ===")

captured[2].on_done("```lua\n  a = 1,\n  b = 2,\n```")
vim.wait(300) -- long enough for the redraw timer to notice
lines = float_lines()
ok(lines[2] and lines[2]:find("finished", 1, true) ~= nil, "the row that just landed flashes finished", lines[2])

print("\n=== moving and settling from the list ===")

press(list_buf, "j")
lines = float_lines()
ok(lines[2]:find("▶", 1, true) ~= nil, "j moved the cursor marker", lines[2])

-- Discard beta: x rejects a finished diff, its two lines coming back as they were.
press(list_buf, "x")
vim.wait(150)
local beta = api.nvim_buf_get_lines(buf_b, 0, -1, false)
ok(vim.deep_equal(beta, { "return {", "  a = 1,", "}" }), "reject restored the original lines", vim.inspect(beta))
ok(#inline.list() == 1, "and dropped the entry", #inline.list())
lines = float_lines()
ok(#lines == 1, "the list shrank to one row", #lines)
ok(lines[1]:find("alpha", 1, true) ~= nil, "the cursor fell back onto the row that is left", lines[1])

-- Accept alpha.
press(list_buf, "a")
vim.wait(150)
local alpha = api.nvim_buf_get_lines(buf_a, 0, -1, false)
ok(vim.deep_equal(alpha, { "local function f()", "  return 2", "end" }), "accept kept the edit", vim.inspect(alpha))
ok(#inline.list() == 0, "nothing left in play", #inline.list())
lines = float_lines()
ok(lines[1] and lines[1]:find("nothing", 1, true) ~= nil, "the empty list says so", lines[1])

press(list_buf, "q")
ok(not list.is_open(), "q closed it")

print("\n=== cancelling from the list ===")

-- Separate rows: two requests over the same lines are refused now, on purpose.
local buf_c = target("gamma.lua", { "x = 1", "y = 1" })
inline.submit({ bufnr = buf_c, range = { s0 = 0, e0 = 1, has_selection = true }, instruction = "make x 2" })
inline.submit({ bufnr = buf_c, range = { s0 = 1, e0 = 2, has_selection = true }, instruction = "make y 3" })
ok(#inline.list() == 2, "two in flight", #inline.list())

list.open()
local _, cancel_buf = float_lines()
local before = captured.cancels
press(cancel_buf, "x")
ok(captured.cancels == before + 1, "x cancelled the transport job", captured.cancels - before)
ok(#inline.list() == 1, "and dropped the entry", #inline.list())

press(cancel_buf, "X")
ok(#inline.list() == 0, "X cancelled the rest", #inline.list())
ok(captured.cancels == before + 2, "both jobs were told to stop", captured.cancels - before)
press(cancel_buf, "q")

print("\n=== nothing to show ===")
list.open()
ok(list.is_open(), "opening with nothing in play still opens the window")
local nwin = nil
for _, w in ipairs(api.nvim_list_wins()) do
	if api.nvim_win_get_config(w).relative ~= "" then
		nwin = w
	end
end
local nbody = nwin and api.nvim_buf_get_lines(api.nvim_win_get_buf(nwin), 0, -1, false) or {}
ok(nbody[1] ~= nil and nbody[1]:find("nothing in flight", 1, true) ~= nil, "which says so", vim.inspect(nbody))
list.close()

print(("\n%d passed, %d failed\n"):format(pass, fail))
flush()
vim.cmd("qa!")
