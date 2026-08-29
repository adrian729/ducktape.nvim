-- Shared presentation helpers: progress virtual text, message floats, list rendering, and
-- highlight definitions.

local api = vim.api

local M = {}

---@return string[]
local function spinner()
	local ok, frames = pcall(function()
		return require("ducktape.config").get().ui.spinner
	end)
	if ok and type(frames) == "table" and #frames > 0 then
		return frames
	end
	return { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
end
M.spinner = spinner

local ns = api.nvim_create_namespace("ducktape_ui")

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

---@param bufnr number
---@param row number 0-indexed
---@return number
local function room_on(bufnr, row)
	local line = api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
	return math.max(20, width_of(bufnr) - vim.fn.strdisplaywidth(line) - 6)
end

---Yes/no confirm using `y`/`n` rather than action-named buttons.
---@param question string
---@param opts? { default?: boolean } Defaults to no for irreversible actions
---@return boolean
function M.confirm(question, opts)
	local yes_by_default = opts ~= nil and opts.default == true
	local answered_yes = vim.fn.confirm(question, "&Yes\n&No", yes_by_default and 1 or 2, "Question") == 1
	vim.cmd("redraw")
	return answered_yes
end

---Truncate by display width, never mid-glyph.
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

---Echo a message that avoids "Press ENTER". Long messages are recorded whole to `:messages` while
---the command line shows only the fitted head.
---@param msg string
---@param level? number `vim.log.levels` value; INFO and below go unhighlighted
---@param opts? { history?: boolean }
function M.say(msg, level, opts)
	local hl = LEVEL_HL[level]
	local record = not (opts ~= nil and opts.history == false)
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

---Animated virtual text following a moving row or region.
---@param bufnr number
---@param row_fn fun(): number|nil, number|nil 0-indexed start row and exclusive end row
---@param label string
---@return { stop: fun(), set_label: fun(text: string) }
function M.progress(bufnr, row_fn, label)
	M.ensure_highlights()
	local mark, tint, frame = nil, nil, 1
	local timer = vim.uv.new_timer()
	local handle = {}
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
			local frames = spinner()
			local text = (" %s %s "):format(frames[frame], ellipsise(label, room_on(bufnr, row)))
			mark = place(mark, row, {
				virt_text = { { text, "DiagnosticVirtualTextHint" } },
				virt_text_pos = "eol",
				hl_mode = "combine",
			})
			return
		end

		local indent = (api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""):match("^%s*")
		local span = e0 - s0
		local extent = span > 0 and ("%d line%s"):format(span, span == 1 and "" or "s") or "insert"
		local head = ("%s %s "):format(indent, spinner()[frame])
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
			sign_text = "↻",
			sign_hl_group = "DucktapeListStarting",
		})

		if span > 0 then
			local last = math.max(row, math.min(e0 - 1, rows - 1))
			local text = api.nvim_buf_get_lines(bufnr, last, last + 1, false)[1] or ""
			-- hl_eol keeps the tint as one block rather than a ragged edge.
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
				frame = (frame % #spinner()) + 1
				render()
			end)
		)
	end

	return handle
end

---Standing marker on a range for a reply waiting on the user.
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

---Float for a reply that must not be inserted into the buffer.
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
		border = require("ducktape.config").get().ui.border,
		title = (" %s — <CR> open in a chat · q dismiss "):format(opts.title),
		title_pos = "center",
	}

	-- Anchor at the target row when the buffer is on screen; otherwise centre.
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

	require("ducktape.keys").bind_panel("message", buf, {
		close = close,
		confirm = function()
			close()
			if opts.on_confirm then
				opts.on_confirm()
			end
		end,
	})

	return win
end

---Assemble a display line from {text, highlight} segments, accumulating byte offsets for Telescope.
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

---Pad to display width so multibyte glyphs stay aligned.
---@param text string
---@param width number
---@return string
function M.pad(text, width)
	return text .. string.rep(" ", math.max(width - vim.fn.strdisplaywidth(text), 0))
end

---Help overlay listing keys and marker meanings. Unfocusable: Telescope closes the picker when
---its prompt buffer is left.
---@param rows { header?: string, key?: string, key_hl?: string, desc?: string }[] Empty entry leaves a blank line
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
		border = require("ducktape.config").get().ui.border,
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

local hl_ready = false
local hl_augroup

---Mix a palette colour over the editor's own background.
---@param colour string `#rrggbb` to mix in
---@param alpha number 0..1
---@param over string `#rrggbb` fallback when Normal has no bg
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

---Define every `Ducktape*` highlight group. Latched; re-derives on `ColorScheme`.
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
		p = {
			base = "#1e1e2e",
			mauve = "#94e2d5",
			peach = "#94e2d5",
			pink = "#94e2d5",
			blue = "#c6a0f6",
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

	local overrides = {}
	local cfg_ok, cfg = pcall(function()
		return require("ducktape.config").get().ui.highlights
	end)
	if cfg_ok and type(cfg) == "table" then
		overrides = cfg
	end

	local defined = {}
	local set = function(name, opts)
		local final = vim.tbl_extend("force", opts, overrides[name] or {})
		final.default = true
		table.insert(defined, name)
		vim.api.nvim_set_hl(0, name, final)
	end

	set("DucktapeWinBarProvider", { fg = p.mauve, bg = "NONE" })
	set("DucktapeWinBarModel", { fg = p.pink, bg = "NONE" })
	set("DucktapeWinBarTitle", { fg = p.blue, bg = "NONE" })
	set("DucktapeWinBarDim", { fg = p.surface1, bg = "NONE" })
	set("DucktapeWinBarSep", { fg = p.surface0, bg = "NONE" })

	local sl = vim.api.nvim_get_hl(0, { name = "StatusLine", link = false })
	local bg = sl and sl.bg or nil
	set("DucktapeFooterKey", { fg = p.key, bg = bg, bold = true })
	set("DucktapeFooterLabel", { fg = p.subtext0, bg = bg })
	set("DucktapeFooterDim", { fg = p.overlay0, bg = bg })

	-- Colours chosen to avoid collisions with common built-in backgrounds (DiffAdd, DiffChange,
	-- Visual, Search, etc.). Mauve and peach are far enough apart and from existing groups.
	set("DucktapeInlineRange", { bg = wash(p.mauve, 0.18, p.base) })
	set("DucktapeInlineWaiting", { bg = wash(p.peach, 0.18, p.base) })

	set("DucktapeListReady", { fg = p.green, bg = "NONE" })
	set("DucktapeListStarting", { fg = p.yellow, bg = "NONE" })
	set("DucktapeListDead", { fg = p.red, bg = "NONE" })
	set("DucktapeListCurrent", { fg = p.lavender, bg = "NONE", bold = true })
	set("DucktapeListDim", { fg = p.overlay1, bg = "NONE" })
	set("DucktapeListHeader", { fg = p.mauve, bg = "NONE", bold = true })
	set("DucktapeListKey", { fg = p.blue, bg = "NONE", bold = true })

	if not hl_augroup then
		hl_augroup = vim.api.nvim_create_augroup("DucktapeHighlights", { clear = true })
		vim.api.nvim_create_autocmd("ColorScheme", {
			group = hl_augroup,
			callback = function()
				hl_ready = false
				vim.schedule(M.ensure_highlights)
			end,
		})
	end
	M._groups = defined
end

return M
