-- `:checkhealth ducktape`.
--
-- Two things this checks that a plugin health check usually does not, both because they are the
-- ways this plugin actually breaks:
--
--   * that the codecompanion internals it reaches into still resolve. A version floor alone would
--     not catch a refactor, and several of these are read with no pcall around them.
--   * that setup ran to completion, since the adapters that deny agent writes are installed there.

local M = {}

local start = vim.health.start
local ok = vim.health.ok
local info = vim.health.info
local warn = vim.health.warn
local error = vim.health.error

local fmt = string.format

-- Lua dependencies. Both optional ones are genuinely optional now — telescope improves the pickers
-- rather than gating them, and catppuccin supplies a palette there is a stand-in for — so each says
-- what is actually lost without it rather than that a feature disappears.
local DEPS = {
	{ name = "codecompanion.nvim", module = "codecompanion" },
	{ name = "plenary.nvim", module = "plenary" },
	{
		name = "telescope.nvim",
		module = "telescope",
		optional = true,
		-- No longer "you lose three features": ducktape.picker falls back to a float it draws
		-- itself, so what is lost is fuzzy matching and the user's own picker layout.
		lost = "fuzzy matching and your own picker layout in the chat list and the model pickers; "
			.. "a built-in float is used instead",
	},
	{
		name = "catppuccin",
		module = "catppuccin.palettes",
		optional = true,
		lost = "the palette every highlight is derived from; a stand-in is used instead",
	},
}

-- The codecompanion internals this plugin depends on. Unversioned, undocumented, and the realistic
-- source of breakage after an upstream bump.
local INTERNALS = {
	{
		what = "interactions.chat.buf_get_chat / .last_chat",
		test = function()
			local chat = require("codecompanion.interactions.chat")
			return type(chat.buf_get_chat) == "function" and type(chat.last_chat) == "function"
		end,
		used_for = "finding the chat in a buffer, and the most recent one — nineteen call sites",
	},
	{
		what = "_G.codecompanion_buffers",
		test = function()
			-- Required first: the global is created at that module's chunk level, so asking before
			-- anything has loaded it would report a break that is only a cold start.
			require("codecompanion.interactions.chat")
			return type(_G.codecompanion_buffers) == "table"
		end,
		used_for = "enumerating every open chat — the chat list, and four functions in chat.lua",
	},
	{
		what = "interactions.chat.parser.headers / .messages",
		test = function()
			local p = require("codecompanion.interactions.chat.parser")
			return type(p.headers) == "function" and type(p.messages) == "function"
		end,
		used_for = "re-deriving the prompt boundary when a sent message was edited",
	},
	{
		what = "interactions.chat.acp.commands.link_buffer_to_session",
		test = function()
			return type(require("codecompanion.interactions.chat.acp.commands").link_buffer_to_session) == "function"
		end,
		used_for = "restoring a chat, and forking one after an edit",
	},
	{
		what = "interactions.chat.acp.render.restore_session",
		test = function()
			return type(require("codecompanion.interactions.chat.acp.render").restore_session) == "function"
		end,
		used_for = "replaying an agent's own transcript into a restored chat",
	},
	{
		what = "interactions.chat.helpers.format_role",
		test = function()
			return type(require("codecompanion.interactions.chat.helpers").format_role) == "function"
		end,
		used_for = "reading roles back out of an edited transcript",
	},
	{
		what = "config.interactions.shared.keymaps.next_hunk / .previous_hunk",
		test = function()
			local shared = require("codecompanion.config").interactions.shared.keymaps
			return shared.next_hunk ~= nil and shared.previous_hunk ~= nil
		end,
		used_for = "deleting codecompanion's own hunk maps so { and } keep their paragraph motion",
	},
	{
		what = "config.interactions.chat.keymaps.send",
		test = function()
			return type(require("codecompanion.config").interactions.chat.keymaps.send) == "table"
		end,
		used_for = "carrying an edited transcript when you send again",
	},
	{
		what = "diff.keymaps accept_change / reject_change",
		test = function()
			local dk = require("codecompanion.diff.keymaps")
			return dk.accept_change ~= nil and dk.reject_change ~= nil
		end,
		used_for = "applying and rejecting an inline diff",
	},
}

-- Programs no plugin manager can install. The provider-specific ones are derived from the registry
-- (see `provider_binaries`), so this is only what the plugin itself needs whatever is configured.
local BINARIES = {
	{ name = "git", used_for = "scoping saved chats and resumable sessions to the repository" },
	{ name = "curl", used_for = "any provider with an HTTP model list" },
	{ name = "node", used_for = "spawning claude-agent-acp" },
}

---The external programs the configured providers need, one entry per provider.
---
---Derived rather than listed: a provider added through config brings its own agent command and its
---own relay, and a fixed list could only ever report on the three that ship.
---@return table[]
local function provider_binaries()
	local providers = require("ducktape.providers")
	local out = {}
	for _, provider in ipairs(providers.names()) do
		local spec = providers.spec(provider) or {}

		-- The agent process behind an ACP adapter, from codecompanion's own adapter definition, so
		-- it is right even for an adapter this plugin has never heard of.
		local adapter_name = providers.acp_adapter(provider)
		if adapter_name then
			-- Named `resolved` rather than `ok`: `ok` here is vim.health.ok, and shadowing it inside a
			-- health check is the kind of mistake that reports nothing and looks like a pass.
			local resolved, adapter = pcall(require("codecompanion.adapters").resolve, adapter_name)
			local command = resolved and adapter and vim.tbl_get(adapter, "commands", "default")
			if type(command) == "table" and type(command[1]) == "string" then
				table.insert(out, {
					name = command[1],
					used_for = ("the %s provider"):format(provider),
					optional = true,
				})
			end
		end

		-- The relay, which is deliberately not vendored.
		local relay = providers.relay(provider)
		if relay and relay.cmd then
			table.insert(out, {
				name = relay.cmd,
				used_for = ("%s's tool-free inline path"):format(provider),
				optional = true,
				note = "not bundled: any program taking content on stdin, the request as arguments and "
					.. "answering on stdout will do. Other providers are unaffected.",
			})
		end

		-- A model list that is a subprocess names its own command.
		local models = spec.models or {}
		if models.strategy == "subprocess" and type(models.cmd) == "table" and models.cmd[1] then
			table.insert(out, {
				name = models.cmd[1],
				used_for = ("%s's model list"):format(provider),
				optional = true,
			})
		end
	end
	return out
end

---Keys a user may set, per route. Checked separately because the routes are not interchangeable:
---`providers` in `vim.g.ducktape` is a real mistake that nothing would otherwise report, since
---plugin/ducktape.lua never reads it and setup never sees it.
local ALLOWED_G = { keymaps = true, statusline = true }

-- Config subtrees whose keys are the user's own names rather than ours, so an unknown key in them is
-- not a typo. Everything else is walked recursively and reported.
local FREEFORM = {
	providers = true, -- provider names
	defaults = true, -- per-scope selections, keyed by provider
	adapters = true, -- codecompanion adapter names
	codecompanion = true, -- codecompanion's own config
	highlights = true, -- highlight group names
	["ui.highlights"] = true,
}

local function check_deps()
	start("ducktape: Lua dependencies")
	for _, dep in ipairs(DEPS) do
		if pcall(require, dep.module) then
			ok(dep.name)
		elseif dep.optional then
			warn(fmt("%s is not installed — without it you lose %s", dep.name, dep.lost))
		else
			error(fmt("%s is required and was not found", dep.name))
		end
	end
end

local function check_parsers()
	start("ducktape: Tree-sitter parsers")
	for _, lang in ipairs({ "markdown", "markdown_inline" }) do
		if pcall(vim.treesitter.language.add, lang) then
			ok(lang)
		else
			error(
				fmt(
					"the %s parser is missing. Neovim does not ship it; install it with nvim-treesitter. "
						.. "Without it the chat does not render and editing a sent message silently does nothing.",
					lang
				)
			)
		end
	end
end

local function check_internals()
	start("ducktape: codecompanion internals")
	if not pcall(require, "codecompanion") then
		return error("codecompanion is not installed, so none of this could be checked")
	end
	for _, api in ipairs(INTERNALS) do
		local resolved, present = pcall(api.test)
		if resolved and present then
			ok(api.what)
		else
			error(fmt("%s no longer resolves. Used for: %s", api.what, api.used_for))
		end
	end
end

local function check_binaries()
	start("ducktape: external programs")
	local seen = {}
	for _, bin in ipairs(vim.list_extend(vim.deepcopy(BINARIES), provider_binaries())) do
		if not seen[bin.name] then
			seen[bin.name] = true
			if vim.fn.executable(bin.name) == 1 then
				ok(fmt("%s (%s)", bin.name, bin.used_for))
			elseif bin.optional then
				warn(
					fmt(
						"%s not found — needed for %s.%s",
						bin.name,
						bin.used_for,
						bin.note and (" " .. bin.note) or ""
					)
				)
			else
				error(fmt("%s not found — needed for %s", bin.name, bin.used_for))
			end
		end
	end

	-- The API keys the configured endpoints name, so a provider added through config gets the same
	-- check rather than only the one this plugin shipped with.
	local providers = require("ducktape.providers")
	for _, provider in ipairs(providers.names()) do
		for endpoint, entry in pairs(providers.endpoints(provider)) do
			if entry.api_key_env then
				if os.getenv(entry.api_key_env) then
					ok(fmt("$%s is set", entry.api_key_env))
				else
					warn(
						fmt(
							"$%s is not set — %s's %s endpoint will refuse. Export it before starting nvim.",
							entry.api_key_env,
							provider,
							endpoint
						)
					)
				end
			end
		end
	end
	if not os.getenv("CLAUDE_CODE_OAUTH_TOKEN") then
		info("$CLAUDE_CODE_OAUTH_TOKEN is not in nvim's environment; claude-agent-acp may still have its own auth")
	end
end

---What each provider is, and what keeps its inline path from writing to the filesystem.
---
---The write defence is the plugin's headline promise, and until now nothing reported on it: whether
---a session had actually accepted the mode was visible only as a line in codecompanion.log. This
---says, per provider, which half of the defence it has and whether the last connection verified it.
local function check_providers()
	start("ducktape: providers")
	local providers = require("ducktape.providers")
	local withheld = require("ducktape.acp_pool").withheld

	for _, provider in ipairs(providers.names()) do
		local kind = providers.kind(provider)
		local shallow = providers.transport(provider, false)
		local deep = providers.transport(provider, true)
		local guard = providers.effective_guard(provider)

		info(
			fmt(
				"%s — %s, inline via %s (deep: %s), sessions %s",
				provider,
				kind,
				shallow,
				deep,
				providers.resumable(provider) and "resumable" or "not resumable"
			)
		)

		-- Only ACP inline can write at all; HTTP and relay have no tool plumbing to deny.
		if shallow == "acp" or deep == "acp" then
			if withheld[provider] then
				warn(fmt("%s: inline is withheld — %s", provider, withheld[provider]))
			elseif guard.unguarded then
				warn(
					fmt(
						"%s: guard.unguarded = true, so its inline agent keeps its write tools. "
							.. "Nothing verifies that writes are denied.",
						provider
					)
				)
			elseif guard.required and next(guard.required) then
				local pairs_out = {}
				for category, value in pairs(guard.required) do
					table.insert(pairs_out, fmt("%s=%s", category, value))
				end
				table.sort(pairs_out)
				ok(fmt("%s: writes denied by %s, verified on every connection", provider, table.concat(pairs_out, " ")))
			elseif guard.derive then
				ok(
					fmt(
						"%s: no mode named, so one is chosen from what the agent advertises and verified "
							.. "before the connection is used",
						provider
					)
				)
			else
				warn(fmt("%s: guard.derive = false and no mode named — inline will be withheld", provider))
			end
		end
	end
end

local function check_config()
	start("ducktape: configuration")
	if require("ducktape").is_ready() then
		ok("setup ran to completion")
	else
		error(
			"setup has not completed. Every keymap will refuse rather than run, because the adapters that "
				.. "deny agent writes are installed by it. Check that codecompanion's `extensions` includes "
				.. "`ducktape`, and :messages for an error from loading it."
		)
	end

	local cfg = require("ducktape.config").get()
	local shipped = require("ducktape.config").defaults

	for key in pairs(type(vim.g.ducktape) == "table" and vim.g.ducktape or {}) do
		if ALLOWED_G[key] then
			ok(fmt("vim.g.ducktape.%s", key))
		elseif shipped[key] ~= nil then
			error(
				fmt(
					"vim.g.ducktape.%s is in the wrong place and is being ignored. Only `keymaps` and "
						.. "`statusline` are read at startup; everything else belongs in the extension's opts.",
					key
				)
			)
		else
			error(fmt("vim.g.ducktape.%s is not a ducktape option", key))
		end
	end

	-- Walked rather than checked one level deep. `:h lua-plugin-config` puts unknown-field detection
	-- in health precisely because it is fiddly, and one level is not enough: a typo inside
	-- `inline.prompt` or `keymaps.panels.status` used to be completely invisible, and `providers`
	-- being merged wholesale meant `optoins` looked like a legitimate new key.
	--
	-- Subtrees whose keys are the user's own names — provider names, adapter names, highlight groups
	-- — are not walked, because there is nothing to compare them against.
	local function walk(value, reference, path)
		if type(value) ~= "table" or type(reference) ~= "table" then
			return
		end
		for key, sub in pairs(value) do
			if type(key) == "string" then
				local here = path == "" and key or (path .. "." .. key)
				if reference[key] == nil then
					error(fmt("`%s` is not a ducktape option", here))
				elseif not (FREEFORM[key] or FREEFORM[here]) then
					walk(sub, reference[key], here)
				end
			end
		end
	end
	walk(cfg, shipped, "")

	-- The discovered model lists, because "the picker is empty" and "the picker has not asked yet"
	-- look identical from the outside.
	local lists = require("ducktape.model_cache").lists()
	local at = require("ducktape.model_cache").generated_at()
	if next(lists) then
		local parts = {}
		for key, models in pairs(lists) do
			table.insert(parts, ("%s %d"):format(key, #models))
		end
		table.sort(parts)
		ok(fmt("models discovered: %s (%s)", table.concat(parts, ", "), at and os.date("%Y-%m-%d %H:%M", at) or "?"))
	else
		info(
			"no models discovered yet — the pickers fill themselves the first time they are opened, or "
				.. "run :Ducktape models"
		)
	end
	-- What the AUTO sentinel currently means, for every provider that has one. Provider-specific
	-- before, which meant a second provider with a fallback list had nothing reporting on it.
	for _, provider in ipairs(require("ducktape.providers").names()) do
		if (require("ducktape.providers").spec(provider) or {}).auto then
			local auto = require("ducktape.providers").resolve_chat_option_value(
				provider,
				"model",
				require("ducktape.providers").AUTO
			)
			info(fmt("%s `auto` currently resolves to %s", provider, tostring(auto)))
		end
	end

	local inline = require("ducktape.providers").current("inline")
	local chat = require("ducktape.providers").current("chat")
	info(fmt("inline: %s (%s)", inline.provider, vim.inspect(inline.opts, { newline = " ", indent = "" })))
	info(fmt("chat:   %s (%s)", chat.provider, vim.inspect(chat.opts, { newline = " ", indent = "" })))
	info(fmt("keymaps: %s", require("ducktape.keys").globals_enabled() and "defaults created" or "globals disabled"))
	local backend, why = require("ducktape.picker").resolve()
	info(fmt("picker: %s (%s)", backend, why))
	info(fmt("session scope: %s → %s", tostring(cfg.session.scope), tostring(require("ducktape.scope").key())))
end

function M.check()
	check_deps()
	check_parsers()
	check_internals()
	check_binaries()
	check_providers()
	check_config()
end

return M
