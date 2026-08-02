-- Every knob the plugin has, and the values it ships with.
--
-- The defaults here are the configuration this plugin was extracted from, unchanged, so an empty
-- `opts` reproduces that setup exactly. Anything a user passes is deep-merged over them.
--
-- Two routes arrive here, because `plugin/ducktape.lua` runs before a plugin manager has applied
-- any `opts`:
--
--   vim.g.ducktape      `keymaps` and `statusline` — read at plugin-script time, i.e. startup
--   extension opts      everything else — read when codecompanion.setup() loads the extension
--
-- `keymaps` may also arrive through the extension route as a late override. Unknown keys are not
-- rejected here; `health.lua` reports them, per :h lua-plugin-config.

local M = {}

---Factory for an ollama HTTP adapter. `overrides` is deep-merged over the shared schema.
---@param overrides table|nil
---@return fun(): table
local function ollama_adapter(overrides)
	return function()
		local providers = require("ducktape.providers")
		return require("codecompanion.adapters").extend(
			"ollama",
			vim.tbl_deep_extend("force", {
				schema = {
					model = {
						default = function()
							return providers.current("inline").opts.model
						end,
					},
					think = {
						default = function()
							return providers.current("inline").opts.think == "on"
						end,
					},
					keep_alive = { default = "30m" }, -- keeps the local model warm between calls
					num_ctx = { default = 16384 }, -- ollama's own default silently truncates a real refactor
				},
			}, overrides or {})
		)
	end
end

M.defaults = {
	-- Provider specs and the current selection. Both are deep-merged into ducktape.providers,
	-- which owns the shipped values; leaving these empty keeps them exactly as shipped.
	--
	-- What can be retuned: the models, defaults, effort, mode, and which options each provider
	-- offers. What cannot: adding a fourth provider kind. Provider names are load-bearing in
	-- about eighteen places across chat, status, chat_list and pick, so the three that ship are
	-- the three there are.
	providers = {},
	defaults = {},

	-- The adapters codecompanion resolves by name. These carry the write defence, so they are
	-- installed by the plugin rather than left for a user to paste into their own config.
	adapters = {
		http = {
			ollama = ollama_adapter({ env = { url = "http://localhost:11434" } }),
			ollama_cloud = ollama_adapter({
				env = {
					url = "https://ollama.com",
					api_key = function()
						return os.getenv("OLLAMA_API_KEY")
					end,
				},
				headers = { Authorization = "Bearer ${api_key}" },
			}),
		},
		acp = {
			claude_code = function()
				local adapter = require("codecompanion.adapters").extend("claude_code", {
					-- The stock value is 20s, and every adapter definition must restate
					-- the 90s one or silently inherit it.
					defaults = {
						timeout = 90000,
						-- The actual write defence: dontAsk denies mutating tools,
						-- shell redirects included. Chat overrides this per session.
						session_config_options = { mode = "dontAsk" },
					},
					-- Hygiene, not enforcement — the capability is inert for both
					-- agents. Advertise nothing we do not intend to serve.
					parameters = {
						clientCapabilities = { fs = { readTextFile = false, writeTextFile = false } },
					},
				})
				-- Drops CLAUDE_CODE_OAUTH_TOKEN from the adapter definition, which is
				-- unnecessary since authMethods is empty. Hygiene only, on two counts:
				-- the child process still inherits the variable from nvim's own
				-- environment, and the old _establish_session stalls turned out to be a
				-- stale claude-agent-acp 0.55.0 that nvm's bin directory put ahead of
				-- Homebrew's 0.59.0 on PATH — not this token.
				-- Assigned rather than merged: tbl_deep_extend cannot remove a key.
				adapter.env = {}
				-- `--yolo` is the exact opposite of what inline wants
				adapter.commands.yolo = nil
				return adapter
			end,
			opencode = function()
				local adapter = require("codecompanion.adapters").extend("opencode", {
					defaults = { timeout = 90000 },
					parameters = {
						clientCapabilities = { fs = { readTextFile = false, writeTextFile = false } },
					},
				})
				adapter.env = {
					OPENCODE_PERMISSION = function()
						return vim.json.encode(require("ducktape.providers").opencode_permission)
					end,
				}
				return adapter
			end,
		},
	},

	-- Claimed only when codecompanion's own stock value is still in place, so a user's explicit
	-- choice survives. See ducktape.setup.
	set_default_adapters = true,

	-- Global keymaps. `false` suppresses the whole <leader>c* set and leaves only the
	-- <Plug>(Ducktape…) maps; `globals = false` inside the table does the same while keeping any
	-- per-action overrides. The buffer-local diff keys are unaffected either way.
	keymaps = {
		globals = true,
		chat_toggle = { "<leader>cc", mode = { "n" }, desc = "AI: toggle last chat" },
		chat_new = { "<leader>cn", mode = { "n", "x" }, desc = "AI: new chat (current provider + options)" },
		chat_close_all = { "<leader>cq", mode = { "n" }, desc = "AI: close all chats" },
		chat_rename = { "<leader>cr", mode = { "n" }, desc = "AI: rename current chat" },
		chat_delete = { "<leader>cd", mode = { "n" }, desc = "AI: delete current chat and its saved transcript" },
		chat_list = { "<leader>cl", mode = { "n" }, desc = "AI: chat list" },
		chat_pick = { "<leader>cmc", mode = { "n" }, desc = "AI: switch chat backend / model" },
		actions = { "<leader>ca", mode = { "n", "x" }, desc = "CodeCompanion: action palette" },
		inline = { "<leader>ci", mode = { "n", "x" }, desc = "AI: inline prompt (no tools)" },
		inline_deep = { "<leader>cI", mode = { "n", "x" }, desc = "AI: inline prompt, may read the repo" },
		inline_pick = { "<leader>cmi", mode = { "n" }, desc = "AI: switch inline backend / model" },
		inline_list = { "<leader>cL", mode = { "n" }, desc = "AI: inline list (in flight + waiting for review)" },
		inline_accept_all = { "<leader>cA", mode = { "n" }, desc = "AI: accept all inline diffs in this buffer" },
		inline_ask_again = {
			"<leader>cR",
			mode = { "n" },
			desc = "AI: ask again about the inline edit under the cursor",
		},
		cancel = {
			"<leader>cx",
			mode = { "n" },
			desc = "AI: cancel inline request under cursor / stop chat agent",
		},
		cancel_all = { "<leader>cX", mode = { "n" }, desc = "AI: cancel all inline requests in this buffer" },
		status = { "<leader>cs", mode = { "n" }, desc = "AI: status panel" },

		-- Buffer-local, bound on a pending inline diff and torn down with it. Not part of the
		-- `globals` switch: they only exist while a diff is waiting, so they cannot collide with
		-- anything the user has mapped the rest of the time.
		diff_accept = { "g2", desc = "AI: accept the diff under the cursor" },
		diff_reject = { "g3", desc = "AI: reject the diff under the cursor" },
		diff_next_hunk = { "<leader>cj", desc = "AI: next hunk in the diff under the cursor" },
		diff_prev_hunk = { "<leader>ck", desc = "AI: previous hunk in the diff under the cursor" },
	},

	-- The inline counters in the statusline: the only place that says something arrived while you
	-- were in another file. Injected from plugin/ducktape.lua at startup, so it is present on the
	-- first redraw rather than whenever codecompanion happens to load.
	statusline = { enabled = true },

	opencode = {
		-- The tool-free relay. Contract: content on stdin, request as arguments, answer on
		-- stdout; exit 1 usage, 2 empty input, 3 missing opencode/jq, 5 no free model, 6 API
		-- error, 124 timeout. Anything meeting that contract can stand in.
		relay = { cmd = "opencode-llm" },
		-- Where the relay's own free-model list lives, checked in this order.
		models_json = {
			"$XDG_CONFIG_HOME/opencode/opencode-models.json",
			"~/.config/opencode/opencode-models.json",
			"~/.local/config/opencode-models.json",
		},
	},

	-- Passed to codecompanion.setup() only on the standalone path, where this plugin sets
	-- codecompanion up itself. Ignored when loaded as an extension, since codecompanion has by
	-- then already been configured by whoever listed us in its `extensions`.
	codecompanion = {},
}

---@type table|nil
local resolved

---The merged configuration. Reads `vim.g.ducktape` on first call so `plugin/ducktape.lua` can ask
---for it before any `setup()` has run.
---@return table
function M.get()
	if not resolved then
		local from_g = type(vim.g.ducktape) == "table" and vim.g.ducktape or {}
		resolved = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), from_g)
	end
	return resolved
end

---Merge `opts` over what is already resolved, and validate the types.
---
---Called from the extension, which is later than `plugin/ducktape.lua`'s first `get()`. Merging
---rather than replacing is what lets the two routes coexist: whatever `vim.g.ducktape` set is
---still in place unless `opts` names the same key.
---@param opts table|nil
---@return table
function M.setup(opts)
	opts = opts or {}
	local cfg = vim.tbl_deep_extend("force", M.get(), opts)

	-- `keymaps = false` is a shorthand the deep merge cannot express, so it is normalised here
	-- into the table form the rest of the code reads.
	if cfg.keymaps == false then
		cfg.keymaps = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults.keymaps), { globals = false })
	end

	vim.validate({
		providers = { cfg.providers, "table" },
		defaults = { cfg.defaults, "table" },
		adapters = { cfg.adapters, "table" },
		keymaps = { cfg.keymaps, "table" },
		statusline = { cfg.statusline, "table" },
		opencode = { cfg.opencode, "table" },
		set_default_adapters = { cfg.set_default_adapters, "boolean" },
		codecompanion = { cfg.codecompanion, "table" },
	})
	vim.validate({
		["opencode.relay.cmd"] = { cfg.opencode.relay.cmd, "string" },
		["opencode.models_json"] = { cfg.opencode.models_json, "table" },
		["statusline.enabled"] = { cfg.statusline.enabled, "boolean" },
		["keymaps.globals"] = { cfg.keymaps.globals, "boolean" },
	})

	resolved = cfg
	return resolved
end

return M
