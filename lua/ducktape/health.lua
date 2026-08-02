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

-- Lua dependencies. Telescope is optional in the sense that everything else works without it, and
-- required in the sense that three features are unreachable — so it says which.
local DEPS = {
	{ name = "codecompanion.nvim", module = "codecompanion" },
	{ name = "plenary.nvim", module = "plenary" },
	{
		name = "telescope.nvim",
		module = "telescope",
		optional = true,
		lost = "the chat list and both model pickers",
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

local BINARIES = {
	{ name = "git", used_for = "scoping resumable chat sessions to the repository" },
	{ name = "curl", used_for = "the ollama provider" },
	{ name = "node", used_for = "spawning claude-agent-acp" },
	{ name = "claude-agent-acp", used_for = "the claude provider", optional = true },
	{ name = "opencode", used_for = "the opencode provider and its model list", optional = true },
	{ name = "jq", used_for = "the opencode relay script", optional = true },
}

---Keys a user may set, per route. Checked separately because the routes are not interchangeable:
---`providers` in `vim.g.ducktape` is a real mistake that nothing would otherwise report, since
---plugin/ducktape.lua never reads it and setup never sees it.
local ALLOWED_G = { keymaps = true, statusline = true }

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
	for _, bin in ipairs(BINARIES) do
		if vim.fn.executable(bin.name) == 1 then
			ok(bin.name)
		elseif bin.optional then
			warn(fmt("%s not found — needed for %s", bin.name, bin.used_for))
		else
			error(fmt("%s not found — needed for %s", bin.name, bin.used_for))
		end
	end

	local relay = require("ducktape.config").get().opencode.relay.cmd
	if vim.fn.executable(relay) == 1 then
		ok(fmt("%s (the tool-free opencode relay)", relay))
	else
		warn(
			fmt(
				"%s is not on PATH, so the tool-free opencode inline path is unavailable. It is not "
					.. "bundled: any program taking content on stdin, the request as arguments and "
					.. "answering on stdout will do. claude and ollama are unaffected.",
				relay
			)
		)
	end

	if os.getenv("OLLAMA_API_KEY") then
		ok("$OLLAMA_API_KEY is set")
	else
		warn("$OLLAMA_API_KEY is not set — ollama's cloud endpoint will refuse. Export it before starting nvim.")
	end
	if not os.getenv("CLAUDE_CODE_OAUTH_TOKEN") then
		info("$CLAUDE_CODE_OAUTH_TOKEN is not in nvim's environment; claude-agent-acp may still have its own auth")
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

	for key in pairs(cfg) do
		if shipped[key] == nil then
			error(fmt("`%s` is not a ducktape option", key))
		end
	end

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
	local auto = require("ducktape.providers").resolve_chat_option_value("opencode", "model", "auto")
	info(fmt("opencode `auto` currently resolves to %s", tostring(auto)))

	local inline = require("ducktape.providers").current("inline")
	local chat = require("ducktape.providers").current("chat")
	info(fmt("inline: %s (%s)", inline.provider, vim.inspect(inline.opts, { newline = " ", indent = "" })))
	info(fmt("chat:   %s (%s)", chat.provider, vim.inspect(chat.opts, { newline = " ", indent = "" })))
	info(fmt("keymaps: %s", require("ducktape.keys").globals_enabled() and "defaults created" or "globals disabled"))
end

function M.check()
	check_deps()
	check_parsers()
	check_internals()
	check_binaries()
	check_config()
end

return M
