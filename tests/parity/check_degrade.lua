-- Without telescope, the three features that need it must say so and everything else must work.
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

local said = {}
local orig = vim.api.nvim_echo
vim.api.nvim_echo = function(chunks, ...)
	for _, c in ipairs(chunks) do
		table.insert(said, c[1])
	end
	return orig(chunks, ...)
end

local function heard_about_telescope(label, fn)
	said = {}
	local ok, err = pcall(fn)
	local msg = table.concat(said, " ")
	check(ok, label .. " did not throw" .. (ok and "" or (": " .. tostring(err))))
	check(msg:lower():find("telescope", 1, true) ~= nil, label .. " named telescope, said: " .. msg:sub(1, 120))
end

heard_about_telescope("the chat list", function()
	require("ducktape.chat_list").open()
end)
heard_about_telescope("the inline picker", function()
	require("ducktape.inline").pick()
end)
heard_about_telescope("the chat picker", function()
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
