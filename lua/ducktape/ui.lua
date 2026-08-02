-- Shared presentation helpers: per-request progress virtual text, and the float that shows a
-- reply the buffer must not receive.

local api = vim.api

local M = {}

-- Shared with the inline list, so a request animates at the same tempo and in the same shape
-- wherever it is being watched from.
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
M.SPINNER = SPINNER

local ns = api.nvim_create_namespace("ducktape_ui")

---Width of a window showing this buffer, or of the screen when it is on none.
---@param bufnr number
---@return number
local function width_of(bufnr)
	for _, win in ipairs(api.nvim_list_wins()) do
		if api.nvim_win_get_buf(win) == bufnr then
			return api.nvim_win_get_width(win)
		end
	end
	return vim.o.columns
end

---Width available for virtual text on a row, so a long prompt gets an ellipsis instead of
---pushing the line off screen.
---@param bufnr number
---@param row number 0-indexed
---@return number
local function room_on(bufnr, row)
	local line = api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
	return math.max(20, width_of(bufnr) - vim.fn.strdisplaywidth(line) - 6)
end

---Ask a yes/no question the way every other command-line program asks one: `y`, `n`, or Enter for
---the default.
---
---One helper rather than a `vim.fn.confirm` at each call site, because the alternative is what was
---there before — `&Delete\n&Cancel`, `&Forget\n&Cancel` — where the key to press was a different
---letter for every question and neither of them was `y`. Naming the action in the button reads
---well in a GUI dialog and badly in a terminal, where the muscle memory is `y`.
---
---An aborted prompt (Esc, or an interrupt) returns 0 from confirm, which is a no.
---@param question string
---@param opts? { default?: boolean } Defaults to no, for anything that cannot be undone
---@return boolean
function M.confirm(question, opts)
	local yes_by_default = opts ~= nil and opts.default == true
	local answered_yes = vim.fn.confirm(question, "&Yes\n&No", yes_by_default and 1 or 2, "Question") == 1
	-- The question stays on the command line after it has been answered, so whatever the caller
	-- reports next lands on the line below it and costs a "Press ENTER" to clear (measured).
	-- Redrawing here does take the prompt back — unlike an overflowing message, see M.say.
	vim.cmd("redraw")
	return answered_yes
end

---Truncate to a display width, marking that something was cut. By character rather than by
---byte, so a multibyte glyph is never sliced in half.
---@param text string
---@param width number
---@return string
function M.ellipsise(text, width)
	if vim.fn.strdisplaywidth(text) <= width then
		return text
	end
	return vim.fn.strcharpart(text, 0, math.max(1, width - 1)) .. "…"
end

local ellipsise = M.ellipsise

local LEVEL_HL = {
	[vim.log.levels.ERROR] = "ErrorMsg",
	[vim.log.levels.WARN] = "WarningMsg",
}

---Say something on the command line, without "Press ENTER or type command to continue".
---
---That prompt is what a message too big for the command line costs, and nothing takes it back
---once it is up: `:redraw`, `:redraw!` and `:mode` all leave it standing (measured). So the only
---way past it is to not overflow. `v:echospace` is exactly how much room there is — 68 cells of
---an 80-column screen, the remainder reserved for 'showcmd' — and the line shown is fitted to it.
---
---A message that does not fit is still recorded whole. 'cmdheight' is grown just long enough for
---the echo that enters the history, then put back before the next redraw, so `:messages` has every
---word while the command line shows only the head. Measured as invisible: with three splits and a
---floating window open, no VimResized or WinResized fired, window heights were unchanged and the
---float kept its geometry.
---
---Used instead of `vim.notify` throughout, which is the same echo without the fitting.
---@param msg string
---@param level? number A `vim.log.levels` value; INFO and below go unhighlighted
---@param opts? { history?: boolean } `history = false` shows it without recording it, for a repeat
---   of something already in `:messages`
function M.say(msg, level, opts)
	local hl = LEVEL_HL[level]
	local record = not (opts ~= nil and opts.history == false)
	-- A newline overflows the command line as surely as length does, and every one of these
	-- messages is a single sentence anyway.
	local flat = msg:gsub("%s*\n%s*", " · ")
	local fitted = ellipsise(flat, math.max(1, vim.v.echospace))

	if fitted == flat then
		return api.nvim_echo({ { flat, hl } }, record, {})
	end
	if not record then
		return api.nvim_echo({ { fitted, hl } }, false, {})
	end

	local saved = vim.o.cmdheight
	vim.o.cmdheight = math.ceil(vim.fn.strdisplaywidth(flat) / math.max(1, vim.o.columns)) + 1
	api.nvim_echo({ { flat, hl } }, true, {})
	vim.o.cmdheight = saved
	api.nvim_echo({ { fitted, hl } }, false, {})
end

---Animated virtual text pinned to a moving row, or to a moving region.
---
---Virtual text rather than a cursor-relative float, because several requests can be in flight
---in one buffer and all of them have to be visible at once.
---
---Given a region — a second return value from `row_fn` — the label goes on a line of its own
---above it and the region itself is tinted, because end-of-line text on the first row says
---nothing about how far down the request reaches. A caller marking a single point (the chat
---spinner) returns one value and keeps the end-of-line text, where there is no extent to show
---and shifting the buffer down by a line would be noise.
---@param bufnr number
---@param row_fn fun(): number|nil, number|nil 0-indexed start row and exclusive end row, re-read
---   every frame so the marks follow edits
---@param label string
---@return { stop: fun(), set_label: fun(text: string) }
function M.progress(bufnr, row_fn, label)
	M.ensure_highlights()
	local mark, tint, frame = nil, nil, 1
	local timer = vim.uv.new_timer()
	local handle = {}
	-- render() runs once before the timer starts, and its invalid-buffer branch calls stop(),
	-- which nils the timer out from under the start() below.
	local stopped = false

	local function clear()
		if api.nvim_buf_is_valid(bufnr) then
			for _, id in ipairs({ mark or -1, tint or -1 }) do
				if id >= 0 then
					pcall(api.nvim_buf_del_extmark, bufnr, ns, id)
				end
			end
		end
		mark, tint = nil, nil
	end

	---@param id number|nil
	---@param row number
	---@param opts table
	---@return number|nil id
	local function place(id, row, opts)
		opts.id = id
		local ok, new = pcall(api.nvim_buf_set_extmark, bufnr, ns, row, 0, opts)
		return ok and new or id
	end

	local function render()
		if stopped then
			return clear()
		end
		if not api.nvim_buf_is_valid(bufnr) then
			return handle.stop()
		end
		local s0, e0 = row_fn()
		if not s0 then
			return clear()
		end
		local rows = api.nvim_buf_line_count(bufnr)
		local row = math.max(0, math.min(s0, rows - 1))

		if not e0 then
			local text = (" %s %s "):format(SPINNER[frame], ellipsise(label, room_on(bufnr, row)))
			mark = place(mark, row, {
				virt_text = { { text, "DiagnosticVirtualTextHint" } },
				virt_text_pos = "eol",
				hl_mode = "combine",
			})
			return
		end

		-- Indented to the code it belongs to, so with two requests in flight the header reads as
		-- part of the block below it rather than as a line of its own.
		local indent = (api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""):match("^%s*")
		local span = e0 - s0
		-- Said in words as well as shown in colour: a tint is easy to miss, and impossible to
		-- see at all on the row the cursor is sitting on.
		local extent = span > 0 and ("%d line%s"):format(span, span == 1 and "" or "s") or "insert"
		local head = ("%s %s "):format(indent, SPINNER[frame])
		local tail = (" · %s"):format(extent)
		local room = width_of(bufnr) - vim.fn.strdisplaywidth(head) - vim.fn.strdisplaywidth(tail) - 2
		mark = place(mark, row, {
			virt_lines = {
				{
					{ head .. ellipsise(label, math.max(20, room)), "DiagnosticVirtualTextHint" },
					{ tail, "DucktapeListDim" },
				},
			},
			virt_lines_above = true,
			-- On the first row only, not one per line: the sign is there so scrolling past the
			-- label still leaves something visible, and a column of identical signs down the
			-- side of a selection says nothing extra.
			sign_text = "↻",
			sign_hl_group = "DucktapeListStarting",
		})

		if span > 0 then
			local last = math.max(row, math.min(e0 - 1, rows - 1))
			local text = api.nvim_buf_get_lines(bufnr, last, last + 1, false)[1] or ""
			-- hl_eol so the tint reads as one block down to the last row, rather than tracing a
			-- ragged edge that looks like a stray visual selection.
			tint = place(tint, row, {
				end_row = last,
				end_col = #text,
				hl_group = "DucktapeInlineRange",
				hl_eol = true,
			})
		end
	end

	function handle.stop()
		stopped = true
		clear()
		-- Defer timer teardown one tick so any mid-flight render() sees stopped and
		-- clears itself rather than racing with the extmark deletion above.
		vim.schedule(function()
			if timer then
				timer:stop()
				if not timer:is_closing() then
					timer:close()
				end
				timer = nil
			end
		end)
	end

	function handle.set_label(text)
		if stopped then
			return
		end
		label = text
		render()
	end

	render()
	if not stopped then
		timer:start(
			100,
			100,
			vim.schedule_wrap(function()
				frame = (frame % #SPINNER) + 1
				render()
			end)
		)
	end

	return handle
end

---A standing marker on a range: something arrived here and is waiting on the user.
---
---Placed once rather than redrawn, because extmarks already follow the text — a reply can sit
---unanswered for as long as it takes, and a timer per waiting reply would cost something for
---nothing. The sign is what carries it when the label has been scrolled past, and is the only part
---visible from elsewhere in the file.
---@param bufnr number
---@param s0 number 0-indexed start row
---@param e0 number Exclusive end row
---@param label string
---@param opts { hl: string, sign: string, sign_hl: string, range_hl?: string }
---@return { stop: fun() }
function M.pinned(bufnr, s0, e0, label, opts)
	M.ensure_highlights()
	local ids = {}

	local function place(row, o)
		local ok, id = pcall(api.nvim_buf_set_extmark, bufnr, ns, row, 0, o)
		if ok then
			table.insert(ids, id)
		end
	end

	if api.nvim_buf_is_valid(bufnr) then
		local rows = api.nvim_buf_line_count(bufnr)
		local row = math.max(0, math.min(s0, rows - 1))
		local indent = (api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""):match("^%s*")
		local head = ("%s %s "):format(indent, opts.sign)
		local room = width_of(bufnr) - vim.fn.strdisplaywidth(head) - 2

		place(row, {
			virt_lines = { { { head .. ellipsise(label, math.max(20, room)), opts.hl } } },
			virt_lines_above = true,
			sign_text = opts.sign,
			sign_hl_group = opts.sign_hl,
		})

		local last = math.max(row, math.min(e0 - 1, rows - 1))
		if last > row or e0 > s0 then
			local text = api.nvim_buf_get_lines(bufnr, last, last + 1, false)[1] or ""
			place(
				row,
				{ end_row = last, end_col = #text, hl_group = opts.range_hl or "DucktapeInlineRange", hl_eol = true }
			)
		end
	end

	return {
		stop = function()
			if not api.nvim_buf_is_valid(bufnr) then
				return
			end
			for _, id in ipairs(ids) do
				pcall(api.nvim_buf_del_extmark, bufnr, ns, id)
			end
			ids = {}
		end,
	}
end

---A float showing a reply that must not be inserted — an answer, a refusal, or a failed tool
---attempt. Anchored at the target range so it is obvious which request it belongs to.
---@param opts { bufnr: number, row: number, title: string, text: string, on_confirm?: fun() }
---@return number winnr
function M.message(opts)
	local lines = {}
	for _, line in ipairs(vim.split(opts.text, "\n", { plain = true })) do
		vim.list_extend(lines, vim.split(line, "\r", { plain = true }))
	end

	local width = math.min(math.floor(vim.o.columns * 0.7), 90)
	local height = math.min(#lines + 1, math.floor(vim.o.lines * 0.5))

	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"

	local config = {
		relative = "editor",
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = (" %s — <CR> open in a chat · q dismiss "):format(opts.title),
		title_pos = "center",
	}

	-- Anchored at the target row when the buffer is on screen, so that with several requests in
	-- flight it is obvious which one is talking. Centred when it is not displayed anywhere.
	local host = opts.bufnr and vim.fn.bufwinid(opts.bufnr) or -1
	if host ~= -1 and opts.row then
		local rows = api.nvim_buf_line_count(opts.bufnr)
		config.relative = "win"
		config.win = host
		config.bufpos = { math.max(0, math.min(opts.row, rows - 1)), 0 }
		config.row, config.col = 1, 0
	end

	local win = api.nvim_open_win(buf, true, config)
	vim.wo[win].wrap = true

	local function close()
		if api.nvim_win_is_valid(win) then
			api.nvim_win_close(win, true)
		end
	end

	vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
	vim.keymap.set("n", "<esc>", close, { buffer = buf, nowait = true })
	vim.keymap.set("n", "<cr>", function()
		close()
		if opts.on_confirm then
			opts.on_confirm()
		end
	end, { buffer = buf, nowait = true })

	return win
end

--=============================================================================
-- Highlighted list lines
--=============================================================================

---Assemble a display line from {text, highlight} segments. Telescope wants byte offsets,
---and the markers these lines carry are multibyte, so the offsets are accumulated from the
---segments rather than written out by hand — hand-written ones drift the moment a glyph
---changes, and a range landing mid-codepoint corrupts the whole line.
---@param segments { [1]: string, [2]: string|nil }[]
---@return string text, table highlights
function M.render(segments)
	local parts, highlights, offset = {}, {}, 0
	for _, seg in ipairs(segments) do
		local text = seg[1]
		if seg[2] and text ~= "" then
			table.insert(highlights, { { offset, offset + #text }, seg[2] })
		end
		table.insert(parts, text)
		offset = offset + #text
	end
	return table.concat(parts), highlights
end

---Pad to a display width — `#text` would over-pad anything holding a multibyte glyph.
---
---Only ever pads *to* the width. Callers wanting a gap after the column append it
---themselves: folding a minimum gap in here reads as "width plus the gap" but cannot be,
---since the two would have to be added rather than maxed, and a column narrower than the
---widest entry would silently lose its alignment instead of its gap.
---@param text string
---@param width number
---@return string
function M.pad(text, width)
	return text .. string.rep(" ", math.max(width - vim.fn.strdisplaywidth(text), 0))
end

--=============================================================================
-- Help overlay
--=============================================================================

---A float listing what a surface's keys do, and what its markers mean.
---
---Shared, because both lists need one for the same reason: a border can hold a handful of keys and
---nvim clips whatever is too long for the window without saying so, so the complete answer cannot
---live down there. The borders advertise `?` and this says the rest.
---
---Unfocusable by default. Telescope closes a picker the moment its prompt buffer is left, so the
---chat list cannot afford to focus this; the inline list can, but there is nothing to do in here
---anyway and keys are better left going to the list underneath.
---@param rows { header?: string, key?: string, key_hl?: string, desc?: string }[] An empty entry
---   leaves a blank line
---@param opts { title: string, key_column?: number, zindex?: number }
---@return { close: fun(), is_open: fun(): boolean }
function M.help(rows, opts)
	M.ensure_highlights()
	local key_column = opts.key_column or 13
	local ns = api.nvim_create_namespace("ducktape_help")

	local lines, all_highlights, width = {}, {}, 0
	for _, row in ipairs(rows) do
		local text, highlights
		if row.header then
			text, highlights = M.render({ { "  " }, { row.header, "DucktapeListHeader" } })
		elseif row.key then
			text, highlights = M.render({
				{ "  " },
				{ M.pad(row.key, key_column), row.key_hl or "DucktapeListKey" },
				{ row.desc, "DucktapeListDim" },
			})
		else
			text, highlights = "", {}
		end
		table.insert(lines, text)
		table.insert(all_highlights, highlights)
		width = math.max(width, vim.fn.strdisplaywidth(text))
	end

	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	for lnum, highlights in ipairs(all_highlights) do
		for _, hl in ipairs(highlights) do
			pcall(api.nvim_buf_set_extmark, buf, ns, lnum - 1, hl[1][1], {
				end_col = hl[1][2],
				hl_group = hl[2],
			})
		end
	end
	vim.bo[buf].modifiable = false

	width = math.min(width + 2, vim.o.columns - 4)
	local height = math.min(#lines, vim.o.lines - 4)
	local win = api.nvim_open_win(buf, false, {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0),
		col = math.max(math.floor((vim.o.columns - width) / 2), 0),
		style = "minimal",
		border = "rounded",
		title = opts.title,
		title_pos = "center",
		focusable = false,
		noautocmd = true,
		zindex = opts.zindex or 300,
	})

	local handle = {}
	function handle.is_open()
		return win ~= nil and api.nvim_win_is_valid(win)
	end
	function handle.close()
		if win and api.nvim_win_is_valid(win) then
			pcall(api.nvim_win_close, win, true)
		end
		if api.nvim_buf_is_valid(buf) then
			pcall(api.nvim_buf_delete, buf, { force = true })
		end
		win = nil
	end
	return handle
end

--=============================================================================
-- Highlights — Catppuccin Mocha palette
--=============================================================================

-- Every ducktape surface draws from one palette, so the groups are defined once here rather than
-- per module: the winbar, the chat footer, the chat list and the provider picker had started
-- to keep their own copies of the same colours, which is how two of them drift apart.

local hl_ready = false

---Mix a palette colour into the editor's own background.
---
---Catppuccin builds its diff backgrounds this way — its DiffDelete is the palette red at 18% over
---`base`, exactly — so a wash at that depth sits with the theme instead of fighting it. Derived
---rather than written out as a hex so another flavour, or a light theme, gets a wash of the right
---depth for *its* background rather than one tuned against Mocha's.
---@param colour string `#rrggbb` to mix in
---@param alpha number 0..1, how much of it
---@param over string `#rrggbb` to mix into when the theme leaves Normal's background unset
---@return string
local function wash(colour, alpha, over)
	local normal = api.nvim_get_hl(0, { name = "Normal", link = false })
	local bg = normal.bg ~= nil and ("#%06x"):format(normal.bg) or over
	local channel = function(hex, at)
		return tonumber(hex:sub(at, at + 1), 16) or 0
	end
	local out = {}
	for _, at in ipairs({ 2, 4, 6 }) do
		local from = channel(bg, at)
		table.insert(out, math.floor(from + (channel(colour, at) - from) * alpha + 0.5))
	end
	return ("#%02x%02x%02x"):format(out[1], out[2], out[3])
end

---Define every `Ai*` highlight group. Latches, so it is cheap to call from anywhere.
---
---Call it from a scheduled context at startup: the fallback branch below is permanent once
---this has run, so resolving the palette before catppuccin has loaded would leave the whole
---UI in stand-in colours for the rest of the session.
function M.ensure_highlights()
	if hl_ready then
		return
	end
	hl_ready = true

	local p = {}
	local ok, palette = pcall(function()
		return require("catppuccin.palettes").get_palette()
	end)
	if ok and palette then
		p = vim.tbl_extend("keep", { key = palette.blue }, palette)
	else
		-- Teal where it shows — a fallback that screams rather than looking plausible
		p = {
			base = "#1e1e2e", -- only ever mixed into, so this one is honest rather than loud
			mauve = "#94e2d5",
			peach = "#94e2d5",
			pink = "#94e2d5",
			blue = "#c6a0f6", -- mauve
			key = "#94e2d5",
			green = "#a6e3a1",
			yellow = "#f9e2af",
			red = "#f38ba8",
			lavender = "#b4befe",
			overlay1 = "#7f849c",
			overlay0 = "#6c7086",
			subtext0 = "#a6adc8",
			surface1 = "#585b70",
			surface0 = "#45475a",
		}
	end

	local set = function(name, opts)
		vim.api.nvim_set_hl(0, name, opts)
	end

	-- Chat winbar
	set("DucktapeWinBarProvider", { fg = p.mauve, bg = "NONE" })
	set("DucktapeWinBarModel", { fg = p.pink, bg = "NONE" })
	set("DucktapeWinBarTitle", { fg = p.blue, bg = "NONE" })
	set("DucktapeWinBarDim", { fg = p.surface1, bg = "NONE" })
	set("DucktapeWinBarSep", { fg = p.surface0, bg = "NONE" })

	-- Chat footer. It sits in the statusline, so it has to carry StatusLine's own background
	-- or it reads as a hole punched in the bar. A transparent theme leaves bg nil, which is
	-- then the right answer anyway.
	local sl = vim.api.nvim_get_hl(0, { name = "StatusLine", link = false })
	local bg = sl and sl.bg or nil
	set("DucktapeFooterKey", { fg = p.key, bg = bg, bold = true })
	set("DucktapeFooterLabel", { fg = p.subtext0, bg = bg })
	set("DucktapeFooterDim", { fg = p.overlay0, bg = bg })

	-- The lines an inline request is running against, and the lines whose reply is waiting on you. A
	-- background rather than a foreground: the code underneath keeps its own syntax colours, which is
	-- the point — it is being marked, not rewritten yet.
	--
	-- Which of the two hues means which is a preference; that it is *these* two is measured. They are
	-- ΔE 15 apart in Lab, further than either is from anything else that paints a background in the
	-- same buffer moments later: every neutral grey is taken (surface0 is ColorColumn, surface1 is
	-- Visual), green is DiffAdd, blue is DiffChange and DiffText, blue-teal is Search. Peach collides
	-- with none of them, and mauve's nearest neighbour is DiffDelete at ΔE 8.1 — teal, the other
	-- candidate, was ΔE 5.9 from DiffAdd, which a pending diff paints over these very lines. Yellow
	-- would have matched the ↻ but lands on Visual over this base, so a marked range would read as a
	-- selection.
	set("DucktapeInlineRange", { bg = wash(p.mauve, 0.18, p.base) })
	set("DucktapeInlineWaiting", { bg = wash(p.peach, 0.18, p.base) })

	-- Chat list and the provider/model picker
	set("DucktapeListReady", { fg = p.green, bg = "NONE" })
	set("DucktapeListStarting", { fg = p.yellow, bg = "NONE" })
	set("DucktapeListDead", { fg = p.red, bg = "NONE" })
	set("DucktapeListCurrent", { fg = p.lavender, bg = "NONE", bold = true })
	set("DucktapeListDim", { fg = p.overlay1, bg = "NONE" })
	set("DucktapeListHeader", { fg = p.mauve, bg = "NONE", bold = true })
	set("DucktapeListKey", { fg = p.blue, bg = "NONE", bold = true })
end

return M
