# Keymaps

## Custom (global)

| Key | Mode | Action |
|---|---|---|
| `<leader>ci` | n, x | Inline prompt — no tools, no repo reads |
| `<leader>cI` | n, x | Inline prompt — may read the repo (ACP transports only) |
| `<leader>cmi` | n | Switch inline backend / model |
| `<leader>cmc` | n | Switch chat backend / model |
| `<leader>cx` | n | Cancel inline request under cursor; in chat: stop agent |
| `<leader>cX` | n | Cancel all inline requests in this buffer |
| `<leader>cj` / `<leader>ck` | n | Next / previous inline diff hunk |
| `g2` / `g3` | n | Accept / reject inline diff under cursor |
| `<leader>cc` | n | Toggle last chat |
| `<leader>ca` | n, x | Action palette |
| `<leader>cn` | n, x | New chat with current provider + options |
| `<leader>cq` | n | Close all chats |
| `<leader>cr` | n | Rename current chat |
| `<leader>cs` | n | Status panel |
| `<leader>cl` | n | Chat list (Telescope) |

## Chat buffer (local to `codecompanion` buffers)

| Key | Action |
|---|---|
| `<CR>` / `<C-s>` | Send message — carries any edits you made to the conversation above |
| `<C-c>` | Close chat buffer |
| `q` | Stop current request |
| `?` | Open chat buffer action palette |
| `ga` | Change adapter for current chat |
| `gd` | Debug window (message history, adapter config) |
| `gf` | Fold / unfold codeblocks |
| `gc` | Insert codeblock |
| `gr` | Regenerate last response |
| `gs` | Toggle system prompt |
| `gx` | Clear chat buffer |
| `gy` | Yank last codeblock |
| `gR` | Go to file under cursor |
| `gM` | Clear all rules |
| `gm` | Between-turn message (send while streaming) |
| `gba` | Sync full buffer content on every turn |
| `gbd` | Sync buffer diff on every turn |
| `gtx` | Reset tool approvals for this chat |
| `gty` | Toggle YOLO mode |
| `gS` | Show Copilot usage stats |
| `{` / `}` | Previous / next chat |
| `[[` / `]]` | Previous / next message header |

## Code review (quickfix window)

| Key | Action |
|---|---|
| `a` | Accept hunk under cursor |
| `c` | Comment on hunk under cursor |
| `d` | Diff hunk under cursor |
| `x` | Ignore hunk's file until baseline advances |
| `]q` / `[q` | Next / previous quickfix entry |

## Chat list (Telescope)

| Key | Action |
|---|---|
| `<CR>` | Focus live chat or restore selected session |
| `<C-d>` | Close selected live chat |
| `r` | n | Rename selected live chat |
