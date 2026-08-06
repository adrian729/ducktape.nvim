# ducktape.nvim

Inline editing, chat sessions and a provider layer on top of
[codecompanion.nvim](https://github.com/olimorris/codecompanion.nvim).

Codecompanion supplies the adapters, the chat buffer and the transport. Ducktape is the layer that
makes a working day out of them: several inline edits in flight at once without stepping on each
other, chats that survive an nvim restart with nothing respawned until you open one, one option UX
across every provider you configure, and inline requests that cannot write to your filesystem.

```
    ⠋ ollama · gpt-oss:120b · return 2 instead · 3 lines
    local function f()
      return 1
    end
```

## What it does

- **Inline editing** — `<leader>ci` on a selection, or on the line under the cursor. Several
  requests at once across buffers, each holding its lines against your edits (and against undo)
  until it settles. Diffs applied per region. Replies that turn out to be prose rather than code
  are kept and readable instead of thrown away. `<leader>cI` lets an ACP provider read the repo
  first.
- **Chat sessions** — one keymap toggles the last chat and reopens it after a restart. Any past
  session for the repository can be restored. Titles you set outlive the agent's own auto-titles.
  Provider, model, effort, mode and agent are per chat. Editing a message you already sent and
  asking again forks a fresh agent session carrying your edited transcript.
- **Any provider, one option UX** — Claude and OpenCode over ACP and Ollama over HTTP out of the
  box, and a registry rather than a fixed set: one table adds a fourth, and every picker, panel and
  discovery pass finds it. Model lists resolved live and cached, free-tier-first defaults, and a
  label at the point of choice saying what a model draws on.
- **A write defence that covers providers we have never seen** — inline transports cannot write.
  Claude runs `mode = dontAsk`, OpenCode gets an explicit deny set, and a provider that names
  nothing has a write-denying mode *derived* from what its own agent advertises. Either way the value
  is read back off the live session and a connection that did not take it is refused. If no safe
  mode exists, inline is withheld for that provider alone rather than run unguarded. Chat may write
  but asks first. Open buffers reload themselves when an agent edits a file underneath them, and
  refuse to when you have unsaved changes.
- **Status and plumbing** — a status panel with live per-session option changes, statusline counters
  for running / waiting / failed inline requests, a pooled ACP connection layer with reuse, overflow
  and idle teardown, and `:Ducktape pool` / `:Ducktape send` / `:Ducktape models` for when something looks wrong.

All 18 global keymaps, the buffer-local diff keys and every list and picker are in
[`docs/keymaps.md`](docs/keymaps.md). The day-to-day guide is
[`docs/how_to_use.md`](docs/how_to_use.md); how it works inside is
[`docs/implementation.md`](docs/implementation.md). After installing, `:h ducktape`.

## Install

Ducktape and codecompanion are **two sibling entries**, not a dependency chain. Ducktape has to be
a start plugin so its keymaps and statusline segment exist from the first redraw; codecompanion
stays deferred and is pulled in by your first ducktape action.

### lazy.nvim

```lua
{
  "adrian729/ducktape.nvim",
  lazy = false,                     -- required: plugin/ducktape.lua owns the keymaps
},
{
  "olimorris/codecompanion.nvim",
  event = "VeryLazy",               -- keep this; see below
  dependencies = { "nvim-lua/plenary.nvim" },
  opts = {
    extensions = {
      ducktape = { opts = {} },     -- empty opts is a complete configuration
    },
  },
},
```

Ducktape ships a `lazy.lua`, so plenary, nvim-treesitter and telescope come along on their own.

**Do not drop `event = "VeryLazy"` from codecompanion.** lazy.nvim derives laziness from the spec,
so a codecompanion entry with no `event`, `keys`, `ft` or `cmd` computes to `lazy = false` and is
loaded synchronously during startup — dependencies, `config`, `setup()` and all. Ducktape is the
one that wants `lazy = false`; codecompanion is the one that must stay deferred.

### vim.pack (Neovim 0.12+)

```lua
vim.pack.add({
  { src = "https://github.com/nvim-lua/plenary.nvim" },
  { src = "https://github.com/nvim-treesitter/nvim-treesitter" },
  { src = "https://github.com/nvim-telescope/telescope.nvim" },
  { src = "https://github.com/olimorris/codecompanion.nvim" },
  { src = "https://github.com/adrian729/ducktape.nvim",
    version = vim.version.range("*") },
})

require("codecompanion").setup({ extensions = { ducktape = { opts = {} } } })
```

`vim.pack` has no dependency field, so the list above is the whole mechanism — the table in the
next section is not a courtesy. Update with `vim.pack.update()`.

Either way, run `:checkhealth ducktape` afterwards. It is the runtime source of truth for
everything below, including the external programs no plugin manager can install.

## Dependencies

| | Required for | Notes |
|---|---|---|
| **codecompanion.nvim** | everything | Developed against **v19.22**. Ducktape reads a dozen of its internal APIs; `:checkhealth ducktape` resolves each one by name, so an upstream refactor is reported rather than discovered. |
| **plenary.nvim** | everything | Codecompanion's own dependency. Declared here too, since a `vim.pack` user gets nothing transitively. |
| **nvim-treesitter** with `markdown` + `markdown_inline` | everything | **The one that is easy to miss.** Neovim ships neither parser. Without them the chat does not render and editing a sent message silently does nothing. |
| **telescope.nvim** | nothing, strictly | Optional. The chat list and both model pickers use it when it is there and a built-in float when it is not, so what you lose is fuzzy matching and your own picker layout — not the feature. `opts.ui.picker` chooses. |
| **catppuccin** | the palette the highlights derive from | Optional. A teal stand-in is used instead. |
| Neovim | — | 0.11+, matching codecompanion's own floor. |

External programs, which have to be on the `PATH` of the shell that launches nvim:

| | Required for |
|---|---|
| `node` + `claude-agent-acp` | the Claude provider |
| `opencode` | the OpenCode provider and its model list |
| `curl` + `$OLLAMA_API_KEY` | Ollama's cloud endpoint |
| a running `ollama` | Ollama's local endpoint only |
| `git` | scoping saved chats and resumable sessions to the repository — degrades to "no resumable sessions", or set `opts.session.scope` |
| `opencode-llm` + `jq` | the tool-free OpenCode inline path only, and **not bundled** — see below |

The provider rows above are the three that ship. `:checkhealth ducktape` derives this list from
whatever you have configured, including a provider's agent command and its relay, so it stays right
after you add one.

### `opencode-llm` is not vendored

OpenCode's tool-free inline path shells out to a program named `opencode-llm`. Ducktape does not
ship it, because the version this was extracted from is a script with a life of its own outside
nvim, and two copies would drift. Anything meeting its contract can stand in:

- content on **stdin**, the request as **arguments**, the answer on **stdout**
- exit codes: `1` usage, `2` empty input, `3` a missing prerequisite, `5` no model available,
  `6` API error, `124` timeout

Point ducktape at yours with `opts.providers.opencode.relay.cmd`. Without it, that one path reports
`opencode-llm is not on PATH` and the Claude and Ollama providers are unaffected.

### If your node comes from nvm

nvm exposes `node` as a shell function, so an nvim started from anything other than an interactive
shell — a GUI launcher, a desktop entry — has no `node` on its `PATH` and `claude-agent-acp` fails
to spawn. The symptom is an ACP session that never answers, not an error naming node. Either launch
nvim from a shell where `node` resolves, or put the nvm bin directory on `vim.env.PATH` in your own
config:

```lua
local nvm = vim.fn.expand("~/.nvm/versions/node")
local newest = vim.fn.glob(nvm .. "/*/bin", false, true)[1]
if newest then
  vim.env.PATH = newest .. ":" .. vim.env.PATH
end
```

## Configuration

`opts = {}` is a complete configuration — the defaults are the setup this was extracted from, so
configuring nothing is the supported case.

Options arrive by **two routes**, and which one depends on when the value is needed.
`plugin/ducktape.lua` runs at startup, before any plugin manager has applied `opts`, so anything it
acts on has to come from `vim.g.ducktape`:

| Route | Fields | Read at |
|---|---|---|
| `vim.g.ducktape` | `keymaps`, `statusline` | startup |
| codecompanion `extensions.ducktape.opts` | everything else | `codecompanion.setup()` |

Putting a field in the wrong table means it is silently ignored, so `:checkhealth ducktape`
validates each route against its own list and names the mistake. It also walks the whole tree, so a
typo nested inside `inline.prompt` or `keymaps.panels.status` is reported rather than ignored.

### `vim.g.ducktape`

```lua
vim.g.ducktape = {
  -- false, or { globals = false }, drops the <leader>c* set and keeps the <Plug> maps.
  -- Per-action overrides: see docs/keymaps.md for the action names.
  keymaps = {
    globals = true,
    inline = { "<leader>ai", mode = { "n", "x" }, desc = "AI: inline prompt" },
  },
  -- The inline counters, appended into vim.o.statusline left of the ruler. `icons` and `label` set
  -- what the segment draws; `require("ducktape.statusline").render()` is the component if you
  -- would rather place it yourself with `enabled = false`.
  statusline = { enabled = true },
}
```

### Extension `opts`

```lua
opts = {
  -- Deep-merged over the shipped provider specs: models, option values, which options each
  -- provider offers. A name that is not one of the three shipped ones **adds a provider** — see
  -- "Adding a provider" below.
  providers = {},

  -- The current selection, per interaction and per provider.
  defaults = {
    inline = {
      provider = "ollama",
      opts = {
        ollama = { endpoint = "cloud", model = "gpt-oss:120b", think = "off" },
        claude = { model = "sonnet", effort = "medium" },
        opencode = { model = "auto" },
      },
    },
    chat = {
      provider = "claude",
      opts = {
        claude = { model = "opus", effort = "xhigh", fast = "off", mode = "default" },
        opencode = { model = "auto", mode = "build" },
        ollama = { endpoint = "cloud", model = "gpt-oss:120b", think = "off" },
      },
    },
  },

  -- Deep-merged over the adapter definitions ducktape installs into codecompanion. These carry
  -- the write defence — the 90s timeout, Claude's `mode = dontAsk`, OpenCode's deny set — so
  -- override with care, and read what :checkhealth says about it afterwards.
  adapters = {},

  -- Claim codecompanion's chat/inline/cmd adapter defaults when they are still its own stock
  -- "copilot". An explicit choice of yours always survives; set this to false if your explicit
  -- choice happens to be copilot.
  set_default_adapters = true,

  -- Inline editing. `prompt` is the contract the model is held to and the single biggest lever on
  -- the quality of what comes back.
  inline = {
    context_lines = 40,      -- lines sent either side of the selection
    timeout_ms = 90000,      -- one value for every transport; the three used to disagree
    diagnostics = true,      -- send the range's diagnostics along with the prompt
    prompt = { contract = "…", no_tools = "…", deep = "…", insert = "…" },
    -- How a reply is judged code or prose. Additive: your entries are tried first and the shipped
    -- ones still apply. The shipped refusal patterns are English, which is the reason this exists.
    parse = {
      refusal_openers = {}, lead_ins = {}, prose_filetypes = {},
      comment_prefixes = {}, leak_patterns = {},
      replace = false,       -- true to use only what is configured
    },
  },

  -- The pool of ACP connections behind inline, per provider.
  pool = {
    cap = 3, idle_overflow_ms = 60000, idle_primary_ms = 900000,
    reap_interval_ms = 15000, timeout_ms = 90000,
  },

  ui = {
    border = "rounded",
    -- "auto" takes telescope if installed and a built-in float otherwise. Also accepts
    -- "telescope", "default", or a function taking the picker spec.
    picker = "auto",
    spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    -- Merged over the palette-derived values. Every group is defined with `default = true`, so a
    -- colourscheme or your own `nvim_set_hl` wins over both.
    highlights = {},
  },

  -- What counts as "this project". Two settings, each defaulting to what it already did:
  --   scope  which resumable agent sessions the chat list offers — the repository root, so they do
  --          not vanish when nvim is opened in a subdirectory
  --   chats  what saved chats are filed under — the working directory, so two subdirectories of one
  --          repository keep their own sets
  -- Each takes "git", "root" (vim.fs.root, no subprocess), "cwd", or a function. Set `chats = "git"`
  -- to share one set of chats per repository; existing per-directory sets are merged into it.
  session = { scope = "git", chats = "cwd" },
}
```

`vim.g.ducktape.keymaps.panels` carries the buffer-local keys inside ducktape's own windows —
`inline_list`, `status`, `picker`, `chat_list`, `message`. See [`docs/keymaps.md`](docs/keymaps.md).

### Model lists discover themselves

Nothing about which models exist is shipped or configured. Each provider is asked — `opencode models`
for the OpenCode free tier and any Go subscription, ollama's `/api/tags` for each endpoint, the live
ACP session for Claude's — and the answers are written to
`stdpath("state")/ducktape/models.json` so the next start has them immediately.

That discovery runs by itself, in the background, the first time the plugin sets up on a machine
with no `models.json` yet — so a fresh install has its lists before you ever open a picker, and
there is no setup step of your own to remember. Every start after that reads the file and asks
nothing.

The lists never expire, because a stale list beats an empty picker and refreshing is one key:

```vim
:Ducktape models
" or <leader>cmr
```

That throws the file away, asks everything again, and reports what came back — the only thing that
picks up an ollama model you just pulled, a subscription that just started, or an
`opencode auth login`. Note `opencode models` reports what the *authenticated* opencode can reach:
if `$XDG_DATA_HOME` points somewhere without `opencode/auth.json` in it, you get the ambient free
tier and no Go models, with exit code 0 and nothing on stderr.

`:checkhealth ducktape` prints what has been discovered, when, and what `auto` currently resolves to.

### Adding a provider

`providers` is a registry, not a fixed set. Every surface — the pickers, the status panel, the chat
list, model discovery, health — walks it, so a fourth provider needs no edit to the plugin.
Codecompanion ships 13 ACP adapters and 18 HTTP ones; ducktape wires three of them by default.

```lua
opts = {
  providers = {
    gemini = {
      label = "Gemini",
      kind = "acp",              -- or "http"
      adapter = "gemini_cli",    -- a codecompanion adapter name
      inline_options = { "model" },
      chat_options = { "model", "mode" },
      options = {
        model = { label = "Model", category = "model", dynamic = true },
        mode  = { label = "Mode", category = "mode", values = { "default", "plan" } },
      },
      -- Where its model list comes from. `live_session` asks a running agent; `subprocess` runs a
      -- command; `http_tags` GETs a list endpoint; `static` is a list you write; `adapter`
      -- delegates to codecompanion's own `schema.model.choices`.
      models = { strategy = "live_session", seed = { "gemini-3-pro" } },
    },
  },
  defaults = { chat = { provider = "gemini" } },
}
```

**You do not have to configure a write defence, and you cannot accidentally skip one.** An ACP
provider that names no `guard.required` gets one *derived* from the live agent: ducktape reads the
modes the agent advertises through its session config options and picks the most restrictive
write-denying one it offers. That value is then read back off the session, and a connection that did
not take it is refused.

If the agent offers no write-denying mode at all, **inline over ACP is withheld for that provider
alone** — chat still works, setup still succeeds, the model picker marks the row, and
`:checkhealth ducktape` says which provider and why. Nothing silently gets a write-capable agent, and
nothing else breaks to achieve that.

To name the mode yourself, or to opt out deliberately:

```lua
providers = {
  gemini = {
    guard = {
      required = { mode = "plan" },  -- verified on every connection
      -- unguarded = true,           -- accept an inline agent with write tools
    },
  },
}
```

An HTTP provider needs no guard: there is no tool plumbing on that path to deny. Give its endpoints
an `extends` and ducktape generates the codecompanion adapters for them — which is exactly how the
two shipped ollama adapters are built, so the path an added provider takes is the one the shipped
provider already uses.

```lua
providers = {
  localai = {
    label = "LocalAI", kind = "http",
    endpoints = {
      main = { url = "http://localhost:8080", adapter = "localai", extends = "openai_compatible" },
    },
    models = { strategy = "http_tags", path = "/v1/models", field = "data", name_key = "id" },
    inline_options = { "endpoint", "model" }, chat_options = { "endpoint", "model" },
    options = {
      endpoint = { label = "Endpoint", values = { "main" } },
      model = { label = "Model", dynamic = true },
    },
  },
}
```

`tests/test_providers.lua` is this contract written down: it adds both of the above and asserts they
reach every surface.

### Standalone, without the extensions block

`require("ducktape").setup(opts)` also works on its own and will call `codecompanion.setup()` for
you, passing `opts.codecompanion` through, if codecompanion has not been set up yet. The extension
is the recommended route; this one exists for `vim.pack` users and anyone who would rather not
route through codecompanion's config.

## Troubleshooting

- `:checkhealth ducktape` first. It reports the Lua dependencies, the parsers, each codecompanion
  internal by name, the external programs, and whether setup ran to completion.
- **Every keymap refuses with a message.** Setup did not finish. Codecompanion loads extensions
  inside a `pcall` that only logs, so check `:messages` and that `extensions.ducktape` is spelled
  the way it is above. Refusing is deliberate: the adapters that deny agent writes are installed by
  that setup, and running without them is worse than not running.
- **Reproducing something.** `minimal.lua` at the repo root is a complete config with nothing in it
  but ducktape and what it needs; `nvim --clean -u minimal.lua` keeps its plugins and state in
  `./.repro` and cannot touch your real install.

## Contributing

```sh
make test        # the suites, under a minimal_init that fetches its own dependencies
make lint        # stylua --check
make fmt         # stylua
make doc         # doc/ducktape.txt, via panvimdoc — needs pandoc
```

`doc/ducktape.txt` is generated, not hand-written, and regenerated by CI on every push to `main`
that touches `README.md` or `docs/` — so `make doc` is only needed if you want to see the result
locally.

Releases are tagged from conventional commits on `main` by release-please, which is what makes
lazy.nvim's `version = "*"` and `vim.pack`'s `vim.version.range()` work.

## Licence

MIT. Codecompanion is Apache-2.0 and is not vendored here — ducktape calls its API and copies none
of its code.
