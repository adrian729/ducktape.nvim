-- The adversarial cases: ducktape must refuse rather than drive an unhardened agent.
--
-- Run under probe_init.lua with DT_VARIANT=no_extension or setup_throws.
local pass, fail = 0, 0
local function check(ok, what)
	if ok then
		pass = pass + 1
	else
		fail = fail + 1
		print("FAIL " .. what)
	end
end

local variant = os.getenv("DT_VARIANT")

-- The keymaps exist regardless — that is the hazard, and why bootstrap has to answer for it.
check(vim.fn.maparg(" ci", "n"):match("^<Plug>%(DucktapeInline") ~= nil, "the keymap still exists")

local said = {}
local orig = vim.api.nvim_echo
vim.api.nvim_echo = function(chunks, ...)
	for _, c in ipairs(chunks) do
		table.insert(said, c[1])
	end
	return orig(chunks, ...)
end
local notified = {}
local orig_notify = vim.notify
vim.notify = function(msg, ...)
	table.insert(notified, msg)
	return orig_notify(msg, ...)
end

local ok = require("ducktape").bootstrap()
vim.api.nvim_echo = orig
vim.notify = orig_notify

check(ok == false, "bootstrap refused")
check(require("ducktape").is_ready() == false, "still not ready")

local heard = table.concat(said, " ") .. " " .. table.concat(notified, " ")
check(heard:find("ducktape", 1, true) ~= nil, "said something naming ducktape: " .. heard:sub(1, 200))
check(heard:find("not set up", 1, true) ~= nil, "explained that setup did not run")
check(heard:find("deny agent writes", 1, true) ~= nil, "explained why it refuses")

if variant == "setup_throws" then
	-- config.lua's validate is the first statement of setup, so this one throws *before* the
	-- adapters go in and codecompanion's stock claude_code is what is left in place. Refusing is
	-- the only thing standing between that and a working keymap.
	local claude = require("codecompanion.adapters").resolve("claude_code")
	check(
		vim.tbl_get(claude, "defaults", "session_config_options", "mode") == nil,
		"a validate failure leaves codecompanion's stock adapter, unhardened"
	)
end

if variant == "late_throw" then
	-- The case an "are the adapters registered?" check would wave through: they went in before the
	-- throw, so only the completion flag distinguishes this from a working setup.
	local claude = require("codecompanion.adapters").resolve("claude_code")
	check(
		vim.tbl_get(claude, "defaults", "session_config_options", "mode") == "dontAsk",
		"the adapters did get installed before the throw — which is why the flag is the check"
	)
	check(package.loaded["ducktape.chat"] == nil, "the step after the throw never ran")
end

print(("refuse[%s]: %d passed, %d failed"):format(variant, pass, fail))
