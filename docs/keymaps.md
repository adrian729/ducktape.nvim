# Keymaps

Every key below is either ducktape's or codecompanion's, and the tables say which. Ducktape's
global set is configurable — see [Configuration](#configuration) at the bottom.

## Global — ducktape

All 19 of them. Each also has a `<Plug>(Ducktape…)` mapping, so you can bind your own key without
touching the config.

| Key | Modes | Action | `<Plug>` name |
|---|---|---|---|
| `<leader>cc` | n | Toggle the last chat, reopening it after a restart | `<Plug>(DucktapeChatToggle)` |
| `<leader>cf` | n | Jump between the chat and the file — opens the chat if it is hidden | `<Plug>(DucktapeChatFocus)` |
| `<leader>cn` | n, x | New chat on the current provider and options | `<Plug>(DucktapeChatNew)` |
| `<leader>cq` | n | Close every chat | `<Plug>(DucktapeChatCloseAll)` |
| `<leader>cr` | n | Rename the current chat | `<Plug>(DucktapeChatRename)` |
| `<leader>cd` | n | Delete the current chat and its saved transcript | `<Plug>(DucktapeChatDelete)` |
| `<leader>cl` | n | Chat list — live chats plus every resumable session for the repo | `<Plug>(DucktapeChatList)` |
| `<leader>cmc` | n | Switch the chat backend / model | `<Plug>(DucktapeChatPick)` |
| `<leader>ca` | n, x | CodeCompanion's action palette | `<Plug>(DucktapeActions)` |
| `<leader>ci` | n, x | Inline prompt — no tools, no repo reads | `<Plug>(DucktapeInline)` |
| `<leader>cI` | n, x | Inline prompt that may read the repo (ACP providers only) | `<Plug>(DucktapeInlineDeep)` |
| `<leader>cmi` | n | Switch the inline backend / model | `<Plug>(DucktapeInlinePick)` |
| `<leader>cmr` | n | Re-ask every provider which models it can reach | `<Plug>(DucktapeModelsRefresh)` |
| `<leader>cL` | n | Inline list — in flight plus waiting for review | `<Plug>(DucktapeInlineList)` |
| `<leader>cA` | n | Accept every inline diff in this buffer | `<Plug>(DucktapeInlineAcceptAll)` |
| `<leader>cR` | n | Ask again about the inline edit under the cursor | `<Plug>(DucktapeInlineAskAgain)` |
| `<leader>cx` | n | Cancel the inline request under the cursor; in a chat, stop the agent | `<Plug>(DucktapeCancel)` |
| `<leader>cX` | n | Cancel every inline request in this buffer | `<Plug>(DucktapeCancelAll)` |
| `<leader>cs` | n | Status panel | `<Plug>(DucktapeStatus)` |

## Pending inline diff — ducktape, buffer-local

Bound when a diff is waiting for review and torn down with it, so they collide with nothing the
rest of the time. The banner above the diff names them, and follows a remap.

| Key | Action |
|---|---|
| `g2` | Accept the diff under the cursor |
| `g3` | Reject the diff under the cursor |
| `<leader>cj` / `<leader>ck` | Next / previous hunk |

While the diff is up, codecompanion's own `{` / `}` hunk maps are deleted from the buffer so plain
paragraph motion keeps working.

## Inline list — ducktape (`<leader>cL`)

| Key | Action |
|---|---|
| `<CR>` | Go to the edit, or read a reply that came to nothing |
| `a` / `g2` | Accept — a diff is applied, a reply goes into a chat |
| `r` | Ask again, with your instruction pre-filled to reword |
| `x` / `g3` | Get rid of it: reject, cancel or dismiss, whichever it is |
| `A` | Accept every diff — replies waiting on you are left alone |
| `X` | Done with all of it: cancel, reject and dismiss |
| `R` | Say out loud that there is no ask-again-for-everything (`r` is one row at a time) |
| `j` / `k` | Move the selection (arrows work too) |
| `?` | Help overlay; `?`, `<Esc>` or `q` closes it again |
| `q` / `<Esc>` | Close the list, once the help is down |

Row markers: `↻` still running, `◆` an edit to review or a reply to read, `✖` failed.

## Chat list — ducktape (`<leader>cl`, Telescope)

| Key | Action |
|---|---|
| `<CR>` | Open it — a stored session is restored first |
| `<C-r>` / `r` | Rename; kept against the session, so it survives reopening |
| `<C-d>` | Close a live chat, or drop a pending one — the session stays |
| `<C-x>` | Delete for good, the agent's own transcript included |
| `?` / `<C-/>` / `<C-_>` | Help overlay; `?`, `<Esc>` or `q` closes it again |
| `<C-n>` / `<C-p>` | Move the selection (`j` and `k` in normal mode) |
| `<C-c>` | Close the list |

Row markers: `▶` the chat you were in, `●` agent up and ready, `◌` agent still connecting, `✕`
agent gone (opening it starts a new one), `·` live chat with no agent yet, `○` not started — costs
nothing until opened.

## Provider / model picker — ducktape (`<leader>cmi`, `<leader>cmc`)

A float, so the whole selection is confirmed as one change rather than applied per keystroke.

| Key | Action |
|---|---|
| `j` / `k` / `<Down>` / `<Up>` | Move between options |
| `l` / `h` / `<Left>` / `<Right>` / `<Tab>` / `<S-Tab>` | Cycle the selected option's value |
| `<CR>` | Confirm |
| `q` / `<Esc>` | Discard |

Leaving the window counts as discarding.

## Chat buffer

`<CR>` and `<C-s>` are ducktape's: same keys, same description, and only the callback is replaced,
so sending carries any edits you made to the conversation above. Everything else here is
codecompanion's own and works as it documents.

| Key | Action |
|---|---|
| `<CR>` / `<C-s>` | **ducktape** — send, carrying edits to the conversation above |
| `<C-c>` | Close the chat buffer |
| `q` | Stop the current request |
| `?` | Chat buffer action palette |
| `ga` | Change the adapter for this chat |
| `gd` | Debug window (message history, adapter config) |
| `gf` | Fold / unfold codeblocks |
| `gc` | Insert a codeblock |
| `gr` | Regenerate the last response |
| `gs` | Toggle the system prompt |
| `gx` | Clear the chat buffer |
| `gy` | Yank the last codeblock |
| `gR` | Go to the file under the cursor |
| `gM` | Clear all rules |
| `gm` | Between-turn message (send while streaming) |
| `gba` | Sync full buffer content on every turn |
| `gbd` | Sync buffer diff on every turn |
| `gtx` | Reset tool approvals for this chat |
| `gty` | Toggle YOLO mode |
| `gS` | Show Copilot usage stats |
| `{` / `}` | Previous / next chat |
| `[[` / `]]` | Previous / next message header |

Ducktape adds the winbar (provider · model · title) and the footer that lists the keys, shrinking
to fit the window width.

## Code review — codecompanion (quickfix window)

Codecompanion's own, listed here because it is easy to reach and easy to mistake for ours.

| Key | Action |
|---|---|
| `a` | Accept the hunk under the cursor |
| `c` | Comment on the hunk under the cursor |
| `d` | Diff the hunk under the cursor against the baseline |
| `x` | Ignore the hunk's file until the baseline advances |

## Configuration

The global set is `vim.g.ducktape.keymaps`, read at startup. Per-action overrides use the action
names from the `<Plug>` column, lowercased with underscores — `chat_toggle`, `inline_deep`,
`diff_accept` and so on:

```lua
vim.g.ducktape = {
  keymaps = {
    inline = { "<leader>ai", mode = { "n", "x" }, desc = "AI: inline prompt" },
    diff_accept = { "<C-y>" },
  },
}
```

`keymaps = false`, or `keymaps = { globals = false }`, suppresses the `<leader>c*` set entirely.
The `<Plug>` maps and the buffer-local diff keys are unaffected either way, and every message that
names a key still names the right one.

A default is skipped when you have already bound that action to a key of your own, or when the key
it wants is already taken. Your mapping wins in both cases; the other 18 still appear.

### Keys inside ducktape's own windows

The four panels — the inline list, the status panel, the model picker's options step, the chat list —
and the reply float bind their keys buffer-locally, so they exist only while the window is up and
cannot collide with anything you have mapped the rest of the time. `:h lua-plugin-keymaps` calls
these uncontroversial, and they are, but `a`, `r` and `x` sit on strong muscle memory — so they are
configurable too, under `keymaps.panels`:

```lua
vim.g.ducktape = {
  keymaps = {
    panels = {
      inline_list = {
        accept = { "<C-y>", "g2" },   -- replaces the shipped { "a", "g2" }
        discard = { "<C-n>" },
      },
      status = { next_value = { "<Tab>" } },
    },
  },
}
```

Each entry is a list of keys, all of them bound to that action. Naming one action leaves every other
action in that panel on its default. Everything that *mentions* a key — the inline list's border
footer, its `?` overlay, the status panel's footer, the chat list's help — is built from these
bindings, so a remap carries into the help rather than leaving it lying.

| Panel | Actions |
|---|---|
| `inline_list` | `down` `up` `accept` `retry` `discard` `open` `help` `close` |
| `status` | `down` `up` `next_value` `prev_value` `edit` `close` |
| `picker` | `down` `up` `next_value` `prev_value` `apply` `discard` |
| `chat_list` | `help` `close` `delete` `rename` `kill` |
| `message` | `close` `confirm` |

In the inline list, the "all of them" keys are derived from the single-row ones by upper-casing them,
so remapping `accept` to `y` moves accept-everything to `Y` rather than stranding it on `A`.

The chat list runs inside whichever picker backend is in use, so its actions are bound in both insert
and normal mode. The other panels are plain floats and normal-mode only.
