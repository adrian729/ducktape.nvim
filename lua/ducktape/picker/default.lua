-- The dependency-free backend: a float this plugin draws itself.
--
-- Exists so that no feature needs a picker plugin installed. It is not a telescope replacement and
-- does not try to be one — but it does filter, because the model picker's whole premise is that
-- typing "opus" gets you there, and a list you can only scroll would lose that.
--
-- Two windows: results above, a one-line prompt below. Filtering is substring, case-insensitive,
-- against each entry's `ordinal` — the same field and the same matcher telescope is given, so a
-- query behaves the same way in both.

local M = {}

local api = vim.api

---Always. That is the point of it.
---@return boolean
function M.available()
	return true
end

---@param spec table See ducktape.picker
---@return table handle
function M.open(spec)
	local ui = require("ducktape.ui")
	local keys = require("ducktape.keys")
	ui.ensure_highlights()

	local ns = api.nvim_create_namespace("DucktapePickerDefault")
	local all, shown, cursor = spec.entries(), {}, 1
	local results_buf, results_win, prompt_buf, prompt_win
	local handle = {}
	local closing = false

	local function is_valid(win)
		return win ~= nil and api.nvim_win_is_valid(win)
	end

	function handle.is_open()
		return is_valid(results_win)
	end

	function handle.close()
		if closing then
			return
		end
		closing = true
		for _, win in ipairs({ prompt_win, results_win }) do
			if is_valid(win) then
				pcall(api.nvim_win_close, win, true)
			end
		end
		for _, buf in ipairs({ prompt_buf, results_buf }) do
			if buf and api.nvim_buf_is_valid(buf) then
				pcall(api.nvim_buf_delete, buf, { force = true })
			end
		end
		results_win, prompt_win, results_buf, prompt_buf = nil, nil, nil, nil
	end

	---@return table|nil
	local function selected()
		return shown[cursor]
	end

	local function query()
		if not (prompt_buf and api.nvim_buf_is_valid(prompt_buf)) then
			return ""
		end
		return api.nvim_buf_get_lines(prompt_buf, 0, 1, false)[1] or ""
	end

	local function draw()
		if not (results_buf and api.nvim_buf_is_valid(results_buf)) then
			return
		end
		local lines = {}
		for _, entry in ipairs(shown) do
			table.insert(lines, entry.text or "")
		end
		if #lines == 0 then
			lines = { "  no matches" }
		end

		vim.bo[results_buf].modifiable = true
		api.nvim_buf_set_lines(results_buf, 0, -1, false, lines)
		vim.bo[results_buf].modifiable = false

		api.nvim_buf_clear_namespace(results_buf, ns, 0, -1)
		for lnum, entry in ipairs(shown) do
			for _, hl in ipairs(entry.highlights or {}) do
				pcall(api.nvim_buf_set_extmark, results_buf, ns, lnum - 1, hl[1][1], {
					end_col = hl[1][2],
					hl_group = hl[2],
				})
			end
		end
		if is_valid(results_win) and #shown > 0 then
			pcall(api.nvim_win_set_cursor, results_win, { math.min(cursor, #shown), 0 })
		end
	end

	---Substring, case-insensitive, on `ordinal` — matching what the telescope backend is given.
	local function filter()
		local q = vim.trim(query():lower())
		shown = {}
		for _, entry in ipairs(all) do
			if q == "" or (entry.ordinal or entry.text or ""):lower():find(q, 1, true) then
				table.insert(shown, entry)
			end
		end
		cursor = math.min(math.max(cursor, 1), math.max(#shown, 1))
		draw()
	end

	function handle.refresh()
		if not handle.is_open() then
			return
		end
		-- The selection is held by value across a refresh: these lists redraw while an agent answers,
		-- and re-selecting the first row every time would drag the cursor off whatever is being read.
		local previous = selected()
		all = spec.entries()
		filter()
		if previous then
			for i, entry in ipairs(shown) do
				if entry.value == previous.value then
					cursor = i
					break
				end
			end
			draw()
		end
	end

	local function move(delta)
		if #shown == 0 then
			return
		end
		cursor = ((cursor - 1 + delta) % #shown) + 1
		draw()
	end

	local function confirm()
		local entry = selected()
		handle.close()
		if entry and spec.on_select then
			spec.on_select(entry)
		end
	end

	-- Geometry: centred, wide enough for the widest row it has, with the prompt on its own line
	-- immediately below. Sized once — resizing under a reader as rows arrive is worse than a row
	-- being clipped.
	local width = 40
	for _, entry in ipairs(all) do
		width = math.max(width, vim.fn.strdisplaywidth(entry.text or ""))
	end
	width = math.min(width + 2, vim.o.columns - 4)
	local height = math.max(math.min(#all, vim.o.lines - 8), 1)
	local row = math.max(math.floor((vim.o.lines - height) / 2) - 2, 0)
	local col = math.max(math.floor((vim.o.columns - width) / 2), 0)
	local border = require("ducktape.config").get().ui.border

	results_buf = api.nvim_create_buf(false, true)
	results_win = api.nvim_open_win(results_buf, false, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = border,
		title = (" %s "):format(spec.title or "Select"),
		title_pos = "center",
		footer = spec.results_title and (" " .. spec.results_title .. " ") or nil,
		footer_pos = spec.results_title and "center" or nil,
	})
	vim.wo[results_win].cursorline = true
	vim.bo[results_buf].modifiable = false

	prompt_buf = api.nvim_create_buf(false, true)
	prompt_win = api.nvim_open_win(prompt_buf, true, {
		relative = "editor",
		width = width,
		height = 1,
		row = row + height + 2,
		col = col,
		style = "minimal",
		border = border,
		title = " filter ",
		title_pos = "left",
	})

	filter()

	-- Typing filters. `TextChanged` as well as `TextChangedI` so a normal-mode edit of the prompt —
	-- `dd`, a paste — is picked up too.
	api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
		buffer = prompt_buf,
		callback = filter,
	})

	local function map(lhs, fn, mode)
		vim.keymap.set(mode or { "i", "n" }, lhs, fn, { buffer = prompt_buf, nowait = true })
	end

	-- Insert mode from the start, like every other picker: the first thing a hand does is type.
	map("<C-n>", function()
		move(1)
	end)
	map("<C-p>", function()
		move(-1)
	end)
	map("<Down>", function()
		move(1)
	end)
	map("<Up>", function()
		move(-1)
	end)
	map("<CR>", confirm)
	map("<C-c>", handle.close)
	-- Normal mode gets the plain motions as well, for anyone who leaves insert to look around.
	map("j", function()
		move(1)
	end, "n")
	map("k", function()
		move(-1)
	end, "n")
	map("q", handle.close, "n")
	map("<Esc>", handle.close, "n")

	require("ducktape.picker").bind_actions(spec, {
		map = function(lhs, fn)
			map(lhs, fn)
		end,
		selected = selected,
		ctx = { refresh = handle.refresh, close = handle.close },
	})

	-- Leaving the prompt closes the whole thing, which is also what guarantees the results window
	-- never outlives it.
	api.nvim_create_autocmd("BufLeave", {
		buffer = prompt_buf,
		once = true,
		callback = function()
			vim.schedule(handle.close)
		end,
	})

	vim.cmd("startinsert")
	return handle
end

return M
