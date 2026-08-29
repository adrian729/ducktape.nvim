-- Inline list: running requests and finished diffs. A float rather than Telescope because this
-- redraws live; Telescope's refresh resets the cursor.

local M = {}

local api = vim.api

local ui = require("ducktape.ui")
local render = ui.render
local pad = ui.pad
local ellipsise = ui.ellipsise

---How long a row keeps saying "finished" after it lands.
local FLASH_MS = 3000

-- Fixed width avoids twitching as the seconds column ticks over.
local ELAPSED_WIDTH = 6

-- Caps for cells that can hold long real values.
local MODEL_CAP = 30
local LOCATION_CAP = 40

-- Below this, the prompt says less than the space it costs.
local MIN_INSTRUCTION = 10

-- Minimum useful lengths: a path still names a file; a model still names the provider.
local LOCATION_MIN = 18
local MODEL_MIN = 14

local STATE = {
	thinking = { label = "thinking", hl = "DucktapeListStarting" },
	finished = { marker = "◆", label = "finished", hl = "DucktapeListCurrent" },
	review = { marker = "◆", label = "review", hl = "DucktapeListReady" },
	-- Prose/failed: nothing is pending in the buffer, so it is read, re-asked or dismissed.
	prose = { marker = "◆", label = "answered", hl = "DucktapeListReady" },
	failed = { marker = "✖", label = "failed", hl = "DucktapeListDead" },
}

local STATE_WIDTH = 0
for _, state in pairs(STATE) do
	STATE_WIDTH = math.max(STATE_WIDTH, vim.fn.strdisplaywidth(state.label))
end

---The three progressively shorter border footers, widest first.
---Widest first because nvim truncates a border footer to the window silently.
---Built from bindings so a remapped panel documents itself.
---@return string[]
local function FOOTERS()
	local keys = require("ducktape.keys")
	local a = keys.panel_label("inline_list", "accept")
	local r = keys.panel_label("inline_list", "retry")
	local x = keys.panel_label("inline_list", "discard")
	local h = keys.panel_label("inline_list", "help")
	return {
		(" %s accept · %s again · %s discard · %s keys "):format(a, r, x, h),
		(" %s · %s · %s · %s keys "):format(a, r, x, h),
		(" %s keys "):format(h),
	}
end

---Everything the list can do, and what the markers mean.
---@return table[]
local function HELP()
	local keys = require("ducktape.keys")
	local function label(action)
		return table.concat(keys.panel("inline_list", action), " ")
	end
	local accept = keys.panel_label("inline_list", "accept")
	local retry = keys.panel_label("inline_list", "retry")
	local discard = keys.panel_label("inline_list", "discard")
	local icons = {}
	for _, part in ipairs(require("ducktape.config").get().statusline.icons or {}) do
		icons[part.key] = part.icon
	end
	return {
		{ header = "This row" },
		{ key = label("open"), desc = "go to the edit, or read a reply that came to nothing" },
		{ key = accept, desc = "accept — a diff is applied, a reply goes into a chat" },
		{ key = retry, desc = "ask again, with your instruction pre-filled to reword" },
		{ key = discard, desc = "get rid of it: reject, cancel or dismiss, whichever it is" },
		{},
		{ header = "Everything" },
		{ key = accept:upper(), desc = "accept every diff — replies waiting on you are left alone" },
		{ key = discard:upper(), desc = "done with all of it: cancel, reject and dismiss" },
		{},
		{ header = "Markers" },
		{ key = icons.running or "↻", key_hl = "DucktapeListStarting", desc = "still running" },
		{ key = icons.answered or "◆", key_hl = "DucktapeListReady", desc = "an edit to review, or a reply to read" },
		{
			key = icons.failed or "✖",
			key_hl = "DucktapeListDead",
			desc = ("failed — %s asks again, %s drops it"):format(retry, discard),
		},
		{},
		{ header = "Navigate" },
		{
			key = ("%s %s"):format(keys.panel_label("inline_list", "down"), keys.panel_label("inline_list", "up")),
			desc = "move the selection (arrows work too)",
		},
		{ key = ("%s %s"):format(label("help"), label("close")), desc = "close this help, keeping the list" },
		{ key = label("close"), desc = "close the list, once this help is down" },
	}
end

-- The help overlay, when it is up. Separate from `view` because it outlives redraws.
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
	index = 1,
	order = nil,
	frame = 1,
	-- order → last seen kind; a request turning into a diff is the transition worth flashing.
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

---@param ms number
---@return string
local function elapsed_text(ms)
	local secs = math.floor(math.max(ms or 0, 0) / 1000)
	if secs < 60 then
		return ("%ds"):format(secs)
	end
	return ("%dm%02ds"):format(math.floor(secs / 60), secs % 60)
end

---Right-align, so the digits line up.
---@param text string
---@param width number
---@return string
local function align_right(text, width)
	return string.rep(" ", math.max(width - vim.fn.strdisplaywidth(text), 0)) .. text
end

---Keep the end of a path when it has to be cut.
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
		return STATE.thinking, ui.spinner()[view.frame]
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

---Where the edit is, or that it is nowhere any more.
---@param entry table
---@return string text, string hl
local function location_of(entry)
	local s0 = entry.resolve()
	if not s0 then
		return "range gone", "DucktapeListDead"
	end
	return shorten_path(("%s:%d"):format(entry.file, s0 + 1), LOCATION_CAP), "DucktapeListDim"
end

---What is worth adding about a row beyond its state.
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
	-- Collapsed to one line: a row is one line high.
	local text = vim.trim((entry.instruction or ""):gsub("%s+", " "))
	return text ~= "" and text or "(no prompt recorded)"
end

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

---Everything up to and including the gap after the location column.
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
---Marker and location come first; the prompt is last to drop. Concessions are made only until
---the prompt has room.
---@param entries table[]
---@param width number
---@return table
local function layout(entries, width)
	-- Measured across rows so the columns line up.
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

---What the border says, shortened to fit. nvim truncates an over-long title silently.
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

---Follow the entry under the cursor, and flash a request turning into a diff.
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
		-- Hold the cursor row so settling one edit leaves it on whatever took its place.
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

	-- Only ever narrow: re-measuring per frame would resize the box under a reader.
	local resized = false
	local max_width = math.max(vim.o.columns - 4, 20)
	if view.width > max_width then
		view.width = max_width
		view.col = math.max(math.floor((vim.o.columns - view.width) / 2), 0)
		resized = true
	end

	-- Reconfigure only when changed; height grows from a fixed top edge.
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

---The entry the user is looking at. Taken from the last frame drawn.
---@return table|nil
local function selected()
	return view.entries[view.index]
end

---Is the entry still the thing it was?
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
	-- codecompanion rather than applied twice.
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

---Discard the entry under the cursor, whichever half of its life it is in.
local function discard_selected()
	local entry = selected()
	if not entry then
		return
	end
	if entry.kind == "diff" or entry.kind == "prose" or entry.kind == "failed" then
		return settle("reject")
	end
	if not still_listed(entry) then
		-- It landed in the last frame; redraw so the next press finds the diff.
		draw()
		return ui.say("[ducktape] that one just landed — x again rejects it", vim.log.levels.INFO)
	end
	require("ducktape.inline").cancel_request(entry.request)
	ui.say(("[ducktape] cancelled %s"):format(entry.file))
	draw()
end

---Settle every diff in the list.
---@param action "accept"|"reject"
local function settle_every(action)
	local inline = require("ducktape.inline")
	local settled, files, running, unread = 0, {}, 0, 0
	for _, entry in ipairs(inline.list()) do
		if entry.kind == "prose" or entry.kind == "failed" then
			-- Left alone: these hold text that exists nowhere else.
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

---Clear the list out entirely: cancel running, reject answered, dismiss unread.
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

---Discard the row and ask the same thing again, with the instruction pre-filled.
local function retry()
	local entry = selected()
	if not entry then
		return
	end
	M.close()
	require("ducktape.inline").ask_again_prompt(entry)
end

---Leave the list and go to the edit itself. A reply that came to nothing is opened instead.
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
	close_help()
end

---@return boolean
function M.is_open()
	return view.win ~= nil and api.nvim_win_is_valid(view.win)
end

local function open()
	local entries = require("ducktape.inline").list()

	-- Open even when empty; an empty list is a normal state once the last row is settled.
	ui.ensure_highlights()
	M.close()

	view.index, view.order, view.frame = 1, entries[1] and entries[1].order or nil, 1
	view.kinds, view.flashed = {}, {}
	-- Already-finished entries are not news; they show "review" from the start.
	for _, entry in ipairs(entries) do
		view.kinds[entry.order] = entry.kind
	end

	-- Size once from the rows on show; the footer must fit or nvim clips it silently.
	local footers = FOOTERS()
	local footer = footers[#footers]
	for _, candidate in ipairs(footers) do
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
		border = require("ducktape.config").get().ui.border,
		title = view.title,
		title_pos = "center",
		footer = footer,
		footer_pos = "center",
	})
	-- style = "minimal" turns cursorline off.
	vim.wo[view.win].cursorline = true
	vim.bo[view.buf].modifiable = false

	local function toggle_help()
		if help_is_open() then
			return close_help()
		end
		help = ui.help(HELP(), { title = " Inline list ", key_column = 11 })
	end

	-- While the help overlay is up, dismiss it instead of closing the list.
	local function close_or_dismiss_help()
		if help_is_open() then
			return close_help()
		end
		M.close()
	end

	local keys = require("ducktape.keys")
	keys.bind_panel("inline_list", view.buf, {
		down = function()
			move(1)
		end,
		up = function()
			move(-1)
		end,
		-- Three verbs: keep it, get rid of it, go again. g2/g3 tag along as aliases.
		accept = function()
			settle("accept")
		end,
		retry = retry,
		discard = discard_selected,
		open = jump,
		help = toggle_help,
		close = close_or_dismiss_help,
	})

	-- Uppercase is "all of them", derived from the single-row keys.
	local function upper(action, fn)
		for _, lhs in ipairs(keys.panel("inline_list", action)) do
			if #lhs == 1 and lhs:match("%a") then
				vim.keymap.set("n", lhs:upper(), fn, { buffer = view.buf, nowait = true })
			end
		end
	end
	upper("accept", function()
		settle_every("accept")
	end)
	upper("discard", discard_every)
	upper("retry", function()
		ui.say(
			"[ducktape] there is no ask-again-for-everything — "
				.. keys.panel_label("inline_list", "retry")
				.. " asks again one row at a time, since each carries its own prompt",
			vim.log.levels.INFO
		)
	end)

	-- Close when focus really leaves. Defer the check: nvim fires WinLeave while relayouting
	-- after a resize, and acting on it would tear the list down.
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

	-- Same tempo as the per-request spinner in the buffer.
	view.timer = vim.uv.new_timer()
	view.timer:start(
		100,
		100,
		vim.schedule_wrap(function()
			if not M.is_open() then
				return M.close()
			end
			view.frame = (view.frame % #ui.spinner()) + 1
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
