-- The wiring no unit test covers: that plugin/ducktape.lua sets everything up without loading the
-- core, that bootstrap() refuses before setup, and that after setup the adapters codecompanion
-- resolves are *ours* -- the ones carrying the write defence.
--
-- The last part is the reason this suite exists. Codecompanion's own stock adapter entries are
-- plain strings pointing at its built-in modules, so an install guard that only looks for "is
-- something already here" silently declines to install ours, and every agent then runs unhardened
-- with a 20s timeout and no dontAsk. That happened, and only a check like this one caught it.

local REPORT = "/tmp/wiring.out"
local passed, failed, lines = 0, 0, {}
local function flush()
	local f = io.open(REPORT, "w")
	f:write(table.concat(lines, "\n"), "\n\n", ("%d passed, %d failed\n"):format(passed, failed))
	f:close()
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

-- The plugin script must not require the core
vim.cmd("runtime plugin/ducktape.lua")
ok(vim.g.loaded_ducktape, "plugin script ran")
ok(package.loaded["ducktape.chat"] == nil and package.loaded["ducktape.inline"] == nil, "core NOT loaded by it")
ok(vim.fn.maparg("<leader>cc", "n") ~= "", "<leader>cc mapped")
ok(vim.fn.maparg("<Plug>(DucktapeChatToggle)", "n") ~= "", "<Plug> mapped")
ok(vim.o.statusline:find("ducktape.statusline", 1, true) ~= nil, "statusline injected")
ok(vim.fn.exists(":Ducktape") == 2, ":Ducktape exists")

-- 2. bootstrap must refuse while not set up
local said = {}
package.loaded["ducktape.ui"] = package.loaded["ducktape.ui"] or require("ducktape.ui")
local real_say = require("ducktape.ui").say
require("ducktape.ui").say = function(m)
	table.insert(said, m)
end
ok(require("ducktape").bootstrap() == false, "bootstrap refuses before setup")
ok((said[1] or ""):find("not set up", 1, true) ~= nil, "and says why")
require("ducktape.ui").say = real_say

-- 3. setup via the extension, the way codecompanion does it
require("codecompanion").setup({ extensions = { ducktape = { opts = {} } } })
ok(require("ducktape").is_ready(), "ready after cc setup")
ok(require("ducktape").bootstrap(), "bootstrap now allows")
local cc = require("codecompanion.config")
ok(type(cc.adapters.acp.claude_code) == "function", "claude_code adapter is ours")
local adapter = require("codecompanion.adapters").resolve("claude_code")
ok(adapter.defaults.timeout == 90000, "timeout 90s")
ok(adapter.defaults.session_config_options.mode == "dontAsk", "mode dontAsk")
ok(adapter.commands.yolo == nil, "yolo removed")
local oc = require("codecompanion.adapters").resolve("opencode")
ok(oc.env.OPENCODE_PERMISSION ~= nil, "opencode denies writes")
ok(type(cc.interactions.chat.keymaps.send.callback) == "function", "send override installed")
ok(cc.interactions.chat.adapter ~= nil, "chat adapter claimed = " .. tostring(cc.interactions.chat.adapter))
ok(cc.interactions.inline.adapter ~= nil, "inline adapter claimed = " .. tostring(cc.interactions.inline.adapter))
ok(type(require("codecompanion").extensions.ducktape.toggle_chat) == "function", "exports are closures")
