# Parity checks

The suites in `tests/` run against a bare runtimepath and answer "does this code still behave the
way it did". These scripts answer a different question: **does the packaging work in a real
config** — the load order, the keymap hedge, the write defence when setup did not finish, and the
three transports against live agents.

They are kept because that is where the one real packaging bug was found. `vim.g.ducktape =
{ keymaps = false }` created every default keymap it asked to suppress, and no unit test could have
caught it: the suites configure through `config.setup()`, and the bug lived on the `config.get()`
route that only `plugin/ducktape.lua` uses.

## Running them

They need a config with the plugin actually installed. `minimal.lua` at the repo root is one:

```sh
nvim --headless --clean -u minimal.lua -c 'luafile tests/parity/check_startup.lua' -c 'qa!'
```

`probe_init.lua` is a variant config for the cases that need a different spec than the parity one.
It reads `$DT_VARIANT` and expects the plugin tree to be installed already, so point its XDG roots
at a config you have launched once:

```sh
DT_VARIANT=keymaps_false nvim --headless -u tests/parity/probe_init.lua \
  -c 'luafile tests/parity/check_keymaps.lua' -c 'qa!'
```

Variants: `default`, `keymaps_false`, `globals_false`, `taken_key`, `own_plug`, `wrong_route`,
`no_extension`, `setup_throws`, `late_throw`, `no_telescope`, `no_catppuccin`.

| Script | Variants it wants | What it establishes |
|---|---|---|
| `check_startup.lua` | the parity config | Before any keypress: the mappings, the command and the statusline segment exist, and neither codecompanion nor any ducktape module is loaded |
| `check_wired.lua` | the parity config | `bootstrap()` loads codecompanion and completes setup, and the adapters in place are the hardened ones |
| `check_refuse.lua` | `no_extension`, `setup_throws`, `late_throw` | Every action refuses, loudly, rather than driving an unhardened agent |
| `check_keymaps.lua` | `default`, `keymaps_false`, `globals_false`, `taken_key`, `own_plug` | A user's own mapping wins on both paths, and `false` reaches the globals without touching the diff keys |
| `check_degrade.lua` | `no_telescope` | The three telescope features name telescope and everything else works |
| `check_live.lua` | the parity config | Real round trips on all three transports, plus that the pool drains |
| `check_ab_opencode.lua` | the parity config | Runs the pre-extraction `lua/ai/` pool beside this one against the same adapter, for telling a regression apart from a provider's bad day |

`check_ab_opencode.lua` expects the pre-extraction tree at `~/dotfiles/nvim_main/.config/nvim` and
is only useful while that exists.

## What they do not cover

The interactive pass: the inline prompt and diff review, the list actions, the pickers' confirm
step, the status panel's live option change, the chat-edit fork, and the visual-mode halves of the
four dual-mode keymaps. Those need a human at a keyboard, and `docs/keymaps.md` is the checklist.
