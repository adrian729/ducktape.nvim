-- The model cache, and what `auto` resolves to.
--
-- The bug this suite exists for: `auto` used to be "the first free model in whatever list we have",
-- and the two sources of that list disagree on order. A hand-written fallback list is ordered by
-- preference; `opencode models` is alphabetical. So opening the picker once — which is what fills the
-- cache — silently moved `auto` onto whichever free model sorts first, which is opencode's own
-- ambient default. Nothing in the old suites could see it: they never filled the cache.

local REPORT = "/tmp/models.out"
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

-- Point the cache somewhere disposable before anything reads it.
vim.env.XDG_STATE_HOME = vim.fn.tempname()

local cache = require("ducktape.model_cache")
local providers = require("ducktape.providers")
local config = require("ducktape.config")

-- Alphabetical, exactly as `opencode models` reports it, so `big-pickle` sorts first among the free
-- ones. That ordering is the whole hazard.
local AS_REPORTED = {
	"auto",
	"opencode/big-pickle",
	"opencode/deepseek-v4-flash-free",
	"opencode/laguna-s-2.1-free",
	"opencode/mimo-v2.5-free",
	"opencode-go/kimi-k3",
	"opencode-go/qwen3.7-max",
}

section("a fresh machine has no cache and says nothing about it")
cache.clear()
providers.forget_models()
ok(cache.read() == nil, "nothing on disk")
eq("the sync list is just the sentinel", #providers.opencode_models(), 1)
eq("and that sentinel is auto", providers.opencode_models()[1], "auto")

section("what is discovered survives a restart")
cache.write("opencode", AS_REPORTED)
providers.clear_cache() -- as if this were a new session: memory empty, disk warm
eq("the list is read back", #providers.opencode_models(), #AS_REPORTED)
ok(vim.tbl_contains(providers.opencode_models(), "opencode-go/kimi-k3"), "Go models are kept")
ok(cache.generated_at() ~= nil, "the write is stamped")

section("a second list merges rather than replacing")
cache.write("ollama:cloud", { "gpt-oss:120b", "kimi-k3" })
local lists = cache.lists()
eq("opencode is still there", #(lists.opencode or {}), #AS_REPORTED)
eq("and ollama is too", #(lists["ollama:cloud"] or {}), 2)

section("auto resolves by preference, not by list order")
config.setup({})
eq(
	"the first preferred model that exists wins",
	providers.resolve_chat_option_value("opencode", "model", "auto"),
	"opencode/deepseek-v4-flash-free"
)
ok(
	providers.resolve_chat_option_value("opencode", "model", "auto") ~= "opencode/big-pickle",
	"and never the ambient default that sorts first"
)

section("preference entries this machine does not offer are skipped")
config.setup({ opencode = { prefer = { "opencode/not-on-this-machine", "opencode/mimo-v2.5-free" } } })
eq(
	"it walks past the missing one",
	providers.resolve_chat_option_value("opencode", "model", "auto"),
	"opencode/mimo-v2.5-free"
)

section("with nothing preferred available, any free model beats the ambient default")
config.setup({ opencode = { prefer = { "opencode/none-of-these", "opencode/either" } } })
local fallback = providers.resolve_chat_option_value("opencode", "model", "auto")
ok(providers.is_free_opencode_model(fallback), "the fallback is free, got " .. tostring(fallback))
ok(not providers.is_go_opencode_model(fallback), "and never spends the Go subscription")

section("a Go model is never auto-selected even when it is preferred")
-- Guards the one mistake in this file that would cost money rather than quality.
config.setup({ opencode = { prefer = { "opencode-go/qwen3.7-max" } } })
local go_pick = providers.resolve_chat_option_value("opencode", "model", "auto")
ok(go_pick ~= "opencode-go/qwen3.7-max", "a Go entry in prefer is not honoured, got " .. tostring(go_pick))

section("a real value is passed through untouched")
config.setup({})
eq(
	"an explicit model",
	providers.resolve_chat_option_value("opencode", "model", "opencode/big-pickle"),
	"opencode/big-pickle"
)
eq("a non-model option", providers.resolve_chat_option_value("opencode", "mode", "build"), "build")

section("forgetting really forgets, on disk as well")
providers.forget_models()
ok(cache.read() == nil, "the file is gone")
eq("and the sync list is back to the sentinel", #providers.opencode_models(), 1)

section("discovery asks only for what is not already known")
-- What setup calls on a first run, and the reason a fresh install needs no setup step of its own.
-- Counted rather than really spawned: the answers would land asynchronously and overwrite the
-- deliberately-ordered lists these assertions depend on.
local spawned, real_system = 0, vim.system
vim.system = function()
	spawned = spawned + 1
end

providers.discover_models() -- nothing known: the state forget_models left above
ok(spawned > 0, "an empty cache asks, got " .. spawned .. " queries")

for _, key in ipairs({ "opencode", "ollama:cloud", "ollama:local" }) do
	cache.write(key, { "something" })
end
providers.clear_cache() -- a new session: memory empty, all three lists on disk
spawned = 0
providers.discover_models()
-- Asking `opencode models` and two curls on every single start is what persisting them avoids.
eq("nothing is asked when every list is known", spawned, 0)

vim.system = real_system
providers.forget_models()

section("a corrupt or foreign cache file is treated as absent")
local file = cache.path()
vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
vim.fn.writefile({ "not json at all" }, file)
ok(cache.read() == nil, "unparseable is nil rather than an error")
vim.fn.writefile({ vim.json.encode({ version = 99, lists = { opencode = { "x" } } }) }, file)
ok(cache.read() == nil, "a future version is nil rather than misread")
cache.clear()
