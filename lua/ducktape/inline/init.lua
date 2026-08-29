-- Inline editing: request, diff, accept/reject, concurrency, cancellation.
--
-- The model only supplies code; nvim decides placement.

local api = vim.api

local input = require("codecompanion.interactions.shared.input")
local parse = require("ducktape.inline.parse")
local providers = require("ducktape.providers")
local ui = require("ducktape.ui")

-- Messages name keys, so they read from the same table that binds them. Resolved per call so a
-- remapped keymap is still described correctly.
---@param action string
---@return string
local function K(action)
	return require("ducktape.keys").label(action)
end

local M = {}

-- Separate from ducktape.ui's namespace so clearing progress text cannot disturb an anchor.
local ANCHOR = api.nvim_create_namespace("ducktape_inline_anchor")
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

---@return { s0: number, e0: number, has_selection: boolean }
local function capture_range()
	local mode = vim.fn.mode()
	if mode == "v" or mode == "V" or mode == "\22" then
		-- Leave visual first so the '< and '> marks are set.
		vim.cmd("normal! \27")
		return { s0 = vim.fn.line("'<") - 1, e0 = vim.fn.line("'>"), has_selection = true }
	end

	-- With no selection the cursor's own line is treated as selected. An empty range would leave
	-- the original line next to the inserted answer; M.submit still accepts an empty range for
	-- callers that genuinely mean to insert.
	local row = api.nvim_win_get_cursor(0)[1] - 1
	return { s0 = row, e0 = row + 1, has_selection = true }
end

---A row and column nvim_buf_set_extmark will accept, plus whether the row had to be moved.
---An exclusive end row equal to the line count has no line to sit on, so it becomes the end of
---the last line. The boolean distinguishes that from a mark genuinely at the start of the last
---line, which a column alone cannot do when that line is empty.
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

---Anchor a range with extmarks so edits elsewhere shift it correctly.
---Both gravities point inwards: the pair must refuse to grow over neighbouring edits. Outward
---gravities were measured to creep onto adjacent lines when those lines were replaced.
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

	-- Disappear if the whole range is deleted. Collapsing start onto finish is not enough: a
	-- user who deletes the range and types a replacement leaves the pair spanning unrelated text.
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
	-- The mark was clamped to the last line; line-wise, the exclusive end is the row after it.
	local e0 = marks.ends_at_eof and (e[1] + 1) or e[1]
	return s[1], math.max(s[1], e0)
end

local function drop_marks(bufnr, marks)
	if not (marks and api.nvim_buf_is_valid(bufnr)) then
		return
	end
	for _, id in pairs(marks) do
		-- `marks` also carries the `ends_at_eof` flag.
		if type(id) == "number" then
			pcall(api.nvim_buf_del_extmark, bufnr, ANCHOR, id)
		end
	end
end

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
---@param bufnr number
---@param range { s0: number, e0: number }
---@return { kind: "request"|"diff", s0: number, e0: number, instruction: string|nil }|nil
local function held_by(bufnr, range)
	-- An insertion point covers the row it sits on, because a replacement that takes that line
	-- takes the seam with it.
	local lo, hi = range.s0, math.max(range.e0, range.s0 + 1)
	local st = buf_state(bufnr)
	local held

	local function consider(kind, order, item)
		local s0, e0 = resolve(bufnr, item.marks)
		if not s0 or lo >= math.max(e0, s0 + 1) or s0 >= hi then
			return
		end
		-- Prefer the oldest, so the answer does not depend on hash order when two overlap.
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
			("[ducktape] %s already has an inline request in flight%s — " .. K("cancel") .. " cancels it, " .. K(
				"inline_list"
			) .. " lists them all"):format(span(held.s0, held.e0), what),
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

-- The prompt contract lives in config; it is the biggest lever on what comes back.
---@return table
local function prompts()
	return require("ducktape.config").get().inline.prompt
end

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
	local cfg = require("ducktape.config").get().inline
	local prompt = prompts()
	local context_lines = cfg.context_lines
	local total = api.nvim_buf_line_count(bufnr)
	local filetype = vim.bo[bufnr].filetype
	local path = vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":.")

	local selection = api.nvim_buf_get_lines(bufnr, range.s0, range.e0, false)
	local before = api.nvim_buf_get_lines(bufnr, math.max(0, range.s0 - context_lines), range.s0, false)
	local after = api.nvim_buf_get_lines(bufnr, range.e0, math.min(total, range.e0 + context_lines), false)

	local head = { prompt.contract, deep and prompt.deep or prompt.no_tools }
	if not range.has_selection then
		table.insert(head, prompt.insert)
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

	local diagnostics = cfg.diagnostics and diagnostics_for(bufnr, range) or ""
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
		selection = selection,
	}
end

---Where a diff's replacement currently sits.
---Use the start mark, not `resolve`: a diff's end mark grows over DiffUI deletion rows and
---never shrinks back, so the reply's own line count is the only reliable measure.
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
	-- Outside every diff, but if only one is pending the intent is unambiguous.
	return only or nil
end

local function bind_diff_keys(bufnr)
	local shared = require("codecompanion.config").interactions.shared.keymaps

	-- DiffUI binds these buffer-locally and dispatches by diff_ui.winnr, so concurrent diffs
	-- clobber each other's {/} maps. Delete them and dispatch by cursor position instead.
	pcall(vim.keymap.del, "n", shared.next_hunk.modes.n, { buffer = bufnr })
	pcall(vim.keymap.del, "n", shared.previous_hunk.modes.n, { buffer = bufnr })
	-- Literal fallbacks in case the shared-keymap structure changes upstream.
	pcall(vim.keymap.del, "n", "}", { buffer = bufnr })
	pcall(vim.keymap.del, "n", "{", { buffer = bufnr })

	local function on(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = bufnr, desc = desc, nowait = true })
	end

	local keys = require("ducktape.keys")
	on(keys.lhs("diff_accept"), function()
		M.accept(bufnr)
	end, keys.desc("diff_accept"))
	on(keys.lhs("diff_reject"), function()
		M.reject(bufnr)
	end, keys.desc("diff_reject"))
	on(keys.lhs("diff_next_hunk"), function()
		M.hunk(bufnr, "next")
	end, keys.desc("diff_next_hunk"))
	on(keys.lhs("diff_prev_hunk"), function()
		M.hunk(bufnr, "previous")
	end, keys.desc("diff_prev_hunk"))
end

-- Defined before `guarded` but called from registry code below it; the lock is released once
-- the last guarded request in a buffer lets go.
local unlock_undo

local function unbind_diff_keys(bufnr)
	local keys = require("ducktape.keys")
	for _, action in ipairs({ "diff_accept", "diff_reject", "diff_next_hunk", "diff_prev_hunk" }) do
		pcall(vim.keymap.del, "n", keys.lhs(action), { buffer = bufnr })
	end
end

local function forget_request(req)
	local st = buf_state(req.bufnr)
	st.requests[req.id] = nil
	if req.progress then
		req.progress.stop()
	end
	unlock_undo(req.bufnr)
end

---@param req table
local function cancel_request(req)
	if req.handle then
		pcall(req.handle.cancel)
	end
	forget_request(req)
	drop_marks(req.bufnr, req.marks)
end

-- Forward declaration: watch_buffer clears waiting replies, and the helpers below need it.
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
	-- resolve_diff clears every shared keymap in the buffer, so rebind any remaining diffs.
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

-- The prompt and answer both refer to the exact range lines, so an edit landing there while
-- the request is in flight means a reply that silently discards whatever the user typed. The
-- guard tracks rows arithmetically from on_bytes, because no extmark configuration survives
-- edits to a one-line range: left gravity drags up, right gravity pushes past.

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

---Say something about a guarded range late enough to be read.
---Scheduled from a timer, not `vim.schedule`: these messages arrive around a mode change, and
-- the redraw that ends one wipes the command line before a scheduled callback runs.
---@param msg string
---@param opts? { history?: boolean }
local function announce(msg, opts)
	vim.defer_fn(function()
		ui.say(msg, vim.log.levels.WARN, opts)
	end, 10)
end

-- What the user tried, and what to say about it. The instruction is omitted: the range label
-- is already visible, and the key to press is the only thing not shown elsewhere.
local HELD = {
	refused = function()
		return "[ducktape] those lines are held by an inline request — " .. K("cancel") .. " cancels it"
	end,
	reverted = function()
		return "[ducktape] put those lines back — " .. K("cancel") .. " cancels the inline request holding them"
	end,
	undo = function()
		return "[ducktape] undo is held off while an inline request runs here — " .. K("cancel") .. " cancels it"
	end,
}

---@param req table
---@param why? "refused"|"reverted"|"undo" Defaults to refused
local function say_protected(req, why)
	-- Echo every attempt, but record to history at most once every 2s.
	local now = vim.uv.now()
	local record = req.warned == nil or now - req.warned >= 2000
	if record then
		req.warned = now
	end
	announce(HELD[why or "refused"](), { history = record })
end

local UNDO_KEYS = { "u", "U", "<C-r>", "g-", "g+" }

-- Compared as keycodes: nvim_buf_get_keymap reports `<C-R>`, so `<C-r>` would not match.
local UNDO_CODES = {}
for _, lhs in ipairs(UNDO_KEYS) do
	UNDO_CODES[vim.keycode(lhs)] = true
end

---Hold undo off while a request is working on lines in this buffer.
---Undo can walk back through changes made before the request existed, taking the whole run
---with it; the guard cancels the request in that case. Any buffer-local mapping already on
---those keys is restored afterwards.
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
		end, { buffer = bufnr, desc = "ducktape: held off while an inline request runs" })
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

---Put a protected range back the way its request left it.
---@param bufnr number
---@param req table
local function restore_guard(bufnr, req)
	local st = buf_state(bufnr)
	local total = api.nvim_buf_line_count(bufnr)
	local at = math.max(math.min(req.guard_row, total), 0)
	st.restoring = true
	-- Joined onto the edit it undoes so the pair is one undo step; refused right after an undo.
	pcall(vim.cmd, "undojoin")
	pcall(api.nvim_buf_set_lines, bufnr, at, math.min(at + req.guard_span, total), false, req.guard)
	st.restoring = false

	req.guard_row, req.guard_span = at, #req.guard
	-- The same edit mangled the anchor marks, so re-anchor from the row the guard knows.
	drop_marks(bufnr, req.marks)
	req.marks = anchor(bufnr, { s0 = at, e0 = at + #req.guard })

	say_protected(req, "reverted")
	if vim.fn.mode():find("^i") then
		vim.cmd("stopinsert")
	end
end

---Apply one reported change to every guarded range.
---Pure arithmetic, because this runs inside on_bytes, which holds textlock.
---@param bufnr number
---@param sr number Row the change starts on
---@param sc number Column it starts at
---@param old_rows number Rows the replaced text spanned, relative to sr
---@param old_cols number Column the replaced text ended at
---@param new_rows number Rows the new text spans, relative to sr
local function track_change(bufnr, sr, sc, old_rows, old_cols, new_rows)
	local delta = new_rows - old_rows

	-- Which existing rows this change rewrote. A pure insertion (old offsets zero) only rewrites
	-- a row when it is past column zero on that row; otherwise it sits between two lines.
	local from, to
	if old_rows == 0 and old_cols == 0 then
		if sc > 0 then
			from, to = sr, sr
		end
	else
		-- An end column of zero means the change stopped at the start of that row.
		to = sr + old_rows - (old_cols == 0 and 1 or 0)
		from, to = sr, math.max(to, sr)
	end

	for _, req in ipairs(guarded(bufnr)) do
		local g, span = req.guard_row, req.guard_span
		if not from then
			-- Insertion between lines.
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
				-- The change reached outside the range; only the range's own former text is known.
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
			-- Last chance to name the instruction, since the request is gone.
			announce(
				("[ducktape] your change spanned an inline request's lines — cancelled it (%s)"):format(
					ui.ellipsise(req.instruction or "?", 20)
				)
			)
		elseif req.violated then
			req.violated = false
			-- Avoid rewriting lines that already match, which would cost an undo step and a warning.
			local now = api.nvim_buf_get_lines(bufnr, req.guard_row, req.guard_row + req.guard_span, false)
			if not vim.deep_equal(now, req.guard) then
				restore_guard(bufnr, req)
			else
				req.guard_span = #req.guard
			end
		end
	end
end

---Watch a buffer's text so an edit on a protected range can be reverted. Attached with the
---first guarded request and detached with the last.
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
			-- Track immediately, but defer the revert because on_bytes holds textlock.
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

local restores, flush_booked = {}, false

---Put rejected diffs' original lines back once every rejection in this tick has been seen.
---Batched and bottom-up: DiffUI deletes a spacer line in clear() after this callback, so
---measuring before that would be one row out; writing bottom-up prevents one restore from
---shifting another's region.
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
			-- Check against the reply before overwriting it. This catches a bad derivation or the
			-- user having edited the diff themselves; leaving the reply is the safer failure.
			local now = api.nvim_buf_get_lines(r.bufnr, r.s0, r.e0, false)
			if vim.deep_equal(now, r.diff.replacement) then
				-- Only this diff's own region; a whole-buffer restore corrupts concurrent requests.
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

---@param bufnr number
local function watch_buffer(bufnr)
	local st = buf_state(bufnr)
	if st.augroup then
		return
	end
	st.augroup = api.nvim_create_augroup("DucktapeInlineBuf" .. bufnr, { clear = true })

	-- Refusing insert mode outright is cheaper and less startling than typing and reverting.
	api.nvim_create_autocmd("InsertEnter", {
		group = st.augroup,
		buffer = bufnr,
		callback = function()
			local req = guard_at(bufnr, api.nvim_win_get_cursor(0)[1] - 1)
			if req then
				-- stopinsert from inside InsertEnter does nothing; schedule it.
				vim.schedule(function()
					vim.cmd("stopinsert")
				end)
				say_protected(req)
			end
		end,
	})

	local function reject_pending()
		-- Snapshot first: rejecting mutates st.diffs while we walk it.
		for _, diff in ipairs(vim.tbl_values(st.diffs)) do
			M.reject(bufnr, diff)
		end
	end

	api.nvim_create_autocmd("WinClosed", {
		group = st.augroup,
		buffer = bufnr,
		callback = function(args)
			-- WinClosed means "a window showing this buffer closed", not "the buffer went away".
			-- Check after a tick: a fast split/close cycle can fire before the new window exists.
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
			-- A reply waiting on a gone buffer has nowhere to land.
			for _, entry in ipairs(vim.tbl_values(st.waiting)) do
				forget_waiting(entry)
			end
			-- A request whose buffer is gone is paying to finish into a void.
			for _, req in ipairs(vim.tbl_values(st.requests)) do
				cancel_request(req)
			end
			-- Both the registry entry and augroup would otherwise accumulate for the session.
			pcall(api.nvim_del_augroup_by_id, st.augroup)
			buffers[bufnr] = nil
		end,
	})
end

-- Prose and outright failures are registered like pending diffs instead of thrown at the screen.
-- They stay visible where they belong, can be read or re-asked, and nothing takes focus.

local WAITING = {
	prose = { sign = "◆", hl = "DucktapeListReady", label = "answered" },
	failed = { sign = "✖", hl = "DucktapeListDead", label = "failed" },
}

---Where a waiting reply's lines are.
---@param entry table
---@return number|nil s0, number|nil e0
local function waiting_region(entry)
	if not entry.marks then
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
		request_id = req.id,
		kind = kind,
		bufnr = bufnr,
		-- Re-anchored: the request's marks are dropped as each request ends, and this outlives it.
		marks = s0 and anchor(bufnr, { s0 = s0, e0 = e0 }) or nil,
		title = opts.title,
		text = opts.text,
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

-- DiffUI scrolls to the first hunk when it renders, which yanks the cursor and recentres the
-- view. Remember cursor position and scroll so both can be put back.

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
			-- Left gravity, so text inserted at the cursor's own row appears below it.
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
				-- Scroll by how far the cursor line moved, so it stays where it was on screen.
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
		-- A model that declines often echoes the selection back inside a fence. Surface the
		-- explanation instead of discarding it.
		if result.preamble then
			wait_on_user(req, "prose", {
				title = ("%s — returned the selection unchanged"):format(req.provider),
				text = result.preamble,
			})
			return ui.say(
				(
					"[ducktape] %s returned the selection unchanged, with an explanation — "
					.. K("inline_list")
					.. " to read it"
				):format(req.provider),
				vim.log.levels.WARN
			)
		end
		return ui.say("[ducktape] the reply matches the buffer — nothing to change", vim.log.levels.INFO)
	end

	-- DiffUI writes the merged view straight into an empty buffer, so the reply would land twice.
	if api.nvim_buf_line_count(bufnr) == 1 and (api.nvim_buf_get_lines(bufnr, 0, 1, true)[1] or "") == "" then
		drop_marks(bufnr, req.marks)
		api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		return ui.say("[ducktape] the buffer was empty, so the reply was inserted directly — u to undo")
	end

	-- DiffUI falls back to the current window when the target buffer is not on screen, which
	-- would yank the user's new window out from under them.
	if vim.fn.bufwinid(bufnr) == -1 then
		local name = vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t"):gsub("^$", "the target buffer")
		wait_on_user(req, "failed", {
			title = ("%s — could not be applied"):format(req.provider),
			text = ("%s answered, but %s was not on screen, so there was nowhere to render the diff without taking over the window you had moved to.\n\nBring the buffer back into view and press e in the inline list to ask again."):format(
				req.provider,
				name
			),
		})
		drop_marks(bufnr, req.marks)
		return ui.say(
			(
				"[ducktape] %s answered, but %s is not on screen — nothing was applied, "
				.. K("inline_list")
				.. " to retry"
			):format(req.provider, name),
			vim.log.levels.WARN
		)
	end

	local original = vim.list_slice(from_lines, s0 + 1, e0)

	-- Marks span exactly the new content once the diff is applied: start holds against insertion
	-- and finish is pushed past the replacement.
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
		-- Keep the list entry where it was: the row changes state in place rather than jumping.
		request_id = req.id,
		bufnr = bufnr,
		marks = marks,
		original = original,
		-- What the diff put there. The end mark grows over DiffUI deletions, so this is the only
		-- reliable measure of the region's extent.
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
		-- Abbreviate <leader> in the banner; the window bar has no room to spell both out.
		banner = ("%s Accept | %s Reject | %s/%s Hunk"):format(
			K("diff_accept"),
			K("diff_reject"),
			K("diff_next_hunk"),
			(K("diff_prev_hunk"):gsub("^<[lL]eader>", ""))
		),
		-- Own g2/g3 so concurrent diffs are possible.
		skip_default_keymaps = true,
		keymaps = {
			on_accept = function()
				forget_diff(diff)
			end,
			on_reject = function()
				-- Defer past resolve_diff's cleanup. DiffUI inserts a spacer line for a hunk at row 0
				-- and deletes it in clear(); restoring first swallowed one of our lines.
				queue_restore(diff)
				forget_diff(diff, true)
			end,
		},
	})

	drop_marks(bufnr, req.marks)
	buf_state(bufnr).diffs[diff.id] = diff
	watch_buffer(bufnr)
	bind_diff_keys(bufnr)

	-- Run after DiffUI's own scheduled scroll.
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

	-- filetype and the original selection keep the parser from rejecting a correct reply.
	local result = parse.parse(reply, { filetype = vim.bo[req.bufnr].filetype, selection = req.selection })

	if result.kind == "code" then
		return show_diff(req, result)
	end

	if result.kind == "noop" then
		drop_marks(req.bufnr, req.marks)
		return ui.say(("[ducktape] %s"):format(result.reason), vim.log.levels.WARN)
	end

	-- Leave prose for the user to come to, rather than opening a float over whatever they are doing.
	wait_on_user(req, "prose", {
		title = ("%s — %s"):format(req.provider, result.reason),
		text = result.text,
	})
	drop_marks(req.bufnr, req.marks)
	ui.say(
		("[ducktape] %s %s — " .. K("inline_list") .. " to read it"):format(req.provider, result.reason),
		vim.log.levels.WARN
	)
end

---Start one inline request. Separated from M.run so it can be driven without the input float.
---@param opts { bufnr: number, range: table, instruction: string, deep?: boolean, timeout?: number }
---@return table|nil req
function M.submit(opts)
	local bufnr = opts.bufnr
	if not api.nvim_buf_is_valid(bufnr) then
		return nil
	end

	local selection = providers.current("inline")
	local transport = providers.transport(selection.provider, opts.deep or false)

	-- Public entry point: refuse deep if the transport cannot read, or it would silently run shallow.
	if opts.deep and not providers.transports[transport].read then
		ui.say(
			(
				"[ducktape] %s uses the %s transport, which cannot read the repository — "
				.. K("inline_pick")
				.. " to switch"
			):format(selection.provider, transport),
			vim.log.levels.WARN
		)
		return nil
	end

	-- Checked here as well as in M.run: another request can start over the same lines while the
	-- prompt float is open.
	if blocked(bufnr, opts.range) then
		return nil
	end

	-- A waiting reply is superseded by asking again; it does not hold the range.
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
		instruction = opts.instruction,
		-- uv.now() so the list counts seconds; os.time() would sit on "0s" for up to a second.
		started = vim.uv.now(),
		marks = anchor(bufnr, opts.range),
	}

	local built = build_prompt(bufnr, opts.range, opts.instruction, opts.deep or false)
	req.selection = built.selection
	-- The lines as the request saw them, so an edit landing on top can be put back.
	if opts.range.e0 > opts.range.s0 then
		req.guard = built.selection
		req.guard_row, req.guard_span = opts.range.s0, #built.selection
	end
	req.progress = ui.progress(bufnr, function()
		return resolve(bufnr, req.marks)
	end, ("%s · %s · %s"):format(selection.provider, tostring(selection.opts.model), opts.instruction))

	local module = transport == "http" and "ducktape.inline.http"
		or transport == "relay" and "ducktape.inline.relay"
		or "ducktape.inline.acp"

	-- Register before sending. A transport can fail synchronously (no opencode on PATH, etc.);
	-- registering afterwards would leave a dead request in the registry with no way to clear it.
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
			-- Keep the row anchored so `e` in the list re-asks with the same instruction.
			wait_on_user(req, "failed", { title = ("%s — failed"):format(selection.provider), text = msg })
			drop_marks(bufnr, req.marks)
			ui.say(("[ducktape] %s — " .. K("inline_list") .. " to retry"):format(msg), vim.log.levels.ERROR)
		end,
		on_tool = function(name)
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

	-- Check before the prompt; being told the lines are taken is no use once an instruction is typed.
	if blocked(bufnr, range) then
		return
	end

	local selection = providers.current("inline")
	local transport = providers.transport(selection.provider, deep)

	if deep and not providers.transports[transport].read then
		return ui.say(
			(
				"[ducktape] "
				.. K("inline_deep")
				.. " needs a transport that can read the repository. %s uses %s, which cannot — "
			):format(selection.provider, transport)
				.. ("it works on claude and on opencode. Switch with %s."):format(K("inline_pick")),
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
---@param bufnr number
---@param action "accept"|"reject"
---@return number settled
local function settle_all(bufnr, action)
	-- Snapshot first: settling one diff mutates the table we would otherwise be walking.
	local pending = vim.tbl_values(buf_state(bufnr).diffs)
	local settled = 0
	for _, diff in ipairs(pending) do
		-- A diff already resolved in the buffer is refused by codecompanion rather than applied twice.
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

	-- A diff belongs to the buffer it was made in, so "none here" and "none anywhere" differ.
	local elsewhere = 0
	for _, entry in ipairs(M.list()) do
		if entry.kind == "diff" and entry.bufnr ~= bufnr then
			elsewhere = elsewhere + 1
		end
	end
	if elsewhere > 0 then
		return ui.say(
			("[ducktape] no diffs waiting in this buffer — %d in others, " .. K("inline_list") .. " settles those"):format(
				elsewhere
			),
			vim.log.levels.INFO
		)
	end
	ui.say("[ducktape] no diffs waiting in this buffer", vim.log.levels.INFO)
end

---Accept every diff in the current buffer. The bulk form of g2.
function M.accept_all()
	settle_all_here("accept")
end

---Reject every diff in the current buffer, restoring each one's original lines.
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
	-- The handler reads diff_ui.winnr captured when the diff was created; a closed window raises.
	if not (diff.ui and diff.ui.winnr and api.nvim_win_is_valid(diff.ui.winnr)) then
		return ui.say("[ducktape] the window this diff was rendered in is gone", vim.log.levels.WARN)
	end
	handler.callback(diff.ui)
end

---Discard the inline edit under the cursor: cancel it if running, reject it if answered.
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

	-- A finished edit: diff_under_cursor also answers with the only pending diff when outside
	-- every one, the same as g2/g3.
	local diff = diff_under_cursor(bufnr)
	if diff and diff.ui then
		M.reject(bufnr, diff)
		return ui.say("[ducktape] rejected the finished edit here")
	end

	-- A reply that arrived but could not be applied.
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
	-- Requests run against the buffer they were started in, so "nothing here" and "nothing
	-- anywhere" are different answers.
	local elsewhere = 0
	for _, entry in ipairs(M.list()) do
		if entry.bufnr ~= bufnr then
			elsewhere = elsewhere + 1
		end
	end
	if elsewhere > 0 then
		return ui.say(
			("[ducktape] nothing in play in this buffer — %d elsewhere, " .. K("inline_list") .. " lists them"):format(
				elsewhere
			),
			vim.log.levels.INFO
		)
	end
	return ui.say("[ducktape] nothing in flight in this buffer", vim.log.levels.INFO)
end

---Discard everything this buffer has in play: cancel every request, reject every diff, dismiss
---every unread reply.
function M.cancel_all()
	local bufnr = api.nvim_get_current_buf()
	local requests = vim.tbl_values(buf_state(bufnr).requests)
	for _, req in ipairs(requests) do
		cancel_request(req)
	end
	local rejected = settle_all(bufnr, "reject")

	-- Unread replies included: this key means "done with all of it".
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

---Cancel one request, wherever it came from.
---@param req table An entry's `request` field, from M.list
function M.cancel_request(req)
	cancel_request(req)
end

---Everything inline has in play right now, across every buffer.
---Ordered by request id so an entry holds its place while the user reads the list.
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
					-- A closure: marks move as the buffer is edited, so callers see the current range.
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

---How much is in play, without building the whole list. Called on every statusline redraw.
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

---Open the reply itself. The float takes focus, which is right here and only here.
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
---@param entry table An entry from M.list
---@param opts { instruction: string }
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
		-- The region the original lines will occupy once they are back.
		local span = #diff.original
		M.reject(bufnr, diff)
		-- Schedule behind the queued restore so the prompt is built from the restored lines.
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
	-- Drop first so the range is free for the request that replaces it.
	forget_waiting(waiting)
	return M.submit({
		bufnr = bufnr,
		range = { s0 = s0, e0 = e0, has_selection = e0 > s0 },
		instruction = instruction,
		deep = deep,
	}) ~= nil
end

---Open the prompt pre-filled with what was asked last time, then ask again.
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
			-- With one thing in the buffer there is nothing else the key could have meant.
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

---Switch the inline backend and model.
function M.pick()
	require("ducktape.pick").open("inline")
end

---@param bufnr number
---@return { requests: number, diffs: number, waiting: number }
function M.stats(bufnr)
	local st = buf_state(bufnr)
	return { requests = count(st.requests), diffs = count(st.diffs), waiting = count(st.waiting) }
end

return M
