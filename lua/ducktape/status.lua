-- Status panel: every provider option for both scopes in one interactive buffer.

local M = {}

local api = vim.api
local ui = require("ducktape.ui")

local HL = {
	label = "Comment",
	value = "Normal",
	editing = "String",
	cursor = "CursorLine",
	reach = "DiagnosticVirtualTextHint",
	border = "FloatBorder",
	title = "FloatTitle",
}

local state = {
	rows = {},
	cursor = 1,
	editing = nil,
	editing_idx = nil,
}

local buf, win

---@return string|nil
local function focused_chat_provider()
	local chat = require("codecompanion.interactions.chat").last_chat()
	if not chat then
		return nil
	end
	if not api.nvim_buf_is_valid(chat.bufnr) then
		return nil
	end
	-- Buffer-recorded provider wins for restored chats; current selection otherwise.
	return chat._ducktape_provider
		or require("ducktape.providers").provider_for_adapter(chat.adapter and chat.adapter.name)
end

---Live session option for a category, if a matching chat is focused.
---@param scope "inline"|"chat"
---@param provider string
---@param category string|nil
---@return table|nil
local function live_option(scope, provider, category)
	if scope ~= "chat" or not category then
		return nil
	end
	local chat = require("codecompanion.interactions.chat").last_chat()
	if not chat or not api.nvim_buf_is_valid(chat.bufnr) then
		return nil
	end
	if focused_chat_provider() ~= provider then
		return nil
	end
	local conn = chat.acp_connection
	if not conn or not conn.get_config_options then
		return nil
	end
	for _, opt in ipairs(conn:get_config_options()) do
		if opt.category == category and opt.type == "select" then
			return opt
		end
	end
end

---@param scope "inline"|"chat"
---@param provider string
---@param key string
---@return string|nil
local function live_session_value(scope, provider, key)
	local spec = require("ducktape.providers").spec(provider)
	local option = spec and (spec.options or {})[key]
	local opt = option and live_option(scope, provider, option.category)
	return opt and opt.currentValue or nil
end

---Live session values for an option. Nil means "fall back to the spec's list"; an empty table
---means the agent offers nothing.
---@param scope "inline"|"chat"
---@param provider string
---@param option table
---@return string[]|nil
local function live_session_values(scope, provider, option)
	local opt = live_option(scope, provider, option.category)
	if not opt then
		return nil
	end
	local ok, ACP = pcall(require, "codecompanion.acp")
	if not ok then
		return nil
	end
	local values = {}
	for _, value in ipairs(ACP.flatten_config_options(opt.options or {})) do
		table.insert(values, value.value)
	end
	return values
end

---@return table[] rows
local function build_rows()
	local providers = require("ducktape.providers")
	local out = {}

	for _, scope in ipairs({ "inline", "chat" }) do
		local sel = providers.current(scope)

		local reach = ""
		if scope == "inline" then
			local transport = providers.transport(sel.provider, false)
			local r = providers.transports[transport]
			reach = r.read and " (can‑read‑repo)" or " (tool‑free)"
		end

		local label = scope == "inline" and "Inline" or "Chat"
		table.insert(out, {
			kind = "provider",
			scope = scope,
			label = label,
			provider = sel.provider,
			reach = reach,
		})

		local spec = providers.providers[sel.provider]
		local option_keys = scope == "inline" and spec.inline_options or spec.chat_options
		for _, key in ipairs(option_keys or {}) do
			local option = spec.options[key]
			if option then
				local value = live_session_value(scope, sel.provider, key) or sel.opts[key]
				table.insert(out, {
					kind = "option",
					scope = scope,
					key = key,
					label = option.label or key,
					category = option.category,
					value = value,
					built_for_provider = sel.provider,
					get_values = function()
						local live = live_session_values(scope, sel.provider, option)
						if live then
							return live
						end
						if option.dynamic then
							if key == "model" then
								return providers.models(sel.provider, sel.opts.endpoint)
							end
							return {}
						end
						return option.values or {}
					end,
				})
			end
		end
	end

	return out
end

---@return string
local function render_row(row, editing, edit_idx)
	if row.kind == "provider" then
		local display_provider = row.provider
		local reach = row.reach
		if editing and edit_idx then
			local providers = require("ducktape.providers")
			local names = providers.names()
			local previewed = names[edit_idx]
			if previewed then
				display_provider = "◂ " .. previewed .. " ▸"
				if row.scope == "inline" then
					local transport = providers.transport(previewed, false)
					local r = providers.transports[transport]
					reach = r.read and " (can‑read‑repo)" or " (tool‑free)"
				end
			end
		end
		local provider_text = string.format("%-8s %s%s", row.label .. ":", display_provider, reach)
		if editing then
			return "▶ " .. provider_text
		end
		return "  " .. provider_text
	end

	if row.kind == "option" then
		local prefix = editing and "▶  " or "   "
		local value = row.value or "—"
		if editing and row.get_values then
			local values = row.get_values()
			if #values > 0 then
				local idx = edit_idx or 1
				value = "◂ " .. (values[idx] or value) .. " ▸"
			end
		end
		return string.format("%s%-7s %s", prefix, row.label .. ":", value)
	end

	return ""
end

local function render()
	if not buf or not api.nvim_buf_is_valid(buf) then
		return
	end

	local lines = {}
	for i, row in ipairs(state.rows) do
		local editing = state.editing == i
		table.insert(lines, render_row(row, editing, state.editing_idx))
	end

	vim.bo[buf].modifiable = true
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false

	api.nvim_buf_clear_namespace(buf, -1, 0, -1)
	api.nvim_buf_add_highlight(buf, -1, HL.cursor, state.cursor - 1, 0, -1)

	if not win or not api.nvim_win_is_valid(win) then
		return
	end
	api.nvim_win_set_cursor(win, { state.cursor, 0 })
end

---Apply a chat option to the live session.
---@param row table
---@param value string
local function apply_to_session(row, value)
	local chat = require("codecompanion.interactions.chat").last_chat()
	if not chat or not api.nvim_buf_is_valid(chat.bufnr) then
		return
	end
	-- last_chat() follows BufEnter, so guard against committing to a chat whose provider changed.
	if focused_chat_provider() ~= row.built_for_provider then
		ui.say(
			"[ducktape] focused chat's provider changed since this row was built — reopen the panel to retry",
			vim.log.levels.WARN
		)
		return
	end
	local conn = chat.acp_connection
	if not conn then
		return
	end
	if not row.category then
		if conn.set_config_option then
			pcall(conn.set_config_option, conn, "agent", value)
		end
		return
	end
	local ACP = require("codecompanion.acp")
	for _, opt in ipairs(conn:get_config_options()) do
		if opt.category == row.category and opt.type == "select" then
			for _, v in ipairs(ACP.flatten_config_options(opt.options or {})) do
				if v.value == value then
					conn:set_config_option(opt.id, value)
					return
				end
			end
		end
	end
end

local function apply_and_stash(row, value)
	local providers = require("ducktape.providers")
	local scope = row.scope

	if row.kind == "provider" then
		providers.set_provider(scope, value)
		return
	end

	-- Guard against stale rows: the focused chat/provider may have changed while the panel was open.
	if row.built_for_provider and row.built_for_provider ~= providers.current(scope).provider then
		ui.say(
			"[ducktape] provider changed since this row was built — reopen the panel to retry",
			vim.log.levels.WARN
		)
		return
	end

	if scope == "chat" then
		apply_to_session(row, value)
	end
	providers.set_option(scope, row.key, value)

	if scope == "inline" then
		local pool = require("ducktape.acp_pool")
		pool.drain_provider(providers.current("inline").provider)
	end
end

local function commit_edit()
	if not state.editing then
		return
	end
	local row = state.rows[state.editing]
	if not row then
		return
	end

	if row.kind == "provider" then
		local providers = require("ducktape.providers")
		local names = providers.names()
		local idx = state.editing_idx
		if idx and names[idx] then
			apply_and_stash(row, names[idx])
			state.rows = build_rows()
			if state.cursor > #state.rows then
				state.cursor = #state.rows
			end
		end
	elseif row.kind == "option" and row.get_values then
		local values = row.get_values()
		local idx = state.editing_idx
		if idx and values[idx] then
			apply_and_stash(row, values[idx])
			state.rows = build_rows()
		end
	end

	state.editing = nil
	state.editing_idx = nil
	render()
end

local function cancel_edit()
	state.editing = nil
	state.editing_idx = nil
	state.rows = build_rows()
	render()
end

local function cycle_values(delta)
	if not state.editing then
		return
	end
	local row = state.rows[state.editing]
	if not row then
		return
	end

	local values
	if row.kind == "provider" then
		local providers = require("ducktape.providers")
		values = providers.names()
	elseif row.kind == "option" and row.get_values then
		values = row.get_values()
	end

	if not values or #values == 0 then
		return
	end

	local idx = state.editing_idx or 1
	idx = ((idx - 1 + delta) % #values) + 1
	state.editing_idx = idx
	render()
end

local function open()
	if win and api.nvim_win_is_valid(win) then
		api.nvim_set_current_win(win)
		return
	end

	-- Prime the opencode model list so the Model row can cycle Go models, not just free relay.
	-- Doing it here avoids a subprocess call on every keypress.
	require("ducktape.providers").opencode_models_async(function() end)

	state.rows = build_rows()
	state.cursor = 1
	state.editing = nil
	state.editing_idx = nil

	buf = api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = true

	-- Refresh on refocus so the panel does not show stale values. Skipped while editing.
	api.nvim_create_autocmd("BufEnter", {
		buffer = buf,
		callback = function()
			if state.editing then
				return
			end
			state.rows = build_rows()
			if state.cursor > #state.rows then
				state.cursor = #state.rows
			end
			render()
		end,
	})

	render()

	local keys = require("ducktape.keys")
	local width = 42
	local height = math.min(#state.rows, 20)
	win = api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		width = width,
		height = height,
		style = "minimal",
		border = require("ducktape.config").get().ui.border,
		title = " AI ",
		title_pos = "center",
		-- Footer names the configured keys so remaps stay honest.
		footer = (" %s edit · %s/%s cycle · %s close "):format(
			keys.panel_label("status", "edit"),
			keys.panel_label("status", "prev_value"),
			keys.panel_label("status", "next_value"),
			keys.panel_label("status", "close")
		),
		footer_pos = "center",
	})

	vim.bo[buf].modifiable = false

	local function move(delta)
		state.cursor = math.min(math.max(state.cursor + delta, 1), #state.rows)
		render()
	end

	local function edit_or_commit()
		if state.editing then
			return commit_edit()
		end
		state.editing = state.cursor
		local row = state.rows[state.cursor]
		local values, current
		if row and row.kind == "provider" then
			values = require("ducktape.providers").names()
			current = row.provider
		elseif row and row.kind == "option" and row.get_values then
			values = row.get_values()
			current = row.value
		end
		local idx
		for i, v in ipairs(values or {}) do
			if v == current then
				idx = i
				break
			end
		end
		state.editing_idx = idx or 1
		render()
	end

	local function close_or_cancel()
		if state.editing then
			cancel_edit()
		else
			M.close()
		end
	end

	require("ducktape.keys").bind_panel("status", buf, {
		down = function()
			move(1)
		end,
		up = function()
			move(-1)
		end,
		next_value = function()
			cycle_values(1)
		end,
		prev_value = function()
			cycle_values(-1)
		end,
		edit = edit_or_commit,
		close = close_or_cancel,
	})
end

---@return boolean
function M.is_open()
	return win and api.nvim_win_is_valid(win)
end

function M.close()
	if win and api.nvim_win_is_valid(win) then
		api.nvim_win_close(win, true)
	end
	win = nil
	buf = nil
	state.rows = {}
	state.cursor = 1
	state.editing = nil
end

function M.toggle()
	if M.is_open() then
		M.close()
	else
		open()
	end
end

return M
