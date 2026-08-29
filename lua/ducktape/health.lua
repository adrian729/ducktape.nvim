-- `:checkhealth ducktape`. Checks things that usually slip past a version floor: that the
-- codecompanion internals we reach into still resolve, and that setup completed.

local M = {}

local start = vim.health.start
local ok = vim.health.ok
local info = vim.health.info
local warn = vim.health.warn
local error = vim.health.error

local fmt = string.format

local DEPS = {
	{ name = "codecompanion.nvim", module = "codecompanion" },
	{ name = "plenary.nvim", module = "plenary" },
	{
		name = "telescope.nvim",
		module = "telescope",
		optional = true,
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

local BINARIES = {
	{ name = "git", used_for = "scoping saved chats and resumable sessions to the repository" },
	{ name = "curl", used_for = "any provider with an HTTP model list" },
	{ name = "node", used_for = "spawning claude-agent-acp" },
}

---@return table[]
local function provider_binaries()
	local providers = require("ducktape.providers")
	local out = {}
	for _, provider in ipairs(providers.names()) do
		local spec = providers.spec(provider) or {}

		local adapter_name = providers.acp_adapter(provider)
		if adapter_name then
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

local ALLOWED_G = { keymaps = true, statusline = true }

-- Subtrees whose keys are user-defined names, so unknown keys in them are not typos.
local FREEFORM = {
	providers = true,
	defaults = true,
	adapters = true,
	codecompanion = true,
	highlights = true,
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

---Report each provider and whether its inline write defence is verified.
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

	-- Walk config recursively, reporting unknown keys. User-named subtrees are skipped.
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

---Chat window lifetime rules: registered, and what would stop them.
local function check_chat_window()
	start("ducktape: chat window rules")

	local cfg = require("ducktape.config").get().chat or {}
	local report = require("ducktape.chat_window").report()

	if report.registered then
		ok("QuitPre and WinClosed are registered")
	else
		error(
			"the chat's lifetime autocmds are missing, so `:q` will leave the chat behind. Restart "
				.. "nvim — these are registered by setup, and an nvim running since before the plugin "
				.. "was installed or updated never got them."
		)
	end

	if cfg.close_with_last_file == false then
		info("close_with_last_file = false — the chat is meant to outlive your last file here")
	else
		ok("close_with_last_file — `:q` in your last file window takes the chat with it")
	end
	if cfg.quit_closes_session == false then
		info("quit_closes_session = false — `:q` in the chat closes only the chat window")
	else
		ok("quit_closes_session — `:q` in the chat quits the session")
	end

	info(fmt("chat windows open: %d", report.chats))

	if #report.unsaved > 0 then
		warn(
			fmt(
				"%d buffer(s) with unsaved changes, so `:q` will be refused with E37 — the chat goes "
					.. "anyway and you are left in your file. `:wq`, `:q!` or `:wa` instead: %s",
				#report.unsaved,
				table.concat(report.unsaved, ", ")
			)
		)
	end
end

function M.check()
	check_deps()
	check_parsers()
	check_internals()
	check_binaries()
	check_providers()
	check_config()
	check_chat_window()
end

return M
