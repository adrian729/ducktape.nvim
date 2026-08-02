-- Single source of truth for the AI integration: which providers exist, what options each
-- carries, what is currently selected, and how far each transport can reach into the machine.
-- Inline, chat and the status panel all read this module, which is what makes the option UX
-- shared rather than reimplemented per surface.

local M = {}

-- Whether a transport can touch the filesystem is a property of the transport, not of which
-- keymap was pressed. Measured, not assumed: neither agent uses the client-mediated fs/* path, so
-- what a transport can reach is decided by the agent process, not by us.
M.transports = {
	http = { read = false, write = false, note = "no filesystem access at all" },
	relay = { read = false, write = false, note = "no filesystem access at all" },
	acp = { read = true, write = false, note = "can read any file you can; writes denied" },
}

-- Sentinel for opencode's model option: let `opencode-llm` walk its own free-tier fallback
-- list instead of pinning one model, so a dead model degrades instead of failing.
M.AUTO = "auto"

---@type table<string, table>
M.providers = {
	ollama = {
		label = "Ollama",
		inline_options = { "endpoint", "model", "think" },
		chat_options = { "endpoint", "model", "think" },
		options = {
			endpoint = { label = "Endpoint", values = { "cloud", "local" } },
			model = { label = "Model", dynamic = true },
			think = { label = "Think", values = { "off", "on" } },
		},
	},
	claude = {
		label = "Claude",
		adapter = "claude_code",
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
			-- exists, via conn:set_config_option("agent", …). Chat-only.
			agent = { label = "Agent", dynamic = true, category = nil },
		},
	},
	opencode = {
		label = "OpenCode",
		adapter = "opencode",
		inline_options = { "model" },
		chat_options = { "model", "mode" },
		options = {
			model = { label = "Model", dynamic = true, category = "model" },
			mode = { label = "Mode", category = "mode", values = { "build", "plan" } },
		},
	},
}

-- Free-first by policy. Inline defaults to the fastest measured free backend.
M.defaults = {
	inline = {
		provider = "ollama",
		opts = {
			ollama = { endpoint = "cloud", model = "gpt-oss:120b", think = "off" },
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
	state = vim.deepcopy(M.defaults)
end

---The current selection for a scope
---@param scope "inline"|"chat"
---@return { provider: string, opts: table, spec: table }
function M.current(scope)
	local sel = selection()[scope]
	return { provider = sel.provider, opts = sel.opts[sel.provider], spec = M.providers[sel.provider] }
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
	selection()[scope].provider = provider
	return true
end

---@param scope "inline"|"chat"
---@param key string
---@param value string
function M.set_option(scope, key, value)
	local sel = selection()[scope]
	local spec = M.providers[sel.provider]
	if not spec or not spec.options[key] then
		return false, ("%s has no option %q"):format(sel.provider, key)
	end
	sel.opts[sel.provider][key] = value
	return true
end

---Which transport a provider uses for a given inline keymap.
---@param provider string
---@param deep boolean True for <leader>cI, which invites repo research
---@return "http"|"relay"|"acp"
function M.transport(provider, deep)
	if provider == "ollama" then
		return "http"
	end
	if provider == "claude" then
		return "acp"
	end
	-- opencode splits: the relay is guaranteed tool-free, ACP is what can actually read the repo
	return deep and "acp" or "relay"
end

---@param provider string
---@param deep boolean
---@return table reach The transports entry for this provider/keymap pair
function M.reach(provider, deep)
	return M.transports[M.transport(provider, deep)]
end

---The CodeCompanion adapter name backing a provider's ACP transport
---@param provider string
---@return string|nil
function M.acp_adapter(provider)
	return M.providers[provider] and M.providers[provider].adapter
end

---The CodeCompanion HTTP adapter name for the current ollama endpoint
---@param scope "inline"|"chat"
---@return string
function M.http_adapter(scope)
	return M.current(scope).opts.endpoint == "local" and "ollama" or "ollama_cloud"
end

--=============================================================================
-- Model lists — resolved live, cached for the nvim session
--=============================================================================

local cache = {}

local function ollama_url(endpoint)
	return endpoint == "local" and "http://localhost:11434" or "https://ollama.com"
end

---Base URL the ollama HTTP adapter should point at for a scope's current endpoint
---@param scope "inline"|"chat"
---@return string
function M.ollama_url(scope)
	return ollama_url(M.current(scope).opts.endpoint)
end

---Fetch the ollama model list for an endpoint. Cached per nvim session.
---@param endpoint "local"|"cloud"
---@param cb fun(models: string[]|nil, err: string|nil)
function M.ollama_models(endpoint, cb)
	local key = "ollama:" .. endpoint
	if cache[key] then
		return cb(cache[key])
	end

	local args = { "curl", "-sS", "--max-time", "10", ollama_url(endpoint) .. "/api/tags" }
	if endpoint == "cloud" then
		local key_env = os.getenv("OLLAMA_API_KEY")
		if not key_env or key_env == "" then
			return cb(nil, "OLLAMA_API_KEY is not set — start nvim from a shell that exports it")
		end
		vim.list_extend(args, { "-H", "Authorization: Bearer " .. key_env })
	end

	vim.system(args, { text = true }, function(out)
		vim.schedule(function()
			if out.code ~= 0 then
				return cb(nil, ("ollama %s: %s"):format(endpoint, vim.trim(out.stderr or "request failed")))
			end
			local ok, json = pcall(vim.json.decode, out.stdout)
			if not ok or type(json) ~= "table" or type(json.models) ~= "table" then
				return cb(nil, ("ollama %s: unexpected response"):format(endpoint))
			end
			local names = vim.tbl_map(function(m)
				return m.name
			end, json.models)
			table.sort(names)
			cache[key] = names
			cb(names)
		end)
	end)
end

-- Which tier a model belongs to is decided by its provider prefix, per opencode's own prefix rule:
-- `opencode/` is the free tier, `opencode-go/` is the Go subscription. Not by the `-free`
-- suffix, which `opencode/big-pickle` does not carry despite being free.
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

-- What running a model draws on, so the picker can say so where the choice is made. Every
-- claim below is traceable, because "free" is the kind of label that rots quietly:
--
--   opencode/…      free tier      opencode's prefix rule
--   opencode-go/…   Go plan        opencode's published limits: — $12/5h, $30/wk, $60/mo rolling
--                                  windows, and "Free models don't count", so these are what
--                                  consume them
--   ollama local    free           runs on this machine; no account, no quota
--   ollama cloud    free tier      ollama's free cloud tier: — light GPU-time usage,
--                                  1 concurrent model, so free but rate-limited
--   claude          Claude plan    claude-agent-acp authenticates with CLAUDE_CODE_OAUTH_TOKEN
--                                  (no ANTHROPIC_API_KEY anywhere in this config), so usage
--                                  counts against the subscription
--
-- Both subscriptions are labelled the same way on purpose. An earlier revision called Go
-- "paid" because its allowance happens to be denominated in dollars while Claude's is not —
-- but that is the unit the window is measured in, not who is paying. Both are plans already
-- paid for, with rolling usage windows; neither bills per token. (Go can overflow into Zen
-- credits once its windows are spent, but that is opt-in from opencode's console, not what a
-- request costs by default.)
--
-- `free` is what drives the highlight, so anything drawing on a plan reads as such at a glance.
---@param provider string
---@param model string|nil
---@param endpoint string|nil ollama's, which is what decides local versus ollama.com
---@return { label: string, free: boolean }|nil
function M.model_tier(provider, model, endpoint)
	if provider == "claude" then
		return { label = "subscription · claude", free = false }
	end
	if provider == "ollama" then
		return { label = endpoint == "local" and "free · local" or "free · cloud", free = true }
	end
	if provider == "opencode" then
		if model == M.AUTO then
			-- The relay only ever walks free models, and resolve_chat_option_value pins a free
			-- one when a live session needs something concrete, so this cannot cost anything.
			return { label = "free", free = true }
		end
		if M.is_go_opencode_model(model) then
			return { label = "subscription · Go", free = false }
		end
		if M.is_free_opencode_model(model) then
			return { label = "free", free = true }
		end
	end
	return nil -- an unrecognised model: saying nothing beats guessing at what it draws on
end

---The relay's free-tier fallback list, read from the same config `opencode-llm` walks.
---
---This is the floor, not the whole story: it is what can be answered without asking opencode
---anything, so it is what the synchronous callers see until `opencode models` has been run.
---@return string[]
local function configured_free_models()
	-- Same locations `opencode-llm` itself checks, in the same order, unless configured otherwise
	local candidates = vim.tbl_map(vim.fn.expand, require("ducktape.config").get().opencode.models_json)
	for _, path in ipairs(candidates) do
		if vim.fn.filereadable(path) == 1 then
			local ok, content = pcall(vim.fn.readfile, path)
			local decoded_ok, json = false, nil
			if ok then
				decoded_ok, json = pcall(vim.json.decode, table.concat(content, "\n"))
			end
			if decoded_ok and type(json) == "table" and type(json.relay) == "table" then
				return json.relay
			end
		end
	end
	return {}
end

---Every opencode model that can be selected, free tier and Go alike.
---
---Synchronous and never blocking: it answers from the cache `M.opencode_models_async` fills,
---and until that has happened from `opencode-models.json`'s relay list. Callers that want the
---Go models to be present have to have asked for them first.
---@return string[]
function M.opencode_models()
	if cache.opencode then
		return cache.opencode
	end

	local models = { M.AUTO }
	vim.list_extend(models, configured_free_models())
	if #models == 1 then
		-- Required here rather than at the top of the file: this module is what every other one
		-- reads, and it stays free of dependencies of its own.
		require("ducktape.ui").say(
			"[ducktape] could not read opencode-models.json — opencode falls back to its ambient model",
			vim.log.levels.WARN
		)
	end
	return models
end

---Ask opencode itself what this machine can reach, then cache it.
---
---`opencode models` is the only source that knows about the Go subscription — the JSON config
---only ever described the free relay walk, which is why Go models were missing from the
---pickers even with a subscription. It takes about half a second, so it is fetched rather than
---waited on, the same way the ollama lists are.
---
---`ollama-cloud/*` entries are dropped: opencode can reach them, but this config already has
---its own ollama provider for those, and listing them twice under two providers would only
---raise the question of which one to pick.
---@param cb fun(models: string[], err: string|nil)
function M.opencode_models_async(cb)
	if cache.opencode then
		return cb(cache.opencode)
	end

	vim.system({ "opencode", "models" }, { text = true }, function(out)
		vim.schedule(function()
			if out.code ~= 0 then
				return cb(M.opencode_models(), vim.trim(out.stderr or "`opencode models` failed"))
			end

			local models = { M.AUTO }
			local free, go = {}, {}
			for line in (out.stdout or ""):gmatch("[^\r\n]+") do
				local model = vim.trim(line)
				if M.is_free_opencode_model(model) then
					table.insert(free, model)
				elseif M.is_go_opencode_model(model) then
					table.insert(go, model)
				end
			end
			-- Free first: the option that consumes nothing is the one that should
			-- be under the cursor when the list opens, with the Go tier a deliberate scroll away.
			vim.list_extend(models, free)
			vim.list_extend(models, go)

			if #models == 1 then
				return cb(M.opencode_models(), "`opencode models` listed no opencode models")
			end
			cache.opencode = models
			cb(models)
		end)
	end)
end

---Reset the model caches so the next lookup re-queries. Exposed for the status panel.
function M.clear_cache()
	cache = {}
end

--=============================================================================
-- ACP session options
--=============================================================================

-- Denying every tool backfires: the model still attempts one, nothing parses the attempt, and
-- raw <tool_call> markup leaks into the reply as text. Allowing reads removes the leak entirely.
M.opencode_permission = {
	edit = "deny",
	write = "deny",
	patch = "deny",
	bash = "deny",
	read = "allow",
	grep = "allow",
	glob = "allow",
	list = "allow",
}

-- The chat counterpart: chat is meant to be able to change things, so the mutating tools are
-- `ask` rather than `deny` — the same "show me before you do it" stance claude's `default`
-- mode gives. Chat used to drop the permission block entirely, which handed it silent write
-- access; nothing announced an edit and nvim did not even reload the file.
M.opencode_chat_permission = {
	edit = "ask",
	write = "ask",
	patch = "ask",
	bash = "ask",
	read = "allow",
	grep = "allow",
	glob = "allow",
	list = "allow",
}

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
	-- AUTO means "let opencode-llm walk its fallback list", which only has meaning on the
	-- relay. A live session has to be pinned to something, and leaving it unset lands on
	-- opencode's ambient default — which is not guaranteed to be a free-tier model.
	--
	-- Searched for rather than taken from a fixed index: the list holds Go models too now, and
	-- index 2 being free was only ever true because of how the list happened to be sorted. AUTO
	-- resolving to a Go model would spend subscription budget on a value the user never picked.
	local resolved
	for _, model in ipairs(M.opencode_models()) do
		if M.is_free_opencode_model(model) then
			resolved = model
			break
		end
	end
	if not resolved then
		-- Nothing to pin to, so staying quiet here would land on exactly the default this
		-- branch exists to avoid. Say so where the user will see it.
		require("ducktape.ui").say(
			"[ducktape] no free opencode model is known, so this session falls back to opencode's "
				.. "own default — check opencode-models.json",
			vim.log.levels.WARN
		)
	end
	return resolved
end

---Session config options to preset on a new inline ACP session.
---@param provider string
---@return table<string, string>
function M.inline_session_options(provider)
	local opts = state.inline.opts[provider] or {}
	local spec = M.providers[provider]
	local out = {}

	for _, key in ipairs(spec.inline_options or {}) do
		local option = spec.options[key]
		local value = M.resolve_chat_option_value(provider, key, opts[key])
		if option and option.category and value and value ~= M.AUTO then
			out[option.category] = value
		end
	end

	-- The actual write defence on claude: dontAsk denies mutating tools, shell redirects
	-- included, and it is applied to every inline session rather than only the deep one.
	for category, value in pairs(M.required_session_options(provider)) do
		out[category] = value
	end

	return out
end

---Session options that are a safety requirement rather than a preference.
---
---Separate from the rest because these have to be *verified* on the live session, not merely
---requested. `acp_defaults.apply` gives up with a `log:warn` if the agent advertised no
---configOptions or if the value does not match one it offers, and on claude that leaves the
---session in its default mode with write-capable tools. Since this mode is the whole write
---defence — neither agent uses the client-mediated `fs/*` path, so the pool's write guard covers
---nothing in practice — a connection that did not take it must not be used.
---@param provider string
---@return table<string, string>
function M.required_session_options(provider)
	if provider == "claude" then
		return { mode = "dontAsk" }
	end
	return {}
end

return M
