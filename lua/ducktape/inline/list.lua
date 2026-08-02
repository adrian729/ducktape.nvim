-- Inline list: every inline edit currently in play — requests still running, and finished ones
-- whose diff nobody has decided on yet — with the keys to settle them from here.
--
-- Deliberately a float rather than a Telescope picker, unlike the chat list. This view redraws
-- itself while it is open, and Picker:refresh re-runs the finder, which re-selects the default
-- row — so a live list would drag the cursor off whatever was being read, ten times a second.
-- There is nothing to fuzzy-search either: a handful of rows at most, and they are picked out by
-- where they are rather than by name. Same float idiom as the status panel and the options step.
--
-- Settling a diff from here is safe because every step of it is buffer-scoped: codecompanion's
-- resolve_diff works on diff_ui.bufnr, DiffUI:close is a no-op for an inline diff, and our own
-- accept/reject handlers address the buffer explicitly. None of it reads the current window, so
-- the target buffer does not even have to be on screen.

local M = {}

local api = vim.api

local ui = require("ducktape.ui")
local render = ui.render
local pad = ui.pad
local ellipsise = ui.ellipsise

---How long a row keeps saying "finished" after its request was seen to land. Long enough to
---catch the eye of someone reading another row, short enough that it is gone by the next look.
local FLASH_MS = 3000

-- Room for "99m59s", which no inline request can reach — every transport times out inside two
-- minutes. Fixed rather than measured across the rows on show: a column sized to the longest
-- value present would widen the moment a request ticked from 9s to 10s, sliding everything to
-- its right by a column while being read.
local ELAPSED_WIDTH = 6

-- Caps, past which the cell is shortened. Both hold long real values — a model name and a path
-- from the repo root — and neither is worth the whole window.
local MODEL_CAP = 30
local LOCATION_CAP = 40

-- Below this there is no point showing the prompt at all: two words and an ellipsis say less
-- than the space they cost.
local MIN_INSTRUCTION = 10

-- How far these two columns can be squeezed before they stop saying anything. A path shortened
-- to 18 still ends in a file name and a line number; a model shortened to 14 still names the
-- provider and enough of the model to tell two of them apart.
local LOCATION_MIN = 18
local MODEL_MIN = 14

local STATE = {
	thinking = { label = "thinking", hl = "DucktapeListStarting" },
	finished = { marker = "◆", label = "finished", hl = "DucktapeListCurrent" },
	review = { marker = "◆", label = "review", hl = "DucktapeListReady" },
	-- A reply that could not be applied: prose, or a refusal. Nothing is pending in the buffer, so
	-- there is nothing to accept — it is read, taken into a chat, re-asked or dismissed.
	prose = { marker = "◆", label = "answered", hl = "DucktapeListReady" },
	failed = { marker = "✖", label = "failed", hl = "DucktapeListDead" },
}

local STATE_WIDTH = 0
for _, state in pairs(STATE) do
	STATE_WIDTH = math.max(STATE_WIDTH, vim.fn.strdisplaywidth(state.label))
end

-- Widest first: the window is at least as wide as whichever of these fits, so the footer is
-- never clipped — nvim truncates a border footer to the window silently.
--
-- Which is also why the full set of keys is not down here any more. Spelling out all six cost 94
-- cells, and since the window is sized to fit its footer, that made every list at least 96 wide —
-- wider than the rows themselves need (67 to 87 for a typical one). The border now carries the
-- three verbs and points at `?` for the rest, the way the chat list does.
local FOOTERS = {
	" a accept · r again · x discard · ? keys ",
	" a · r · x · ? keys ",
	" ? keys ",
}

-- Everything the list can do, and what the markers in it mean. Not on the border, because the
-- border is clipped to the window without warning and this has to be complete.
local HELP = {
	{ header = "This row" },
	{ key = "<CR>", desc = "go to the edit, or read a reply that came to nothing" },
	{ key = "a", desc = "accept — a diff is applied, a reply goes into a chat" },
	{ key = "r", desc = "ask again, with your instruction pre-filled to reword" },
	{ key = "x", desc = "get rid of it: reject, cancel or dismiss, whichever it is" },
	{},
	{ header = "Everything" },
	{ key = "A", desc = "accept every diff — replies waiting on you are left alone" },
	{ key = "X", desc = "done with all of it: cancel, reject and dismiss" },
	{},
	{ header = "Markers" },
	{ key = "↻", key_hl = "DucktapeListStarting", desc = "still running" },
	{ key = "◆", key_hl = "DucktapeListReady", desc = "an edit to review, or a reply to read" },
	{ key = "✖", key_hl = "DucktapeListDead", desc = "failed — r asks again, x drops it" },
	{},
	{ header = "Navigate" },
	{ key = "j k", desc = "move the selection (arrows work too)" },
	{ key = "? <Esc> q", desc = "close this help, keeping the list" },
	{ key = "q <Esc>", desc = "close the list, once this help is down" },
}

-- The help overlay, when it is up. Separate from `view` because it outlives a redraw and is torn
-- down with the list rather than with a frame.
local help = nil

local function help_is_open()
	return help ~= nil and help.is_open()
end

local function close_help()
	if help then
		help.close()
	end
	help = nil
end

local view = {
	win = nil,
	buf = nil,
	-- The row under the cursor, and the entry it belongs to. Both, because the cursor follows
	-- the entry while it exists and falls back to the row's position when it stops existing.
	index = 1,
	order = nil,
	frame = 1,
	-- order → the kind last drawn, and when a change of kind was noticed. A request turning
	-- into a diff is the one transition worth announcing, and it can only be recognised by
	-- having seen the row before.
	kinds = {},
	flashed = {},
	timer = nil,
	width = nil,
	row = nil,
	col = nil,
	height = nil,
	title = nil,
	entries = {},
}

local ns = api.nvim_create_namespace("DucktapeInlineList")

--=============================================================================
-- Cells
--=============================================================================

---@param ms number
---@return string
local function elapsed_text(ms)
	local secs = math.floor(math.max(ms or 0, 0) / 1000)
	if secs < 60 then
		return ("%ds"):format(secs)
	end
	return ("%dm%02ds"):format(math.floor(secs / 60), secs % 60)
end

---Right-align, so the digits of the seconds line up rather than the leading edge of the number.
---@param text string
---@param width number
---@return string
local function align_right(text, width)
	return string.rep(" ", math.max(width - vim.fn.strdisplaywidth(text), 0)) .. text
end

---Keep the end of a path when it has to be cut: the file name says more about where an edit is
---than the directories above it do.
---@param text string
---@param width number
---@return string
local function shorten_path(text, width)
	if vim.fn.strdisplaywidth(text) <= width then
		return text
	end
	local chars = vim.fn.strchars(text)
	return "…" .. vim.fn.strcharpart(text, chars - math.max(width - 1, 1))
end

---@param entry table
---@param now number
---@return table state, string marker
local function state_of(entry, now)
	if entry.kind == "request" then
		return STATE.thinking, ui.SPINNER[view.frame]
	end
	if entry.kind ~= "diff" then
		local state = STATE[entry.kind]
		return state, state.marker
	end
	local flashed = view.flashed[entry.order]
	if flashed and now - flashed < FLASH_MS then
		return STATE.finished, STATE.finished.marker
	end
	return STATE.review, STATE.review.marker
end

---Where the edit is, or that it is nowhere any more. Rare now that a range with a request on it
---is put back when it is deleted: this shows for the tick between the deletion and the restore,
---or for a range the restore could not recover — and that one cancels the request outright.
---@param entry table
---@return string text, string hl
local function location_of(entry)
	local s0 = entry.resolve()
	if not s0 then
		return "range gone", "DucktapeListDead"
	end
	return shorten_path(("%s:%d"):format(entry.file, s0 + 1), LOCATION_CAP), "DucktapeListDim"
end

---What is worth adding about a row beyond its state: the tool a request is running, or how much
---of the buffer a finished edit touches.
---@param entry table
---@return string
local function extra_of(entry)
	if entry.kind == "request" then
		return entry.activity and ("· " .. entry.activity) or ""
	end
	if entry.kind == "prose" or entry.kind == "failed" then
		return "· <CR> read"
	end
	if entry.hunks then
		return ("· %d hunk%s"):format(entry.hunks, entry.hunks == 1 and "" or "s")
	end
	return ""
end

---@param entry table
---@return string
local function model_of(entry)
	return ellipsise(("%s · %s"):format(entry.provider or "?", entry.model or "?"), MODEL_CAP)
end

---@param entry table
---@return string
local function instruction_of(entry)
	-- Collapsed to one line: the prompt float takes whatever was typed, newlines included, and
	-- a row is one line high.
	local text = vim.trim((entry.instruction or ""):gsub("%s+", " "))
	return text ~= "" and text or "(no prompt recorded)"
end

--=============================================================================
-- Rendering
--=============================================================================

---@param entries table[]
---@return number
local function natural_width(entries)
	local widest = 0
	for _, entry in ipairs(entries) do
		local extra = extra_of(entry)
		widest = math.max(
			widest,
			2
				+ 2
				+ STATE_WIDTH
				+ 2
				+ ELAPSED_WIDTH
				+ 2
				+ vim.fn.strdisplaywidth(model_of(entry))
				+ 2
				+ vim.fn.strdisplaywidth((location_of(entry)))
				+ 2
				+ vim.fn.strdisplaywidth(instruction_of(entry))
				+ (extra ~= "" and 2 + vim.fn.strdisplaywidth(extra) or 0)
				+ 1
		)
	end
	return widest
end

---Everything up to and including the gap that follows the location column: the part of a row
---whose width is decided by the columns rather than by the space left over.
---@param plan table
---@return number
local function fixed_width(plan)
	return 2
		+ 2
		+ (plan.state and STATE_WIDTH + 2 or 0)
		+ (plan.elapsed and ELAPSED_WIDTH + 2 or 0)
		+ (plan.model > 0 and plan.model + 2 or 0)
		+ plan.location
		+ 2
end

---How much of a row fits, and so what it shows.
---
---The marker and where the edit is come first — without those a row cannot be acted on at all —
---and the prompt second, because it is the only thing on the row that cannot be worked out from
---the rest of it. Everything else gives up space to it, in order of how little is lost by
---shortening or dropping it, and each concession is only made if the prompt still has nowhere to
---go without it.
---
---The note at the end of the row is settled last and never costs another column: a tool name or
---a hunk count is worth having, but not at the price of knowing which model is running.
---@param entries table[]
---@param width number
---@return table
local function layout(entries, width)
	-- Measured across the rows on show, so the columns line up with each other. These cells only
	-- change when a row does, unlike the clock, so sizing from them cannot make the list twitch.
	local plan = { state = true, elapsed = true, model = 0, location = 0, instruction = 0, extra = 0 }
	local extra_width = 0
	for _, entry in ipairs(entries) do
		plan.model = math.max(plan.model, vim.fn.strdisplaywidth(model_of(entry)))
		plan.location = math.max(plan.location, vim.fn.strdisplaywidth((location_of(entry))))
		extra_width = math.max(extra_width, vim.fn.strdisplaywidth(extra_of(entry)))
	end

	local function room()
		return width - fixed_width(plan) - 1
	end

	local concessions = {
		function()
			plan.location = math.min(plan.location, LOCATION_MIN)
		end,
		function()
			plan.model = plan.model > 0 and math.min(plan.model, MODEL_MIN) or 0
		end,
		function()
			plan.model = 0
		end,
		function()
			plan.elapsed = false
		end,
		function()
			plan.state = false
		end,
	}
	for _, concede in ipairs(concessions) do
		if room() >= MIN_INSTRUCTION then
			break
		end
		concede()
	end

	if room() < MIN_INSTRUCTION then
		-- Nothing left to give up. The location takes whatever there is, since a row naming
		-- neither the file nor the prompt would be unactionable.
		if fixed_width(plan) > width then
			plan.location = math.max(width - (fixed_width(plan) - plan.location), 1)
		end
		return plan
	end

	if extra_width > 0 and room() - extra_width - 2 >= MIN_INSTRUCTION then
		plan.extra = extra_width
	end
	plan.instruction = room() - (plan.extra > 0 and plan.extra + 2 or 0)
	return plan
end

---@param entries table[]
---@param now number
---@param plan table
---@return string[] lines, table[] highlights
local function lines_for(entries, now, plan)
	if #entries == 0 then
		local text, highlights = render({
			{ "  " },
			{ ellipsise("nothing in flight, nothing waiting on you", math.max(view.width - 3, 1)), "DucktapeListDim" },
		})
		return { text }, { highlights }
	end

	local out, all_highlights = {}, {}
	for i, entry in ipairs(entries) do
		local state, marker = state_of(entry, now)
		local location, location_hl = location_of(entry)
		local extra = extra_of(entry)
		local on_cursor = i == view.index

		local segments = {
			{ on_cursor and "▶ " or "  ", on_cursor and "DucktapeListCurrent" or nil },
			{ marker .. " ", state.hl },
		}
		if plan.state then
			table.insert(segments, { pad(state.label, STATE_WIDTH) .. "  ", state.hl })
		end
		if plan.elapsed then
			table.insert(segments, { align_right(elapsed_text(entry.since), ELAPSED_WIDTH) .. "  ", "DucktapeListDim" })
		end
		if plan.model > 0 then
			table.insert(
				segments,
				{ pad(ellipsise(model_of(entry), plan.model), plan.model) .. "  ", "DucktapeWinBarProvider" }
			)
		end
		table.insert(segments, { pad(shorten_path(location, plan.location), plan.location), location_hl })
		if plan.instruction > 0 then
			table.insert(segments, { "  " })
			table.insert(segments, {
				pad(ellipsise(instruction_of(entry), plan.instruction), plan.instruction),
				"DucktapeWinBarTitle",
			})
		end
		if plan.extra > 0 and extra ~= "" then
			table.insert(segments, { "  " .. extra, "DucktapeListDim" })
		end

		local text, highlights = render(segments)
		table.insert(out, text)
		table.insert(all_highlights, highlights)
	end
	return out, all_highlights
end

---What the border says, in as much detail as it has room for. Shortened rather than left to be
---clipped: nvim truncates an over-long title to the window without a word about it.
---@param entries table[]
---@param width number
---@return string
local function title_for(entries, width)
	local thinking, review, unread = 0, 0, 0
	for _, entry in ipairs(entries) do
		if entry.kind == "request" then
			thinking = thinking + 1
		elseif entry.kind == "diff" then
			review = review + 1
		else
			unread = unread + 1
		end
	end

	---@param sep string
	---@param labels string[] One per count, in the order thinking, review, unread
	local function join(sep, labels)
		local bits = {}
		for i, n in ipairs({ thinking, review, unread }) do
			if n > 0 then
				table.insert(bits, ("%d%s"):format(n, labels[i]))
			end
		end
		return table.concat(bits, sep)
	end

	if thinking + review + unread == 0 then
		for _, candidate in ipairs({ " Inline — all settled ", " all settled ", "" }) do
			if vim.fn.strdisplaywidth(candidate) <= width then
				return candidate
			end
		end
	end

	local candidates = {
		(" Inline — %s "):format(join(" · ", { " thinking", " to review", " to read" })),
		(" %s "):format(join(" · ", { " thinking", " review", " to read" })),
		(" %s "):format(join(" · ", { "↻", "◆", "✉" })),
		"",
	}
	for _, candidate in ipairs(candidates) do
		if vim.fn.strdisplaywidth(candidate) <= width then
			return candidate
		end
	end
	return ""
end

---Follow the entry under the cursor rather than the row it happens to be on, and notice a
---request turning into a diff on the way.
---@param entries table[]
---@param now number
local function track(entries, now)
	local found
	for i, entry in ipairs(entries) do
		if entry.order == view.order then
			found = i
		end
		local was = view.kinds[entry.order]
		if was == "request" and entry.kind == "diff" then
			view.flashed[entry.order] = now
		end
		view.kinds[entry.order] = entry.kind
	end

	if found then
		view.index = found
	else
		-- The entry the cursor was on has gone. Hold the position it was in, so settling one
		-- edit leaves the cursor on whatever took its place instead of jumping to the top.
		view.index = math.max(math.min(view.index, #entries), math.min(1, #entries))
	end
	view.order = entries[view.index] and entries[view.index].order or nil
end

local function draw()
	if not (view.buf and api.nvim_buf_is_valid(view.buf)) then
		return
	end
	local now = vim.uv.now()
	local entries = require("ducktape.inline").list()
	view.entries = entries
	track(entries, now)

	local lines, all_highlights = lines_for(entries, now, layout(entries, view.width or 80))

	vim.bo[view.buf].modifiable = true
	pcall(api.nvim_buf_set_lines, view.buf, 0, -1, false, lines)
	vim.bo[view.buf].modifiable = false

	api.nvim_buf_clear_namespace(view.buf, ns, 0, -1)
	for lnum, highlights in ipairs(all_highlights) do
		for _, hl in ipairs(highlights) do
			pcall(api.nvim_buf_set_extmark, view.buf, ns, lnum - 1, hl[1][1], {
				end_col = hl[1][2],
				hl_group = hl[2],
			})
		end
	end

	if not (view.win and api.nvim_win_is_valid(view.win)) then
		return
	end

	-- A terminal shrunk under the list would otherwise leave a float hanging off the screen. Only
	-- ever narrowed, never widened back: the width is chosen from the rows that were on show when
	-- it opened, and re-measuring would resize the box under whoever is reading it.
	local resized = false
	local max_width = math.max(vim.o.columns - 4, 20)
	if view.width > max_width then
		view.width = max_width
		view.col = math.max(math.floor((vim.o.columns - view.width) / 2), 0)
		resized = true
	end

	-- Only when it actually changed: reconfiguring a float on every frame is churn the terminal
	-- can see. The height grows and shrinks with the list, from a top edge that stays put —
	-- re-centring would slide the whole box up the screen as rows were settled.
	local height = math.max(math.min(#lines, vim.o.lines - 6), 1)
	local row = math.min(view.row, math.max(vim.o.lines - height - 3, 0))
	if row ~= view.row then
		view.row, resized = row, true
	end
	local title = title_for(entries, view.width)
	if resized or height ~= view.height or title ~= view.title then
		view.height, view.title = height, title
		pcall(api.nvim_win_set_config, view.win, {
			relative = "editor",
			row = view.row,
			col = view.col,
			width = view.width,
			height = height,
			title = title,
			title_pos = "center",
		})
	end

	pcall(api.nvim_win_set_cursor, view.win, { math.max(view.index, 1), 0 })
end

--=============================================================================
-- Actions
--=============================================================================

---The entry the user is looking at. Taken from the last frame drawn rather than from a fresh
---read, so a key always acts on the row that was under the cursor when it was pressed.
---@return table|nil
local function selected()
	return view.entries[view.index]
end

---Is the entry still the thing it was? A tenth of a second is long enough for a request to have
---landed, and cancelling one that already has would report something that did not happen.
---@param entry table
---@return boolean
local function still_listed(entry)
	for _, e in ipairs(require("ducktape.inline").list()) do
		if e.order == entry.order and e.kind == entry.kind then
			return true
		end
	end
	return false
end

local function settle(action)
	local entry = selected()
	if not entry then
		return
	end
	if entry.kind == "prose" or entry.kind == "failed" then
		if action == "accept" and entry.kind == "prose" then
			-- The nearest thing to accepting a reply that is not code: take it somewhere it can be
			-- talked about.
			require("ducktape.inline").to_chat(entry.waiting)
			ui.say(("[ducktape] opened %s in a chat"):format(entry.file))
			return draw()
		end
		if action == "reject" then
			require("ducktape.inline").dismiss(entry.waiting)
			ui.say(("[ducktape] dismissed %s"):format(entry.file))
			return draw()
		end
		return ui.say("[ducktape] nothing to accept there — <CR> reads it, r asks again", vim.log.levels.WARN)
	end
	if entry.kind ~= "diff" then
		return ui.say("[ducktape] that one is still running — x cancels it", vim.log.levels.WARN)
	end
	-- `resolved` as well as the registry: a diff settled in the buffer itself is refused by
	-- codecompanion rather than applied twice, and reporting success on top of that would be a
	-- lie about what the buffer now holds.
	if not still_listed(entry) or not (entry.diff.ui and not entry.diff.ui.resolved) then
		return ui.say("[ducktape] that one has already been settled", vim.log.levels.INFO)
	end

	local inline = require("ducktape.inline")
	if action == "accept" then
		inline.accept(entry.bufnr, entry.diff)
	else
		inline.reject(entry.bufnr, entry.diff)
	end
	ui.say(("[ducktape] %s %s"):format(action == "accept" and "accepted" or "rejected", entry.file))
	draw()
end

---Discard the entry under the cursor, whichever half of its life it is in: cancel it if it is
---running, reject it if it has answered. One key for "make this go away", since which state a row
---is in is exactly what changes on its own while the list is open.
local function discard_selected()
	local entry = selected()
	if not entry then
		return
	end
	if entry.kind == "diff" or entry.kind == "prose" or entry.kind == "failed" then
		return settle("reject")
	end
	if not still_listed(entry) then
		-- It landed in the last frame, so it is a diff now rather than a request. Rejecting is
		-- what x means for one of those, so redraw and let the next press find it.
		draw()
		return ui.say("[ducktape] that one just landed — x again rejects it", vim.log.levels.INFO)
	end
	require("ducktape.inline").cancel_request(entry.request)
	ui.say(("[ducktape] cancelled %s"):format(entry.file))
	draw()
end

---Settle every diff in the list, wherever it belongs — the counterpart to X, which cancels every
---request the same way.
---
---The files are named in the report rather than just counted: this reaches buffers that are not on
---screen, and knowing which ones changed is what makes the result checkable afterwards.
---@param action "accept"|"reject"
local function settle_every(action)
	local inline = require("ducktape.inline")
	local settled, files, running, unread = 0, {}, 0, 0
	for _, entry in ipairs(inline.list()) do
		if entry.kind == "prose" or entry.kind == "failed" then
			-- Left alone on purpose. These are the only entries holding text that exists nowhere
			-- else, so a key meaning "settle the diffs" must not be the thing that throws away an
			-- explanation nobody has read.
			unread = unread + 1
		elseif entry.kind ~= "diff" then
			running = running + 1
		elseif entry.diff.ui and not entry.diff.ui.resolved then
			if action == "accept" then
				inline.accept(entry.bufnr, entry.diff)
			else
				inline.reject(entry.bufnr, entry.diff)
			end
			settled = settled + 1
			if not vim.tbl_contains(files, entry.file) then
				table.insert(files, entry.file)
			end
		end
	end

	local left = unread > 0 and (", %d repl%s still to read"):format(unread, unread == 1 and "y" or "ies") or ""

	if settled == 0 then
		return ui.say(
			running > 0
					and ("[ducktape] nothing to settle yet — %d still running, x or X cancels%s"):format(
						running,
						left
					)
				or ("[ducktape] no diffs waiting to be settled%s"):format(left ~= "" and (" —" .. left:sub(2)) or ""),
			vim.log.levels.INFO
		)
	end

	local where = table.concat(vim.list_slice(files, 1, 3), ", ")
	if #files > 3 then
		where = ("%s and %d more"):format(where, #files - 3)
	end
	ui.say(
		("[ducktape] %s %d diff(s) in %s%s"):format(
			action == "accept" and "accepted" or "rejected",
			settled,
			where,
			left
		)
	)
	draw()
end

---Clear the list out entirely: cancel what is running, reject what has answered, dismiss what was
---never read. The counterpart to A, which keeps the answers instead.
---
---Unread replies go too. This is the "I am done with all of it" key, and one that left rows behind
---would need a second key to finish the job — the count in the message is what says a reply was
---among them.
local function discard_every()
	local inline = require("ducktape.inline")
	local cancelled, rejected, dismissed = 0, 0, 0
	for _, entry in ipairs(inline.list()) do
		if entry.kind == "request" then
			inline.cancel_request(entry.request)
			cancelled = cancelled + 1
		elseif entry.kind == "prose" or entry.kind == "failed" then
			inline.dismiss(entry.waiting)
			dismissed = dismissed + 1
		elseif entry.diff.ui and not entry.diff.ui.resolved then
			inline.reject(entry.bufnr, entry.diff)
			rejected = rejected + 1
		end
	end

	local said = {}
	if cancelled > 0 then
		table.insert(said, ("cancelled %d request(s)"):format(cancelled))
	end
	if rejected > 0 then
		table.insert(said, ("rejected %d diff(s)"):format(rejected))
	end
	if dismissed > 0 then
		table.insert(said, ("dismissed %d unread repl%s"):format(dismissed, dismissed == 1 and "y" or "ies"))
	end
	if #said == 0 then
		return ui.say("[ducktape] nothing in play", vim.log.levels.INFO)
	end
	ui.say("[ducktape] " .. table.concat(said, ", "))
	draw()
end

---Get rid of what is on this row and ask the same thing again, with the instruction pre-filled.
---
---Works on every kind of row, which is what makes it worth a key rather than a special case: a diff
---is rejected first, a running request cancelled, a reply dismissed. The list closes because the
---prompt float replaces it, and whatever happens next is reported there.
local function retry()
	local entry = selected()
	if not entry then
		return
	end
	M.close()
	require("ducktape.inline").ask_again_prompt(entry)
end

---Leave the list and go to the edit itself, which is where a diff is read and where g2/g3 and
---the hunk motions already live. A reply that came to nothing has nothing to jump *to*, so it
---opens the reply instead — which is the one place a float taking focus is right, since it was
---asked for.
local function jump()
	local entry = selected()
	if not entry then
		return
	end
	if entry.kind == "prose" or entry.kind == "failed" then
		local waiting = entry.waiting
		M.close()
		return require("ducktape.inline").read(waiting)
	end
	local bufnr, s0 = entry.bufnr, entry.resolve()
	M.close()

	if not api.nvim_buf_is_valid(bufnr) then
		return ui.say("[ducktape] the buffer that edit belongs to is gone", vim.log.levels.WARN)
	end
	local win = vim.fn.bufwinid(bufnr)
	if win ~= -1 then
		api.nvim_set_current_win(win)
	else
		vim.cmd("buffer " .. bufnr)
	end
	if s0 then
		pcall(api.nvim_win_set_cursor, 0, { math.min(s0 + 1, api.nvim_buf_line_count(bufnr)), 0 })
		vim.cmd("normal! zz")
	end
end

local function move(delta)
	local total = #view.entries
	if total == 0 then
		return
	end
	view.index = ((view.index - 1 + delta) % total) + 1
	view.order = view.entries[view.index] and view.entries[view.index].order or nil
	draw()
end

--=============================================================================
-- Window
--=============================================================================

function M.close()
	if view.timer then
		local timer = view.timer
		view.timer = nil
		timer:stop()
		if not timer:is_closing() then
			timer:close()
		end
	end
	if view.win and api.nvim_win_is_valid(view.win) then
		pcall(api.nvim_win_close, view.win, true)
	end
	if view.buf and api.nvim_buf_is_valid(view.buf) then
		pcall(api.nvim_buf_delete, view.buf, { force = true })
	end
	view.win, view.buf = nil, nil
	view.entries = {}
	view.height, view.title = nil, nil
	-- A plain float of its own, so nothing else would take it down with the list it documents.
	close_help()
end

---@return boolean
function M.is_open()
	return view.win ~= nil and api.nvim_win_is_valid(view.win)
end

local function open()
	local entries = require("ducktape.inline").list()

	-- Opens even with nothing to show, saying so in the window. It used to answer with a message on
	-- the command line, which reads as "the key did nothing" to anyone not watching that line — and
	-- the window is where the answer was expected. The empty state is written for anyway: settling
	-- the last row from in here leaves the list standing and says the same thing.
	ui.ensure_highlights()
	M.close() -- reopening rather than stacking, if one is somehow still up

	view.index, view.order, view.frame = 1, entries[1] and entries[1].order or nil, 1
	view.kinds, view.flashed = {}, {}
	-- Anything already finished when the list opened is not news, so it says "review" from the
	-- start rather than flashing at someone who has only just looked.
	for _, entry in ipairs(entries) do
		view.kinds[entry.order] = entry.kind
	end

	-- Sized once, from the rows on show: the window has to be at least as wide as the footer or
	-- nvim clips it without saying so, and re-measuring per frame would resize the box under a
	-- reader every time a new request arrived.
	local footer = FOOTERS[#FOOTERS]
	for _, candidate in ipairs(FOOTERS) do
		if vim.fn.strdisplaywidth(candidate) + 2 <= vim.o.columns - 4 then
			footer = candidate
			break
		end
	end
	view.width = math.min(math.max(natural_width(entries), vim.fn.strdisplaywidth(footer) + 2), vim.o.columns - 4)
	local height = math.max(math.min(#entries, vim.o.lines - 6), 1)
	view.height, view.title = height, title_for(entries, view.width)
	view.row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0)
	view.col = math.max(math.floor((vim.o.columns - view.width) / 2), 0)

	view.buf = api.nvim_create_buf(false, true)
	view.win = api.nvim_open_win(view.buf, true, {
		relative = "editor",
		row = view.row,
		col = view.col,
		width = view.width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = view.title,
		title_pos = "center",
		footer = footer,
		footer_pos = "center",
	})
	-- style = "minimal" turns cursorline off, and the row under the cursor is what every key here
	-- acts on.
	vim.wo[view.win].cursorline = true
	vim.bo[view.buf].modifiable = false

	local function on(keys, fn)
		for _, key in ipairs(keys) do
			vim.keymap.set("n", key, fn, { buffer = view.buf, nowait = true })
		end
	end
	on({ "j", "<Down>" }, function()
		move(1)
	end)
	on({ "k", "<Up>" }, function()
		move(-1)
	end)
	-- Three verbs, one each: keep it, get rid of it, go again.
	--
	-- There is no reject key, because there was nothing for it to do that x did not already do —
	-- on a diff both rejected, on a reply both dismissed, and on a running request r could only
	-- point at x. So x absorbed it, and r went to the thing that had no key: asking again.
	--
	-- g2/g3 come along as aliases because they are what settles a diff in the buffer itself, and
	-- g3 lands on discard, which is what it means there.
	on({ "a", "g2" }, function()
		settle("accept")
	end)
	on({ "r" }, retry)
	on({ "x", "g3" }, discard_selected)
	-- Uppercase is "all of them", the same way X is to x.
	on({ "A" }, function()
		settle_every("accept")
	end)
	on({ "X" }, discard_every)
	on({ "R" }, function()
		-- Bound to say so rather than left silent: a key that does nothing reads as a dropped
		-- keypress, and this one used to mean something.
		ui.say(
			"[ducktape] there is no ask-again-for-everything — r asks again one row at a time, since each carries its own prompt",
			vim.log.levels.INFO
		)
	end)
	on({ "<CR>" }, jump)
	on({ "?" }, function()
		if help_is_open() then
			return close_help()
		end
		help = ui.help(HELP, { title = " Inline list ", key_column = 11 })
	end)
	-- <Esc> and q are what a hand reaches for to dismiss a popup, and both otherwise close the
	-- list — which would take the list away along with the help it was explaining. While the
	-- overlay is up they dismiss it and stop there.
	on({ "q", "<Esc>" }, function()
		if help_is_open() then
			return close_help()
		end
		M.close()
	end)

	-- Moving away closes it, which is also what guarantees the redraw timer never outlives the
	-- window it was drawing into.
	--
	-- Whether focus really left is answered a tick later rather than taken from the event: nvim
	-- leaves and re-enters a float while laying windows out again after the terminal is resized,
	-- and taking WinLeave at face value would tear the list down every time its own window
	-- changed size. Not `once`, since that first leave may well have been one of those.
	api.nvim_create_autocmd("WinLeave", {
		buffer = view.buf,
		callback = function()
			vim.schedule(function()
				if M.is_open() and api.nvim_get_current_win() ~= view.win then
					M.close()
				end
			end)
		end,
	})

	draw()

	-- The same tempo as the per-request spinner in the buffer, so a request that is being watched
	-- from both places animates as one thing.
	view.timer = vim.uv.new_timer()
	view.timer:start(
		100,
		100,
		vim.schedule_wrap(function()
			if not M.is_open() then
				return M.close()
			end
			view.frame = (view.frame % #ui.SPINNER) + 1
			draw()
		end)
	)
end

---Toggle the inline list.
function M.toggle()
	if M.is_open() then
		M.close()
	else
		open()
	end
end

M.open = open

return M
