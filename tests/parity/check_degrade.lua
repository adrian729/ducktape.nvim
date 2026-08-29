-- With the built-in picker fallback, chat/model pickers must open without telescope and never mention it.
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

---Run a picker feature and assert it opens a window without mentioning telescope.
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
	-- The default backend opens results + prompt; one window proves something was shown.
	check(#vim.api.nvim_list_wins() > before, label .. " opened a window")

	-- Close floats between cases; they stack.
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

check(require("ducktape.statusline").render() == "", "the statusline still renders")
check(
	vim.tbl_get(require("codecompanion.adapters").resolve("claude_code"), "defaults", "session_config_options", "mode")
		== "dontAsk",
	"the write defence is still in place"
)
check(require("ducktape.inline.list").toggle ~= nil, "the inline list is reachable")

print(("degrade: %d passed, %d failed"):format(pass, fail))
