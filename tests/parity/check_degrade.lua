-- Without telescope, nothing is unreachable any more.
--
-- This check used to assert the opposite: the chat list and both model pickers named telescope and
-- did nothing. `ducktape.picker` gives them a backend that needs no plugin, so what is left to
-- establish is that they really open, that the fallback is the one chosen, and that they say nothing
-- about telescope — a message naming a plugin you do not need is its own kind of wrong.
local pass, fail = 0, 0
local function check(ok, what)
	if ok then
		pass = pass + 1
	else
		fail = fail + 1
		print("FAIL " .. what)
	end
end

check(pcall(require, "telescope") == false, "telescope really is absent")
check(require("ducktape").bootstrap() == true, "the plugin still sets up")

local picker = require("ducktape.picker")
local backend, why = picker.resolve()
check(backend == "default", "the built-in backend is chosen, got " .. tostring(backend))
check(type(why) == "string" and why ~= "", "and it says why: " .. tostring(why))

local said = {}
local orig = vim.api.nvim_echo
vim.api.nvim_echo = function(chunks, ...)
	for _, c in ipairs(chunks) do
		table.insert(said, c[1])
	end
	return orig(chunks, ...)
end

---Each of the three features telescope used to gate: it has to open a window of its own and not
---mention telescope on the way.
local function opens_without_telescope(label, fn)
	said = {}
	local before = #vim.api.nvim_list_wins()
	local ok, err = pcall(fn)
	local msg = table.concat(said, " ")
	check(ok, label .. " did not throw" .. (ok and "" or (": " .. tostring(err))))
	check(
		msg:lower():find("telescope", 1, true) == nil,
		label .. " did not mention telescope, said: " .. msg:sub(1, 120)
	)
	-- The default backend opens two windows, results and prompt. One is enough to establish that
	-- something was actually shown rather than silently skipped.
	check(#vim.api.nvim_list_wins() > before, label .. " opened a window")

	-- Back to a clean slate for the next one: these are real floats and they stack.
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_config(win).relative ~= "" then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end
	vim.cmd("stopinsert")
end

opens_without_telescope("the chat list", function()
	require("ducktape.chat_list").open()
end)
opens_without_telescope("the inline picker", function()
	require("ducktape.inline").pick()
end)
opens_without_telescope("the chat picker", function()
	require("ducktape.chat").pick()
end)

vim.api.nvim_echo = orig

-- The rest is unaffected.
check(require("ducktape.statusline").render() == "", "the statusline still renders")
check(
	vim.tbl_get(require("codecompanion.adapters").resolve("claude_code"), "defaults", "session_config_options", "mode")
		== "dontAsk",
	"the write defence is still in place"
)
check(require("ducktape.inline.list").toggle ~= nil, "the inline list is reachable")

print(("degrade: %d passed, %d failed"):format(pass, fail))
