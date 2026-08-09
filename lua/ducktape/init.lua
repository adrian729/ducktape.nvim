-- Setup, and the guarantee the rest of the plugin leans on.
--
-- In the configuration this was extracted from, the keymaps lived in codecompanion's own lazy
-- `keys` table, which made one promise nothing ever wrote down: no action could run before
-- `codecompanion.setup()` had, and therefore never before the hardened adapters were installed.
-- Moving the keymaps into `plugin/ducktape.lua` throws that promise away — they now exist from
-- startup whether or not this module ever ran. `M.bootstrap()` puts it back explicitly.

local M = {}

---Set once, as the final statement of `M.setup`.
---
---A flag rather than "are the adapters registered", because codecompanion loads extensions inside
---a `pcall` and only logs a failure: a throw part-way through setup leaves the adapters in place
---and everything after them missing, which is exactly the state where the chat-persistence
---autocmd never registered and open chats are silently not saved on exit.
local ready = false

---@return boolean
function M.is_ready()
	return ready
end

---Names this plugin has installed, so a second setup does not mistake its own work for a user's.
---@type table<string, boolean>
local installed = {}

---Install the adapters this plugin needs into codecompanion's live config.
---
---Safe after `codecompanion.setup()` has run: ACP and HTTP adapters are resolved by *name at use
---time*, so writing into the table they are looked up in is equivalent to having passed them to
---setup.
---
---Codecompanion's own stock entries are plain **strings** — `adapters.acp.claude_code` is the
---string `"claude_code"`, a pointer at its built-in module. So a string means "nobody has
---customised this" and must be replaced; only a table or function is somebody's real definition,
---and that is kept, because clobbering a user's adapter is worse than warning them that theirs may
---not carry the write defence.
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

---Generate HTTP adapters for any provider endpoint that describes one.
---
---A provider added through `opts.providers` with an `endpoints` table whose entries name `extends`
---gets a codecompanion adapter per endpoint, carrying the URL, the API key and the shared schema.
---Without this, adding an HTTP provider would mean hand-writing an adapter that restates what the
---endpoint already said.
---
---Never overwrites an entry that `opts.adapters` already names: an explicit definition is the more
---specific statement of intent.
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

---Take over codecompanion's default adapter for the interactions this plugin drives, but only
---where the value is still codecompanion's own stock `"copilot"`.
---
---That is the only signal available: by the time an extension runs, `config.setup(opts)` has
---already merged the user's own choice in, so a user who deliberately picked copilot is
---indistinguishable from one who picked nothing. `set_default_adapters = false` is how they say so.
---
---Which adapter is claimed comes from the configured defaults rather than a fixed list, so a user
---who made a provider of their own the default gets that one claimed instead of ollama's.
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

---Replace the callback behind the chat's send key, leaving its keys, modes and description alone.
---
---Guarded because `config.setup` strips keymaps a user disabled, so `send = false` in their config
---makes this a nil index — and inside codecompanion's `pcall` that would abort every step after it.
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
---@return table cfg The resolved configuration
function M.setup(opts)
	local cfg = require("ducktape.config").setup(opts)

	-- Standalone path: whoever called us did not route through codecompanion's `extensions`, so
	-- codecompanion has not been configured and there is nothing for us to write into yet.
	if not vim.g.loaded_codecompanion or not package.loaded["codecompanion.config"] then
		require("codecompanion").setup(cfg.codecompanion or {})
	end

	require("ducktape.providers").apply(cfg)
	-- After apply, so a provider that arrived through `opts.providers` is in the registry, and
	-- before install_adapters, which is what writes the result into codecompanion.
	generate_adapters(cfg)
	-- Nothing on this machine has ever asked the providers what they can reach, so ask now, in the
	-- background. Without it the first picker of a fresh install opens with only the `auto` sentinel
	-- and fills in once the query lands — which works, but makes an install look like it needs a
	-- setup step it does not have. Only ever on a first run: the answers are persisted.
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
	-- Required for its own sake: loading it registers the VimLeavePre that saves open chats and
	-- reads back the ones from last session. Nothing is respawned here — a saved chat becomes a
	-- real one only when the user opens it, which is why an nvim start costs no agent processes.
	require("ducktape.chat")
	-- The chat's lifetime rules: closing the last file takes the chat with it, and `:q` in the chat
	-- quits. Registered here rather than at that module's load so a session that never set the
	-- plugin up keeps nvim's own window behaviour.
	require("ducktape.chat_window").setup()

	ready = true
	return cfg
end

---Make sure codecompanion, and therefore this plugin, is configured before an action runs.
---
---Called first by every keymap and command in `plugin/ducktape.lua`. Requiring codecompanion is
---what does the work: through a plugin manager's module loader it loads codecompanion, runs its
---config, and so runs this plugin's extension — all synchronously, before the require returns.
---
---Order matters. Codecompanion first, the ducktape module second: reversed, a ducktape module with
---a chunk-level codecompanion require (inline, acp_pool, inline.http) would still be loading when
---the extension came back round to it, and `loop or previous error loading module` inside
---codecompanion's `pcall` would leave this plugin half-configured with no visible error.
---@return boolean ok False when the action must not proceed
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
