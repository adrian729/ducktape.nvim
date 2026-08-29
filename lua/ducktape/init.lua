-- Setup and the readiness guarantee the rest of the plugin leans on. Keymaps exist from startup
-- in `plugin/ducktape.lua`, so `M.bootstrap()` ensures setup has run before any action.

local M = {}

---Set only by the final statement of `M.setup`. A flag rather than "adapters registered" because
---a throw part-way through codecompanion's extension `pcall` can leave adapters in place while
---later steps (e.g. chat persistence autocmds) never ran.
local ready = false

---@return boolean
function M.is_ready()
	return ready
end

---@type table<string, boolean>
local installed = {}

---Install adapters into codecompanion's live config. Stock entries are strings ("claude_code"),
---so a string means uncustomised and is replaced; tables/functions are kept as the user's own.
---@param cfg table
local function install_adapters(cfg)
	local cc = require("codecompanion.config")
	for kind, set in pairs(cfg.adapters or {}) do
		cc.adapters[kind] = cc.adapters[kind] or {}
		for name, factory in pairs(set) do
			local existing = cc.adapters[kind][name]
			local theirs = existing ~= nil and type(existing) ~= "string" and not installed[kind .. "." .. name]
			if theirs then
				require("ducktape.ui").say(
					("[ducktape] %s adapter %q is already defined; keeping yours, which may not carry the write defence"):format(
						kind,
						name
					),
					vim.log.levels.WARN
				)
			else
				cc.adapters[kind][name] = factory
				installed[kind .. "." .. name] = true
			end
		end
	end
end

---Generate HTTP adapters from provider endpoints, unless `opts.adapters` already names one.
---@param cfg table
local function generate_adapters(cfg)
	local providers = require("ducktape.providers")
	cfg.adapters = cfg.adapters or {}
	cfg.adapters.http = cfg.adapters.http or {}

	for _, provider in ipairs(providers.names()) do
		for endpoint, entry in pairs(providers.endpoints(provider)) do
			if entry.extends and entry.adapter and cfg.adapters.http[entry.adapter] == nil then
				cfg.adapters.http[entry.adapter] =
					require("ducktape.config").http_adapter(provider, endpoint, entry.extends)
			end
		end
	end
end

---Claim codecompanion's default adapter from stock `"copilot"` for our interactions. Only the
---stock string is changed; a deliberate user choice is indistinguishable once config.setup merged
---it, so `set_default_adapters = false` opts out.
local function claim_default_adapters()
	local cc = require("codecompanion.config")
	local providers = require("ducktape.providers")

	local chat = providers.adapter_name(providers.current("chat").provider, "chat")
	local inline = providers.adapter_name(providers.current("inline").provider, "inline")
	local wanted = { chat = chat, inline = inline, cmd = inline }

	for interaction, adapter in pairs(wanted) do
		local at = cc.interactions and cc.interactions[interaction]
		if adapter and at and at.adapter == "copilot" then
			at.adapter = adapter
		end
	end
end

---Replace the chat send callback. Guarded because a disabled send keymap becomes nil.
local function override_send()
	local send = require("codecompanion.config").interactions.chat.keymaps.send
	if type(send) ~= "table" then
		return
	end
	send.callback = function(chat)
		require("ducktape.chat_edit").send(chat)
	end
end

---@param opts table|nil
---@return table cfg
function M.setup(opts)
	local cfg = require("ducktape.config").setup(opts)

	-- Standalone path: no extension routed through codecompanion yet, so set it up ourselves.
	if not vim.g.loaded_codecompanion or not package.loaded["codecompanion.config"] then
		require("codecompanion").setup(cfg.codecompanion or {})
	end

	require("ducktape.providers").apply(cfg)
	generate_adapters(cfg)
	-- Prime the model cache on first run so the first picker is not empty.
	if vim.tbl_isempty(require("ducktape.model_cache").lists()) then
		require("ducktape.providers").discover_models()
	end
	install_adapters(cfg)
	override_send()
	if cfg.set_default_adapters then
		claim_default_adapters()
	end

	require("ducktape.debug").setup()
	require("ducktape.reload").setup()
	-- Loading registers `VimLeavePre` for saving/opening chats; no agent is spawned here.
	require("ducktape.chat")
	require("ducktape.chat_window").setup()

	ready = true
	return cfg
end

---Ensure codecompanion is loaded and this plugin's extension has run before an action proceeds.
---Order matters: codecompanion first, ducktape second. Reversed, chunk-level codecompanion requires
---in `inline`/`acp_pool` would still be loading when the extension re-entered them.
---@return boolean ok
function M.bootstrap()
	if not ready then
		pcall(require, "codecompanion")
	end
	if not ready then
		require("ducktape.ui").say(
			"[ducktape] not set up — add it to codecompanion's `extensions` (see :h ducktape) or call "
				.. "require('ducktape').setup(). Refusing to run, because the adapters that deny agent writes "
				.. "are installed by that setup.",
			vim.log.levels.ERROR
		)
		return false
	end
	return true
end

return M
