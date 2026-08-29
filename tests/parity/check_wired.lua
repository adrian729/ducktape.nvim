-- First keypress: bootstrap loads codecompanion and installs the hardened adapters.
local pass, fail = 0, 0
local function check(ok, what)
	if ok then
		pass = pass + 1
	else
		fail = fail + 1
		print("FAIL " .. what)
	end
end

check(package.loaded["codecompanion"] == nil, "codecompanion not loaded before bootstrap")
check(require("ducktape").is_ready() == false, "not ready before bootstrap")

check(require("ducktape").bootstrap() == true, "bootstrap() succeeded")
check(package.loaded["codecompanion"] ~= nil, "bootstrap loaded codecompanion")
check(require("ducktape").is_ready() == true, "setup ran to completion")

local cc = require("codecompanion.config")
local adapters = require("codecompanion.adapters")

local claude = adapters.resolve("claude_code")
check(claude ~= nil, "claude_code resolves")
check(claude.defaults.timeout == 90000, "claude timeout is 90s, got " .. tostring(claude and claude.defaults.timeout))
check(
	vim.tbl_get(claude, "defaults", "session_config_options", "mode") == "dontAsk",
	"claude runs mode = dontAsk, got " .. tostring(vim.tbl_get(claude, "defaults", "session_config_options", "mode"))
)
check(claude.commands.yolo == nil, "claude has no yolo command")
check(vim.tbl_isempty(claude.env or {}), "claude adapter env emptied")
check(
	vim.tbl_get(claude, "parameters", "clientCapabilities", "fs", "writeTextFile") == false,
	"claude advertises no fs write capability"
)

local opencode = adapters.resolve("opencode")
check(opencode ~= nil, "opencode resolves")
check(opencode.defaults.timeout == 90000, "opencode timeout is 90s")
local perm = opencode.env and opencode.env.OPENCODE_PERMISSION
check(type(perm) == "function", "opencode carries OPENCODE_PERMISSION")
if type(perm) == "function" then
	local decoded = vim.json.decode(perm())
	for _, tool in ipairs({ "edit", "write", "patch" }) do
		check(decoded[tool] == "deny", ("opencode denies %s, got %s"):format(tool, tostring(decoded[tool])))
	end
	check(decoded.bash ~= nil, "opencode constrains bash")
end

local ollama = adapters.resolve("ollama_cloud")
check(ollama ~= nil, "ollama_cloud resolves")
check(ollama.env.url == "https://ollama.com", "ollama_cloud points at the cloud endpoint")
check(ollama.schema.num_ctx.default == 16384, "ollama num_ctx default restated")

check(
	cc.interactions.chat.adapter == "claude_code",
	"chat adapter claimed, got " .. tostring(cc.interactions.chat.adapter)
)
check(cc.interactions.inline.adapter == "ollama_cloud", "inline adapter claimed")
check(cc.interactions.cmd.adapter == "ollama_cloud", "cmd adapter claimed")

local send = cc.interactions.chat.keymaps.send
check(type(send) == "table" and type(send.callback) == "function", "send is still a keymap with a callback")
local src = debug.getinfo(send.callback, "S").source
check(src:find("ducktape", 1, true) ~= nil, "send callback is ours, from " .. src)
check(send.modes ~= nil, "send kept its own modes")

-- ducktape.chat registers the save-on-exit hook.
local persistence = vim.api.nvim_get_autocmds({ group = "DucktapeChatPersistence" })
check(#persistence > 0, "chat persistence autocmds registered")
local events = {}
for _, au in ipairs(persistence) do
	events[au.event] = true
end
check(events.VimLeavePre == true, "VimLeavePre registered")

local providers = require("ducktape.providers")
local inline = providers.current("inline")
check(inline.provider == "ollama", "inline provider is ollama")
check(inline.opts.model == "gpt-oss:120b", "inline model is gpt-oss:120b")
check(inline.opts.endpoint == "cloud", "inline endpoint is cloud")
local chat = providers.current("chat")
check(chat.provider == "claude", "chat provider is claude")
check(chat.opts.model == "opus", "chat model is opus")
check(chat.opts.effort == "xhigh", "chat effort is xhigh")
check(chat.opts.mode == "default", "chat mode is default")

check(require("ducktape.statusline").render() == "", "statusline renders empty with nothing in play")

check(vim.tbl_count(require("ducktape.acp_pool").snapshot and {} or {}) == 0, "pool untouched")

print(("wired: %d passed, %d failed"):format(pass, fail))
