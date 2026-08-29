-- ui.say / ui.confirm: the command line never overflows, and nothing is lost when it would have.
local REPORT = "/tmp/ui_say.out"
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

local ui = require("ducktape.ui")
vim.o.columns = 80
vim.o.laststatus = 2
local function history()
	return vim.api.nvim_exec2("messages", { output = true }).output or ""
end
local function shown()
	-- last history line is the fitted echo; overflow text is read from the full message
	local h = vim.split(history(), "\n", { plain = true })
	return h[#h] ~= "" and h[#h] or h[#h - 1] or ""
end

section("a message that fits is shown whole")
vim.cmd("messages clear")
ui.say("[ducktape] deleted chat 3")
ok(history():find("[ducktape] deleted chat 3", 1, true) ~= nil, "it reaches :messages", history())
ok(vim.fn.strdisplaywidth(shown()) <= vim.v.echospace, "and fits the command line", vim.v.echospace)

section("a message too long for the command line")
vim.cmd("messages clear")
local long = "[ducktape] " .. string.rep("long-", 40)
local before = vim.o.cmdheight
ui.say(long, vim.log.levels.WARN)
ok(history():find(long, 1, true) ~= nil, "is recorded in full, not truncated", #history())
ok(vim.o.cmdheight == before, "and 'cmdheight' is put back", vim.o.cmdheight)
local fitted = ui.ellipsise(long, vim.v.echospace)
ok(vim.fn.strdisplaywidth(fitted) <= vim.v.echospace, "while the line shown fits", vim.fn.strdisplaywidth(fitted))
ok(fitted:sub(-3) == "…", "and says it was cut", fitted:sub(-6))

section("width is read per call, not cached")
vim.o.columns = 200
local wide = ui.ellipsise(long, vim.v.echospace)
ok(#wide > #fitted, "a wider screen shows more of the same message", ("%d vs %d"):format(#wide, #fitted))
vim.o.columns = 80

section("a message with newlines in it")
vim.cmd("messages clear")
ui.say("[ducktape] first line\nsecond line")
ok(history():find("first line · second line", 1, true) ~= nil, "is flattened onto one line", history())
ok(history():find("\nsecond line", 1, true) == nil, "so it cannot scroll the command line", history())

section("every level is accepted")
for _, level in ipairs({ vim.log.levels.INFO, vim.log.levels.WARN, vim.log.levels.ERROR }) do
	ok(pcall(ui.say, "[ducktape] level check", level), "level " .. level)
end
ok(pcall(ui.say, "[ducktape] no level given"), "and no level at all")

section("confirm answers yes/no")
vim.api.nvim_feedkeys("y", "L", false)
ok(ui.confirm("Delete it?") == true, "y is yes")
vim.api.nvim_feedkeys("n", "L", false)
ok(ui.confirm("Delete it?") == false, "n is no")
vim.api.nvim_feedkeys("\r", "L", false)
ok(ui.confirm("Delete it?") == false, "Enter takes the default, which is no")
vim.api.nvim_feedkeys("\r", "L", false)
ok(ui.confirm("Delete it?", { default = true }) == true, "unless the caller asks for yes")

flush()
