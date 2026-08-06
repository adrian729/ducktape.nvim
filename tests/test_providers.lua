-- Adding a provider nobody wrote code for.
--
-- The suite this exists for: `providers` looked like a table you could add a key to, and was not.
-- A fourth provider was accepted by `set_provider`, then routed to *another provider's* relay,
-- given no write defence, never asked for its models, and shown in no picker. Two of those failed
-- silently and one of them threw.
--
-- So every assertion below is about a provider this code has never heard of. `gemini_cli` and
-- `openai_compatible` are used as the adapter names because codecompanion ships both as files but
-- registers neither, which makes them the closest thing to a genuinely third-party adapter.

local REPORT = "/tmp/providers.out"
local passed, failed, lines = 0, 0, {}
local function flush()
	local f = io.open(REPORT, "w")
	f:write(table.concat(lines, "\n"), "\n\n", ("%d passed, %d failed\n"):format(passed, failed))
	f:close()
end
local function section(t)
	table.insert(lines, "\n=== " .. t .. " ===")
end
local function ok(cond, what, detail)
	if cond then
		passed = passed + 1
		table.insert(lines, "  ok   " .. what)
	else
		failed = failed + 1
		table.insert(lines, "  FAIL " .. what .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
	end
	flush()
end
local function eq(what, got, want)
	ok(got == want, what, ("got %q want %q"):format(tostring(got), tostring(want)))
end

vim.env.XDG_STATE_HOME = vim.fn.tempname()

local config = require("ducktape.config")
local providers = require("ducktape.providers")

-- A minimal-but-complete ACP provider and a minimal-but-complete HTTP one. Neither names a guard,
-- which is the interesting part: the ACP one has to get a derived defence rather than none.
local GEMINI = {
	label = "Gemini",
	kind = "acp",
	adapter = "gemini_cli",
	inline_options = { "model" },
	chat_options = { "model", "mode" },
	options = {
		model = { label = "Model", category = "model", dynamic = true },
		mode = { label = "Mode", category = "mode", values = { "default", "plan" } },
	},
	models = { strategy = "static", values = { "gemini-3-pro", "gemini-3-flash" } },
}

local LOCALAI = {
	label = "LocalAI",
	kind = "http",
	endpoints = {
		main = { url = "http://localhost:8080", adapter = "localai", extends = "openai_compatible" },
	},
	inline_options = { "endpoint", "model" },
	chat_options = { "endpoint", "model" },
	options = {
		endpoint = { label = "Endpoint", values = { "main" } },
		model = { label = "Model", dynamic = true },
	},
	models = { strategy = "http_tags", path = "/v1/models", field = "data", name_key = "id" },
}

config.setup({ providers = { gemini = GEMINI, localai = LOCALAI } })
providers.apply(config.get())

section("the registry sees them")
ok(vim.tbl_contains(providers.names(), "gemini"), "gemini is a provider")
ok(vim.tbl_contains(providers.names(), "localai"), "localai is a provider")
eq("five providers in all", #providers.names(), 5)
eq("gemini is acp", providers.kind("gemini"), "acp")
eq("localai is http", providers.kind("localai"), "http")

section("nothing throws on a provider with no `defaults` entry of its own")
-- Every one of these used to be `attempt to index field 'opts' (a nil value)`.
ok(providers.set_provider("inline", "gemini"), "set_provider accepts it")
ok(
	pcall(function()
		return providers.current("inline").opts.model
	end),
	"current().opts is readable"
)
ok(providers.set_option("inline", "model", "gemini-3-pro"), "set_option works")
eq("and the value stuck", providers.current("inline").opts.model, "gemini-3-pro")

section("its inline transport is its own, never another provider's relay")
-- The bug: an unknown provider fell through to `deep and "acp" or "relay"`, which is opencode's
-- relay script. The request went to a different vendor entirely.
eq("gemini shallow inline is its own agent", providers.transport("gemini", false), "acp")
eq("gemini deep inline too", providers.transport("gemini", true), "acp")
eq("localai is http both ways", providers.transport("localai", false), "http")
eq("localai deep is http as well", providers.transport("localai", true), "http")
ok(providers.relay("gemini") == nil, "gemini has no relay")
-- The shipped provider that does have one still uses it, so the default did not swallow the case.
eq("opencode still relays the shallow path", providers.transport("opencode", false), "relay")
eq("and uses acp for the deep one", providers.transport("opencode", true), "acp")

section("the write defence is derived, not skipped")
local guard = providers.effective_guard("gemini")
ok(guard.required == nil, "the spec names no required mode")
ok(guard.derive, "so one is derived")
ok(not guard.unguarded, "and it is not unguarded")

-- A stand-in for a live session: `derive_guard` reads exactly this shape off a real connection.
local function fake_conn(modes)
	return {
		get_config_options = function()
			return {
				{
					category = "mode",
					type = "select",
					id = "mode",
					currentValue = modes[1],
					options = vim.tbl_map(function(m)
						return { value = m, name = m }
					end, modes),
				},
			}
		end,
	}
end

local derived = providers.derive_guard("gemini", fake_conn({ "default", "acceptEdits", "plan" }))
eq("the most restrictive offered mode is chosen", derived and derived.mode, "plan")

local none, why = providers.derive_guard("gemini", fake_conn({ "default", "acceptEdits" }))
ok(none == nil, "an agent offering no write-denying mode yields no guard")
ok(type(why) == "string" and why:find("write%-denying"), "and says why, got " .. tostring(why))

local no_modes, why2 = providers.derive_guard("gemini", fake_conn({}))
ok(no_modes == nil, "an agent advertising no mode option at all yields no guard")
ok(type(why2) == "string" and #why2 > 0, "and says why")

-- A spec that names one keeps it: derivation must not override a deliberate choice. claude's
-- `dontAsk` is the case that matters — `plan` would also be safe and would win a derivation.
eq(
	"a named requirement outranks derivation",
	providers.derive_guard("claude", fake_conn({ "default", "plan", "dontAsk" })).mode,
	"dontAsk"
)
eq("and is what gets verified", providers.required_session_options("claude").mode, "dontAsk")

-- The explicit opt-out, which is the only way to an unguarded inline agent.
providers.providers.gemini.guard = { unguarded = true }
local waived = providers.derive_guard("gemini", fake_conn({ "default" }))
ok(waived ~= nil and vim.tbl_isempty(waived), "guard.unguarded = true waives it deliberately")
providers.providers.gemini.guard = nil

section("adapters resolve by name, for a provider and for an endpoint")
eq("the acp adapter", providers.acp_adapter("gemini"), "gemini_cli")
ok(providers.acp_adapter("localai") == nil, "an http provider has no acp adapter")
eq("the endpoint's adapter", providers.adapter_name("localai", "inline"), "localai")
eq("mapped back to its provider", providers.provider_for_adapter("localai"), "localai")
eq("and so is the shipped one", providers.provider_for_adapter("ollama_cloud"), "ollama")
eq("acp adapters map back too", providers.provider_for_adapter("gemini_cli"), "gemini")

section("model discovery covers them")
local keys = {}
for _, target in ipairs(providers.discoverable()) do
	keys[target.key] = target.label
end
ok(keys["localai:main"] ~= nil, "localai's endpoint is discoverable")
-- `static` has nothing to ask, so it is deliberately absent rather than queried pointlessly.
ok(keys["gemini"] == nil, "a static list is not queried")
eq("its models are still available", #providers.models("gemini"), 2)
ok(vim.tbl_contains(providers.models("gemini"), "gemini-3-pro"), "and are the ones configured")
-- Regression guard on the shipped keys: the persisted file uses these names.
ok(keys["ollama:cloud"] ~= nil, "ollama cloud is still discoverable")
ok(keys["opencode"] ~= nil, "opencode is still discoverable")

section("a live session's own list wins over a static one")
local enriched = providers.enrich_from_session("gemini", {
	get_models = function()
		return {
			currentModelId = "gemini-4-pro",
			availableModels = { { modelId = "gemini-4-pro" }, { modelId = "gemini-4-flash" } },
		}
	end,
})
ok(enriched ~= nil, "the session list is taken")
ok(vim.tbl_contains(providers.models("gemini"), "gemini-4-pro"), "a model released since is now offered")

section("capabilities decide behaviour, not names")
ok(providers.resumable("gemini"), "an acp provider can resume sessions")
ok(not providers.resumable("localai"), "an http provider cannot")
ok(not providers.resumable("ollama"), "which is still true of the shipped http provider")
eq("after_session options are read off the spec", #providers.after_session_options("claude", "chat"), 1)
eq("and a provider without one has none", #providers.after_session_options("gemini", "chat"), 0)

section("tiers degrade rather than guess")
ok(providers.model_tier("gemini", "gemini-3-pro") == nil, "an unknown model claims nothing")
eq("a shipped endpoint still reports its tier", providers.model_tier("ollama", "x", "local").label, "free · local")

section("the picker shows them")
-- The failure this catches: build_entries enumerated three providers by hand, so a fourth was
-- selectable everywhere except the picker.
local rendered = {}
for _, entry in ipairs(require("ducktape.pick")._entries_for_test("inline")) do
	rendered[entry.value.provider] = true
end
for _, name in ipairs({ "gemini", "localai", "claude", "opencode", "ollama" }) do
	ok(rendered[name], name .. " has rows in the picker")
end

section("the deprecated opencode config route still works")
config.setup({ opencode = { prefer = { "opencode/somewhere" } } })
eq(
	"prefer is folded onto the provider spec",
	vim.tbl_get(config.get(), "providers", "opencode", "auto", "prefer", 1),
	"opencode/somewhere"
)
config.setup({ opencode = { relay = { cmd = "my-relay" } } })
eq("and so is the relay command", providers.relay_cmd("opencode"), "my-relay")

section("a bad `defaults.provider` is caught rather than left to fail later")
config.setup({ defaults = { inline = { provider = "nope" } } })
providers.apply(config.get())
ok(providers.providers[providers.defaults.inline.provider] ~= nil, "it falls back to a real provider")

flush()
