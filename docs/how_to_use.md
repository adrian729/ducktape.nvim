# How to use the AI integration

## Inline editing

Inline editing modifies code directly in your buffer. You pick *what* to change and *where*; the model supplies the replacement code. No tools, no autonomous multi-step work, no side effects. The model never decides where its output lands.

**Making an edit:**
1. Optionally, make a visual selection of the code you want to change
2. Press `<leader>ci` (no tools, no repo reads) or `<leader>cI` (may read the repo to learn conventions; works on claude and opencode only)
3. Type your instruction in the floating prompt and press `<CR>`

`<leader>cI` only works with ACP providers (claude, opencode). On ollama it shows a message telling you to switch providers — ollama has no tool access outside of HTTP, so it cannot read the repo.

With a visual selection, the reply replaces exactly that range. With no selection, the line your cursor is on is used as if you had selected it — so the reply replaces that line. Up to 40 lines above and below are included in the prompt as context. LSP diagnostics in the range are included automatically. The floating prompt and the progress spinner both show the provider and model.

You can have several inline requests in flight in the same buffer at once. Each one marks its own lines and gets an independent diff when it lands.

**Seeing which lines a request is working on:**

While a request runs, the lines it was given get a cool mauve tint, and a spinner line sits directly above them showing the provider, model, your instruction, and how many lines are in play:

```
    ⠋ ollama · gpt-oss:120b · return 2 instead · 3 lines
    local function f()
      return 1
    end
```

The mark follows the code: edit above it and the whole thing moves down with it. With no visual selection the range is the one line you were on, marked and protected exactly like any other.

You can freely add, delete or edit code **above** an in-flight request. The range is tracked by position in the text, not by line number, so it moves with your edits and the reply still lands on the lines you picked — verified for insertions above, deletions above, and insertion points. The one thing your later edits cannot reach is the prompt: it was built and sent when you submitted, so the model is working from the surroundings as they were then. If you change something above that alters what the edit should be, cancel and ask again.

**One request per region:**

Lines already busy cannot be given a second edit. Starting a request that overlaps one already in flight, or a diff you have not accepted or rejected yet, is refused and tells you which lines are taken, what is on them, and which key clears it — `<leader>cx` to cancel a running request, `g2`/`g3` to settle a diff. Adjacent ranges are fine, and so are the same line numbers in a different buffer.

The reason is that both requests build their prompt from the same lines, so whichever answer arrived second would be rewriting code the other one had already replaced.

**Lines in flight are protected:**

While a request is running you cannot change the lines it was given. Typing on them, deleting them or pasting over them is reverted immediately, and pressing `i`, `a`, `cw` or anything else that would start typing there drops you straight back into normal mode. Anything that does slip through is caught by the same revert.

`u`, `U`, `<C-r>`, `g-` and `g+` are held off entirely for as long as any lines in the buffer are held — not just on those lines. Undo walks back through changes made before the request existed, and one step of that can take the whole run of lines with it, which used to cancel the request outright. `<leader>cx` is the way out if the undo matters more than the answer. (`:undo` and `:earlier` are not keys and are not covered — they still cancel, and say so.) `u` undoes your edit and the revert together, as one step.

Every one of those says why on the command line — `put those lines back — <leader>cx cancels the inline request holding them` when an edit was undone, `those lines are held by an inline request — <leader>cx cancels it` when insert mode was refused. Repeated attempts keep saying it, so a second try is never answered with silence; only `:messages` is spared the duplicates.

This is not tidiness — the model was given those exact lines and its answer is applied back over them, so an edit of yours underneath would be thrown away silently the moment you accepted the diff. Cancel the request with `<leader>cx` if you would rather make the change yourself.

The rest of the buffer is completely free to edit, including the lines immediately above and below the range.

One case behaves differently on purpose: a single change that spans the range *and* lines outside it — deleting a whole function that contains it, say — is left alone, and the request is cancelled instead. Only the range's own former text is known, so putting that back would mean guessing at the rest of your change.

**Reviewing and applying edits:**

When a reply arrives it is rendered as a diff — the original code shown as deletions, the new code as additions. Until you act on it, the buffer is **not** permanently changed.

A reply landing never moves your cursor or scrolls your window, even when the diff is rendered in the buffer you are working in. Requests take seconds and land whenever they land, so keep typing — the tinted range and the inline list are how you find the edit when you are ready for it.

- `g2` — accept the diff under your cursor (makes the change permanent)
- `g3` — reject the diff under your cursor (restores the original)
- `<leader>cA` — accept **every** diff in this buffer
- `<leader>cR` — ask again about the edit under the cursor
- `<leader>cj` / `<leader>ck` — move to the next/previous hunk in the diff under your cursor

When your cursor is outside any diff but only one diff is pending, `g2`/`g3` act on that one.

`<leader>cL` opens the list whether or not anything is in it — an empty list says `nothing in flight, nothing waiting on you` and is titled `all settled`, rather than answering with a message you might not be looking at.

`<leader>cA` only touches diffs — anything still running is left running, and the message tells you how many were settled. For every buffer at once, `A` in the inline list does the same thing.

There is no reject key. `x` does it: on a diff it rejects, on a reply it dismisses, on a request still running it cancels — one key for "get rid of this", whatever state it is in. `r` is free for the thing that had no key, asking again.

If you edited the lines of a diff yourself before rejecting it, your version is kept and you get a message saying so, rather than having your work quietly replaced by the original.

If you close the buffer or the last window showing it while a diff is pending, the diff is rejected automatically — your buffer is not left in a half-applied state.

**When a reply cannot be applied:**

Not every reply becomes a diff. The model may explain rather than edit, decline outright, or leak a failed tool attempt; the request itself may fail (dead model, nothing on `PATH`, timeout); or it may answer while its buffer is on screen nowhere, leaving no window to render a diff in.

None of these open anything over what you are doing. The reply is **kept** and waits for you, exactly like a pending diff:

- the range stays marked, its label reading `answered` or `failed`, with `◆` or `✖` in the signcolumn — so it is visible from anywhere in that file, even scrolled past the label. The tint turns warm as it does, so a range with a reply waiting on it reads differently at a glance from one still being worked on
- a count appears in the statusline, which is how you know when the file is not on screen at all
- a row appears in the inline list

Nothing is lost by looking away. The old behaviour — a float that grabbed your cursor the moment a reply landed — was also the *only* copy: dismissing it destroyed the text and the chat hand-off with it.

From the list, on one of those rows:

| Key | Does |
|---|---|
| `<CR>` | read the reply (this is the one float that takes focus, because you asked for it) |
| `a` | open a chat pre-loaded with the exchange — your instruction, the selection, the reply |
| `r` | **ask again**, with your original instruction pre-filled so you can reword it first |
| `x` | dismiss it |

`r` is the one worth knowing, and it works on **any** row, not just these: on a diff that came back wrong it rejects it first, on a request still running it cancels it, then asks again either way. A wrong answer, a refusal and a failure are all reasons to switch model, so re-asking goes out with whatever provider and model are selected *now*. Switch with `<leader>cmi` first, then `r`.

`A` and `<leader>cA` leave these rows alone and tell you how many they left — accepting is about *edits*, and a reply is not one. `X` and `<leader>cX` do take them: that is the "done with all of it" key, and the message names how many unread replies went with it. `<leader>cx` with the cursor on one dismisses just that one.

Asking again over the same lines — `<leader>ci` there, or `r`/`<leader>cR` — replaces the waiting reply, since you have superseded it.

**Discarding an edit:**

Press `<leader>cx`. If the edit under your cursor is still running it is cancelled; if it has already answered, it is rejected. One key for "make this go away", whichever half of its life the edit is in — which state it is in is exactly the thing that changes on its own while you are not looking. In a chat buffer it stops the running agent instead.

Press `<leader>cX` to clear the whole buffer out: everything still running is cancelled, every diff is rejected, and every unread reply is dismissed. The message says how many of each.

**The inline list — everything in play at once:**

Press `<leader>cL`. One row per inline edit that has not been settled: requests still running, and finished ones whose diff you have not accepted or rejected yet. The buffer-scoped keys (`g2`/`g3`, `<leader>cx`/`cX`/`cA`/`cR`) only reach the buffer you are in, but a request runs against the buffer it was *started* in — so this is the view that shows the ones you have since moved away from, and the only place that settles them all at once.

```
┌ Inline — 2 thinking · 1 to review · 1 to read ──────────────────────────────────────────┐
│▶ ◆ review        0s  ollama · gpt-oss:120b  lua/ai/inline/parse.lua:1  make this a s…  │
│  ⠋ thinking     12s  ollama · gpt-oss:120b  lua/ai/pick.lua:2          add a b key s…  │
│  ◆ answered     31s  ollama · gpt-oss:120b  lua/ai/status.lua:88       why is this s…  │
│  ⠋ thinking      4s  claude · sonnet        lua/ai/chat.lua:2          explain the r…  │
└──────────────── a accept · r again · x discard · ? keys ────────────────────────────────┘
```

- `⠋ thinking` — still running, with how long for, and on ACP providers the tool it is using right now
- `◆ review` — finished; the diff is sitting in the buffer waiting on you, with its hunk count
- `◆ finished` — it landed while you were looking at the list. Says so for three seconds, then settles to `review`
- `◆ answered` — replied with something that is not an edit. `<CR>` reads it, `r` asks again
- `✖ failed` — the request died. `r` asks again

The border carries the three keys you reach for and points at `?` for the rest, which opens the same kind of overlay the chat list has — every key, plus what each marker means. It is not on the border because a border is clipped to the window without warning, and because spelling out all six keys made the window 96 columns wide before its own rows had any say.

The list redraws itself while it is open, so a request finishing changes state in front of you rather than needing a reopen. The row keeps its place when that happens: entries are ordered by the request each came from rather than by state, so nothing moves under your cursor.

| Key | Does |
|---|---|
| `j` / `k` | move (wraps around) |
| `<CR>` | close the list and jump to the edit, cursor on its first line |
| `a` or `g2` | accept the diff on this row — or, on an `answered` row, open it in a chat |
| `r` | ask again: get rid of what is on this row and re-send, instruction pre-filled |
| `x` or `g3` | discard this row: cancel it if running, reject or dismiss it if not |
| `A` | accept **every** diff in the list, across every buffer |
| `X` | empty the list: cancel everything running, reject every diff, dismiss every unread reply |
| `?` | the full set of keys and what the markers mean, over the list rather than on its border |
| `q` / `<Esc>` | close |

Uppercase is "all of them" throughout. `A`/`R` leave anything still running alone and report what they settled — naming the files, since they reach buffers that are not on screen. `X` is the one that empties the list outright.

`a`/`r` on a row that is still running tells you it is not ready yet rather than doing nothing. Accepting and rejecting work whether or not the target buffer is on screen.

`range gone` where the location should be means the lines the edit was anchored to have since been deleted. You will rarely see it on a running request now that deleting its lines puts them back; on a pending diff it means the answer has nowhere left to go, so reject it.

A reply that arrives while its buffer is on screen *nowhere* still cannot be applied — the diff UI would take over whichever window you had moved to — but it is no longer thrown away. It becomes a `failed` row with the range still anchored, so bringing the buffer back into view and pressing `e` asks the same thing again. Requests to a buffer that is merely not focused are fine.

**The statusline:**

A segment appears in your statusline whenever inline has anything in play, and is empty otherwise:

```
lua/ai/retry.lua        AI 2↻ 1◆        12,4        45%
```

`↻` still running · `◆` answered, or an edit waiting on you · `✖` failed. This is the only signal that reaches you when the file in question is not on screen at all — the marks are in the buffer and the list is behind a key, and a message scrolls away.

It is injected into whatever nvim already puts in your statusline rather than replacing it, so the built-in parts — diagnostics count, the busy indicator, the ruler — are untouched.

On a narrow terminal, columns are dropped rather than clipped, in order of how little is lost: the tool name or hunk count first, then the model, then the clock, then the word for the state. The marker, the location and the prompt are the last things standing.

**Switching provider or model:**

Press `<leader>cmi`. One flat Telescope list of every provider/model pair, so finding what you want is one search — type `opus` or `qwen` rather than working through a provider step first. The current selection is marked `▶` and sits nearest the prompt.

- **ollama** — contributes one row per endpoint, listed as `ollama cloud` and `ollama local`, because the endpoint decides which models you get. Both lists are fetched from the ollama API and cached for the session
- **claude** — runs over ACP. The session runs in `dontAsk` mode, which denies mutating tools
- **opencode** — every model this machine can reach, asked of `opencode models` itself: the free tier (`opencode/…`) and the Go subscription (`opencode-go/…`). Free models are listed first, so the cheap option is the one under the cursor. For `ci` opencode runs through the `opencode-llm` relay (no tools at all); for `cI` over ACP with repo-read permission but mutation denied
  - `auto` is a sentinel rather than a model: it lets `opencode-llm` walk its own free fallback list, so a dead model degrades instead of failing. When a live session needs a real model pinned, `auto` always resolves to a **free** one — never to a Go model you did not pick
  - `ollama-cloud/…` models are reachable through opencode too, but they are left out here because the `ollama` provider already offers them; listing them under two providers would only raise the question of which to use

**Every row says what it draws on.** The labels are not decoration — nothing in these model names tells you whether picking one consumes a usage budget or nothing at all:

| Label | Means | Where that comes from |
|---|---|---|
| `free` | Free tier, consumes nothing | opencode's `opencode/…` prefix, per `MODELS.md` |
| `free · local` | Runs on this machine — no account, no quota | ollama with `endpoint = local` |
| `free · cloud` | Free tier, but rate-limited: light GPU-time, 1 concurrent model | `MODELS.md`, "Ollama Cloud (Free)" |
| `subscription · claude` | Counts against your Claude plan | claude-agent-acp authenticates with `CLAUDE_CODE_OAUTH_TOKEN`; there is no `ANTHROPIC_API_KEY` in this config |
| `subscription · Go` | Counts against your OpenCode Go plan | `MODELS.md`, "Limits" — $12/5h, $30/wk, $60/mo rolling windows, and "Free models don't count" |

Both subscriptions are labelled the same way deliberately. Go's allowance happens to be denominated in dollars where Claude's is not, but that is the unit the window is measured in rather than who is paying — both are plans you have already paid for, with rolling usage windows, and neither bills per token. (Go can overflow into Zen credits once its windows are spent, but that is opt-in from opencode's console, not what a request costs by default.)

Anything drawing on a plan is highlighted rather than dimmed, so it registers without being read for. The labels are searchable too: type `free` for everything that consumes nothing, `subscription` for everything that does, or `Go` / `claude` for one plan in particular.

The one place this lives is `providers.model_tier` in `providers.lua`, which carries the source for each claim in a comment — a "free" label is worth being able to check rather than trust.

The list opens immediately rather than waiting on any of that: ollama's models come off the network and opencode's out of a subprocess, so blocking until they all arrive would slow down every switch — including switches to claude, which needs neither. Rows appear as each source answers, and both are cached for the session, so only the first switch pays. A source that cannot be reached is left out with one warning naming the reason, and everything else still works.

`<CR>` on a row continues into that provider's other options — effort, mode and fast for claude, mode for opencode, think for ollama:

```
┌ claude · opus ────────────────────────────────────────┐
│  Effort  ◂ xhigh ▸                                    │
│  Fast      off                   opus only            │
│  Mode      default               asks before editing  │
└ h/l cycle · j/k move · <CR> apply · q discard ────────┘
```

`h`/`l` cycles the value under the cursor and wraps around; `j`/`k` moves between rows.

**The whole run is one decision, applied only by `<CR>`.** Nothing — not the model, not the options — reaches the configuration until then, so leaving with `q`, `<Esc>` or by clicking away keeps the provider, model and options exactly as they were, and says so. That is what makes it safe to scroll through `mode` values to read what each one does: nothing you pass through on the way is kept.

A provider with nothing left to choose (inline + opencode) commits on the list's own `<CR>`, since there was nothing to confirm.

An option with no stored value shows as `unset` rather than being filled in with its first value, and stays unset unless you cycle it. Claude's `fast` is the case that matters: it is deliberately unset *and* its first value is `on`, so defaulting it would quietly enable it on every switch. It is also model-dependent — opus offers it, sonnet does not — which the row says as `opus only` rather than pretending to filter. Once cycled there is no way back to unset, same as the status panel.

Claude's `agent` is not offered here at all, because the list of agents only exists on a running agent; `<leader>cs` is where that lives, since it can read the live connection.

`<leader>cmc` is the same list for chat. One difference worth knowing: an inline switch takes effect on the next request (the connection pool is drained so nothing reuses the old model), while a chat switch sets the default for **new** chats — a conversation already open keeps the model it was created with. `<leader>cs` is what reaches into a chat already in progress.

Defaults: ollama cloud with `gpt-oss:120b` — measured ~4s on a typical refactor, no local RAM cost, free.

**When the model declines:**

If the model returns an explanation or says it cannot do the edit, nothing opens over your work. The reply is kept and waits for you — see **When a reply cannot be applied** above.

---

## Chat

Chat is a full conversation buffer where you can talk to a model, invoke tools, run slash commands, and share editor context. It works with all three providers.

**Starting and managing chats:**

- `<leader>cn` — start a new chat with the current provider and its preset options. The buffer title shows `provider · model` until the chat auto-titles from your first message
- `<leader>cc` — toggle the last chat buffer (creates a new one if none exists)
- `<leader>cq` — close all chat buffers
- `<leader>cr` — rename the current chat
- `<leader>cd` — delete the current chat *and* the agent's saved transcript of it (asks `y`/`n` first, defaulting to no; cannot be undone)
- `<leader>cl` — open the chat list (Telescope picker, see below)

**Switching chat provider or model:**

Press `<leader>cmc` — the same flat list described under [Switching provider or model](#switching-provider-or-model), for the chat scope. It sets the default for new chats; `<leader>cs` changes a chat already open. Defaults: claude with opus + xhigh effort + `default` mode, which is the mode that asks before editing.

**The chat's own key line:**

Every chat window carries a footer along its bottom edge with the keys you need most:

```
 <CR> send · q stop · ga model · ? keys   │   <leader>cr rename · <leader>cd delete
```

`?` is the important one — it opens CodeCompanion's full list of chat keymaps, so the footer only has to get you there. The line shortens as the window narrows (dropping the rename/delete pair first, then `ga`, then `q`) rather than being clipped mid-word, so a narrow split shows less but always shows `?`.

**Chat list:**

`<leader>cl` opens a Telescope picker showing three sections:
- **Live chats** — every open chat buffer, suffixed with its `provider · model`. `<CR>` focuses it
- **From last session** — chats that were open when nvim last quit and haven't been reopened yet, marked `(from last session)`. `<CR>` starts one and replays its history. Nothing is running behind these
- **Resumable sessions** — every other past ACP session (including ones started in a terminal outside nvim), filtered to the current git repo. `<CR>` opens it in a new chat buffer with full history

Press `?` (or `<C-/>` without leaving insert mode) for an overlay listing every key and marker. The picker's border only advertises `?`, because Telescope clips a border title to the window width without saying so — a legend there would be as complete as your terminal is wide and no more.

`<Esc>`, `q` and `?` all dismiss the overlay and leave the list up; with no overlay open, `<Esc>` and `q` close the list as usual, and `<C-c>` closes it either way.

Each line leads with two markers:

| Marker | Means |
|---|---|
| `▶` | The chat `<leader>cc` reaches. Always listed first |
| `●` | Agent up and ready to take a message |
| `◌` | Agent still starting. Sending now would fail |
| `✕` | Agent process is gone. The buffer survived a crash; reopen the session to get a working one |
| `○` | Not started — no agent behind it at all until you open it |

Anything not `●` also carries a short reason in dim text, since a coloured glyph alone doesn't say what's wrong. Ready-but-hidden chats are annotated `(hidden)` — they hold a running agent even though no window shows them.

Every section takes the same three edits, also listed under `?`:

| Key | Does |
|---|---|
| `<C-r>` (or `r` in normal mode) | Rename. Live chat, pending chat, or stored session alike |
| `<C-d>` | Stop it coming back, without deleting anything. On a live chat that closes the buffer and frees its agent; on a pending one it drops out of the reopen set and becomes an ordinary stored session |
| `<C-x>` | Delete for good — the chat *and* the agent's copy of the conversation. Asks first |

Renaming is local: agents name a session from their own summary of it and ACP has no way to override that, so chosen names are kept in `~/.local/state/nvim/ai/chat_titles.json`, keyed by session ID. That is also what makes a rename stick — the agent pushes a fresh auto-title at the end of every turn, and a name you chose is re-applied over it.

Sessions are cached; the list updates on each open.

**Chats survive restarts:**

Open ACP chats are remembered per directory. On quit, their session IDs are written to `~/.local/state/nvim/ai/chat_sessions.json`; the next time you start nvim in the same directory they wait in `<leader>cl` under **from last session**, and open on demand.

Nothing is started for you. A restore spawns an agent subprocess and makes a blocking `session/load` round trip, so starting them eagerly meant paying for chats you might never look at — an nvim start now costs zero agent processes no matter how many chats were open when it quit. `<leader>cc` reopens the most recent one when no chat is live, so continuing where you left off is still one keypress; `<leader>cn` is what asks for a fresh chat instead.

The agent keeps its own memory across the restart — this resumes the real ACP session (`session/load`), it does not just repaint the text. A follow-up question can refer back to anything from before the restart.

Notes:
- Reopening takes a few seconds while the agent starts and replays the transcript. Only the chat you picked pays that cost.
- Pending chats are read straight from the JSON, so they show instantly and are listed even with no agent running anywhere.
- Only ACP chats (claude, opencode) persist. ollama chats are HTTP with no server-side session, so they cannot be resumed.
- Closing a chat (`<leader>cq`, or `<C-d>` in the chat list) drops it from the saved set, so it is not reopened on the next start — but its session survives and stays resumable from `<leader>cl`. `<leader>cd` / `<C-x>` is what removes the session itself.
- A name you gave a chat comes back with it, and keeps applying to the session afterwards even if you close the chat.
- There is no cap. Nothing is spawned until you pick something, so however many chats were open, all of them wait in the list.
- A pending chat you never open stays pending across as many restarts as you like — quitting does not quietly drop it.
- A chat you opened but never sent a message in comes back as an empty chat. The agent only commits a session to its own store once there has been a real exchange, so there is no history to reload — but the chat itself reopens on its original provider/model rather than disappearing.
- If a saved session has since been deleted or aged out of the agent's store, the chat still reopens, just without its transcript, and you get one `[ai] session <id> is gone — reopened without history` warning.

**The agent asks before it edits:**

Chat can change files, but not silently — it asks first, and you see a diff of the proposed change before answering. Approve once, approve for the rest of the session, or reject; rejecting leaves the file exactly as it was. Requests queue, so a turn touching several files asks about each in turn.

This is `mode = "default"` for claude and `edit/write/patch/bash = "ask"` for opencode, both set in `ai/providers.lua`. Inline is stricter and unchanged: claude inline forces `dontAsk`, which *denies* mutating tools outright (despite the name), and opencode inline denies them via `OPENCODE_PERMISSION`.

To loosen it for one session, use `<leader>cs` and change Mode — `acceptEdits` applies edits without asking, `plan` makes it read-only. Changing the default means editing `providers.lua`.

**Agent edits show up in your open buffers:**

The chat agent edits files on disk rather than through nvim, and nvim does not notice that by itself — so a file you had open used to keep showing the pre-edit text while the version underneath it had moved on. Save from that stale buffer and you overwrite the agent's work.

Buffers now follow those edits automatically. The agent reports each file it touches, and the matching buffer is reloaded, with the cursor and scroll position kept where they were. A sweep at the end of every turn catches anything edited without being reported — a shell redirect, or a script the agent ran.

The one case left to you is a genuine conflict: if the buffer has **unsaved changes** and the agent also changed the file, neither version is touched, and you get

```
[ai] foo.lua was edited by the agent but has unsaved changes here — :e! to take the agent's version, :w to keep yours
```

Picking a winner automatically would throw away one side silently, so it asks instead. This still matters even though the agent asks before editing: you approve the edit, and the reload has to land in a buffer you may meanwhile have typed into.

**Editing a message you already sent:**

Edit anything above the prompt you are typing, ask your next question, and the answer comes from the conversation as you have just rewritten it. Nothing to confirm, nothing to choose — the chat carries on being the same chat, under the same name.

That is a change: editing the transcript used to be a trap, where the text changed on screen and nothing else did. An ACP agent (claude, opencode) keeps its own copy of the conversation and is only ever sent your *new* message, so a reworded question above reached nobody; ollama is sent a message table that nothing re-reads from the buffer, with the same result.

You will see one line when it happens:

```
[ai] asking with your edited conversation
```

Editing on its own does nothing at all — no message, no work, no interruption. It is asking a question with the edit in place that makes it count, which is also when you can rewrite as much as you like while thinking.

What is kept:

- **The title.** Whatever the chat was called stays, and stays through the turns after it, so the chat does not silently rename itself out from under you
- **Provider, model, effort, mode** — everything you had set
- **The buffer**, exactly as you edited it. Nothing is rewritten on screen

Under the hood the agent gets a new session carrying the edited conversation, because there is no way to change the copy it already holds. Reviving a chat after a restart looks like the same trick but runs the other way round: `session/load` asks the agent to replay *its* memory to us, and ACP has no method for pushing ours back. Two consequences worth knowing:

- The agent's past replies reach it as quoted text rather than as its own turns, and tool calls in the transcript are prose by then — so a file it read before, it reads again. Which also means you can edit its replies and it will take them as what it said
- The pre-edit conversation stays in the agent's own session store, so it turns up in `<leader>cl` among the resumable sessions under its own auto-title. That makes it a way back if you edited something you wanted, and `<C-x>` there removes it. It is not deleted for you: a `session/delete` sent from the process that still has the session open is written straight back by that same process (measured), so making it stick would mean respawning the agent mid-chat

For ollama there is no session to replace. The edited conversation simply goes out as the message list with its roles intact, which is lossless.

Two smaller fixes come with this:

- Editing history used to corrupt the *next* message rather than merely being ignored. The line your new prompt is parsed from was fixed when the last reply landed, so deleting two lines of history above it meant your question was skipped entirely, and adding four meant your previous question was sent again with the new one glued onto it. That boundary is now re-read from the buffer on every send
- Sending with nothing typed says `[ai] nothing to send — type your question under the last header` instead of submitting an empty message, which the API rejects with a 400 in a red box

**Inside the chat buffer:**

The chat buffer has its own set of keymaps and features. Send a message with `<CR>` or `<C-s>` in normal mode (or `<C-c>` in insert mode). Stop a running request with `q`.

| Feature | How |
|---|---|
| Change adapter/model | `ga` opens the adapter selector |
| Debug window | `gd` shows full message history, adapter config, and context items. Editable — `<C-s>` persists changes back to the chat |
| Regenerate | `gr` re-sends the last prompt |
| System prompt | `gs` toggles it on/off |
| Clear chat | `gx` clears the buffer content |
| Fold codeblocks | `gf` folds/unfolds code blocks |
| Insert codeblock | `gc` |
| Yank last codeblock | `gy` |
| Go to file under cursor | `gR` |
| Clear all rules | `gM` |
| Between-turn message | `gm` sends a message while the LLM is still streaming |
| Sync full buffer every turn | `gba` |
| Sync buffer diff every turn | `gbd` |
| Navigate chats | `{` / `}` for previous/next chat |
| Navigate headers | `[[` / `]]` for previous/next message header |
| Show keymaps | `?` opens the chat buffer's action palette |
| Reset tool approvals | `gtx` resets all `always allow` decisions for this chat |
| YOLO mode | `gty` auto-approves tool calls (dangerous — excludes delete/run_command by default) |
| Copilot usage stats | `gS` shows usage statistics |

Some adapters expose a `show_settings` yaml block at the top of the chat buffer where you can tweak model parameters between responses. Enabled by `display.chat.show_settings = true`.

Chat buffers also support automatic title generation (needs background interactions enabled in config).

**Sending context to the LLM:**

All chat features below work by typing the trigger character followed by the name. Completion is available via nvim-cmp or blink.cmp (or native `<C-_>`). Context items appear in a `Context` blockquote in the chat buffer.

**Editor Context** — type `#` in the chat buffer:

| Context | What it shares |
|---|---|
| `#{buffer}` | Current buffer (diff by default; `{all}` for full content) |
| `#{buffers}` | All open buffers |
| `#{code_review}` | Pending code review comments |
| `#{diagnostics}` | LSP diagnostics for current buffer |
| `#{diff}` | Current git diff (staged + unstaged) |
| `#{messages}` | Neovim's `:messages` history |
| `#{quickfix}` | Quickfix list contents |
| `#{selection}` | Last visual selection |
| `#{terminal}` | Last terminal buffer output |
| `#{viewport}` | What you see on screen |

Buffer context can be synced so the LLM receives updates on each turn. Use `#{buffer}{all}` to send the full buffer every turn, or `#{buffer}{diff}` (the default) to send only changes.

**Slash Commands** — type `/` in the chat buffer:

| Command | What it does |
|---|---|
| `/acp_session_options` | Change ACP session config options (adapter models, modes, etc.) |
| `/buffer` | Add contents of one or more open buffers |
| `/command` | Switch ACP adapter command (ACP adapters only) |
| `/compact` | Summarize chat history and clear old messages, preserving system prompt and rules |
| `/fetch` | Fetch and add content from a URL |
| `/file` | Add contents of one or more files (including PDFs for supported adapters) |
| `/fork` | Duplicate the chat buffer with full history (HTTP adapters only) |
| `/help` | Add vim help content |
| `/image` | Add an image from a file or URL (vision-capable models only) |
| `/mcp` | Start or stop MCP servers |
| `/mode` | Switch ACP agent operating mode (ACP adapters only) |
| `/now` | Insert current datetime stamp |
| `/resume` | Resume a previous ACP session into this chat (fresh buffer only) |
| `/rules` | Add rules groups to the chat |
| `/share` | Share the conversation as a secret GitHub Gist |
| `/symbols` | Add a Tree-sitter symbol outline of a file |

**Tools and Agents** — type `@` in the chat buffer:

Tool groups combine multiple tools. `@{agent}` enables autonomous coding (creates files, runs commands, searches code). `@{files}` enables file operations only. Individual tools can also be invoked:

| Tool | What it does |
|---|---|
| `@{agent}` | Autonomous coding agent: reads, writes, searches, runs commands |
| `@{files}` | File operations: create, delete, read, insert-edit, search |
| `@{ask_questions}` | Ask clarifying questions before acting |
| `@{create_file}` | Create a file in the working directory |
| `@{delete_file}` | Delete a file in the working directory |
| `@{fetch_webpage}` | Fetch and parse webpage content |
| `@{file_search}` | Search for files by glob pattern |
| `@{get_changed_files}` | Get git diff of changed files |
| `@{get_diagnostics}` | Retrieve LSP diagnostics for a file |
| `@{grep_search}` | Search file contents with ripgrep |
| `@{insert_edit_into_file}` | Apply code edits to files or buffers |
| `@{memory}` | Store and retrieve information across chats |
| `@{read_file}` | Read contents of a file |
| `@{run_command}` | Execute a shell command |
| `@{web_search}` | Search the web via Tavily |

Tools that modify the filesystem (`create_file`, `delete_file`, `run_command`, `insert_edit_into_file`) require approval by default. `run_command` and `delete_file` are excluded from YOLO mode. Approvals are per-chat-buffer and per-tool — approving in one chat does not affect another.

MCP servers expose additional tools prefixed `@{mcp:*}`.

**Rules:**

Rules files (like `CLAUDE.md`, `AGENTS.md`, `.cursorrules`) are automatically loaded into new chat buffers. Use the `/rules` slash command to add more rule groups. `gM` clears all rules from the chat buffer. Rules can contain system prompts, file references, and arbitrary instruction text.

---

## Messages and prompts

Nothing the integration tells you costs a keypress. Messages are fitted to the room the command line has, so none of them can trigger "Press ENTER or type command to continue" — the one that used to come up after deleting a chat, for instance.

A message too long to fit ends in `…`. The full text is still in `:messages`, which is also where to look if one scrolled past before you read it.

Questions are answered `y` or `n`, with Enter taking the default. The default is *no* wherever the answer cannot be undone — deleting a chat, deleting a stored session — so Enter and Esc both leave things as they were. Anything asking for a name or a value asks in the usual way instead, on the command line, with Esc to back out.

---

## Status panel

`<leader>cs` opens a floating panel showing every provider option for both inline and chat scopes. It is the fastest way to inspect and change your configuration.

The panel is interactive:
- `j`/`k` or arrow keys — navigate rows
- `<CR>` — enter edit mode on the current row
- `h`/`l` — cycle through values while editing
- `<CR>` again — commit the change (or `<Esc>`/`q` to cancel)
- `q` or `<Esc>` — close the panel

Provider rows show the current provider and, for inline, a transport reach marker: `(tool-free)` or `(can-read-repo)`.

Cycling opencode's Model row reaches both the free tier and the Go subscription, the same set `<leader>cmi`/`<leader>cmc` list — the panel asks `opencode models` when it opens, so it does not matter which surface you got there from.

Changes apply immediately:
- **Inline scope** — updates stored defaults and drains the connection pool so the next request uses the new provider/model
- **Chat scope** — updates stored defaults AND applies the change to the focused chat's live session

The panel rebuilds its rows when refocused, so if something changed outside the panel (e.g. you switched the focused chat to a different provider), the next time you look at it, it shows the current state. While a row is being edited, this refresh is skipped so your edit is not disrupted.

---

## Action palette

`<leader>ca` or `:CodeCompanionActions` opens CodeCompanion's action palette. This gives quick access to:

- **Chat** — open a new chat buffer
- **Open Chats** — jump to any open chat buffer
- **Built-in prompts**: Generate commit message, Explain code, Explain LSP diagnostics, Fix code, Generate unit tests
- **Chat with rules** — start a chat with specific rule groups loaded
- **Workflows** — run agentic workflows

These prompts can also be called from the command-line with their alias: `:CodeCompanion /explain`, `:CodeCompanion /fix`, `:CodeCompanion /commit`, `:CodeCompanion /lsp`, `:CodeCompanion /tests`.

---

## Code review

Code review lets you leave comments on agent-produced code and send them back as a batch, with full file/line/code context. It works with ACP agents, built-in tools, and even CLI agents running outside Neovim.

**Workflow:**
1. `:CodeCompanionCodeReview Start` — marks the baseline (what you'll review against)
2. Let the agent work
3. `:CodeCompanionCodeReview` — opens agent changes in the quickfix list
4. Navigate with `]q`/`[q`. Press `d` to diff a hunk, `c` to comment, `a` to accept, `x` to ignore the file
5. `:CodeCompanionCodeReview Comment` — leave a comment on the current line or visual selection
6. In a chat buffer, type `#{code_review}` and send — all pending comments are sent to the LLM with full context
7. `:CodeCompanionCodeReview Approve` — advance the baseline; the next review only shows new changes

For agents outside CodeCompanion, use `:CodeCompanionCodeReview Share` to export the review to a file and paste its path into the agent.

---

## CLI interaction

`:CodeCompanionCLI` opens a terminal buffer running a CLI agent (e.g. Claude Code). You can send prompts, add context, and interact with the agent from within Neovim.

- `:CodeCompanionCLI <prompt>` — send a prompt to the last CLI instance (or create one)
- `:CodeCompanionCLI! <prompt>` — send and auto-submit (agent starts immediately)
- `:CodeCompanionCLI agent=<name> <prompt>` — use a specific agent
- `:CodeCompanionCLI Ask` — open a rich prompt input buffer with completion support

The prompt input buffer supports `#{editor_context}` references, the `/buffer` and `/file` slash commands (which insert `@path` references instead of file contents), and scrollable history with `<Up>`/`<Down>`. Write with `:w` to send, `:w!` to send and submit.

The special `#{this}` context resolves to the current buffer in normal mode, or the visual selection + file reference in visual mode.

---

## Debug commands

Two developer commands for inspecting the connection pool:

- `:AiPoolStatus` — shows a table of live ACP connections: provider, connection id, primary vs overflow, state, age, idle time, busy/idle status, and session id. Also shows queued request depth per provider. Nothing should be spawned at startup — an empty panel confirms lazy loading
- `:AiDebugSend {provider} {prompt}` — sends a raw prompt through the pool and opens the full reply in a scratch buffer. No parsing, no placement, no buffer mutation. Useful for isolating transport problems from parsing/placement bugs. Works with ACP providers only (claude, opencode)

---

## Built-in commands

These CodeCompanion commands remain available alongside the custom features above:

- `:CodeCompanionChat` — open a chat buffer (uses claude by default)
- `:CodeCompanionChat Toggle` — toggle the last chat
- `:CodeCompanionChat <prompt>` — open a chat and send a prompt
- `:CodeCompanionChat adapter=<name>` — open with a specific adapter
- `:CodeCompanionChat Add` — add visual selection to the current chat
- `:CodeCompanionChat Changes` — open quickfix of files changed by the LLM
- `:CodeCompanionChat RefreshCache` — refresh conditional elements in the chat
- `:CodeCompanion` — built-in inline (uses ollama cloud by default, superseded by `<leader>ci`)
- `:CodeCompanionCmd` — generate a Neovim command (uses ollama cloud by default)
- `:CodeCompanionActions Refresh` — refresh the action palette and prompt library
- `:checkhealth codecompanion` — check dependencies and log file location
