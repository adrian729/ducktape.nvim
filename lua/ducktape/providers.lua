-- Registry of AI providers: specs, current selections, transports, and model discovery.
-- Consumers read specs rather than branching on provider names, so a provider added through
-- config appears in every surface without edits elsewhere.

local M = {}

M.transports = {
	http = { read = false, write = false, note = "no filesystem access at all" },
	relay = { read = false, write = false, note = "no filesystem access at all" },
	acp = { read = true, write = false, note = "can read any file you can; writes denied" },
}

-- "Use the provider's own fallback list" sentinel. Degrades gracefully when a pinned model dies.
M.AUTO = "auto"

-- Write-denying modes, most preferred first. Used to derive a guard when a spec names none.
-- Asking modes are excluded: inline has no UI to answer permission prompts.
M.SAFE_MODES = { "dontAsk", "plan", "readOnly", "readonly", "read-only" }

local GO_PREFIX = "opencode-go/"
local FREE_PREFIX = "opencode/"

---@param model string
---@return boolean
function M.is_free_opencode_model(model)
	return type(model) == "string" and vim.startswith(model, FREE_PREFIX)
end

---@param model string
---@return boolean
function M.is_go_opencode_model(model)
	return type(model) == "string" and vim.startswith(model, GO_PREFIX)
end

-- Provider spec schema documented in `:h ducktape`.
---@type table<string, table>
M.providers = {
	ollama = {
		label = "Ollama",
		kind = "http",
		-- Endpoint is part of which model you get; describing it as data keeps picker, discovery
		-- and adapter generation in one place.
		endpoints = {
			cloud = {
				url = "https://ollama.com",
				adapter = "ollama_cloud",
				extends = "ollama",
				api_key_env = "OLLAMA_API_KEY",
				tier = { label = "free · cloud", free = true },
			},
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
			think = {
				label = "Think",
				values = { "off", "on" },
				to_schema = function(value)
					return value == "on"
				end,
			},
		},
		capabilities = { resumable_sessions = false },
	},

	claude = {
		label = "Claude",
		kind = "acp",
		adapter = "claude_code",
		tier = function()
			return { label = "subscription · claude", free = false }
		end,
		models = { strategy = "live_session", seed = { "default", "sonnet", "opus", "haiku" } },
		guard = { required = { mode = "dontAsk" } },
		inline_options = { "model", "effort", "fast" },
		chat_options = { "model", "effort", "fast", "mode", "agent" },
		options = {
			model = { label = "Model", category = "model", values = { "default", "sonnet", "opus", "haiku" } },
			effort = {
				label = "Effort",
				category = "thought_level",
				values = { "default", "low", "medium", "high", "xhigh", "max" },
			},
			-- opus supports it, sonnet does not; harmless but logs warnings, so unset by default.
			fast = { label = "Fast", category = "model_config", values = { "on", "off" } },
			mode = {
				label = "Mode",
				category = "mode",
				values = { "auto", "default", "acceptEdits", "plan", "dontAsk", "bypassPermissions" },
			},
			-- category = nil in the agent schema; set after session exists. Chat-only.
			agent = { label = "Agent", dynamic = true, category = nil, after_session = true },
		},
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
		option_notes = { fast = "opus only" },
		capabilities = { resumable_sessions = true },
	},

	opencode = {
		label = "OpenCode",
		kind = "acp",
		adapter = "opencode",
		-- Go subscription draws on $12/5h, $30/wk, $60/mo windows; "free" models do not count.
		tier = function(model)
			if model == M.AUTO then
				return { label = "free", free = true }
			end
			if M.is_go_opencode_model(model) then
				return { label = "subscription · Go", free = false }
			end
			if M.is_free_opencode_model(model) then
				return { label = "free", free = true }
			end
		end,
		-- `opencode models` is the only source that knows about the Go subscription and what this
		-- machine is entitled to; it needs no live agent.
		models = {
			strategy = "subprocess",
			cmd = { "opencode", "models" },
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
			empty_when = 1,
			sentinel = { M.AUTO },
		},
		auto = {
			prefer = {
				"opencode/deepseek-v4-flash-free",
				"opencode/mimo-v2.5-free",
				"opencode/laguna-s-2.1-free",
				"opencode/ling-3.0-flash-free",
				"opencode/north-mini-code-free",
				"opencode/nemotron-3-ultra-free",
			},
			-- AUTO must never resolve onto a subscription model: the user did not choose one.
			eligible = function(model)
				return M.is_free_opencode_model(model)
			end,
			warn = "no free opencode model is known yet, so this session falls back to opencode's own "
				.. "default — :Ducktape models asks opencode what it can reach",
		},
		-- Tool-free relay for shallow inline. Native to `inline/relay.lua`; it composes
		-- `opencode run` itself, walking `auto.prefer` until one answers. Denying tools on the ACP
		-- path leaks `<tool_call>` markup into replies; pairing the deny set with a "no tools"
		-- prompt stops the attempt at source.
		relay = true,
		transports = { shallow = "relay", deep = "acp" },
		guard = {
			env = {
				-- Denying every tool leaks raw `<tool_call>` markup; allowing reads removes the leak.
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
				-- Chat is meant to change things. `ask` gives the same "show me first" stance as
				-- claude's `default`. Dropping the block handed chat silent write access.
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

-- Free-first. Inline defaults to opencode's relay with AUTO so the relay can degrade onto the
-- next preferred model if one is renamed/retired.
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
			claude = { model = "opus", effort = "xhigh", fast = "off", mode = "default" },
			opencode = { model = M.AUTO, mode = "build" },
		},
	},
}

---@param provider string|nil
---@return table|nil
function M.spec(provider)
	return provider and M.providers[provider] or nil
end

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
	-- Infer from codecompanion's adapter registry, which may not be set up when a spec is first read.
	local ok, cc = pcall(require, "codecompanion.config")
	if ok and spec.adapter and type(spec.adapter) == "string" then
		if cc.adapters and cc.adapters.acp and cc.adapters.acp[spec.adapter] then
			return "acp"
		end
	end
	return spec.relay and "acp" or "http"
end

---@param provider string
---@return table<string, table>
function M.endpoints(provider)
	local spec = M.spec(provider)
	return (spec and spec.endpoints) or {}
end

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

---@type table<string, { provider: string, opts: table<string, table> }>|nil
local state

---Lazy selection, seeded from defaults. A keymap can require this before setup merged user config.
---@return table
local function selection()
	if not state then
		state = vim.deepcopy(M.defaults)
	end
	return state
end

---Ensure every known provider has an options table in every scope, so a provider added through
-- `opts.providers` without a matching `opts.defaults` entry does not throw on first read.
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

---@param cfg table
function M.apply(cfg)
	if cfg.providers and next(cfg.providers) then
		M.providers = vim.tbl_deep_extend("force", M.providers, cfg.providers)
	end
	if cfg.defaults and next(cfg.defaults) then
		M.defaults = vim.tbl_deep_extend("force", M.defaults, cfg.defaults)
	end
	seed_opts(M.defaults)

	-- Catch a selected provider that does not exist now rather than at first keypress.
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

---@param scope "inline"|"chat"
---@return { provider: string, opts: table, spec: table }
function M.current(scope)
	local sel = selection()[scope]
	local provider = sel.provider
	return { provider = provider, opts = sel.opts[provider] or {}, spec = M.providers[provider] }
end

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

---@param provider string
---@param deep boolean True for <leader>cI, which may read the repo
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
	if spec and spec.relay and not deep then
		return "relay"
	end
	return "acp"
end

---@param provider string
---@param deep boolean
---@return table
function M.reach(provider, deep)
	return M.transports[M.transport(provider, deep)]
end

---@param provider string
---@param ... string
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

---@param provider string
---@return true|nil
function M.relay(provider)
	local spec = M.spec(provider)
	if not spec or not spec.relay then
		return nil
	end
	return true
end

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

---@param provider string
---@return string|nil
function M.acp_adapter(provider)
	if M.kind(provider) ~= "acp" then
		return nil
	end
	return M.adapter_name(provider)
end

---@param scope "inline"|"chat"
---@return string|nil
function M.http_adapter(scope)
	local provider = M.current(scope).provider
	if M.kind(provider) ~= "http" then
		return nil
	end
	return M.adapter_name(provider, scope)
end

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

---@deprecated Use `M.endpoint_url`
---@param scope "inline"|"chat"
---@return string
function M.ollama_url(scope)
	return M.endpoint_url(scope, "ollama") or "http://localhost:11434"
end

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
	return nil
end

local cache = {}

---Seed the session cache from disk once. Keeps pickers and AUTO from being empty on startup.
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

---@param key string
---@param models string[]
local function remember(key, models)
	cache[key] = models
	require("ducktape.model_cache").write(key, models)
end

---@param provider string
---@param endpoint? string
---@return string
function M.cache_key(provider, endpoint)
	return endpoint and (provider .. ":" .. endpoint) or provider
end

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
	return vim.deepcopy(strategy.values or strategy.sentinel or strategy.seed or {})
end

---@param provider string
---@param endpoint string|nil
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

---@param provider string
---@param strategy table
---@param cb fun(models: string[]|nil, err: string|nil)
local function fetch_subprocess(provider, strategy, cb)
	local cmd = strategy.cmd
	if type(cmd) ~= "table" or #cmd == 0 then
		return cb(nil, ("%s has no model command"):format(provider))
	end
	if vim.fn.executable(cmd[1]) == 0 then
		return cb(nil, ("`%s` is not on PATH"):format(cmd[1]))
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
	-- static and live_session have nothing to ask.
	cb(known)
end

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
		table.insert(names, type(model) == "string" and model or value)
	end
	table.sort(names)
	cb(names)
end

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

---Prime the model cache in the background. Called from setup on first run.
function M.discover_models()
	for _, provider in ipairs(M.names()) do
		for _, entry in ipairs(M.cache_keys(provider)) do
			M.models_async(provider, entry.endpoint, function() end)
		end
	end
end

---@return { provider: string, endpoint: string|nil, key: string, label: string }[]
function M.discoverable()
	local out = {}
	for _, provider in ipairs(M.names()) do
		local strategy = (M.spec(provider) or {}).models or {}
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

function M.clear_cache()
	cache = {}
	seeded = false
end

function M.forget_models()
	cache = {}
	seeded = true
	require("ducktape.model_cache").clear()
end

-- Pre-registry model API.

---@deprecated Use `M.models_async("ollama", endpoint, cb)`
---@param endpoint "local"|"cloud"
---@param cb fun(models: string[]|nil, err: string|nil)
function M.ollama_models(endpoint, cb)
	return M.models_async("ollama", endpoint, function(models, err)
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
		derive = guard.derive ~= false,
	}
end

---Derive the most restrictive write-denying mode the live session offers. Returns nil when no
-- safe mode exists, signalling that inline should be withheld.
---@param provider string
---@param conn table
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

---@param provider string
---@return table<string, string>
function M.required_session_options(provider)
	return vim.deepcopy(M.effective_guard(provider).required or {})
end

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

-- Pre-registry permission tables kept for direct readers.

---@deprecated Read `M.effective_guard("opencode").env` instead.
M.opencode_permission = M.providers.opencode.guard.env.OPENCODE_PERMISSION

---@deprecated Read `M.effective_guard("opencode").chat_env` instead.
M.opencode_chat_permission = M.providers.opencode.guard.chat_env.OPENCODE_PERMISSION

return M
