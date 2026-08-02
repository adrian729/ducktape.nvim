-- Status panel: every provider option for both scopes in one interactive buffer.
-- Rows are generated from providers.lua's schema — a new provider option appears here
-- with no edit to this file.
--
-- j/k or arrows: navigate  Enter: edit  h/l: cycle values  q/Esc: close
-- Chat option changes apply live to the focused chat's session AND update stored defaults.
-- Inline option changes update stored defaults; model changes also drain the pool.

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
	editing = nil, -- row index, or nil
	editing_idx = nil, -- index into the option's value list
}

local buf, win

--=============================================================================
-- Row generation
--=============================================================================

---Options that exist only on the live session (category = nil) and are therefore
---chat-only with no stored default to display when no chat is focused.
local CHAT_ONLY_OPTIONS = { agent = true }

---@return string|nil provider name or nil
local function focused_chat_provider()
	local chat = require("codecompanion.interactions.chat").last_chat()
	if not chat then
		return nil
	end
	if not api.nvim_buf_is_valid(chat.bufnr) then
		return nil
	end
	-- The chat's adapter name maps back to a provider name via providers.lua
	local name = chat.adapter and chat.adapter.name
	if name == "claude_code" then
		return "claude"
	end
	if name == "opencode" then
		return "opencode"
	end
	-- HTTP adapters: "ollama" or "ollama_cloud"
	if name == "ollama" or name == "ollama_cloud" then
		return "ollama"
	end
end

---@param scope "inline"|"chat"
---@param provider string
---@param key string
---@return string|nil
local function live_session_value(scope, provider, key)
	if scope ~= "chat" then
		return nil
	end
	local chat = require("codecompanion.interactions.chat").last_chat()
	if not chat or not api.nvim_buf_is_valid(chat.bufnr) then
		return nil
	end
	-- The focused chat may belong to a different provider than the one this
	-- row/value is being read for (last_chat() tracks BufEnter, not our own
	-- provider selection) — reading against it would return the wrong session.
	if focused_chat_provider() ~= provider then
		return nil
	end
	local conn = chat.acp_connection
	if not conn or not conn.get_config_options then
		return nil
	end
	local providers = require("ducktape.providers")
	local option = providers.providers[provider].options[key]
	if not option or not option.category then
		return nil
	end
	for _, opt in ipairs(conn:get_config_options()) do
		if opt.category == option.category and opt.type == "select" then
			return opt.currentValue
		end
	end
end

---@return table[] rows
local function build_rows()
	local providers = require("ducktape.providers")
	local out = {}

	for _, scope in ipairs({ "inline", "chat" }) do
		local sel = providers.current(scope)

		-- Provider row with reach marker (inline only)
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

		-- Option rows
		local spec = providers.providers[sel.provider]
		local option_keys = scope == "inline" and spec.inline_options or spec.chat_options
		for _, key in ipairs(option_keys or {}) do
			local option = spec.options[key]
			if option then
				-- Value: live session first, then stored default, then nil
				local value = live_session_value(scope, sel.provider, key) or sel.opts[key]
				table.insert(out, {
					kind = "option",
					scope = scope,
					key = key,
					label = option.label or key,
					category = option.category,
					value = value,
					-- Captured so a commit against a since-gone-stale `value` can be checked
					-- against the CURRENT provider at commit time (see apply_and_stash).
					built_for_provider = sel.provider,
					-- For cycling: the list of possible values
					get_values = function()
						if option.dynamic then
							if sel.provider == "opencode" then
								-- Live session first (mirrors the "Dynamic from
								-- live session" lookup below) so the real
								-- current model is found even when it falls
								-- outside the static free-tier list.
								if scope == "chat" and option.category and focused_chat_provider() == sel.provider then
									local chat = require("codecompanion.interactions.chat").last_chat()
									local conn = chat and chat.acp_connection
									if conn then
										local ACP = require("codecompanion.acp")
										for _, opt in ipairs(conn:get_config_options()) do
											if opt.category == option.category and opt.type == "select" then
												local vals = {}
												for _, v in ipairs(ACP.flatten_config_options(opt.options or {})) do
													table.insert(vals, v.value)
												end
												return vals
											end
										end
									end
								end
								return providers.opencode_models()
							end
							if sel.provider == "ollama" and scope == "chat" then
								-- Without a live session, use stored values
								return {}
							end
						end
						-- Dynamic from live session (tried first so the live
						-- session's actual current value is always found, even
						-- when it falls outside the static list below)
						if scope == "chat" and focused_chat_provider() == sel.provider then
							local chat = require("codecompanion.interactions.chat").last_chat()
							local conn = chat and chat.acp_connection
							if conn and option.category then
								local ACP = require("codecompanion.acp")
								for _, opt in ipairs(conn:get_config_options()) do
									if opt.category == option.category and opt.type == "select" then
										local vals = {}
										for _, v in ipairs(ACP.flatten_config_options(opt.options or {})) do
											table.insert(vals, v.value)
										end
										return vals
									end
								end
							end
						end
						if option.values then
							return option.values
						end
						return {}
					end,
				})
			end
		end
	end

	return out
end

--=============================================================================
-- Rendering
--=============================================================================

---@return string
local function render_row(row, editing, edit_idx)
	if row.kind == "provider" then
		local display_provider = row.provider
		local reach = row.reach
		if editing and edit_idx then
			local providers = require("ducktape.providers")
			local names = vim.tbl_keys(providers.providers)
			table.sort(names)
			local previewed = names[edit_idx]
			if previewed then
				display_provider = "◂ " .. previewed .. " ▸"
				-- Reach is inline-only (see build_rows); recompute for the
				-- previewed provider so cycling doesn't show a stale marker.
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

	api.nvim_buf_set_option(buf, "modifiable", true)
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	api.nvim_buf_set_option(buf, "modifiable", false)

	-- Highlight cursor row
	api.nvim_buf_clear_namespace(buf, -1, 0, -1)
	api.nvim_buf_add_highlight(buf, -1, HL.cursor, state.cursor - 1, 0, -1)

	if not win or not api.nvim_win_is_valid(win) then
		return
	end
	api.nvim_win_set_cursor(win, { state.cursor, 0 })
end

--=============================================================================
-- Edit actions
--=============================================================================

---Apply a chat option to the live session.
---@param row table
---@param value string
local function apply_to_session(row, value)
	local chat = require("codecompanion.interactions.chat").last_chat()
	if not chat or not api.nvim_buf_is_valid(chat.bufnr) then
		return
	end
	-- The focused chat (last_chat()) may have changed provider since this row
	-- was built — writing against it would silently commit to the WRONG session.
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
		-- Agent: category = nil, set directly
		if conn.set_config_option then
			pcall(conn.set_config_option, conn, "agent", value)
		end
		return
	end
	local ACP = require("codecompanion.acp")
	for _, opt in ipairs(conn:get_config_options()) do
		if opt.category == row.category and opt.type == "select" then
			-- Resolve value id against the option's values
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

	-- Row values are captured at build_rows() time and can go stale while the panel
	-- stays open (see the BufEnter refresh in open()). If the provider changed since,
	-- committing would write this value into the WRONG provider's stored opts.
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
		local names = vim.tbl_keys(providers.providers)
		table.sort(names)
		local idx = state.editing_idx
		if idx and names[idx] then
			apply_and_stash(row, names[idx])
			-- Rebuild rows: options change when provider changes
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
	-- Rebuild: revert displayed values to stored ones
	state.rows = build_rows()
	render()
end

--=============================================================================
-- Cycling
--=============================================================================

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
		values = vim.tbl_keys(providers.providers)
		table.sort(values)
	elseif row.kind == "option" and row.get_values then
		values = row.get_values()
	end

	if not values or #values == 0 then
		return
	end

	local idx = state.editing_idx or 1
	idx = ((idx - 1 + delta) % #values) + 1
	state.editing_idx = idx
	-- Show the cycled value inline without rebuilding
	render()
end

--=============================================================================
-- Window & keymaps
--=============================================================================

local function open()
	if win and api.nvim_win_is_valid(win) then
		api.nvim_set_current_win(win)
		return
	end

	-- Warms the opencode list so cycling its Model row can reach the Go subscription and not
	-- just the free relay tier. Asked for here rather than inside get_values because that runs
	-- on every keypress, and the answer comes out of a subprocess.
	require("ducktape.providers").opencode_models_async(function() end)

	state.rows = build_rows()
	state.cursor = 1
	state.editing = nil
	state.editing_idx = nil

	buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_option(buf, "buftype", "nofile")
	api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	api.nvim_buf_set_option(buf, "modifiable", true)

	-- Rows are only otherwise rebuilt on open()/commit/cancel, so if the panel is left
	-- open while live state changes elsewhere (chat switched, session restored, inline
	-- provider swapped), refresh on refocus rather than showing stale values. Skipped
	-- while editing so an in-progress edit isn't disrupted; buffer-scoped, so this is
	-- cleaned up automatically by bufhidden=wipe when the buffer goes away.
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

	local width = 42
	local height = math.min(#state.rows, 20)
	win = api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " AI ",
		title_pos = "center",
		footer = " ENTER edit · h/l cycle · q close ",
		footer_pos = "center",
	})

	api.nvim_buf_set_option(buf, "modifiable", false)

	local function on(lhs, fn)
		vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true })
	end

	on("j", function()
		state.cursor = math.min(state.cursor + 1, #state.rows)
		render()
	end)
	on("k", function()
		state.cursor = math.max(state.cursor - 1, 1)
		render()
	end)
	on("<down>", function()
		state.cursor = math.min(state.cursor + 1, #state.rows)
		render()
	end)
	on("<up>", function()
		state.cursor = math.max(state.cursor - 1, 1)
		render()
	end)
	on("<cr>", function()
		if state.editing then
			commit_edit()
			return
		end
		state.editing = state.cursor
		local row = state.rows[state.cursor]
		local values, current
		if row and row.kind == "provider" then
			values = vim.tbl_keys(require("ducktape.providers").providers)
			table.sort(values)
			current = row.provider
		elseif row and row.kind == "option" and row.get_values then
			values = row.get_values()
			current = row.value
		end
		local idx
		if values then
			for i, v in ipairs(values) do
				if v == current then
					idx = i
					break
				end
			end
		end
		state.editing_idx = idx or 1
		render()
	end)
	on("h", function()
		cycle_values(-1)
	end)
	on("l", function()
		cycle_values(1)
	end)
	on("<esc>", function()
		if state.editing then
			cancel_edit()
		else
			M.close()
		end
	end)
	on("q", function()
		if state.editing then
			cancel_edit()
		else
			M.close()
		end
	end)
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

---Toggle the status panel.
function M.toggle()
	if M.is_open() then
		M.close()
	else
		open()
	end
end

return M
