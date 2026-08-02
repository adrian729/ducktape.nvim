-- Inline editing: prompt, placement, anchoring, diff, accept/reject, concurrency, cancellation.
--
-- The contract is that nvim decides placement and the model only supplies code. A visual
-- selection is replaced exactly; with no selection the reply is inserted at the cursor. The
-- model never says where its output goes, so it cannot route an edit into a chat, a new buffer,
-- or anywhere outside the range the user picked.

local api = vim.api

local input = require("codecompanion.interactions.shared.input")
local parse = require("ducktape.inline.parse")
local providers = require("ducktape.providers")
local ui = require("ducktape.ui")

local M = {}

-- Anchors and reject-time region marks. Separate from ducktape.ui's namespace so clearing progress
-- text can never disturb an anchor.
local ANCHOR = api.nvim_create_namespace("ducktape_inline_anchor")
local CONTEXT_LINES = 40
local seq = 0

---@type table<number, { requests: table<number, table>, diffs: table<number, table>, waiting: table<number, table>, augroup?: number, attached?: boolean, restoring?: boolean, pending?: boolean }>
local buffers = {}

local function buf_state(bufnr)
	buffers[bufnr] = buffers[bufnr] or { requests = {}, diffs = {}, waiting = {} }
	return buffers[bufnr]
end

local function count(tbl)
	local n = 0
	for _ in pairs(tbl) do
		n = n + 1
	end
	return n
end

--=============================================================================
-- Range capture and anchoring
--=============================================================================

---@return { s0: number, e0: number, has_selection: boolean }
local function capture_range()
	local mode = vim.fn.mode()
	if mode == "v" or mode == "V" or mode == "\22" then
		-- Leave visual first so the '< and '> marks are set
		vim.cmd("normal! \27")
		return { s0 = vim.fn.line("'<") - 1, e0 = vim.fn.line("'>"), has_selection = true }
	end

	-- No visual selection: the cursor's own line, treated exactly as if it had been selected.
	--
	-- An empty range — insert here, replace nothing — looks like the more conservative default and
	-- is not. Asking for an edit while sitting on a line is asking about *that line*, and answering
	-- with an insertion above it leaves the original still there, next to a modified copy of
	-- itself, for the user to clean up by hand. M.submit still accepts an empty range for callers
	-- that genuinely mean to insert.
	local row = api.nvim_win_get_cursor(0)[1] - 1
	return { s0 = row, e0 = row + 1, has_selection = true }
end

---A row that nvim_buf_set_extmark will accept, the column to use on it, and whether the row had
---to be moved to get there.
---
---An exclusive end row equal to the line count has no line to sit on, so it becomes the end of
---the last line instead. `resolve` needs to tell that apart from a mark that genuinely sits at
---the start of the last line, or a selection running to the end of the buffer silently loses its
---final line and the reply's own last line is appended as a duplicate.
---
---The third return value is what carries that, rather than the column: reading the column back
---cannot distinguish the two cases when the last line is **empty**, because then the end of the
---line and the start of it are the same position. A buffer ending in a blank line is ordinary,
---and so is a buffer that is nothing but one.
---@param bufnr number
---@param row number
---@return number row, number col, boolean clamped
local function clamp(bufnr, row)
	local total = api.nvim_buf_line_count(bufnr)
	if row < total then
		return row, 0, false
	end
	local last = math.max(0, total - 1)
	return last, #(api.nvim_buf_get_lines(bufnr, last, last + 1, false)[1] or ""), true
end

---Anchor a range with extmarks so edits elsewhere — including another inline accept — shift it
---correctly. The built-in snapshots whole-buffer line numbers instead, which is exactly why two
---of its requests corrupt each other.
---
---The gravities point inwards, both of them, which is what keeps the pair spanning the lines the
---user picked and nothing else. They are the opposite of the diff marks in show_diff, and for the
---opposite reason: those have to grow to cover the text the diff inserts into them, whereas these
---have to refuse to.
---
---Measured, because the outward-facing pair looks harmless and is not: a mark at (1,0) with left
---gravity moves to (0,0) when the line above it is replaced, and one at (4,0) with right gravity
---moves to (5,0) when the line below it is. Either way the range quietly grows over a line the
---user edited while the request was in flight, and the reply then overwrites that edit.
---@param bufnr number
---@param range table
---@return table anchor
local function anchor(bufnr, range)
	local srow, scol = clamp(bufnr, range.s0)
	local erow, ecol, ends_at_eof = clamp(bufnr, range.e0)

	local marks = {
		ends_at_eof = ends_at_eof,
		start = api.nvim_buf_set_extmark(bufnr, ANCHOR, srow, scol, { right_gravity = true }),
		finish = api.nvim_buf_set_extmark(bufnr, ANCHOR, erow, ecol, { right_gravity = false }),
	}

	-- A separate mark whose only job is to disappear if the whole range is deleted. Collapsing
	-- start onto finish is not a reliable test on its own: a user who deletes the range and
	-- types a replacement leaves the pair spanning unrelated text.
	if range.e0 > range.s0 then
		marks.guard = api.nvim_buf_set_extmark(bufnr, ANCHOR, srow, scol, {
			end_row = erow,
			end_col = ecol,
			invalidate = true,
			undo_restore = false,
		})
	end

	return marks
end

---@param bufnr number
---@param marks table
---@return number|nil s0, number|nil e0
local function resolve(bufnr, marks)
	if not api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	if marks.guard then
		local g = api.nvim_buf_get_extmark_by_id(bufnr, ANCHOR, marks.guard, {})
		if not g or #g == 0 then
			return nil
		end
	end
	local s = api.nvim_buf_get_extmark_by_id(bufnr, ANCHOR, marks.start, {})
	local e = api.nvim_buf_get_extmark_by_id(bufnr, ANCHOR, marks.finish, {})
	if not s or #s == 0 or not e or #e == 0 then
		return nil
	end
	-- The mark could not be placed on its own row, so it sits on the last line and that line is
	-- part of the region: line-wise, the exclusive end is the row after it.
	local e0 = marks.ends_at_eof and (e[1] + 1) or e[1]
	return s[1], math.max(s[1], e0)
end

local function drop_marks(bufnr, marks)
	if not (marks and api.nvim_buf_is_valid(bufnr)) then
		return
	end
	for _, id in pairs(marks) do
		-- marks carries the ends_at_eof flag alongside the ids
		if type(id) == "number" then
			pcall(api.nvim_buf_del_extmark, bufnr, ANCHOR, id)
		end
	end
end

--=============================================================================
-- One edit per region
--=============================================================================

---A line range as the user counts them.
---@param s0 number
---@param e0 number Exclusive; equal to s0 for an insertion point
---@return string
local function span(s0, e0)
	if e0 <= s0 + 1 then
		return ("line %d"):format(s0 + 1)
	end
	return ("lines %d-%d"):format(s0 + 1, e0)
end

---The request or diff already holding any of these lines.
---
---Two inline edits over the same lines cannot both be right. Both prompts are built from the
---same text, so whichever answer lands second describes a rewrite of code the other one has
---already replaced — and applying it means writing over the first answer with lines that were
---never meant to sit next to it.
---@param bufnr number
---@param range { s0: number, e0: number }
---@return { kind: "request"|"diff", s0: number, e0: number, instruction: string|nil }|nil
local function held_by(bufnr, range)
	-- An insertion point occupies no lines, but it does sit on one, and an edit that replaces
	-- that line takes the seam with it — so it is treated as covering the row it is on.
	local lo, hi = range.s0, math.max(range.e0, range.s0 + 1)
	local st = buf_state(bufnr)
	local held

	local function consider(kind, order, item)
		local s0, e0 = resolve(bufnr, item.marks)
		if not s0 or lo >= math.max(e0, s0 + 1) or s0 >= hi then
			return
		end
		-- The oldest, so the answer does not depend on hash order when two things overlap.
		if not held or order < held.order then
			held = { kind = kind, order = order, s0 = s0, e0 = e0, instruction = item.instruction }
		end
	end

	for id, req in pairs(st.requests) do
		consider("request", id, req)
	end
	for id, diff in pairs(st.diffs) do
		consider("diff", diff.request_id or id, diff)
	end
	return held
end

---Whether a new request over this range has to be refused, saying why and which key settles the
---thing in the way.
---@param bufnr number
---@param range { s0: number, e0: number }
---@return boolean
local function blocked(bufnr, range)
	local held = held_by(bufnr, range)
	if not held then
		return false
	end
	local what = held.instruction and (' ("%s")'):format(ui.ellipsise(held.instruction, 40)) or ""
	if held.kind == "request" then
		ui.say(
			("[ducktape] %s already has an inline request in flight%s — <leader>cx cancels it, <leader>cL lists them all"):format(
				span(held.s0, held.e0),
				what
			),
			vim.log.levels.WARN
		)
	else
		ui.say(
			("[ducktape] %s has an inline diff waiting on you%s — g2 accepts it, g3 rejects it"):format(
				span(held.s0, held.e0),
				what
			),
			vim.log.levels.WARN
		)
	end
	return true
end

--=============================================================================
-- Prompt
--=============================================================================

-- One contract for every transport. An earlier revision asked HTTP and relay for a
-- `{"code":"…"}` envelope instead; that is reverted, and deliberately not to be reintroduced.
-- Measured on ollama cloud with the same selection: under the envelope the model returned the
-- whole enclosing function — the <before> and <after> context included — while the plain
-- contract returned exactly the selected lines. It is also the workaround this rebuild set out
-- to delete (README → *The contract*), and no envelope survives a code fragment whose braces do
-- not balance, which is most fragments.
local CONTRACT = [[
You are an inline code editor inside Neovim. The editor decides where your output goes;
you only supply code. Return ONLY the replacement text for the selected region.
Reproduce every line you are not changing exactly as given. Do not add commentary.]]

local NO_TOOLS = "You have no tools. Work only from the text below."
local DEEP = [[
You may read files in this repository to learn its conventions before answering.
Do not modify any file: the editor applies your output, not you.]]

-- Only reachable through M.submit now: the keymaps send the cursor's line as the selection, so
-- there is no empty range to describe unless a caller asks for one.
local INSERT = [[
The selected region is empty. Return only the new code to insert at that point.]]

---@param bufnr number
---@param range table
---@return string
local function diagnostics_for(bufnr, range)
	local out = {}
	for _, d in ipairs(vim.diagnostic.get(bufnr)) do
		if d.lnum >= range.s0 and d.lnum <= math.max(range.s0, range.e0 - 1) then
			table.insert(out, ("line %d: %s"):format(d.lnum + 1, vim.split(d.message, "\n", { plain = true })[1]))
		end
	end
	return table.concat(out, "\n")
end

---@param bufnr number
---@param range table
---@param instruction string
---@param deep boolean
---@return { prompt: string, instruction: string, content: string, selection: string[] }
local function build_prompt(bufnr, range, instruction, deep)
	local total = api.nvim_buf_line_count(bufnr)
	local filetype = vim.bo[bufnr].filetype
	local path = vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":.")

	local selection = api.nvim_buf_get_lines(bufnr, range.s0, range.e0, false)
	local before = api.nvim_buf_get_lines(bufnr, math.max(0, range.s0 - CONTEXT_LINES), range.s0, false)
	local after = api.nvim_buf_get_lines(bufnr, range.e0, math.min(total, range.e0 + CONTEXT_LINES), false)

	local head = { CONTRACT, deep and DEEP or NO_TOOLS }
	if not range.has_selection then
		table.insert(head, INSERT)
	end

	local content = {
		("<file path=%s filetype=%s lines=%d-%d>"):format(
			path ~= "" and path or "[no name]",
			filetype ~= "" and filetype or "text",
			range.s0 + 1,
			range.e0
		),
		"<before>",
		table.concat(before, "\n"),
		"</before>",
		"<selection>",
		table.concat(selection, "\n"),
		"</selection>",
		"<after>",
		table.concat(after, "\n"),
		"</after>",
		"</file>",
	}

	local diagnostics = diagnostics_for(bufnr, range)
	if diagnostics ~= "" then
		table.insert(content, "<diagnostics>")
		table.insert(content, diagnostics)
		table.insert(content, "</diagnostics>")
	end

	local instruction_block = table.concat(head, "\n\n") .. "\n\nInstruction: " .. instruction
	local content_block = table.concat(content, "\n")

	return {
		instruction = instruction_block,
		content = content_block,
		prompt = instruction_block .. "\n\n" .. content_block .. "\n",
		-- Kept for the parser: a reply that reuses lines of the selection is an edit, however
		-- little it looks like code on its own.
		selection = selection,
	}
end

--=============================================================================
-- Diff keymaps
--=============================================================================

---Where a diff's replacement currently sits: the start mark for the row it begins on, and the
---reply's own line count for how far it reaches.
---
---Deliberately not `resolve`, because a diff's end mark cannot be trusted. DiffUI renders a
---deletion as real lines and takes them out again in `clear()`, and a right-gravity mark grows
---over them without ever shrinking back; a neighbouring diff landing on the row after this one
---pushes it as well. Measured: three one-line diffs on rows 0, 1 and 3 resolved to 0..2, 1..2 and
---3..5 when each owned exactly one row — which is how rejecting them all ate a line.
---
---The start mark has none of that trouble. It faces left at the top of the region, so only whole
---rows moving above it shift it, and those shift its content with it.
---@param diff table
---@return number|nil s0, number|nil e0
local function diff_region(diff)
	if not api.nvim_buf_is_valid(diff.bufnr) then
		return nil
	end
	local m = api.nvim_buf_get_extmark_by_id(diff.bufnr, ANCHOR, diff.marks.start, {})
	if not m or #m == 0 then
		return nil
	end
	local total = api.nvim_buf_line_count(diff.bufnr)
	if m[1] >= total then
		return nil
	end
	return m[1], math.min(m[1] + #diff.replacement, total)
end

---@param bufnr number
---@return table|nil
local function diff_under_cursor(bufnr)
	local diffs = buf_state(bufnr).diffs
	local row = api.nvim_win_get_cursor(0)[1] - 1

	local only
	for _, d in pairs(diffs) do
		local s0, e0 = diff_region(d)
		if s0 and row >= s0 and row < math.max(e0, s0 + 1) then
			return d
		end
		only = only == nil and d or false
	end
	-- Outside every diff, but if only one is pending the intent is unambiguous
	return only or nil
end

local function bind_diff_keys(bufnr)
	local shared = require("codecompanion.config").interactions.shared.keymaps

	-- DiffUI binds these two buffer-locally even when skipping default keymaps, shadowing the
	-- core paragraph motions while a diff is pending — and the second concurrent diff clobbers
	-- the first's. Ours dispatch by cursor position instead.
	pcall(vim.keymap.del, "n", shared.next_hunk.modes.n, { buffer = bufnr })
	pcall(vim.keymap.del, "n", shared.previous_hunk.modes.n, { buffer = bufnr })
	-- Delete the literal keys too, in case upstream changes the shared-keymap structure and the
	-- reads above silently find nothing. These are the stock defaults; harmless if not bound.
	pcall(vim.keymap.del, "n", "}", { buffer = bufnr })
	pcall(vim.keymap.del, "n", "{", { buffer = bufnr })

	local function on(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = bufnr, desc = desc, nowait = true })
	end

	on("g2", function()
		M.accept(bufnr)
	end, "AI: accept the diff under the cursor")
	on("g3", function()
		M.reject(bufnr)
	end, "AI: reject the diff under the cursor")
	on("<leader>cj", function()
		M.hunk(bufnr, "next")
	end, "AI: next hunk in the diff under the cursor")
	on("<leader>ck", function()
		M.hunk(bufnr, "previous")
	end, "AI: previous hunk in the diff under the cursor")
end

-- Defined further down, where `guarded` is in scope, but called from the registry bookkeeping above
-- it: the lock comes off as soon as the last request in a buffer lets go of its lines.
local unlock_undo

local function unbind_diff_keys(bufnr)
	for _, lhs in ipairs({ "g2", "g3", "<leader>cj", "<leader>ck" }) do
		pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
	end
end

--=============================================================================
-- Registry bookkeeping
--=============================================================================

local function forget_request(req)
	local st = buf_state(req.bufnr)
	st.requests[req.id] = nil
	if req.progress then
		req.progress.stop()
	end
	unlock_undo(req.bufnr)
end

---Stop one request and forget everything it was holding: the transport's job, the spinner and
---the anchor it would have applied its answer to.
---@param req table
local function cancel_request(req)
	if req.handle then
		pcall(req.handle.cancel)
	end
	forget_request(req)
	drop_marks(req.bufnr, req.marks)
end

-- Declared here because watch_buffer has to clear waiting replies when a buffer goes, and it is
-- defined before them — they in turn need watch_buffer, so one of the two has to be forward
-- declared.
---@type fun(entry: table)
local forget_waiting

---@param diff table
---@param keep_marks? boolean The reject path still needs them after this returns
local function forget_diff(diff, keep_marks)
	local st = buf_state(diff.bufnr)
	st.diffs[diff.id] = nil
	if not keep_marks then
		drop_marks(diff.bufnr, diff.marks)
	end
	-- resolve_diff clears every shared keymap in the buffer, including the g2/g3 we own, so a
	-- second pending diff would silently lose its bindings.
	vim.schedule(function()
		if not api.nvim_buf_is_valid(diff.bufnr) then
			return
		end
		if count(buf_state(diff.bufnr).diffs) > 0 then
			bind_diff_keys(diff.bufnr)
		else
			unbind_diff_keys(diff.bufnr)
		end
	end)
end

--=============================================================================
-- Protecting a range while its request is in flight
--=============================================================================

-- The prompt is built from the exact lines of the range and the answer is applied back over
-- them, so an edit landing on one in the meantime means a reply that rewrites text the user has
-- since changed — silently discarding whatever they typed the moment they accept it. Editing
-- anywhere else in the buffer is untouched.
--
-- The guard tracks its own rows arithmetically, from the geometry `on_bytes` reports, rather than
-- reading them back off an extmark. No single mark configuration can do this job: measured on a
-- --clean nvim, a left-gravity mark at the top of the range is dragged *up* when the line above it
-- is replaced, and a right-gravity one is pushed *past* the replacement when its own line is — and
-- a one-line range is entirely its own first line, so the second case is every edit to it. That
-- was reverting a one-line range's edit one row too low, leaving the typed text in place with the
-- original inserted underneath it. Arithmetic has no such ambiguity: `guard_row` is where the
-- lines start and `guard_span` is how many rows they now occupy.
--
-- Only a real selection is protected. An insertion point holds no lines to put back, and its
-- anchor rides along with the edits around it, so its answer still lands where it was asked for.

---@param bufnr number
---@return table[]
local function guarded(bufnr)
	local out = {}
	for _, req in pairs(buf_state(bufnr).requests) do
		if req.guard then
			table.insert(out, req)
		end
	end
	return out
end

---@param bufnr number
---@param row number 0-indexed
---@return table|nil req
local function guard_at(bufnr, row)
	for _, req in ipairs(guarded(bufnr)) do
		if row >= req.guard_row and row < req.guard_row + math.max(req.guard_span, 1) then
			return req
		end
	end
end

---Say something about a guarded range, late enough to be read.
---
---From a timer, not from the caller and not from `vim.schedule`: these messages all come out around
---a mode change, and the redraw that ends one wipes the command line. Scheduled callbacks run
---*before* that redraw — measured, along with the consequence: the warning was reaching `:messages`
---and never the screen, which is exactly as good as saying nothing. A timer runs after it.
---@param msg string
---@param opts? { history?: boolean }
local function announce(msg, opts)
	vim.defer_fn(function()
		ui.say(msg, vim.log.levels.WARN, opts)
	end, 10)
end

-- What the user tried, and what to say about it. The instruction is not named in any of them: it
-- would be the first thing cut when the message is fitted to the command line, and the range's own
-- label is directly above the lines in question — the key to press is what is nowhere else.
local HELD = {
	refused = "[ducktape] those lines are held by an inline request — <leader>cx cancels it",
	reverted = "[ducktape] put those lines back — <leader>cx cancels the inline request holding them",
	undo = "[ducktape] undo is held off while an inline request runs here — <leader>cx cancels it",
}

---@param req table
---@param why? "refused"|"reverted"|"undo" Defaults to refused, the do-nothing-yet case
local function say_protected(req, why)
	-- Always shown, recorded at most once every 2s. The backstop can fire once per keystroke and a
	-- stream of identical entries would bury the history, but suppressing the *echo* means a second
	-- attempt says nothing at all — and each attempt has wiped the command line on its way in.
	local now = vim.uv.now()
	local record = req.warned == nil or now - req.warned >= 2000
	if record then
		req.warned = now
	end
	announce(HELD[why or "refused"], { history = record })
end

-- Undo and redo, and the two ways of walking the tree by hand.
local UNDO_KEYS = { "u", "U", "<C-r>", "g-", "g+" }

-- Compared as keycodes, not as strings: nvim_buf_get_keymap reports `<C-R>`, so a mapping already on
-- redo would not match the `<C-r>` written above and would be replaced without being handed back.
local UNDO_CODES = {}
for _, lhs in ipairs(UNDO_KEYS) do
	UNDO_CODES[vim.keycode(lhs)] = true
end

---Hold undo off while a request is working on lines in this buffer.
---
---Undo is the one edit the guard cannot answer well. Reverting a change *to* the held lines is fine
---— their former text is known — but undo walks back through changes that were made before the
---request existed, and a single step of that can take the whole run of lines with it. That is the
---case the guard has to cancel the request for, since it knows what the lines said but not where
---they would now belong. Measured: two `u` presses with a request in flight cancelled it.
---
---So the keys are refused for as long as lines are held, which is seconds, and `<leader>cx` is the
---way out. Any buffer-local mapping already on those keys is put back afterwards, so a plugin that
---owns `u` in this buffer does not silently lose it. `:undo` and `:earlier` are not keys and are not
---covered — the guard remains the backstop there, cancelling as it did before.
---@param bufnr number
local function lock_undo(bufnr)
	local st = buf_state(bufnr)
	if st.undo_lock then
		return
	end
	st.undo_lock = {}
	for _, map in ipairs(api.nvim_buf_get_keymap(bufnr, "n")) do
		if UNDO_CODES[vim.keycode(map.lhs)] then
			table.insert(st.undo_lock, map)
		end
	end
	for _, lhs in ipairs(UNDO_KEYS) do
		vim.keymap.set("n", lhs, function()
			local req = guarded(bufnr)[1]
			if not req then
				return unlock_undo(bufnr)
			end
			say_protected(req, "undo")
		end, { buffer = bufnr, desc = "ai: held off while an inline request runs" })
	end
end

---@param bufnr number
function unlock_undo(bufnr)
	local st = buffers[bufnr]
	if not st or not st.undo_lock or #guarded(bufnr) > 0 then
		return
	end
	local restore = st.undo_lock
	st.undo_lock = nil
	if not api.nvim_buf_is_valid(bufnr) then
		return
	end
	for _, lhs in ipairs(UNDO_KEYS) do
		pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
	end
	for _, map in ipairs(restore) do
		pcall(vim.fn.mapset, map)
	end
end

---Put a protected range back the way its request left it, at the row the guard has been tracking.
---@param bufnr number
---@param req table
local function restore_guard(bufnr, req)
	local st = buf_state(bufnr)
	local total = api.nvim_buf_line_count(bufnr)
	local at = math.max(math.min(req.guard_row, total), 0)
	st.restoring = true
	-- Joined onto the edit it undoes, so the pair is one undo step: left as two, a `u` would put
	-- the blocked edit back and the guard would immediately revert it again. Refused right after
	-- an undo, which is why it is a pcall and not a hard requirement.
	pcall(vim.cmd, "undojoin")
	pcall(api.nvim_buf_set_lines, bufnr, at, math.min(at + req.guard_span, total), false, req.guard)
	st.restoring = false

	req.guard_row, req.guard_span = at, #req.guard
	-- Re-anchored from the row the guard knows: the same edit that mangled the lines mangled the
	-- anchor marks, and a range that resolves to nothing would have its answer dropped on arrival.
	drop_marks(bufnr, req.marks)
	req.marks = anchor(bufnr, { s0 = at, e0 = at + #req.guard })

	say_protected(req, "reverted")
	if vim.fn.mode():find("^i") then
		vim.cmd("stopinsert")
	end
end

---Apply one reported change to every guarded range in the buffer: move the ones it happened above,
---and mark the ones it happened *inside*.
---
---Pure arithmetic, because this runs inside `on_bytes`, which holds textlock — nothing here may
---read or write the buffer.
---@param bufnr number
---@param sr number Row the change starts on
---@param sc number Column it starts at
---@param old_rows number Rows the replaced text spanned, relative to sr
---@param old_cols number Column the replaced text ended at
---@param new_rows number Rows the new text spans, relative to sr
local function track_change(bufnr, sr, sc, old_rows, old_cols, new_rows)
	local delta = new_rows - old_rows

	-- Which existing rows this change rewrote. A change that replaced nothing (both old offsets
	-- zero) only inserted: at a column of zero it sits between two lines and rewrites neither, and
	-- past column zero it splits the line it is on, which does count as rewriting it.
	local from, to
	if old_rows == 0 and old_cols == 0 then
		if sc > 0 then
			from, to = sr, sr
		end
	else
		-- An end column of zero means the change stopped at the start of that row, so the row
		-- itself contributed nothing to it.
		to = sr + old_rows - (old_cols == 0 and 1 or 0)
		from, to = sr, math.max(to, sr)
	end

	for _, req in ipairs(guarded(bufnr)) do
		local g, span = req.guard_row, req.guard_span
		if not from then
			-- An insertion between lines: at or above the range it pushes the whole thing down;
			-- strictly inside it, it has broken the run of lines the model was given.
			if sr <= g then
				req.guard_row = g + delta
			elseif sr < g + span then
				req.violated = true
				req.guard_span = span + delta
			end
		elseif to < g then
			req.guard_row = g + delta
		elseif from < g + span then
			if from >= g and to < g + span then
				req.violated = true
				req.guard_span = span + delta
			else
				-- The change reached outside the range as well. Only the range's own former text is
				-- known, so putting it back would mean guessing at the rest — the request is stopped
				-- instead, which is honest and leaves the user's change alone.
				req.swept = true
			end
		end
	end
end

---@param bufnr number
local function enforce_guards(bufnr)
	if not api.nvim_buf_is_valid(bufnr) then
		return
	end
	for _, req in ipairs(guarded(bufnr)) do
		if req.swept then
			req.swept = false
			cancel_request(req)
			-- Named here, unlike the messages above: the request is gone and its label with it, so
			-- this is the last place its instruction appears at all.
			announce(
				("[ducktape] your change spanned an inline request's lines — cancelled it (%s)"):format(
					ui.ellipsise(req.instruction or "?", 20)
				)
			)
		elseif req.violated then
			req.violated = false
			-- Verified before writing: a change and its own undo can both land in one tick, and
			-- rewriting lines that already say the right thing would cost the user an undo step and
			-- a warning for nothing.
			local now = api.nvim_buf_get_lines(bufnr, req.guard_row, req.guard_row + req.guard_span, false)
			if not vim.deep_equal(now, req.guard) then
				restore_guard(bufnr, req)
			else
				req.guard_span = #req.guard
			end
		end
	end
end

---Watch a buffer's text so an edit on a protected range can be put straight back. Attached with
---the first guarded request and detached with the last, so a buffer with nothing in flight in it
---pays nothing.
---@param bufnr number
local function watch_text(bufnr)
	local st = buf_state(bufnr)
	if st.attached then
		return
	end
	st.attached = true
	api.nvim_buf_attach(bufnr, false, {
		on_bytes = function(_, b, _, sr, sc, _, old_rows, old_cols, _, new_rows)
			local s = buffers[b]
			if not s or #guarded(b) == 0 then
				if s then
					s.attached = false
				end
				return true -- detach
			end
			if s.restoring then
				return
			end
			-- Every change is tracked, so the rows stay exact; only the reverting is deferred, since
			-- on_bytes holds textlock and the buffer cannot be written from here. One pass per tick
			-- however many changes arrive, so a paste is one restore rather than one per line.
			track_change(b, sr, sc, old_rows, old_cols, new_rows)
			if s.pending then
				return
			end
			s.pending = true
			vim.schedule(function()
				local cur = buffers[b]
				if cur then
					cur.pending = false
				end
				enforce_guards(b)
			end)
		end,
	})
end

-- Rejected diffs whose original lines are due back, and whether a flush is already booked.
local restores, flush_booked = {}, false

---Put a rejected diff's original lines back, once every rejection in this tick has been seen.
---
---Batched rather than restored on the spot, because rejecting two diffs in one buffer at once
---otherwise loses a line between them. show_diff's marks face outwards so they can grow over the
---text the diff inserts into them, and that also means a write on the row one of them sits on
---drags it: restore the lower region and the upper diff's end mark is pushed a row down, so its
---own restore then overwrites the line just put back. Measured on adjacent regions — and it
---depends on which one goes first, so it corrupted only sometimes.
---
---The flush measures every queued region before writing any of them, so no region is read after
---another has moved it, and applies them bottom-up, so a write can never shift a region still to
---come. Measuring is deliberately left to the flush rather than done at rejection time: DiffUI
---deletes its spacer line in `clear()`, which runs after this callback, and rows taken before that
---would be one out.
---@param diff table
local function queue_restore(diff)
	table.insert(restores, diff)
	if flush_booked then
		return
	end
	flush_booked = true
	vim.schedule(function()
		flush_booked = false
		local pending = restores
		restores = {}

		local regions = {}
		for _, d in ipairs(pending) do
			local s0, e0 = diff_region(d)
			if s0 then
				table.insert(regions, { diff = d, bufnr = d.bufnr, s0 = s0, e0 = e0 })
			end
			drop_marks(d.bufnr, d.marks)
		end

		table.sort(regions, function(a, b)
			if a.bufnr ~= b.bufnr then
				return a.bufnr < b.bufnr
			end
			return a.s0 > b.s0
		end)

		for _, r in ipairs(regions) do
			-- Checked against the reply before overwriting it. The region is derived rather than
			-- read back from a mark, so this is what catches a derivation that has gone wrong — and
			-- also the user having edited the diff themselves, where putting the original back would
			-- throw away their work without asking. Leaving the reply in place is the safer failure:
			-- it is visible, and g3 is still there once they are done.
			local now = api.nvim_buf_get_lines(r.bufnr, r.s0, r.e0, false)
			if vim.deep_equal(now, r.diff.replacement) then
				-- Only this diff's own region, never the whole buffer: a whole-buffer restore is
				-- what makes the built-in corrupt a second concurrent request.
				pcall(api.nvim_buf_set_lines, r.bufnr, r.s0, r.e0, false, r.diff.original)
			else
				ui.say(
					("[ducktape] %s:%d has changed since that edit was made — its original lines were left alone"):format(
						vim.fn.fnamemodify(api.nvim_buf_get_name(r.bufnr), ":t"),
						r.s0 + 1
					),
					vim.log.levels.WARN
				)
			end
		end
	end)
end

---Auto-reject on premature close is disabled under skip_default_keymaps, so restoring the
---original lines is ours to do.
---@param bufnr number
local function watch_buffer(bufnr)
	local st = buf_state(bufnr)
	if st.augroup then
		return
	end
	st.augroup = api.nvim_create_augroup("DucktapeInlineBuf" .. bufnr, { clear = true })

	-- Refusing insert mode outright is both cheaper and less startling than letting the text
	-- change and putting it back — nothing has been typed yet at this point. The guard above is
	-- still the backstop, for the operators that change text without ever entering insert.
	api.nvim_create_autocmd("InsertEnter", {
		group = st.augroup,
		buffer = bufnr,
		callback = function()
			local req = guard_at(bufnr, api.nvim_win_get_cursor(0)[1] - 1)
			if req then
				-- Scheduled, because `stopinsert` called from inside InsertEnter does nothing at all:
				-- measured, mode was still "i" 250ms later. This was the whole refusal, so insert mode
				-- was in fact being entered on held lines and only the backstop was stopping the typing.
				vim.schedule(function()
					vim.cmd("stopinsert")
				end)
				say_protected(req)
			end
		end,
	})

	local function reject_pending()
		-- Snapshot first: rejecting mutates st.diffs while we walk it
		for _, diff in ipairs(vim.tbl_values(st.diffs)) do
			M.reject(bufnr, diff)
		end
	end

	api.nvim_create_autocmd("WinClosed", {
		group = st.augroup,
		buffer = bufnr,
		callback = function(args)
			-- WinClosed's pattern is a window id, so `buffer =` scopes this to "a window showing
			-- this buffer closed" — not "the buffer went away". Without the count below, closing
			-- one split of two throws away a finished edit the user had not accepted yet.
			-- WinClosed fires before the window is gone, so the closing one still counts.
			-- Deferred: a fast split/close cycle can fire WinClosed before the new window for the
			-- same buffer exists, so checking immediately would count zero and reject.
			local closing = tonumber(args.match)
			vim.defer_fn(function()
				for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
					if win ~= closing then
						return
					end
				end
				reject_pending()
			end, 50)
		end,
	})

	api.nvim_create_autocmd({ "BufDelete", "BufUnload" }, {
		group = st.augroup,
		buffer = bufnr,
		callback = function()
			reject_pending()
			-- A reply waiting on a buffer that has gone has nothing left to point at, and its retry
			-- would have nowhere to land.
			for _, entry in ipairs(vim.tbl_values(st.waiting)) do
				forget_waiting(entry)
			end
			-- A request whose buffer is gone has nowhere to land, and on_reply would discard it
			-- anyway — so stop paying for it rather than letting the agent finish into a void.
			for _, req in ipairs(vim.tbl_values(st.requests)) do
				cancel_request(req)
			end
			-- Neither the registry entry nor the augroup is reachable again once the buffer is
			-- wiped, and both would otherwise accumulate for the rest of the session.
			pcall(api.nvim_del_augroup_by_id, st.augroup)
			buffers[bufnr] = nil
		end,
	})
end

--=============================================================================
-- Applying a reply
--=============================================================================

--=============================================================================
-- Replies that cannot be applied
--=============================================================================

-- A reply that is not code — an answer, a refusal, leaked tool markup — and a request that failed
-- outright both leave something the user has to decide about, and neither can be written into the
-- buffer. They used to be thrown straight at the screen: prose opened a float that took focus, and
-- an error was a notify and nothing else.
--
-- Both are registered instead, so they behave like a pending diff: they wait, they are visible
-- where they belong, they show up in the list wherever the user is, and they can be read, taken
-- into a chat, re-asked or dismissed at whatever moment suits. Nothing takes focus, and nothing is
-- lost by looking away — which the float was, since dismissing it destroyed the only copy.

local WAITING = {
	prose = { sign = "◆", hl = "DucktapeListReady", label = "answered" },
	failed = { sign = "✖", hl = "DucktapeListDead", label = "failed" },
}

---Where a waiting reply's lines are, or nothing if it never had any or they have gone.
---
---A function rather than `entry.marks and resolve(...)` at each call site: that idiom truncates a
---two-value return to one, so the end row came back nil everywhere it was written that way.
---@param entry table
---@return number|nil s0, number|nil e0
local function waiting_region(entry)
	if not entry.marks then
		-- Both, so a caller destructuring two values gets two.
		return nil, nil
	end
	return resolve(entry.bufnr, entry.marks)
end

---@param entry table
function forget_waiting(entry)
	buf_state(entry.bufnr).waiting[entry.id] = nil
	if entry.marker then
		entry.marker.stop()
	end
	drop_marks(entry.bufnr, entry.marks)
end

---Hand a request's leftovers to the user rather than dropping them.
---@param req table
---@param kind "prose"|"failed"
---@param opts { title: string, text: string }
local function wait_on_user(req, kind, opts)
	local bufnr = req.bufnr
	if not api.nvim_buf_is_valid(bufnr) then
		return drop_marks(bufnr, req.marks)
	end

	local s0, e0 = resolve(bufnr, req.marks)
	local look = WAITING[kind]

	seq = seq + 1
	local entry = {
		id = seq,
		-- Keeps the row where the request was, so a reply arriving changes its state in place.
		request_id = req.id,
		kind = kind,
		bufnr = bufnr,
		-- Re-anchored rather than reusing the request's marks: those are dropped as each request
		-- ends, and this outlives it.
		marks = s0 and anchor(bufnr, { s0 = s0, e0 = e0 }) or nil,
		title = opts.title,
		text = opts.text,
		-- Everything a retry needs. The provider is recorded for the row rather than for the resend:
		-- re-asking goes out with whatever is selected now, since a refusal is a common reason to
		-- switch model first.
		instruction = req.instruction,
		deep = req.deep,
		provider = req.provider,
		model = req.model,
		selection = req.selection,
		finished = vim.uv.now(),
	}

	if s0 then
		entry.marker =
			ui.pinned(bufnr, s0, e0, ("%s · %s · %s"):format(req.provider, look.label, req.instruction or "?"), {
				hl = "DiagnosticVirtualTextHint",
				sign = look.sign,
				sign_hl = look.hl,
				range_hl = "DucktapeInlineWaiting",
			})
	end

	buf_state(bufnr).waiting[entry.id] = entry
	watch_buffer(bufnr)
	return entry
end

--=============================================================================
-- Holding the cursor still
--=============================================================================

-- DiffUI scrolls to the first hunk when it renders (diff/ui.lua:603 → scroll_to_line, which is a
-- `:LINE` plus `normal! zz` inside the window showing the buffer). A request runs for seconds and
-- lands whenever it lands, so that is a cursor yanked away from whatever was being typed, and the
-- view recentred under it. Both are put back.

---Where the cursor is in every window on this buffer, and what those windows are looking at.
---@param bufnr number
---@return table[]
local function hold_view(bufnr)
	local held = {}
	local total = api.nvim_buf_line_count(bufnr)
	for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
		local view = api.nvim_win_call(win, vim.fn.winsaveview)
		table.insert(held, {
			win = win,
			view = view,
			-- An extmark as well as the saved line number: the diff writes its own rows in, so the
			-- line the cursor was on is not necessarily the line it should be on afterwards. Left
			-- gravity, so text inserted at the cursor's own row appears below it rather than
			-- carrying it along.
			mark = api.nvim_buf_set_extmark(bufnr, ANCHOR, math.min(view.lnum - 1, total - 1), 0, {
				right_gravity = false,
			}),
		})
	end
	return held
end

---@param bufnr number
---@param held table[]
local function release_view(bufnr, held)
	for _, h in ipairs(held) do
		if api.nvim_buf_is_valid(bufnr) and api.nvim_win_is_valid(h.win) and api.nvim_win_get_buf(h.win) == bufnr then
			local view = vim.deepcopy(h.view)
			local m = api.nvim_buf_get_extmark_by_id(bufnr, ANCHOR, h.mark, {})
			if m and #m > 0 then
				-- The window is scrolled by however far the cursor's own line moved, so the line
				-- stays where it was on screen rather than the view jumping to catch up with it.
				local shifted = (m[1] + 1) - h.view.lnum
				view.lnum = m[1] + 1
				view.topline = math.max(h.view.topline + shifted, 1)
			end
			view.lnum = math.max(math.min(view.lnum, api.nvim_buf_line_count(bufnr)), 1)
			api.nvim_win_call(h.win, function()
				vim.fn.winrestview(view)
			end)
		end
		if api.nvim_buf_is_valid(bufnr) then
			pcall(api.nvim_buf_del_extmark, bufnr, ANCHOR, h.mark)
		end
	end
end

---@param req table
---@param result ducktape.parse.Result
local function show_diff(req, result)
	local lines = result.lines
	local bufnr = req.bufnr
	local s0, e0 = resolve(bufnr, req.marks)
	if not s0 then
		drop_marks(bufnr, req.marks)
		return ui.say(
			"[ducktape] the anchored range was deleted while the request was in flight — result dropped",
			vim.log.levels.WARN
		)
	end

	local from_lines = api.nvim_buf_get_lines(bufnr, 0, -1, true)
	local to_lines = {}
	vim.list_extend(to_lines, vim.list_slice(from_lines, 1, s0))
	vim.list_extend(to_lines, lines)
	vim.list_extend(to_lines, vim.list_slice(from_lines, e0 + 1))

	if vim.deep_equal(from_lines, to_lines) then
		drop_marks(bufnr, req.marks)
		-- A model that declines usually echoes the selection back inside a fence and explains
		-- itself around it. Reporting only "nothing to change" would throw that explanation away
		-- and leave the user staring at an unchanged buffer with no idea why.
		if result.preamble then
			-- result.preamble, not result.text: kind "code" has no text field, only the prose that
			-- surrounded the fence.
			wait_on_user(req, "prose", {
				title = ("%s — returned the selection unchanged"):format(req.provider),
				text = result.preamble,
			})
			return ui.say(
				("[ducktape] %s returned the selection unchanged, with an explanation — <leader>cL to read it"):format(
					req.provider
				),
				vim.log.levels.WARN
			)
		end
		return ui.say("[ducktape] the reply matches the buffer — nothing to change", vim.log.levels.INFO)
	end

	-- An empty buffer never reaches the diff UI. DiffUI's own create_diff_display writes the
	-- merged old-and-new view straight in when it finds the buffer empty (diff/ui.lua:439), and
	-- apply_inline then applies its hunks on top of that — so the reply lands twice. There is
	-- nothing to compare against in an empty buffer anyway, and `u` is a complete way back.
	if api.nvim_buf_line_count(bufnr) == 1 and (api.nvim_buf_get_lines(bufnr, 0, 1, true)[1] or "") == "" then
		drop_marks(bufnr, req.marks)
		api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		return ui.say("[ducktape] the buffer was empty, so the reply was inserted directly — u to undo")
	end

	-- The diff UI takes over a window to show itself, and falls back to the *current* one when
	-- the target buffer is not on screen (diff/ui.lua:426), which would yank whatever the user
	-- moved on to read out from under them. Requests run for seconds, so moving on is normal.
	if vim.fn.bufwinid(bufnr) == -1 then
		local name = vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t"):gsub("^$", "the target buffer")
		-- Registered rather than discarded, so the instruction survives: bring the buffer back on
		-- screen and `e` in the list asks the same thing again.
		wait_on_user(req, "failed", {
			title = ("%s — could not be applied"):format(req.provider),
			text = ("%s answered, but %s was not on screen, so there was nowhere to render the diff without taking over the window you had moved to.\n\nBring the buffer back into view and press e in the inline list to ask again."):format(
				req.provider,
				name
			),
		})
		drop_marks(bufnr, req.marks)
		return ui.say(
			("[ducktape] %s answered, but %s is not on screen — nothing was applied, <leader>cL to retry"):format(
				req.provider,
				name
			),
			vim.log.levels.WARN
		)
	end

	local original = vim.list_slice(from_lines, s0 + 1, e0)

	-- Placed before show_diff and tracked through it: the change is confined to [start, finish),
	-- start holds against insertion and finish is pushed past the replacement, so the pair spans
	-- exactly the new content once the diff has been applied.
	local srow, scol = clamp(bufnr, s0)
	local erow, ecol, ends_at_eof = clamp(bufnr, e0)
	local marks = {
		ends_at_eof = ends_at_eof,
		start = api.nvim_buf_set_extmark(bufnr, ANCHOR, srow, scol, { right_gravity = false }),
		finish = api.nvim_buf_set_extmark(bufnr, ANCHOR, erow, ecol, { right_gravity = true }),
	}

	seq = seq + 1
	local diff = {
		id = seq,
		-- The request this came out of, so M.list can keep the entry where it was when the
		-- request it describes finishes: the row changes state in place rather than jumping to
		-- the bottom of the list under a cursor that was reading it.
		request_id = req.id,
		bufnr = bufnr,
		marks = marks,
		original = original,
		-- What the diff put there, which is how its extent is known later: the end mark grows over
		-- DiffUI's own deletion rows and never shrinks back, so the reply's own length is the only
		-- reliable measure of how far the region reaches. See diff_region.
		replacement = lines,
		provider = req.provider,
		model = req.model,
		instruction = req.instruction,
		finished = vim.uv.now(),
	}

	local held = hold_view(bufnr)

	local helpers = require("codecompanion.helpers")
	diff.ui = helpers.show_diff({
		bufnr = bufnr,
		from_lines = from_lines,
		to_lines = to_lines,
		diff_id = diff.id,
		ft = vim.bo[bufnr].filetype,
		inline = true,
		banner = "g2 Accept | g3 Reject | <leader>cj/ck Hunk",
		-- What lets us own g2/g3, which is what makes concurrent diffs possible at all
		skip_default_keymaps = true,
		keymaps = {
			on_accept = function()
				forget_diff(diff)
			end,
			on_reject = function()
				-- Deferred past resolve_diff's own cleanup. When a hunk starts at line 1, DiffUI
				-- inserts a real spacer line at row 0 and deletes it again in clear(), which runs
				-- after this handler — restoring first made that deletion land on a line of ours
				-- and silently swallow it.
				queue_restore(diff)
				forget_diff(diff, true)
			end,
		},
	})

	drop_marks(bufnr, req.marks)
	buf_state(bufnr).diffs[diff.id] = diff
	watch_buffer(bufnr)
	bind_diff_keys(bufnr)

	-- After DiffUI's own scroll, which it schedules from inside show_diff — so this one, queued
	-- once show_diff has returned, is the one that runs last.
	vim.schedule(function()
		release_view(bufnr, held)
	end)
end

---@param req table
---@param reply string
local function on_reply(req, reply)
	forget_request(req)
	if not api.nvim_buf_is_valid(req.bufnr) then
		return
	end

	-- The filetype and the original selection are what keep the parser from mistaking a correct
	-- reply for prose: in a Markdown buffer the right answer *is* a sentence, and a reply that
	-- echoes lines of the selection is an edit whatever it looks like in isolation.
	local result = parse.parse(reply, { filetype = vim.bo[req.bufnr].filetype, selection = req.selection })

	if result.kind == "code" then
		return show_diff(req, result)
	end

	if result.kind == "noop" then
		drop_marks(req.bufnr, req.marks)
		return ui.say(("[ducktape] %s"):format(result.reason), vim.log.levels.WARN)
	end

	-- Left for the user to come to, rather than opened over whatever they are doing. Requests run
	-- for seconds and land whenever they land, and a float that took focus mid-keystroke was both
	-- disruptive and the only copy of the reply.
	wait_on_user(req, "prose", {
		title = ("%s — %s"):format(req.provider, result.reason),
		text = result.text,
	})
	drop_marks(req.bufnr, req.marks)
	ui.say(("[ducktape] %s %s — <leader>cL to read it"):format(req.provider, result.reason), vim.log.levels.WARN)
end

--=============================================================================
-- Public entry points
--=============================================================================

---Start one inline request. Separated from M.run so it can be driven without the input float,
---which is what the test suites drive.
---@param opts { bufnr: number, range: table, instruction: string, deep?: boolean, timeout?: number }
---@return table|nil req
function M.submit(opts)
	local bufnr = opts.bufnr
	if not api.nvim_buf_is_valid(bufnr) then
		return nil
	end

	local selection = providers.current("inline")
	local transport = providers.transport(selection.provider, opts.deep or false)

	-- Repeated from M.run because this is a public entry point in its own right, and a deep
	-- request on a transport that cannot read would otherwise silently run as a shallow one.
	if opts.deep and not providers.transports[transport].read then
		ui.say(
			("[ducktape] %s uses the %s transport, which cannot read the repository — <leader>cm to switch"):format(
				selection.provider,
				transport
			),
			vim.log.levels.WARN
		)
		return nil
	end

	-- Checked here as well as in M.run: the prompt float is open for as long as it takes to type
	-- an instruction, and another request can be started over the same lines while it is.
	if blocked(bufnr, opts.range) then
		return nil
	end

	-- A waiting reply over these lines is superseded by asking again, so it does not hold the range
	-- the way a request or a pending diff does — nothing of it is going to be applied.
	local lo, hi = opts.range.s0, math.max(opts.range.e0, opts.range.s0 + 1)
	for _, entry in ipairs(vim.tbl_values(buf_state(bufnr).waiting)) do
		local ws, we = waiting_region(entry)
		if not ws or (lo < math.max(we, ws + 1) and ws < hi) then
			forget_waiting(entry)
		end
	end

	seq = seq + 1
	local req = {
		id = seq,
		bufnr = bufnr,
		provider = selection.provider,
		model = tostring(selection.opts.model),
		transport = transport,
		deep = opts.deep or false,
		-- What was asked, kept for the list and for the chat hand-off in on_reply, which was
		-- already reading this field before anything set it.
		instruction = opts.instruction,
		-- Loop time rather than os.time(): the list counts seconds, and os.time() only moves
		-- once one has fully elapsed, so a request would sit on "0s" for up to a second.
		started = vim.uv.now(),
		marks = anchor(bufnr, opts.range),
	}

	local built = build_prompt(bufnr, opts.range, opts.instruction, opts.deep or false)
	req.selection = built.selection
	-- The lines as the request saw them, so an edit that lands on top of them can be put back,
	-- plus where they are and how many rows they currently occupy — see track_change.
	if opts.range.e0 > opts.range.s0 then
		req.guard = built.selection
		req.guard_row, req.guard_span = opts.range.s0, #built.selection
	end
	-- Both values of resolve, so the spinner marks the whole range rather than just its first row.
	req.progress = ui.progress(bufnr, function()
		return resolve(bufnr, req.marks)
	end, ("%s · %s · %s"):format(selection.provider, tostring(selection.opts.model), opts.instruction))

	local module = transport == "http" and "ducktape.inline.http"
		or transport == "relay" and "ducktape.inline.relay"
		or "ducktape.inline.acp"

	-- Registered before the send, not after. A transport can fail synchronously — no
	-- `opencode-llm` on PATH, an adapter that will not resolve — and its on_error runs inside
	-- send(); registering afterwards would put an already-dead request into the buffer's registry
	-- with nothing left to clear it, so `<leader>cx` would keep reporting a phantom in flight.
	buf_state(bufnr).requests[req.id] = req
	watch_buffer(bufnr)
	if req.guard then
		watch_text(bufnr)
		lock_undo(bufnr)
	end

	req.handle = require(module).send({
		prompt = built.prompt,
		instruction = built.instruction,
		content = built.content,
		provider = selection.provider,
		bufnr = bufnr,
		timeout = opts.timeout,
	}, {
		on_done = function(reply)
			on_reply(req, reply)
		end,
		on_error = function(msg)
			forget_request(req)
			-- Kept rather than dropped, so the work put into the instruction is not lost with it:
			-- the row stays in the list with the range still anchored, and `e` there re-asks.
			wait_on_user(req, "failed", { title = ("%s — failed"):format(selection.provider), text = msg })
			drop_marks(bufnr, req.marks)
			ui.say(("[ducktape] %s — <leader>cL to retry"):format(msg), vim.log.levels.ERROR)
		end,
		on_tool = function(name)
			-- Recorded as well as rendered: the virtual text is only visible where the edit is,
			-- and M.list shows the same thing for buffers that are not on screen.
			req.activity = name
			if req.progress then
				req.progress.set_label(("%s · %s"):format(selection.provider, name))
			end
		end,
	})

	return req
end

---@param deep boolean True for <leader>cI, which invites repo research
function M.run(deep)
	local bufnr = api.nvim_get_current_buf()
	local range = capture_range()

	-- Before the prompt rather than after it: being told the lines are taken is no use once an
	-- instruction has been typed out.
	if blocked(bufnr, range) then
		return
	end

	local selection = providers.current("inline")
	local transport = providers.transport(selection.provider, deep)

	if deep and not providers.transports[transport].read then
		return ui.say(
			("[ducktape] <leader>cI needs a transport that can read the repository. %s uses %s, which cannot — "):format(
				selection.provider,
				transport
			) .. "it works on claude and on opencode. Switch with <leader>cm.",
			vim.log.levels.WARN
		)
	end

	input.open({
		title = (" Inline — %s · %s%s "):format(
			selection.provider,
			tostring(selection.opts.model),
			deep and " · repo reads" or ""
		),
		on_submit = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			M.submit({ bufnr = bufnr, range = range, instruction = vim.trim(text), deep = deep })
		end,
	})
end

---@param bufnr? number
---@param diff? table Resolve this diff instead of the one under the cursor
function M.accept(bufnr, diff)
	bufnr = bufnr or api.nvim_get_current_buf()
	diff = diff or diff_under_cursor(bufnr)
	if not diff or not diff.ui then
		return ui.say("[ducktape] no diff here", vim.log.levels.WARN)
	end
	require("codecompanion.diff.keymaps").accept_change.callback(diff.ui)
end

---@param bufnr? number
---@param diff? table
function M.reject(bufnr, diff)
	bufnr = bufnr or api.nvim_get_current_buf()
	diff = diff or diff_under_cursor(bufnr)
	if not diff or not diff.ui then
		return ui.say("[ducktape] no diff here", vim.log.levels.WARN)
	end
	require("codecompanion.diff.keymaps").reject_change.callback(diff.ui)
end

---Settle every diff in one buffer.
---
---Both directions are safe to do in bulk. Accepting only clears the diff's decorations — the
---reply is already in the buffer by then — so nothing shifts under the diffs not yet reached.
---Rejecting does write, but each restore resolves its own extmarks when it runs, so the lines a
---later diff puts back are the ones it currently owns rather than where it started.
---@param bufnr number
---@param action "accept"|"reject"
---@return number settled
local function settle_all(bufnr, action)
	-- Snapshot first: settling one diff mutates the table we would otherwise be walking.
	local pending = vim.tbl_values(buf_state(bufnr).diffs)
	local settled = 0
	for _, diff in ipairs(pending) do
		-- A diff already resolved in the buffer is refused by codecompanion rather than applied
		-- twice, so counting it would misreport what the buffer now holds.
		if diff.ui and not diff.ui.resolved then
			if action == "accept" then
				M.accept(bufnr, diff)
			else
				M.reject(bufnr, diff)
			end
			settled = settled + 1
		end
	end
	return settled
end

---@param action "accept"|"reject"
local function settle_all_here(action)
	local bufnr = api.nvim_get_current_buf()
	local settled = settle_all(bufnr, action)
	if settled > 0 then
		return ui.say(("[ducktape] %s %d diff(s)"):format(action == "accept" and "accepted" or "rejected", settled))
	end

	-- Same distinction M.cancel draws: a diff belongs to the buffer it was made in, so "none here"
	-- and "none anywhere" are different answers and only one of them means there is nothing to do.
	local elsewhere = 0
	for _, entry in ipairs(M.list()) do
		if entry.kind == "diff" and entry.bufnr ~= bufnr then
			elsewhere = elsewhere + 1
		end
	end
	if elsewhere > 0 then
		return ui.say(
			("[ducktape] no diffs waiting in this buffer — %d in others, <leader>cL settles those"):format(elsewhere),
			vim.log.levels.INFO
		)
	end
	ui.say("[ducktape] no diffs waiting in this buffer", vim.log.levels.INFO)
end

---Accept every diff in the current buffer. The bulk form of g2, scoped like `<leader>cX`.
function M.accept_all()
	settle_all_here("accept")
end

---Reject every diff in the current buffer, restoring each one's original lines.
---
---No key of its own: `<leader>cX` does this and cancels what is still running, and wanting one
---without the other turned out to be too fine a distinction to spend a key on. Kept because it is
---the honest half of the pair and `settle_all` needs the same reporting either way.
function M.reject_all()
	settle_all_here("reject")
end

---@param bufnr number
---@param direction "next"|"previous"
function M.hunk(bufnr, direction)
	local diff = diff_under_cursor(bufnr)
	if not diff then
		return ui.say("[ducktape] no diff here", vim.log.levels.WARN)
	end
	local keymaps = require("codecompanion.diff.keymaps")
	local handler = direction == "next" and keymaps.next_hunk or keymaps.previous_hunk
	-- The handler reads the cursor out of diff_ui.winnr, captured when the diff was created and
	-- never revalidated, so a since-closed window would raise instead of reporting.
	if not (diff.ui and diff.ui.winnr and api.nvim_win_is_valid(diff.ui.winnr)) then
		return ui.say("[ducktape] the window this diff was rendered in is gone", vim.log.levels.WARN)
	end
	handler.callback(diff.ui)
end

---Discard the inline edit under the cursor: cancel it if it is still running, reject it if it has
---already answered.
---
---One key for "make this go away" whichever half of its life the edit is in. Being told to press
---something else instead is no use — the intent is the same either way, and which state the thing
---is in is exactly what is easy to lose track of while it changes on its own.
function M.cancel()
	local bufnr = api.nvim_get_current_buf()
	local st = buf_state(bufnr)
	local row = api.nvim_win_get_cursor(0)[1] - 1

	for _, req in pairs(st.requests) do
		local s0, e0 = resolve(bufnr, req.marks)
		if s0 and row >= s0 and row <= math.max(s0, e0) then
			cancel_request(req)
			return ui.say("[ducktape] cancelled 1 request(s)")
		end
	end

	-- A finished one, where rejecting is what cancelling means. diff_under_cursor also answers
	-- with the only pending diff when the cursor is outside every one, the same as g2/g3 — the
	-- intent is unambiguous when there is nothing else it could mean.
	local diff = diff_under_cursor(bufnr)
	if diff and diff.ui then
		M.reject(bufnr, diff)
		return ui.say("[ducktape] rejected the finished edit here")
	end

	-- A reply that arrived but could not be applied. Discarding is all there is to do to one of
	-- these from the buffer; reading and re-asking live in the list.
	for _, entry in pairs(st.waiting) do
		local ws, we = waiting_region(entry)
		if ws and row >= ws and row < math.max(we, ws + 1) then
			forget_waiting(entry)
			return ui.say(
				("[ducktape] dismissed the %s reply here"):format(entry.kind == "prose" and "unapplied" or "failed")
			)
		end
	end

	-- Not over an inline request — if we're in a chat buffer, stop the agent
	local ft = vim.bo[bufnr].filetype
	if ft == "codecompanion" then
		return require("ducktape.chat").stop()
	end
	-- Requests run against the buffer they were started in, not the one on screen, so
	-- "nothing here" and "nothing anywhere" are different answers and only one of them
	-- means there is nothing to do.
	local elsewhere = 0
	for _, entry in ipairs(M.list()) do
		if entry.bufnr ~= bufnr then
			elsewhere = elsewhere + 1
		end
	end
	if elsewhere > 0 then
		return ui.say(
			("[ducktape] nothing in play in this buffer — %d elsewhere, <leader>cL lists them"):format(elsewhere),
			vim.log.levels.INFO
		)
	end
	return ui.say("[ducktape] nothing in flight in this buffer", vim.log.levels.INFO)
end

---Discard everything this buffer has in play: cancel every request still running, reject every diff
---that has answered, and dismiss every reply that was never read. The bulk form of `<leader>cx`, and
---the counterpart to `<leader>cA`, which keeps the answers instead.
function M.cancel_all()
	local bufnr = api.nvim_get_current_buf()
	local requests = vim.tbl_values(buf_state(bufnr).requests)
	for _, req in ipairs(requests) do
		cancel_request(req)
	end
	local rejected = settle_all(bufnr, "reject")

	-- Unread replies included: this is the key for being done with all of it, and one that left rows
	-- behind would need a second key to finish the job.
	local waiting = vim.tbl_values(buf_state(bufnr).waiting)
	for _, entry in ipairs(waiting) do
		forget_waiting(entry)
	end

	local said = {}
	if #requests > 0 then
		table.insert(said, ("cancelled %d request(s)"):format(#requests))
	end
	if rejected > 0 then
		table.insert(said, ("rejected %d diff(s)"):format(rejected))
	end
	if #waiting > 0 then
		table.insert(said, ("dismissed %d unread repl%s"):format(#waiting, #waiting == 1 and "y" or "ies"))
	end
	if #said == 0 then
		return ui.say("[ducktape] nothing in play in this buffer", vim.log.levels.INFO)
	end
	ui.say("[ducktape] " .. table.concat(said, ", "))
end

---Cancel one request, wherever it came from. What the list acts on; `M.cancel` and
---`M.cancel_all` reach the same code by way of the cursor and the buffer.
---@param req table An entry's `request` field, from M.list
function M.cancel_request(req)
	cancel_request(req)
end

---Everything inline has in play right now, across every buffer: requests still running, and
---finished edits whose diff nobody has decided on yet.
---
---Ordered by the request each entry came out of rather than by buffer or state, so an entry
---holds its place for as long as it exists — a list that reordered itself as requests finished
---would move rows under the cursor of whoever was reading them.
---@return { kind: "request"|"diff", order: number, bufnr: number, file: string, provider: string, model: string|nil, instruction: string|nil, activity: string|nil, deep: boolean|nil, since: number, hunks: number|nil, request: table|nil, diff: table|nil, resolve: fun(): number|nil, number|nil }[]
function M.list()
	local now = vim.uv.now()
	local out = {}

	for bufnr, st in pairs(buffers) do
		if api.nvim_buf_is_valid(bufnr) then
			local name = api.nvim_buf_get_name(bufnr)
			local file = name ~= "" and vim.fn.fnamemodify(name, ":.") or "[no name]"

			for _, req in pairs(st.requests) do
				table.insert(out, {
					kind = "request",
					order = req.id,
					bufnr = bufnr,
					file = file,
					provider = req.provider,
					model = req.model,
					instruction = req.instruction,
					activity = req.activity,
					deep = req.deep,
					since = now - (req.started or now),
					request = req,
					-- A closure rather than a resolved pair: marks move as the buffer is edited,
					-- and the caller acting on an entry wants where the range is now, not where it
					-- was when the list was last drawn.
					resolve = function()
						return resolve(bufnr, req.marks)
					end,
				})
			end

			for _, entry in pairs(st.waiting) do
				table.insert(out, {
					kind = entry.kind,
					order = entry.request_id or entry.id,
					bufnr = bufnr,
					file = file,
					provider = entry.provider,
					model = entry.model,
					instruction = entry.instruction,
					deep = entry.deep,
					since = now - (entry.finished or now),
					waiting = entry,
					resolve = function()
						return waiting_region(entry)
					end,
				})
			end

			for _, diff in pairs(st.diffs) do
				local hunks = diff.ui and diff.ui.diff and diff.ui.diff.hunks
				table.insert(out, {
					kind = "diff",
					order = diff.request_id or diff.id,
					bufnr = bufnr,
					file = file,
					provider = diff.provider,
					model = diff.model,
					instruction = diff.instruction,
					since = now - (diff.finished or now),
					hunks = hunks and #hunks or nil,
					diff = diff,
					resolve = function()
						return diff_region(diff)
					end,
				})
			end
		end
	end

	table.sort(out, function(a, b)
		return a.order < b.order
	end)
	return out
end

---How much is in play, without building the whole list. What the statusline reads, so it is called
---on every redraw of every window and does no allocation beyond the table it returns.
---@return { running: number, review: number, answered: number, failed: number, total: number }
function M.counts()
	local out = { running = 0, review = 0, answered = 0, failed = 0, total = 0 }
	for bufnr, st in pairs(buffers) do
		if api.nvim_buf_is_valid(bufnr) then
			for _ in pairs(st.requests) do
				out.running = out.running + 1
			end
			for _ in pairs(st.diffs) do
				out.review = out.review + 1
			end
			for _, entry in pairs(st.waiting) do
				if entry.kind == "prose" then
					out.answered = out.answered + 1
				else
					out.failed = out.failed + 1
				end
			end
		end
	end
	out.total = out.running + out.review + out.answered + out.failed
	return out
end

---Open the reply itself. The float takes focus, which is right here and only here: it is opened
---because the user asked for it, not because something arrived.
---@param entry table An entry's `waiting` field, from M.list
function M.read(entry)
	local s0 = waiting_region(entry)
	ui.message({
		bufnr = entry.bufnr,
		row = s0 or 0,
		title = entry.title,
		text = entry.text,
		on_confirm = function()
			if not api.nvim_buf_is_valid(entry.bufnr) then
				return ui.say("[ducktape] source buffer was closed — cannot open chat", vim.log.levels.WARN)
			end
			require("ducktape.chat").open_with_context({
				messages = {
					{
						role = "user",
						content = ("[ducktape (inline)] %s\n\n%s"):format(
							entry.instruction,
							table.concat(entry.selection or {}, "\n")
						),
					},
					{ role = "llm", content = entry.text },
				},
			})
		end,
	})
end

---Take the reply into a chat, without reading it in the float first.
---@param entry table
function M.to_chat(entry)
	if not api.nvim_buf_is_valid(entry.bufnr) then
		return ui.say("[ducktape] source buffer was closed — cannot open chat", vim.log.levels.WARN)
	end
	require("ducktape.chat").open_with_context({
		messages = {
			{
				role = "user",
				content = ("[ducktape (inline)] %s\n\n%s"):format(
					entry.instruction,
					table.concat(entry.selection or {}, "\n")
				),
			},
			{ role = "llm", content = entry.text },
		},
	})
	forget_waiting(entry)
end

---Get rid of whatever is on these lines and ask the same thing again.
---
---Works on anything in the list, which is what makes it worth a key of its own: a diff that came
---back wrong is rejected first, a request still running is cancelled, and a reply that came to
---nothing is dismissed. In every case the lines end up as they were before the request, which is
---what the new prompt has to be built from.
---
---Goes out with whatever provider and model are selected *now* rather than the one that answered.
---A wrong answer, a refusal and a failure are all common reasons to switch model, and re-sending to
---the thing that just got it wrong is rarely what is wanted.
---@param entry table An entry from M.list
---@param opts { instruction: string } The instruction, possibly reworded in the prompt float
---@return boolean started
function M.ask_again(entry, opts)
	local bufnr = entry.bufnr
	if not api.nvim_buf_is_valid(bufnr) then
		ui.say("[ducktape] that buffer is gone", vim.log.levels.WARN)
		return false
	end
	local st = buf_state(bufnr)
	local instruction, deep = opts.instruction, entry.deep

	local function gone()
		ui.say("[ducktape] those lines are gone — nothing to ask about", vim.log.levels.WARN)
		return false
	end

	if entry.kind == "request" then
		local req = entry.request
		if not st.requests[req.id] then
			ui.say(
				"[ducktape] that one finished while you were typing — ask again from the list",
				vim.log.levels.INFO
			)
			return false
		end
		local s0, e0 = resolve(bufnr, req.marks)
		if not s0 then
			return gone()
		end
		cancel_request(req)
		return M.submit({
			bufnr = bufnr,
			range = { s0 = s0, e0 = e0, has_selection = e0 > s0 },
			instruction = instruction,
			deep = deep,
		}) ~= nil
	end

	if entry.kind == "diff" then
		local diff = entry.diff
		if not (st.diffs[diff.id] and diff.ui and not diff.ui.resolved) then
			ui.say("[ducktape] that one was settled already — ask again from the list", vim.log.levels.INFO)
			return false
		end
		local s0 = diff_region(diff)
		if not s0 then
			return gone()
		end
		-- The region the *original* lines will occupy once they are back, not the one the reply
		-- occupies now. The restore replaces the diff's region in place, so the start row holds.
		local span = #diff.original
		M.reject(bufnr, diff)
		-- Behind the queued restore, so the prompt is built from the lines that came back rather
		-- than from the reply being thrown away. vim.schedule is FIFO and the flush was booked
		-- during the reject above, so this lands after it.
		vim.schedule(function()
			M.submit({
				bufnr = bufnr,
				range = { s0 = s0, e0 = s0 + span, has_selection = span > 0 },
				instruction = instruction,
				deep = deep,
			})
		end)
		return true
	end

	local waiting = entry.waiting
	if not st.waiting[waiting.id] then
		ui.say("[ducktape] that reply is no longer waiting", vim.log.levels.INFO)
		return false
	end
	local s0, e0 = waiting_region(waiting)
	if not s0 then
		forget_waiting(waiting)
		return gone()
	end
	-- Dropped first, so the range it was holding is free for the request that replaces it.
	forget_waiting(waiting)
	return M.submit({
		bufnr = bufnr,
		range = { s0 = s0, e0 = e0, has_selection = e0 > s0 },
		instruction = instruction,
		deep = deep,
	}) ~= nil
end

---Open the prompt pre-filled with what was asked last time, then ask again.
---
---Pre-filled rather than blank so `<CR>` alone means "exactly that again", and asked *before*
---anything is settled so backing out of the prompt leaves everything as it was.
---@param entry table An entry from M.list
function M.ask_again_prompt(entry)
	local file = entry.file
	input.open({
		title = (" Ask again — %s "):format(file),
		initial_content = entry.instruction,
		on_submit = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			if M.ask_again(entry, { instruction = vim.trim(text) }) then
				ui.say(("[ducktape] asked again about %s"):format(file))
			end
		end,
	})
end

---Ask again about whatever the cursor is on, without going through the list.
function M.ask_again_here()
	local bufnr = api.nvim_get_current_buf()
	local row = api.nvim_win_get_cursor(0)[1] - 1

	local under, only
	for _, entry in ipairs(M.list()) do
		if entry.bufnr == bufnr then
			local s0, e0 = entry.resolve()
			if s0 and row >= s0 and row < math.max(e0 or s0 + 1, s0 + 1) then
				under = entry
				break
			end
			-- The same courtesy g2/g3 extend: with one thing in the buffer there is nothing else
			-- the key could have meant.
			only = only == nil and entry or false
		end
	end

	local entry = under or only or nil
	if not entry then
		return ui.say("[ducktape] nothing here to ask again about", vim.log.levels.WARN)
	end
	M.ask_again_prompt(entry)
end

---Throw a waiting reply away.
---@param entry table
function M.dismiss(entry)
	forget_waiting(entry)
end

---Switch the inline backend and model. Shared with chat — see ducktape.pick.
function M.pick()
	require("ducktape.pick").open("inline")
end

---How many requests and diffs this buffer is carrying. Handy when checking by hand whether
---something is still in flight or a diff was left behind.
---@param bufnr number
---@return { requests: number, diffs: number, waiting: number }
function M.stats(bufnr)
	local st = buf_state(bufnr)
	return { requests = count(st.requests), diffs = count(st.diffs), waiting = count(st.waiting) }
end

return M
