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

--=============================================================================
-- Adapter factories
--=============================================================================

---Factory for an HTTP adapter backing one endpoint of one provider.
---
---Everything that used to be written twice — the URL, the API-key environment variable — is read
---off the provider spec at resolve time instead, so `providers.<name>.endpoints` is the only place
---that knows. `extends` names the codecompanion adapter to build on.
---@param provider string
---@param endpoint string
---@param extends string
---@param overrides table|nil Deep-merged over the shared schema
---@return fun(): table
function M.http_adapter(provider, endpoint, extends, overrides)
	return function()
		local providers = require("ducktape.providers")
		local entry = providers.endpoints(provider)[endpoint] or {}

		local env = { url = entry.url }
		local headers
		if entry.api_key_env then
			env.api_key = function()
				return os.getenv(entry.api_key_env)
			end
			headers = { Authorization = "Bearer ${api_key}" }
		end

		return require("codecompanion.adapters").extend(
			extends,
			vim.tbl_deep_extend("force", {
				env = env,
				headers = headers,
				schema = {
					-- The scope is inline here because that is what this adapter is claimed for by
					-- default; `ducktape.chat` re-points these two at the chat scope when it
					-- resolves the same adapter for a chat.
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

---Factory for an ACP adapter, carrying the requested half of a provider's write defence.
---
---The `timeout` and the `clientCapabilities` are the same for every ACP provider; what differs is
---the session options and the environment, both of which come from the provider's `guard`. So a
---provider added through config gets the same treatment as the three that ship, without having to
---restate any of this.
---@param provider string
---@param extends string
---@param overrides table|nil
---@return fun(): table
function M.acp_adapter(provider, extends, overrides)
	return function()
		local providers = require("ducktape.providers")
		local cfg = M.get()

		local adapter = require("codecompanion.adapters").extend(
			extends,
			vim.tbl_deep_extend("force", {
				-- The stock value is 20s, and every adapter definition must restate the 90s one
				-- or silently inherit it.
				defaults = {
					timeout = cfg.pool.timeout_ms,
					-- The requested half of the write defence. The verified half is in
					-- ducktape.acp_pool, which is the one that actually keeps writes out.
					session_config_options = providers.required_session_options(provider),
				},
				-- Hygiene, not enforcement — the capability is inert for both shipped agents.
				-- Advertise nothing we do not intend to serve.
				parameters = {
					clientCapabilities = { fs = { readTextFile = false, writeTextFile = false } },
				},
			}, overrides or {})
		)

		-- Merged into whatever the adapter already had rather than replacing it: a third-party ACP
		-- adapter may carry its own API-key entry, and wiping that would stop it authenticating.
		-- Only touched at all when the provider's guard actually names an environment variable.
		local guard_env = providers.guard_env(provider, "inline")
		if next(guard_env) then
			adapter.env = adapter.env or {}
			for name in pairs(guard_env) do
				adapter.env[name] = function()
					-- Resolved per spawn rather than captured, so a config change lands without a
					-- restart and the JSON is encoded from whatever the spec says now.
					return providers.guard_env(provider, "inline")[name]
				end
			end
		end
		return adapter
	end
end

---The claude adapter, which needs two things no other ACP provider does.
---@return table
local function claude_adapter()
	local adapter = M.acp_adapter("claude", "claude_code")()
	-- Drops CLAUDE_CODE_OAUTH_TOKEN from the adapter definition, which is unnecessary since
	-- authMethods is empty. Hygiene only, on two counts: the child process still inherits the
	-- variable from nvim's own environment, and the old _establish_session stalls turned out to be
	-- a stale claude-agent-acp 0.55.0 that nvm's bin directory put ahead of Homebrew's 0.59.0 on
	-- PATH — not this token.
	adapter.env = {}
	-- `--yolo` is the exact opposite of what inline wants
	adapter.commands.yolo = nil
	return adapter
end

M.defaults = {
	-- Provider specs and the current selection. Both are deep-merged into ducktape.providers,
	-- which owns the shipped values; leaving these empty keeps them exactly as shipped.
	--
	-- This is a registry: a name that is not one of the three shipped ones adds a provider rather
	-- than being ignored. What a spec may carry is documented on `ducktape.providers.providers`.
	-- An ACP provider that names no `guard.required` has one derived from whatever write-denying
	-- mode its agent advertises, so the smallest useful spec is also a safe one.
	providers = {},
	defaults = {},

	-- Session `mode` values that count as denying writes, most preferred first. Consulted when a
	-- provider's guard is derived rather than named. Widen it only if you know a mode is safe.
	safe_modes = nil, -- nil = ducktape.providers.SAFE_MODES

	-- The adapters codecompanion resolves by name. These carry the write defence, so they are
	-- installed by the plugin rather than left for a user to paste into their own config.
	--
	-- A provider added through `providers` with an `endpoints` table whose entries name `extends`
	-- gets its HTTP adapters generated, so this only needs an entry for something the generator
	-- cannot describe.
	adapters = {
		-- Empty on purpose. Both ollama adapters are generated from `providers.ollama.endpoints`
		-- by `ducktape.setup`, so the shipped provider takes the same path an added one does — the
		-- surest way for that path not to rot. Name an adapter here to define it by hand instead;
		-- an explicit entry always wins over a generated one.
		http = {},
		acp = {
			claude_code = claude_adapter,
			opencode = M.acp_adapter("opencode", "opencode"),
		},
	},

	-- Claimed only when codecompanion's own stock value is still in place, so a user's explicit
	-- choice survives. See ducktape.setup.
	set_default_adapters = true,

	-- Inline editing. `prompt` is the contract the model is held to and the single biggest lever on
	-- the quality of what comes back, so it is configurable rather than compiled in.
	inline = {
		-- Lines of surrounding context sent either side of the selection.
		context_lines = 40,
		-- One value for every transport. The three used to disagree by 30s for no reason anyone
		-- had written down.
		timeout_ms = 90000,
		-- Send the buffer's diagnostics for the selected range along with the prompt.
		diagnostics = true,

		prompt = {
			-- One contract for every transport. An earlier revision asked HTTP and relay for a
			-- `{"code":"…"}` envelope instead; that is reverted, and deliberately not to be
			-- reintroduced. Measured on ollama cloud with the same selection: under the envelope
			-- the model returned the whole enclosing function — the <before> and <after> context
			-- included — while the plain contract returned exactly the selected lines. No envelope
			-- survives a code fragment whose braces do not balance, which is most fragments.
			contract = [[
You are an inline code editor inside Neovim. The editor decides where your output goes;
you only supply code. Return ONLY the replacement text for the selected region.
Reproduce every line you are not changing exactly as given. Do not add commentary.]],
			no_tools = "You have no tools. Work only from the text below.",
			deep = [[
You may read files in this repository to learn its conventions before answering.
Do not modify any file: the editor applies your output, not you.]],
			insert = [[
The selected region is empty. Return only the new code to insert at that point.]],
		},

		-- How a reply is judged to be code or prose. Every list here is *added to* the shipped one
		-- rather than replacing it, because the shipped values are measured and losing one is a
		-- regression nobody would notice until an edit silently did not happen.
		--
		-- The reason this is configurable at all: refusal phrasing is per-model-family and
		-- English-only as shipped, so a provider whose refusals read differently would have them
		-- applied to the buffer as if they were code.
		parse = {
			refusal_openers = {},
			lead_ins = {},
			prose_filetypes = {},
			comment_prefixes = {},
			leak_patterns = {},
			-- Set to true to use only what is configured above, ignoring the shipped lists.
			replace = false,
		},
	},

	-- The pool of ACP connections behind inline. One warm primary per provider, overflow spawned
	-- on demand and reaped when idle.
	pool = {
		-- Per provider. opencode idles at ~536 MB, so this cap earns its keep there; an agent with
		-- a lighter footprint can afford more.
		cap = 3,
		idle_overflow_ms = 60 * 1000,
		idle_primary_ms = 15 * 60 * 1000,
		reap_interval_ms = 15 * 1000,
		timeout_ms = 90 * 1000,
	},

	-- What this plugin's own windows look like, and where its highlights come from.
	ui = {
		border = "rounded",
		-- Which picker the chat list and the model pickers use. "auto" takes the first of
		-- telescope, snacks, fzf-lua and mini.pick that is installed, and falls back to a plain
		-- float this plugin draws itself — so none of them is a hard requirement.
		picker = "auto",
		spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
		-- Merged over the palette-derived values. Anything set here wins, and every group is
		-- defined with `default = true` so a colourscheme or your own `nvim_set_hl` wins over both.
		highlights = {},
	},

	-- The chat as a window. It is a sidecar to the file it was opened next to, and nvim has no way
	-- to know that: to it the chat window is an ordinary window, so closing the file leaves a
	-- session that is nothing but chat — one that cannot even be toggled away, because the hide
	-- codecompanion does it with is E444 on the last window.
	chat = {
		-- Closing the last file window takes the chat with it, which quits the session. A tab that
		-- empties this way has its chat hidden instead, when other tabs still hold files.
		close_with_last_file = true,
		-- `:q` in the chat quits the session, the same as `:q` in the last file window. Putting the
		-- chat away without quitting is what `<leader>cc` is for, so `:q` is free to mean what it
		-- says. Set false to have `:q` close only the chat window.
		quit_closes_session = true,
	},

	-- What counts as "this project". Two settings, because the two things being scoped want
	-- different answers and always have — collapsing them onto one would silently move somebody's
	-- saved chats.
	--
	-- Each takes:
	--   "git"  the repository root, from `git rev-parse --show-toplevel`
	--   "root" the nearest ancestor holding a `.git`, via vim.fs.root — no subprocess, but it does
	--          not resolve symlinks, and an agent reporting a resolved path would then not match
	--   "cwd"  the working directory
	--   fun()  anything you like, returning a path or nil
	session = {
		-- Which resumable agent sessions the chat list offers. The repository root, so sessions do
		-- not vanish when nvim is opened in a subdirectory — which is what this was for.
		scope = "git",
		-- What saved chats are filed under. The working directory, so two subdirectories of one
		-- repository keep their own sets of chats.
		--
		-- Set this to "git" to share one set per repository instead, which also makes it agree with
		-- `scope` above. Doing so migrates every existing cwd-keyed set under that root into one,
		-- merged rather than first-wins — see `read_entries` in ducktape.chat.
		chats = "cwd",
	},

	-- Global keymaps. `false` suppresses the whole <leader>c* set and leaves only the
	-- <Plug>(Ducktape…) maps; `globals = false` inside the table does the same while keeping any
	-- per-action overrides. The buffer-local diff keys are unaffected either way.
	keymaps = {
		globals = true,
		chat_toggle = { "<leader>cc", mode = { "n" }, desc = "AI: toggle last chat" },
		chat_focus = { "<leader>cf", mode = { "n" }, desc = "AI: jump between the chat and the file" },
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
		models_refresh = { "<leader>cmr", mode = { "n" }, desc = "AI: re-ask every provider for its models" },
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

		-- Buffer-local keys inside this plugin's own windows. `:h lua-plugin-keymaps` calls these
		-- uncontroversial, and they are — but `a`, `r` and `x` sit on strong muscle memory, so
		-- there is a way out. Each entry is a list of keys; all of them are bound to the action.
		panels = {
			inline_list = {
				down = { "j", "<Down>" },
				up = { "k", "<Up>" },
				-- Three verbs, one each: keep it, get rid of it, go again. g2/g3 come along as
				-- aliases because they are what settles a diff in the buffer itself.
				accept = { "a", "g2" },
				retry = { "r" },
				discard = { "x", "g3" },
				open = { "<CR>" },
				help = { "?" },
				close = { "q", "<Esc>" },
			},
			status = {
				down = { "j", "<Down>" },
				up = { "k", "<Up>" },
				next_value = { "l", "<Right>", "<Tab>" },
				prev_value = { "h", "<Left>", "<S-Tab>" },
				edit = { "<CR>" },
				close = { "q", "<Esc>" },
			},
			picker = {
				down = { "j", "<Down>" },
				up = { "k", "<Up>" },
				next_value = { "l", "<Right>", "<Tab>" },
				prev_value = { "h", "<Left>", "<S-Tab>" },
				apply = { "<CR>" },
				discard = { "q", "<Esc>" },
			},
			chat_list = {
				help = { "<C-_>", "<C-/>" },
				close = { "<C-c>" },
				delete = { "<C-d>" },
				rename = { "<C-r>" },
				kill = { "<C-x>" },
			},
			message = {
				close = { "q", "<Esc>" },
				confirm = { "<CR>" },
			},
		},
	},

	-- The inline counters in the statusline: the only place that says something arrived while you
	-- were in another file. Injected from plugin/ducktape.lua at startup, so it is present on the
	-- first redraw rather than whenever codecompanion happens to load.
	statusline = {
		enabled = true,
		-- Ordered, because the segment reads left to right in the order things happen: sent,
		-- answered, waiting on a decision, gave up.
		icons = {
			{ key = "running", icon = "↻", hl = "DucktapeListStarting" },
			{ key = "answered", icon = "◆", hl = "DucktapeListReady" },
			{ key = "review", icon = "◆", hl = "DucktapeListCurrent" },
			{ key = "failed", icon = "✖", hl = "DucktapeListDead" },
		},
		label = "AI",
	},

	-- Deprecated. `prefer` moved onto the opencode provider spec, so everything about a provider
	-- is in one place. Still honoured, and wins over the spec when set, so an existing config
	-- keeps working.
	--   opts.opencode.prefer  →  opts.providers.opencode.auto.prefer
	opencode = { prefer = nil },

	-- Passed to codecompanion.setup() only on the standalone path, where this plugin sets
	-- codecompanion up itself. Ignored when loaded as an extension, since codecompanion has by
	-- then already been configured by whoever listed us in its `extensions`.
	codecompanion = {},
}

---@type table|nil
local resolved

---`keymaps = false` is a shorthand the deep merge cannot express, so it is normalised into the table
---form the rest of the code reads. Applied on both routes: `plugin/ducktape.lua` asks `M.get()` for
---the keymaps long before any `setup()` runs, so normalising only in `setup` would leave
---`vim.g.ducktape = { keymaps = false }` creating the whole default set it asked to suppress.
---@param cfg table
---@return table
local function normalise(cfg)
	if cfg.keymaps == false then
		cfg.keymaps = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults.keymaps), { globals = false })
	end
	return cfg
end

---Fold the deprecated top-level `opencode` block onto the provider spec it moved to.
---
---Done here rather than in `providers.apply` so it works on the config-only path too: a caller
---that has set the config but not run a full `setup` still gets the value it asked for.
---@param cfg table
local function migrate_opencode(cfg)
	local legacy = cfg.opencode or {}
	local moved = {}
	if legacy.prefer then
		moved.auto = { prefer = legacy.prefer }
	end
	if next(moved) then
		cfg.providers = cfg.providers or {}
		-- "keep" rather than "force": an explicit `providers.opencode` entry is the current
		-- spelling and outranks the deprecated one.
		cfg.providers.opencode = vim.tbl_deep_extend("keep", cfg.providers.opencode or {}, moved)
	end
	return cfg
end

---The merged configuration. Reads `vim.g.ducktape` on first call so `plugin/ducktape.lua` can ask
---for it before any `setup()` has run.
---@return table
function M.get()
	if not resolved then
		local from_g = type(vim.g.ducktape) == "table" and vim.g.ducktape or {}
		resolved = normalise(vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), from_g))
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
	local cfg = normalise(migrate_opencode(vim.tbl_deep_extend("force", M.get(), opts)))

	for name, value in pairs({
		providers = cfg.providers,
		defaults = cfg.defaults,
		adapters = cfg.adapters,
		keymaps = cfg.keymaps,
		statusline = cfg.statusline,
		inline = cfg.inline,
		pool = cfg.pool,
		ui = cfg.ui,
		session = cfg.session,
		opencode = cfg.opencode,
		codecompanion = cfg.codecompanion,
	}) do
		vim.validate(name, value, "table")
	end
	vim.validate("set_default_adapters", cfg.set_default_adapters, "boolean")
	vim.validate("safe_modes", cfg.safe_modes, "table", true)
	vim.validate("statusline.enabled", cfg.statusline.enabled, "boolean")
	vim.validate("statusline.icons", cfg.statusline.icons, "table")
	vim.validate("keymaps.globals", cfg.keymaps.globals, "boolean")
	vim.validate("keymaps.panels", cfg.keymaps.panels, "table")
	vim.validate("inline.context_lines", cfg.inline.context_lines, "number")
	vim.validate("inline.timeout_ms", cfg.inline.timeout_ms, "number")
	vim.validate("inline.diagnostics", cfg.inline.diagnostics, "boolean")
	vim.validate("inline.prompt", cfg.inline.prompt, "table")
	vim.validate("inline.parse", cfg.inline.parse, "table")
	vim.validate("ui.picker", cfg.ui.picker, { "string", "function" })
	vim.validate("ui.border", cfg.ui.border, { "string", "table" })
	vim.validate("ui.highlights", cfg.ui.highlights, "table")
	vim.validate("session.scope", cfg.session.scope, { "string", "function" })
	for _, key in ipairs({ "cap", "idle_overflow_ms", "idle_primary_ms", "reap_interval_ms", "timeout_ms" }) do
		vim.validate("pool." .. key, cfg.pool[key], "number")
	end

	resolved = cfg
	return resolved
end

return M
