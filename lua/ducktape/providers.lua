-- Single source of truth for the AI integration: which providers exist, what options each
-- carries, what is currently selected, and how far each transport can reach into the machine.
-- Inline, chat and the status panel all read this module, which is what makes the option UX
-- shared rather than reimplemented per surface.
--
-- This is a *registry*, not a fixed set. Every provider is described by a spec, and every
-- consumer reads the spec rather than branching on a provider's name. Adding a fourth provider
-- is `providers.<name> = { … }` in your own config; nothing here or in the surfaces needs an
-- edit. What a spec may say is documented on the shipped three below and in `:h ducktape`.
--
-- Three properties are load-bearing enough to be worth stating up front, because they are what
-- keeps an unknown provider from being worse than no provider:
--
--   * a provider's inline transport comes from its own spec, so it can never be routed through
--     another provider's relay (which is what a name-keyed if-chain used to do);
--   * an ACP provider's write defence is *derived from the live agent* when the spec does not
--     name one, by choosing the most restrictive mode the agent itself advertises;
--   * if no write-denying mode can be found, inline-over-ACP is withheld for that provider
--     alone. Chat still works. Setup still succeeds. `:checkhealth ducktape` says so.

local M = {}

-- Whether a transport can touch the filesystem is a property of the transport, not of which
-- keymap was pressed. Measured, not assumed: neither shipped agent uses the client-mediated fs/*
-- path, so what a transport can reach is decided by the agent process, not by us.
M.transports = {
	http = { read = false, write = false, note = "no filesystem access at all" },
	relay = { read = false, write = false, note = "no filesystem access at all" },
	acp = { read = true, write = false, note = "can read any file you can; writes denied" },
}

-- Sentinel for a model option whose value is "let the provider walk its own fallback list"
-- instead of pinning one model, so a dead model degrades instead of failing.
M.AUTO = "auto"

-- Session `mode` values that deny writes, most preferred first. Used to *derive* an inline write
-- defence for an ACP provider whose spec does not name one: the agent advertises its own modes
-- through session config options, so the safe one can be found rather than configured.
--
-- Order is by usefulness-while-still-safe, not by strictness. `dontAsk` auto-denies mutating tools
-- while leaving the agent otherwise normal, which is what inline wants. `plan` is read-only and
-- also safe, but some agents treat it as "produce a plan, not an answer", so it is second.
--
-- Modes that *ask* are deliberately absent. Inline has no UI to answer a permission prompt, so an
-- asking mode is not a defence — it is a hang.
M.SAFE_MODES = { "dontAsk", "plan", "readOnly", "readonly", "read-only" }

-- Which tier an opencode model belongs to is decided by its provider prefix, per opencode's own
-- prefix rule: `opencode/` is the free tier, `opencode-go/` is the Go subscription. Not by the
-- `-free` suffix, which `opencode/big-pickle` does not carry despite being free.
local GO_PREFIX = "opencode-go/"
local FREE_PREFIX = "opencode/"

---Is this a free-tier opencode model?
---@param model string
---@return boolean
function M.is_free_opencode_model(model)
	return type(model) == "string" and vim.startswith(model, FREE_PREFIX)
end

---Is this an OpenCode Go model, i.e. one that draws on the Go subscription?
---@param model string
---@return boolean
function M.is_go_opencode_model(model)
	return type(model) == "string" and vim.startswith(model, GO_PREFIX)
end

--=============================================================================
-- The registry
--=============================================================================

-- What a provider spec may carry. Everything except `label` has a default, and the defaults are
-- chosen so that the smallest possible spec is also a safe one.
--
--   label            string, shown wherever the provider is named
--   kind             "acp" | "http". Inferred from codecompanion's adapter registry if absent.
--   adapter          string | fun(scope, opts): string — the codecompanion adapter name
--   endpoints        table<string, { url, adapter, api_key_env?, tier? }> for HTTP providers
--                    whose endpoint decides which models exist (see ollama)
--   options          table<string, { label, category?, values?, dynamic? }>
--   inline_options   string[] — which options inline offers, in order
--   chat_options     string[] — likewise for chat
--   transports       { shallow = "http"|"relay"|"acp", deep = … }. Defaulted from `kind`.
--   relay            { cmd, exits } — a tool-free subprocess transport, if the provider has one
--   guard            see `M.effective_guard`
--   models           see `M.models_async`
--   auto             { prefer = string[], eligible = fun(model): boolean, warn = string }
--   tier             fun(model, opts): { label, free } | nil
--   capabilities     { resumable_sessions = boolean }
--   value_notes      table<string, table<string, string>> — what a value means, per option
--   option_notes     table<string, string> — a standing caveat about an option
---@type table<string, table>
M.providers = {
	ollama = {
		label = "Ollama",
		kind = "http",
		-- The endpoint is part of which model you get rather than a separate question: the two
		-- lists barely overlap. Describing it as data is what lets the picker, the model
		-- discovery and the adapter choice all derive from one place.
		-- `extends` names the codecompanion adapter each endpoint builds on, which is what lets
		-- `ducktape.setup` generate the adapter definitions instead of them being written out by
		-- hand. The two shipped ollama adapters come from exactly this, so the path an added
		-- provider takes is the one the shipped provider already uses.
		endpoints = {
			cloud = {
				url = "https://ollama.com",
				adapter = "ollama_cloud",
				extends = "ollama",
				api_key_env = "OLLAMA_API_KEY",
				-- ollama's free cloud tier: light GPU-time usage, 1 concurrent model, so free
				-- but rate-limited.
				tier = { label = "free · cloud", free = true },
			},
			-- Runs on this machine; no account, no quota.
			["local"] = {
				url = "http://localhost:11434",
				adapter = "ollama",
				extends = "ollama",
				tier = { label = "free · local", free = true },
			},
		},
		models = { strategy = "http_tags", path = "/api/tags", field = "models", name_key = "name" },
		inline_options = { "endpoint", "model", "think" },
		chat_options = { "endpoint", "model", "think" },
		options = {
			endpoint = { label = "Endpoint", values = { "cloud", "local" } },
			model = { label = "Model", dynamic = true },
			-- `to_schema` converts a stored option value into what the codecompanion adapter schema
			-- wants. Only needed where the two disagree, as here: the option is an enum the picker
			-- can cycle, the schema field is a boolean.
			think = {
				label = "Think",
				values = { "off", "on" },
				to_schema = function(value)
					return value == "on"
				end,
			},
		},
		-- Plain HTTP: there is no agent process, so there is no session to resume.
		capabilities = { resumable_sessions = false },
	},

	claude = {
		label = "Claude",
		kind = "acp",
		adapter = "claude_code",
		-- claude-agent-acp authenticates with CLAUDE_CODE_OAUTH_TOKEN (no ANTHROPIC_API_KEY
		-- anywhere in this config), so usage counts against the subscription.
		tier = function()
			return { label = "subscription · claude", free = false }
		end,
		-- The seed is what the picker shows before an agent has ever run; the live session is
		-- authoritative and replaces it, so a model released after this was written still appears.
		models = { strategy = "live_session", seed = { "default", "sonnet", "opus", "haiku" } },
		-- Named rather than derived. `plan` would also be safe and `M.SAFE_MODES` would find it,
		-- but `dontAsk` is the better answer here and only the spec knows that: it denies mutating
		-- tools while leaving the agent otherwise normal, where claude's `plan` produces a plan
		-- instead of an edit.
		guard = { required = { mode = "dontAsk" } },
		inline_options = { "model", "effort", "fast" },
		chat_options = { "model", "effort", "fast", "mode", "agent" },
		options = {
			-- Values below were read off a live session's configOptions. The status panel
			-- re-resolves them from the connection, since the set is model-dependent.
			model = { label = "Model", category = "model", values = { "default", "sonnet", "opus", "haiku" } },
			effort = {
				label = "Effort",
				category = "thought_level",
				values = { "default", "low", "medium", "high", "xhigh", "max" },
			},
			-- Offered only on models that support it — opus does, sonnet does not. Sending it
			-- for a model that lacks it is harmless but logs a warning on every spawn, so it
			-- stays unset by default and the status panel adds it when the session offers it.
			fast = { label = "Fast", category = "model_config", values = { "on", "off" } },
			-- What each value does, read off the agent rather than guessed from the name:
			-- `default` asks before every mutating tool call, `acceptEdits` applies edits
			-- unannounced, `plan` is read-only, and `dontAsk` auto-*denies* rather than
			-- auto-allowing (acp-agent.js:1615 lists it beside rule-based denials).
			mode = {
				label = "Mode",
				category = "mode",
				values = { "auto", "default", "acceptEdits", "plan", "dontAsk", "bypassPermissions" },
			},
			-- category = nil in the agent's own schema, so it can only be set after the session
			-- exists, via conn:set_config_option("agent", …). Chat-only. `after_session` is what
			-- tells chat to stash it and apply it on the first submit instead of at Chat.new time.
			agent = { label = "Agent", dynamic = true, category = nil, after_session = true },
		},
		-- What a value means where the name does not say it, and where getting it wrong is
		-- expensive. Two of mode's six values read as the opposite of what they do.
		value_notes = {
			mode = {
				default = "asks before editing",
				acceptEdits = "applies edits unannounced",
				plan = "read-only",
				dontAsk = "denies edits, does not allow them",
				bypassPermissions = "no checks at all",
				auto = "agent decides",
			},
		},
		-- `fast` is model-dependent and there is no per-model list to filter by, so the row says
		-- so rather than pretending to.
		option_notes = { fast = "opus only" },
		capabilities = { resumable_sessions = true },
	},

	opencode = {
		label = "OpenCode",
		kind = "acp",
		adapter = "opencode",
		-- opencode's published limits — $12/5h, $30/wk, $60/mo rolling windows, and "Free models
		-- don't count" — so Go models are what consume them. Both subscriptions are labelled the
		-- same way on purpose: an earlier revision called Go "paid" because its allowance happens
		-- to be denominated in dollars while Claude's is not, but that is the unit the window is
		-- measured in, not who is paying. Neither bills per token.
		tier = function(model)
			if model == M.AUTO then
				-- The relay only ever walks free models, and `resolve_chat_option_value` pins a
				-- free one when a live session needs something concrete, so this cannot cost.
				return { label = "free", free = true }
			end
			if M.is_go_opencode_model(model) then
				return { label = "subscription · Go", free = false }
			end
			if M.is_free_opencode_model(model) then
				return { label = "free", free = true }
			end
		end,
		-- `opencode models` is the only source that knows about the Go subscription, and the only
		-- one that knows what *this* machine is entitled to. It needs no live agent, which is why
		-- it beats asking a session.
		models = {
			strategy = "subprocess",
			cmd = { "opencode", "models" },
			-- Free first: the option that consumes nothing is the one that should be under the
			-- cursor when the list opens, with the Go tier a deliberate scroll away.
			--
			-- `ollama-cloud/*` entries are dropped: opencode can reach them, but there is an
			-- ollama provider for those already, and listing them twice under two providers would
			-- only raise the question of which one to pick.
			parse = function(stdout)
				local free, go = {}, {}
				for line in (stdout or ""):gmatch("[^\r\n]+") do
					local model = vim.trim(line)
					if M.is_free_opencode_model(model) then
						table.insert(free, model)
					elseif M.is_go_opencode_model(model) then
						table.insert(go, model)
					end
				end
				local out = { M.AUTO }
				vim.list_extend(out, free)
				vim.list_extend(out, go)
				return out
			end,
			-- The sentinel alone is not an answer, so this counts as "nothing came back".
			empty_when = 1,
			sentinel = { M.AUTO },
		},
		-- Which free model the AUTO sentinel becomes when a live session has to be pinned to
		-- something real. A preference, not a fact, which is why it is configured rather than
		-- derived: what a machine *can* reach comes from `opencode models`, but that is
		-- alphabetical, and letting the order decide put AUTO on opencode's own ambient default.
		-- Free-tier names change, so an entry that no longer exists is skipped, not an error.
		auto = {
			prefer = {
				"opencode/deepseek-v4-flash-free",
				"opencode/mimo-v2.5-free",
				"opencode/laguna-s-2.1-free",
				"opencode/ling-3.0-flash-free",
				"opencode/north-mini-code-free",
				"opencode/nemotron-3-ultra-free",
			},
			-- AUTO is what a user picked *instead of* naming a model, so resolving it onto a
			-- subscription model would spend budget on a value they never chose.
			eligible = function(model)
				return M.is_free_opencode_model(model)
			end,
			warn = "no free opencode model is known yet, so this session falls back to opencode's own "
				.. "default — :Ducktape models asks opencode what it can reach",
		},
		-- The tool-free relay, used for shallow inline. Guaranteed no repo access, free model.
		-- Native to `inline/relay.lua`, not a shelled-out script: it composes `opencode run`
		-- itself, walking `auto.prefer` (below) until one model answers. That also means no `jq`,
		-- and no dependency on anything in the user's own opencode config — the agent it runs
		-- under is self-provisioned into a project-local opencode.json ducktape owns, so a
		-- colleague with a bare `opencode` install gets the same tool-free path unmodified.
		--
		-- Why this and not ACP for shallow inline: `opencode acp` has no --agent flag, and denying
		-- a tool the model wants stops the execution but not the attempt, so tool-call markup leaks
		-- into the reply as text. The relay pairs the same deny set with a prompt telling the model
		-- it has no tools, which stops the attempt at source.
		relay = true,
		transports = { shallow = "relay", deep = "acp" },
		-- Derived rather than named: opencode's write defence is the OPENCODE_PERMISSION deny set
		-- below, which is a request and not something a session reports back. `M.SAFE_MODES` finds
		-- `plan` among the modes opencode advertises, which *is* readable off the live session —
		-- so the deep inline path gets a verified defence as well as a requested one.
		guard = {
			env = {
				-- Denying every tool backfires: the model still attempts one, nothing parses the
				-- attempt, and raw <tool_call> markup leaks into the reply as text. Allowing reads
				-- removes the leak entirely.
				OPENCODE_PERMISSION = {
					edit = "deny",
					write = "deny",
					patch = "deny",
					bash = "deny",
					read = "allow",
					grep = "allow",
					glob = "allow",
					list = "allow",
				},
			},
			chat_env = {
				-- Chat is meant to be able to change things, so the mutating tools are `ask`
				-- rather than `deny` — the same "show me before you do it" stance claude's
				-- `default` mode gives. Chat used to drop the permission block entirely, which
				-- handed it silent write access; nothing announced an edit and nvim did not even
				-- reload the file.
				OPENCODE_PERMISSION = {
					edit = "ask",
					write = "ask",
					patch = "ask",
					bash = "ask",
					read = "allow",
					grep = "allow",
					glob = "allow",
					list = "allow",
				},
			},
		},
		inline_options = { "model" },
		chat_options = { "model", "mode" },
		options = {
			model = { label = "Model", dynamic = true, category = "model" },
			mode = { label = "Mode", category = "mode", values = { "build", "plan" } },
		},
		value_notes = { mode = { build = "can edit", plan = "read-only" } },
		capabilities = { resumable_sessions = true },
	},
}

-- Free-first by policy. Inline defaults to opencode's relay, model left on `AUTO` rather than
-- pinned: `auto.prefer` above already puts `opencode/deepseek-v4-flash-free` first, so a fresh
-- install gets exactly that model on the first request — but pinning would throw away the walk
-- that lets the relay degrade onto the next preferred model if this one is ever renamed or
-- retired, which is a real risk for a free-tier name and not one worth taking for no latency gain.
M.defaults = {
	inline = {
		provider = "opencode",
		opts = {
			ollama = { endpoint = "local", model = "qwen3-coder:30b", think = "off" },
			claude = { model = "sonnet", effort = "medium" },
			opencode = { model = M.AUTO },
		},
	},
	chat = {
		provider = "claude",
		opts = {
			ollama = { endpoint = "cloud", model = "gpt-oss:120b", think = "off" },
			-- `default` rather than `acceptEdits`: the agent asks before it writes, and
			-- CodeCompanion answers with a diff of the proposed change. Edits landing
			-- unannounced is worth avoiding even now that open buffers follow them (ducktape.reload)
			-- — seeing the diff first is the difference between reviewing a change and
			-- discovering it. Switch a single session with <leader>cs if it gets tedious.
			claude = { model = "opus", effort = "xhigh", fast = "off", mode = "default" },
			opencode = { model = M.AUTO, mode = "build" },
		},
	},
}

--=============================================================================
-- Spec access
--=============================================================================

---The spec for a provider, or nil.
---@param provider string|nil
---@return table|nil
function M.spec(provider)
	return provider and M.providers[provider] or nil
end

---Every provider name, sorted, so every surface iterates in the same order.
---@param filter? fun(spec: table, name: string): boolean
---@return string[]
function M.names(filter)
	local out = {}
	for name, spec in pairs(M.providers) do
		if not filter or filter(spec, name) then
			table.insert(out, name)
		end
	end
	table.sort(out)
	return out
end

---What kind of transport backs this provider. Explicit in the spec, or inferred from
---codecompanion's own adapter registry, which is the only other place that knows.
---@param provider string
---@return "acp"|"http"
function M.kind(provider)
	local spec = M.spec(provider)
	if not spec then
		return "http"
	end
	if spec.kind then
		return spec.kind
	end
	-- Inferred lazily rather than at `apply` time: codecompanion's config is what holds the
	-- answer, and a spec can be read before it has been set up.
	local ok, cc = pcall(require, "codecompanion.config")
	if ok and spec.adapter and type(spec.adapter) == "string" then
		if cc.adapters and cc.adapters.acp and cc.adapters.acp[spec.adapter] then
			return "acp"
		end
	end
	return spec.relay and "acp" or "http"
end

---The endpoints table for a provider, always a table.
---@param provider string
---@return table<string, table>
function M.endpoints(provider)
	local spec = M.spec(provider)
	return (spec and spec.endpoints) or {}
end

---Endpoint names for a provider, in the order the `endpoint` option lists them so the picker and
---the discovery loop agree, falling back to sorted order.
---@param provider string
---@return string[]
function M.endpoint_names(provider)
	local spec = M.spec(provider)
	local endpoints = M.endpoints(provider)
	if not spec or vim.tbl_isempty(endpoints) then
		return {}
	end
	local option = spec.options and spec.options.endpoint
	local out = {}
	for _, name in ipairs((option and option.values) or {}) do
		if endpoints[name] then
			table.insert(out, name)
		end
	end
	if #out > 0 then
		return out
	end
	for name in pairs(endpoints) do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

--=============================================================================
-- Selection
--=============================================================================

---@type table<string, { provider: string, opts: table<string, table> }>|nil
local state

---The live selection, seeded from the defaults on first use.
---
---Resolved lazily rather than at chunk level. A keymap can pull this module in before
---`ducktape.setup` has merged the user's config — the bootstrap contract makes that unlikely, not
---impossible — and a snapshot taken then would silently ignore whatever they configured.
---@return table
local function selection()
	if not state then
		state = vim.deepcopy(M.defaults)
	end
	return state
end

---Give every known provider an options table in every scope.
---
---Without this, a provider added through `opts.providers` but not through `opts.defaults` is
---selectable and then throws on the first read: `current(scope).opts` is nil, so `.opts.model`,
---`set_option` and the adapter lookup all fail. `providers` and `defaults` arrive as independent
---config keys, so nothing else cross-checks them.
---@param into table
local function seed_opts(into)
	for _, scope in ipairs({ "inline", "chat" }) do
		into[scope] = into[scope] or {}
		into[scope].opts = into[scope].opts or {}
		for name in pairs(M.providers) do
			into[scope].opts[name] = into[scope].opts[name] or {}
		end
	end
end

---Merge the user's `providers` and `defaults` overrides into the shipped tables.
---
---Called once from `ducktape.setup`. Re-seeds the selection so an override to `defaults` lands
---even if something already read the selection into existence.
---@param cfg table The resolved ducktape config
function M.apply(cfg)
	if cfg.providers and next(cfg.providers) then
		M.providers = vim.tbl_deep_extend("force", M.providers, cfg.providers)
	end
	if cfg.defaults and next(cfg.defaults) then
		M.defaults = vim.tbl_deep_extend("force", M.defaults, cfg.defaults)
	end
	seed_opts(M.defaults)

	-- A selected provider that does not exist is a typo worth catching here rather than at the
	-- first keypress, and falling back is better than leaving the scope unusable.
	for _, scope in ipairs({ "inline", "chat" }) do
		local sel = M.defaults[scope]
		if sel and sel.provider and not M.providers[sel.provider] then
			local fallback = M.names()[1]
			require("ducktape.ui").say(
				("[ducktape] defaults.%s.provider = %q is not a known provider; using %q"):format(
					scope,
					tostring(sel.provider),
					tostring(fallback)
				),
				vim.log.levels.ERROR
			)
			sel.provider = fallback
		end
	end

	state = vim.deepcopy(M.defaults)
end

---The current selection for a scope
---@param scope "inline"|"chat"
---@return { provider: string, opts: table, spec: table }
function M.current(scope)
	local sel = selection()[scope]
	local provider = sel.provider
	-- `or {}` rather than a bare index: a provider added without a matching `defaults` entry used
	-- to make every reader of `.opts` throw. seed_opts covers the configured path; this covers a
	-- provider written straight into `M.providers` at runtime.
	return { provider = provider, opts = sel.opts[provider] or {}, spec = M.providers[provider] }
end

---The live options for a provider within a scope, selected or not. `M.current` only reaches
---the selected provider's, which is not enough when restoring a chat that belongs to the
---other one.
---@param scope "inline"|"chat"
---@param provider string
---@return table|nil
function M.opts_for(scope, provider)
	local sel = selection()[scope]
	return sel and sel.opts[provider] or nil
end

---@param scope "inline"|"chat"
---@param provider string
function M.set_provider(scope, provider)
	if not M.providers[provider] then
		return false, ("unknown provider: %s"):format(provider)
	end
	local sel = selection()[scope]
	sel.provider = provider
	sel.opts[provider] = sel.opts[provider] or {}
	return true
end

---@param scope "inline"|"chat"
---@param key string
---@param value string
function M.set_option(scope, key, value)
	local sel = selection()[scope]
	local spec = M.providers[sel.provider]
	if not spec or not spec.options or not spec.options[key] then
		return false, ("%s has no option %q"):format(sel.provider, key)
	end
	sel.opts[sel.provider] = sel.opts[sel.provider] or {}
	sel.opts[sel.provider][key] = value
	return true
end

--=============================================================================
-- Transports and adapters
--=============================================================================

---Which transport a provider uses for a given inline keymap.
---
---Read off the spec, never guessed from the name. The default for an ACP provider is its own
---agent for both depths: routing an unknown provider through another provider's relay — which a
---name-keyed if-chain did — sends the request to a different vendor's script entirely.
---@param provider string
---@param deep boolean True for <leader>cI, which invites repo research
---@return "http"|"relay"|"acp"
function M.transport(provider, deep)
	local spec = M.spec(provider)
	local key = deep and "deep" or "shallow"
	if spec and spec.transports and spec.transports[key] then
		return spec.transports[key]
	end
	if M.kind(provider) == "http" then
		return "http"
	end
	-- An ACP provider with a relay uses it for the shallow path only, since the relay is the
	-- tool-free half of the pair and `deep` is the one that may read the repo.
	if spec and spec.relay and not deep then
		return "relay"
	end
	return "acp"
end

---@param provider string
---@param deep boolean
---@return table reach The transports entry for this provider/keymap pair
function M.reach(provider, deep)
	return M.transports[M.transport(provider, deep)]
end

---Read a provider field out of the resolved config, so a value set through `opts` lands even when
---`M.apply` has not run.
---
---`apply` merges `opts.providers` into the specs, and after it has run this and the spec agree. But
---the config can legitimately be set without a full setup — and the deprecated `opts.opencode.*`
---keys are folded into `opts.providers.opencode` by `config.setup`, so looking here is also what
---keeps those working.
---@param provider string
---@param ... string Path within the provider's config entry
---@return any
local function from_config(provider, ...)
	local ok, cfg = pcall(function()
		return require("ducktape.config").get()
	end)
	if not ok or type(cfg) ~= "table" then
		return nil
	end
	return vim.tbl_get(cfg, "providers", provider, ...)
end

---Whether a provider has a tool-free relay transport at all.
---@param provider string
---@return true|nil
function M.relay(provider)
	local spec = M.spec(provider)
	if not spec or not spec.relay then
		return nil
	end
	return true
end

---The ordered, free-tier model list a provider's relay walks when no model is pinned.
---
---Reuses `auto.prefer` (and its config override) rather than a second list: the relay's fallback
---order and AUTO's live-session pin are the same preference, just consumed differently — the
---relay tries each in turn until one answers, a live session pins the first one `M.models` still
---offers.
---@param provider string
---@return string[]
function M.relay_models(provider)
	local spec = M.spec(provider) or {}
	local auto = spec.auto or {}
	local eligible = auto.eligible or function()
		return true
	end
	local out = {}
	for _, model in ipairs(from_config(provider, "auto", "prefer") or auto.prefer or {}) do
		if eligible(model) then
			table.insert(out, model)
		end
	end
	return out
end

---The codecompanion adapter name backing a provider, for a scope.
---
---`adapter` may be a string, or a function of the scope's options for a provider whose adapter
---depends on them — ollama's endpoint decides between two adapter definitions. An `endpoints`
---table is read for the same purpose without needing a function.
---@param provider string
---@param scope? "inline"|"chat"
---@return string|nil
function M.adapter_name(provider, scope)
	local spec = M.spec(provider)
	if not spec then
		return nil
	end
	local opts = (scope and M.opts_for(scope, provider)) or {}

	if type(spec.adapter) == "function" then
		return spec.adapter(scope, opts)
	end
	local endpoints = M.endpoints(provider)
	if not vim.tbl_isempty(endpoints) then
		local chosen = endpoints[opts.endpoint] or endpoints[M.endpoint_names(provider)[1]]
		if chosen and chosen.adapter then
			return chosen.adapter
		end
	end
	return spec.adapter
end

---The codecompanion adapter name backing a provider's ACP transport
---@param provider string
---@return string|nil
function M.acp_adapter(provider)
	if M.kind(provider) ~= "acp" then
		return nil
	end
	return M.adapter_name(provider)
end

---The codecompanion HTTP adapter name for a scope's current provider and endpoint.
---
---Nil for an ACP provider, mirroring `acp_adapter`. Without that check this answered with the ACP
---adapter's name, which every caller would then have resolved down the wrong transport.
---@param scope "inline"|"chat"
---@return string|nil
function M.http_adapter(scope)
	local provider = M.current(scope).provider
	if M.kind(provider) ~= "http" then
		return nil
	end
	return M.adapter_name(provider, scope)
end

---Which provider a codecompanion adapter name belongs to.
---
---The inverse of `adapter_name`, needed because codecompanion hands back an adapter and the
---surfaces think in providers. There were three hand-written copies of this mapping — in the chat
---list, the status panel and the chat itself — and each knew about a different subset of the three
---shipped adapters.
---@param name string|nil
---@return string|nil
function M.provider_for_adapter(name)
	if type(name) ~= "string" then
		return nil
	end
	for _, provider in ipairs(M.names()) do
		if type(M.spec(provider).adapter) == "string" and M.spec(provider).adapter == name then
			return provider
		end
		for _, entry in pairs(M.endpoints(provider)) do
			if entry.adapter == name then
				return provider
			end
		end
	end
	return nil
end

---The base URL a provider's current endpoint points at, if it has endpoints at all.
---@param scope "inline"|"chat"
---@param provider? string
---@return string|nil
function M.endpoint_url(scope, provider)
	provider = provider or M.current(scope).provider
	local endpoints = M.endpoints(provider)
	local opts = M.opts_for(scope, provider) or {}
	local chosen = endpoints[opts.endpoint] or endpoints[M.endpoint_names(provider)[1]]
	return chosen and chosen.url or nil
end

---Base URL the ollama HTTP adapter should point at for a scope's current endpoint.
---@deprecated Use `M.endpoint_url` — kept because it is part of the pre-registry API.
---@param scope "inline"|"chat"
---@return string
function M.ollama_url(scope)
	return M.endpoint_url(scope, "ollama") or "http://localhost:11434"
end

--=============================================================================
-- Tiers
--=============================================================================

-- What running a model draws on, so the picker can say so where the choice is made. Each claim is
-- traceable from the spec that makes it, because "free" is the kind of label that rots quietly.
-- `free` is what drives the highlight, so anything drawing on a plan reads as such at a glance.

---@param provider string
---@param model string|nil
---@param endpoint string|nil
---@return { label: string, free: boolean }|nil
function M.model_tier(provider, model, endpoint)
	local spec = M.spec(provider)
	if not spec then
		return nil
	end
	local endpoints = M.endpoints(provider)
	if endpoint and endpoints[endpoint] and endpoints[endpoint].tier then
		return endpoints[endpoint].tier
	end
	if type(spec.tier) == "function" then
		local ok, tier = pcall(spec.tier, model, endpoint)
		if ok then
			return tier
		end
		return nil
	end
	if type(spec.tier) == "table" then
		return spec.tier
	end
	-- An unrecognised model: saying nothing beats guessing at what it draws on.
	return nil
end

--=============================================================================
-- Model lists — resolved live, cached for the nvim session
--=============================================================================

local cache = {}

---Seed the session cache from the last run's answers, once.
---
---Without this every start began with an empty picker and an `auto` with nothing to resolve
---against, because both are answered synchronously and every list is discovered asynchronously.
local seeded = false
local function seed()
	if seeded then
		return
	end
	seeded = true
	for key, models in pairs(require("ducktape.model_cache").lists()) do
		if cache[key] == nil and type(models) == "table" then
			cache[key] = models
		end
	end
end

---Remember a list for the rest of the session and for the next one.
---@param key string
---@param models string[]
local function remember(key, models)
	cache[key] = models
	require("ducktape.model_cache").write(key, models)
end

---The cache key a provider's list lives under. Endpoint providers get one per endpoint, which is
---the shape the persisted file has always had (`ollama:cloud`), so nothing migrates.
---@param provider string
---@param endpoint? string
---@return string
function M.cache_key(provider, endpoint)
	return endpoint and (provider .. ":" .. endpoint) or provider
end

---Every list key a provider contributes, so discovery and health can enumerate them.
---@param provider string
---@return { key: string, endpoint: string|nil }[]
function M.cache_keys(provider)
	local endpoints = M.endpoint_names(provider)
	if #endpoints == 0 then
		return { { key = M.cache_key(provider), endpoint = nil } }
	end
	local out = {}
	for _, endpoint in ipairs(endpoints) do
		table.insert(out, { key = M.cache_key(provider, endpoint), endpoint = endpoint })
	end
	return out
end

---What is already known for a provider, without asking anything. Synchronous and never blocking:
---it answers from the session cache, which is seeded from the last run's persisted answers.
---
---Deliberately silent when there is nothing yet. There is nothing wrong in that state — it is what
---a first run looks like.
---@param provider string
---@param endpoint? string
---@return string[]
function M.models(provider, endpoint)
	seed()
	local key = M.cache_key(provider, endpoint)
	if cache[key] then
		return cache[key]
	end
	local spec = M.spec(provider)
	local strategy = spec and spec.models or {}
	-- `values` is the whole answer for a static list. A sentinel is a usable answer where a provider
	-- has one, and a seed is a static list good enough to pick from until the live one lands.
	return vim.deepcopy(strategy.values or strategy.sentinel or strategy.seed or {})
end

---An HTTP list endpoint — ollama's `/api/tags`, or anything else shaped like it.
---@param provider string
---@param endpoint string|nil Nil is reported as an error: this strategy needs an endpoint to ask.
---@param strategy table
---@param cb fun(models: string[]|nil, err: string|nil)
local function fetch_http_tags(provider, endpoint, strategy, cb)
	local entry = M.endpoints(provider)[endpoint]
	if not entry or not entry.url then
		return cb(nil, ("%s has no endpoint %q"):format(provider, tostring(endpoint)))
	end

	local args = { "curl", "-sS", "--max-time", "10", entry.url .. (strategy.path or "/api/tags") }
	if entry.api_key_env then
		local key = os.getenv(entry.api_key_env)
		if not key or key == "" then
			return cb(nil, ("$%s is not set — start nvim from a shell that exports it"):format(entry.api_key_env))
		end
		vim.list_extend(args, { "-H", "Authorization: Bearer " .. key })
	end

	vim.system(args, { text = true }, function(out)
		vim.schedule(function()
			if out.code ~= 0 then
				return cb(nil, ("%s %s: %s"):format(provider, endpoint, vim.trim(out.stderr or "request failed")))
			end
			local ok, json = pcall(vim.json.decode, out.stdout)
			if not ok or type(json) ~= "table" then
				return cb(nil, ("%s %s: unexpected response"):format(provider, endpoint))
			end
			local list = json[strategy.field or "models"]
			if type(list) ~= "table" then
				return cb(nil, ("%s %s: unexpected response"):format(provider, endpoint))
			end
			local names = {}
			for _, item in ipairs(list) do
				local name = type(item) == "table" and item[strategy.name_key or "name"] or item
				if type(name) == "string" then
					table.insert(names, name)
				end
			end
			table.sort(names)
			cb(names)
		end)
	end)
end

---A subprocess that prints one model per line, or whatever `parse` makes of its stdout.
---@param provider string
---@param strategy table
---@param cb fun(models: string[]|nil, err: string|nil)
local function fetch_subprocess(provider, strategy, cb)
	local cmd = strategy.cmd
	if type(cmd) ~= "table" or #cmd == 0 then
		return cb(nil, ("%s has no model command"):format(provider))
	end
	vim.system(cmd, { text = true }, function(out)
		vim.schedule(function()
			if out.code ~= 0 then
				return cb(nil, vim.trim(out.stderr or ("`" .. table.concat(cmd, " ") .. "` failed")))
			end
			local parse = strategy.parse
			local models
			if type(parse) == "function" then
				local ok, parsed = pcall(parse, out.stdout)
				models = ok and parsed or nil
			else
				models = {}
				for line in (out.stdout or ""):gmatch("[^\r\n]+") do
					local model = vim.trim(line)
					if model ~= "" then
						table.insert(models, model)
					end
				end
			end
			if type(models) ~= "table" or #models <= (strategy.empty_when or 0) then
				return cb(nil, ("`%s` listed no %s models"):format(table.concat(cmd, " "), provider))
			end
			cb(models)
		end)
	end)
end

---Ask a provider what models this machine can reach, then cache it for this session and the next.
---
---Which question gets asked comes from the spec's `models` strategy:
---
---  http_tags     GET <endpoint.url><path>, one entry per endpoint. Needs no agent.
---  subprocess    run `cmd`, parse stdout. Needs no agent.
---  live_session  a running ACP agent is the only source; see `M.enrich_from_session`. What is
---                cached from a previous session is used until one is up, so this never blocks
---                and never spawns an agent just to fill a picker.
---  adapter       delegate to codecompanion's own `schema.model.choices`, which several HTTP
---                adapters implement including their own caching.
---  static        `values`, as given.
---@param provider string
---@param endpoint string|nil
---@param cb fun(models: string[], err: string|nil)
function M.models_async(provider, endpoint, cb)
	seed()
	local key = M.cache_key(provider, endpoint)
	if cache[key] then
		return cb(cache[key])
	end

	local spec = M.spec(provider)
	local strategy = (spec and spec.models) or {}
	local known = M.models(provider, endpoint)

	local function done(models, err)
		if models and #models > 0 then
			remember(key, models)
			return cb(models, err)
		end
		cb(known, err)
	end

	if strategy.strategy == "http_tags" then
		return fetch_http_tags(provider, endpoint, strategy, done)
	end
	if strategy.strategy == "subprocess" then
		return fetch_subprocess(provider, strategy, done)
	end
	if strategy.strategy == "adapter" then
		return M.models_from_adapter(provider, endpoint, done)
	end
	-- static and live_session have nothing to ask. Report what is known and let a live session
	-- enrich it later.
	cb(known)
end

---Delegate a model list to the codecompanion adapter behind a provider.
---
---HTTP adapters expose `schema.model.choices(adapter, opts)` and several implement real discovery
---with their own caching. `async = true` never blocks: it answers from that cache and kicks off a
---fetch, so the answer may be empty on a cold start and full a moment later.
---
---Not available for ACP adapters — none of codecompanion's carry a `schema` at all, which is why
---`live_session` exists as a separate strategy.
---@param provider string
---@param endpoint string|nil
---@param cb fun(models: string[]|nil, err: string|nil)
function M.models_from_adapter(provider, endpoint, cb)
	local name = M.adapter_name(provider, "inline")
	if endpoint then
		local entry = M.endpoints(provider)[endpoint]
		name = (entry and entry.adapter) or name
	end
	if not name then
		return cb(nil, ("%s has no adapter to ask"):format(provider))
	end
	local ok, adapters = pcall(require, "codecompanion.adapters")
	if not ok then
		return cb(nil, "codecompanion is not available")
	end
	local resolved = adapters.resolve(name)
	local choices = resolved and resolved.schema and resolved.schema.model and resolved.schema.model.choices
	if not choices then
		return cb(nil, ("the %s adapter offers no model list"):format(name))
	end
	if type(choices) == "function" then
		local fetched
		ok, fetched = pcall(choices, resolved, { async = true })
		if not ok then
			return cb(nil, ("the %s adapter failed to list models"):format(name))
		end
		choices = fetched
	end
	if type(choices) ~= "table" then
		return cb(nil, ("the %s adapter offers no model list"):format(name))
	end
	local names = {}
	for model, value in pairs(choices) do
		-- `choices` is a map of model → metadata for adapters that carry metadata, and a plain
		-- array for those that do not.
		table.insert(names, type(model) == "string" and model or value)
	end
	table.sort(names)
	cb(names)
end

---Take a live ACP session's own model list and cache it.
---
---The only source for a `live_session` provider, and worth doing opportunistically for any ACP
---provider: the agent knows what it currently offers, including models released after this spec
---was written. Never spawns anything — it is called with a connection that already exists.
---@param provider string
---@param conn table
---@return string[]|nil models
function M.enrich_from_session(provider, conn)
	if not conn or type(conn.get_models) ~= "function" then
		return nil
	end
	local ok, models = pcall(conn.get_models, conn)
	if not ok or type(models) ~= "table" or type(models.availableModels) ~= "table" then
		return nil
	end
	local names = {}
	for _, entry in ipairs(models.availableModels) do
		if type(entry.modelId) == "string" then
			table.insert(names, entry.modelId)
		end
	end
	if #names == 0 then
		return nil
	end
	table.sort(names)
	seed()
	remember(M.cache_key(provider), names)
	return names
end

---Ask every provider what it can reach, for the side effect of caching the answers.
---
---Called from setup on a machine that has never discovered anything, so the first picker is already
---full instead of filling a moment after it opens. Cheap after that: the lists are read from disk and
---this is not called again.
---
---Silent, including on failure. Nobody has asked for a model list at this point, so an unreachable
---local ollama is not news; every call site that does ask reports its own errors, and
---`:Ducktape models` is the loud version of this.
function M.discover_models()
	for _, provider in ipairs(M.names()) do
		for _, entry in ipairs(M.cache_keys(provider)) do
			M.models_async(provider, entry.endpoint, function() end)
		end
	end
end

---Every provider/endpoint pair worth reporting on, for `:Ducktape models` and `:checkhealth`.
---@return { provider: string, endpoint: string|nil, key: string, label: string }[]
function M.discoverable()
	local out = {}
	for _, provider in ipairs(M.names()) do
		local strategy = (M.spec(provider) or {}).models or {}
		-- Nothing to ask for these two: static is already an answer, and live_session needs an
		-- agent nobody has asked to spawn.
		if strategy.strategy ~= "static" and strategy.strategy ~= "live_session" then
			for _, entry in ipairs(M.cache_keys(provider)) do
				table.insert(out, {
					provider = provider,
					endpoint = entry.endpoint,
					key = entry.key,
					label = entry.endpoint and (provider .. " " .. entry.endpoint) or provider,
				})
			end
		end
	end
	return out
end

---Reset the model caches so the next lookup re-queries. Exposed for the status panel.
---
---Leaves the persisted lists alone: the status panel clears this to pick up a model added since,
---not to lose what it already knows if the query fails. `M.forget_models` is the harder reset.
function M.clear_cache()
	cache = {}
	seeded = false
end

---Throw away everything known about models, on disk included, so the next lookup rediscovers it.
---Behind `:Ducktape models`.
function M.forget_models()
	cache = {}
	seeded = true -- nothing left to seed from, and re-seeding would read the file we just deleted
	require("ducktape.model_cache").clear()
end

--=============================================================================
-- Pre-registry model API, kept so nothing that used it has to change
--=============================================================================

---@deprecated Use `M.models_async("ollama", endpoint, cb)`
---@param endpoint "local"|"cloud"
---@param cb fun(models: string[]|nil, err: string|nil)
function M.ollama_models(endpoint, cb)
	return M.models_async("ollama", endpoint, function(models, err)
		-- The old contract reported nil-plus-error rather than last-known-plus-error.
		if err and (not models or #models == 0) then
			return cb(nil, err)
		end
		cb(models, err)
	end)
end

---@deprecated Use `M.models("opencode")`
---@return string[]
function M.opencode_models()
	return M.models("opencode")
end

---@deprecated Use `M.models_async("opencode", nil, cb)`
---@param cb fun(models: string[], err: string|nil)
function M.opencode_models_async(cb)
	return M.models_async("opencode", nil, cb)
end

--=============================================================================
-- ACP session options and the write defence
--=============================================================================

---The guard for a provider, with config-supplied pieces resolved.
---
---A guard has two halves, and only the second is enforcement:
---
---  request   `required` (or a mode derived from the agent) plus `env`, pushed onto the session.
---            codecompanion's `acp_defaults.apply` is best-effort here: it warns and carries on
---            when the agent advertises no such category or rejects the value.
---  verify    the values are read back off the live session and the connection is refused if they
---            did not stick. `acp_pool` does this. It is the whole defence.
---
---`required` may be absent, in which case a mode is derived from what the agent advertises — see
---`M.derive_guard`. `unguarded = true` is how a user says they want an ACP inline connection with
---no write defence at all.
---@param provider string
---@return { required: table<string,string>|nil, env: table|nil, chat_env: table|nil, unguarded: boolean, derive: boolean }
function M.effective_guard(provider)
	local spec = M.spec(provider) or {}
	local guard = spec.guard or {}
	return {
		required = guard.required,
		env = guard.env,
		chat_env = guard.chat_env,
		unguarded = guard.unguarded == true,
		-- Deriving is the default: a spec that names nothing still gets a defence if the agent
		-- offers one, which is what keeps an unknown provider safe with no configuration.
		derive = guard.derive ~= false,
	}
end

---Choose the most restrictive write-denying mode a live session actually offers.
---
---This is what lets a provider nobody has ever heard of be guarded anyway. The agent advertises
---its own modes through session config options; we pick from them rather than asking the user to
---know them. Returns nil when the agent offers no write-denying mode at all, which is the signal
---to withhold inline rather than to proceed.
---@param provider string
---@param conn table A connected, session-established ACP connection
---@return table<string,string>|nil required, string|nil why
function M.derive_guard(provider, conn)
	local guard = M.effective_guard(provider)
	if guard.required and next(guard.required) then
		return guard.required
	end
	if guard.unguarded then
		return {}
	end
	if not guard.derive then
		return {}
	end
	if not conn or type(conn.get_config_options) ~= "function" then
		return nil, "the agent reported no session options, so no write defence could be verified"
	end

	local safe = require("ducktape.config").get().safe_modes or M.SAFE_MODES
	local offered = {}
	local mode_option
	for _, opt in ipairs(conn:get_config_options()) do
		if opt.category == "mode" and opt.type == "select" then
			mode_option = opt
			local ok, ACP = pcall(require, "codecompanion.acp")
			local values = ok and ACP.flatten_config_options(opt.options or {}) or {}
			for _, value in ipairs(values) do
				if type(value.value) == "string" then
					offered[value.value] = true
				end
			end
		end
	end
	if not mode_option then
		return nil, "the agent advertises no `mode` option, so writes cannot be denied on the session"
	end

	for _, mode in ipairs(safe) do
		if offered[mode] then
			return { mode = mode }
		end
	end
	return nil,
		("the agent offers no write-denying mode (it offers %s)"):format(table.concat(vim.tbl_keys(offered), ", "))
end

---Session options that are a safety requirement rather than a preference.
---
---Separate from the rest because these have to be *verified* on the live session, not merely
---requested. Since the mode is the whole write defence — neither shipped agent uses the
---client-mediated `fs/*` path, so the pool's write guard covers nothing in practice — a connection
---that did not take it must not be used.
---
---Returns only what the spec names. A provider that names nothing gets its requirement derived
---from the live agent at connection time instead, which is why this being empty is no longer the
---same as "no defence".
---@param provider string
---@return table<string, string>
function M.required_session_options(provider)
	return vim.deepcopy(M.effective_guard(provider).required or {})
end

---Resolve a stored option value for a live session, substituting the AUTO sentinel with a
---real model so it never reaches an agent as a literal value — agents don't recognize "auto"
---and silently fall back to their own ambient default instead of erroring.
---@param provider string
---@param key string
---@param value string|nil
---@return string|nil
function M.resolve_chat_option_value(provider, key, value)
	if key ~= "model" or value ~= M.AUTO then
		return value
	end
	local spec = M.spec(provider) or {}
	local auto = spec.auto
	if not auto then
		-- No fallback policy: passing the sentinel through would reach the agent as a literal, so
		-- drop it and let the agent use its own default, which is the only thing left.
		return nil
	end

	-- AUTO means "walk a fallback list", which only has meaning on the relay. A live session has to
	-- be pinned to something, and leaving it unset lands on the provider's ambient default — which
	-- is not guaranteed to be a free-tier model.
	--
	-- Which model, though, is a preference and not a fact, so it comes from config rather than from
	-- the order a list happens to arrive in. That order used to decide it, and the two sources
	-- disagree: a hand-written fallback list is ordered by preference, while `opencode models` is
	-- alphabetical. So opening the picker once — which is what fills the cache — silently moved
	-- AUTO onto whichever free model sorts first, the ambient default this branch exists to avoid.
	local available = M.models(provider)
	local function offered(model)
		return vim.tbl_contains(available, model)
	end
	local eligible = auto.eligible or function()
		return true
	end

	local resolved
	for _, model in ipairs(from_config(provider, "auto", "prefer") or auto.prefer or {}) do
		if offered(model) and eligible(model) then
			resolved = model
			break
		end
	end
	-- Nothing preferred is on this machine, so any eligible model beats the ambient default. Sorted
	-- order is arbitrary here, but it is arbitrary among models that are all equally acceptable.
	if not resolved then
		for _, model in ipairs(available) do
			if model ~= M.AUTO and eligible(model) then
				resolved = model
				break
			end
		end
	end
	if not resolved and auto.warn then
		-- Nothing to pin to, so staying quiet here would land on exactly the default this branch
		-- exists to avoid. Say so where the user will see it.
		require("ducktape.ui").say("[ducktape] " .. auto.warn, vim.log.levels.WARN)
	end
	return resolved
end

---Session config options to preset on a new inline ACP session.
---@param provider string
---@return table<string, string>
function M.inline_session_options(provider)
	local opts = (selection().inline.opts or {})[provider] or {}
	local spec = M.spec(provider) or {}
	local out = {}

	for _, key in ipairs(spec.inline_options or {}) do
		local option = (spec.options or {})[key]
		local value = M.resolve_chat_option_value(provider, key, opts[key])
		if option and option.category and value and value ~= M.AUTO then
			out[option.category] = value
		end
	end

	-- The requested half of the write defence, applied to every inline session rather than only
	-- the deep one. What the spec does not name is derived from the agent once it is up.
	for category, value in pairs(M.required_session_options(provider)) do
		out[category] = value
	end

	return out
end

---Options that can only be set once a live session exists, because the agent gives them no
---category and `session/set_config_option` is the only way in.
---@param provider string
---@param scope "inline"|"chat"
---@return string[]
function M.after_session_options(provider, scope)
	local spec = M.spec(provider) or {}
	local keys = (scope == "inline" and spec.inline_options or spec.chat_options) or {}
	local out = {}
	for _, key in ipairs(keys) do
		local option = (spec.options or {})[key]
		if option and option.after_session then
			table.insert(out, key)
		end
	end
	return out
end

---Can this provider's chats be saved and resumed?
---
---A plain HTTP provider has no agent process and therefore no session to reopen, so a saved entry
---for one could never be more than an empty buffer. Declared rather than inferred from `kind`, so a
---future HTTP provider with its own resume story can say so.
---@param provider string
---@return boolean
function M.resumable(provider)
	local spec = M.spec(provider)
	if not spec then
		return false
	end
	local declared = (spec.capabilities or {}).resumable_sessions
	if declared ~= nil then
		return declared
	end
	return M.kind(provider) == "acp"
end

---The environment a provider's adapter needs for a scope, as a table of name → value.
---
---This is the requested half of the write defence for providers whose agent takes a permission
---set through the environment rather than a session mode.
---@param provider string
---@param scope "inline"|"chat"
---@return table<string, string>
function M.guard_env(provider, scope)
	local guard = M.effective_guard(provider)
	local source = scope == "chat" and (guard.chat_env or guard.env) or guard.env
	local out = {}
	for name, value in pairs(source or {}) do
		out[name] = type(value) == "table" and vim.json.encode(value) or value
	end
	return out
end

--=============================================================================
-- Pre-registry permission tables, kept for anything that read them directly
--=============================================================================

---@deprecated Read `M.effective_guard("opencode").env` instead.
M.opencode_permission = M.providers.opencode.guard.env.OPENCODE_PERMISSION

---@deprecated Read `M.effective_guard("opencode").chat_env` instead.
M.opencode_chat_permission = M.providers.opencode.guard.chat_env.OPENCODE_PERMISSION

return M
