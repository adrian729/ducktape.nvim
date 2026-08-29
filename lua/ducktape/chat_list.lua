-- Picker over live chats and resumable sessions, scoped to the project via `ducktape.scope`.

local M = {}

local api = vim.api
local ui = require("ducktape.ui")
local scope = require("ducktape.scope")

local function ensure_highlights()
	vim.schedule(function()
		ui.ensure_highlights()
	end)
end

---@param iso string ISO-8601 timestamp
---@return string
local function relative_time(iso)
	local ts = os.time()
	local parts = {}
	local function push(val, unit)
		if val > 0 then
			table.insert(parts, val .. unit)
		end
	end
	local year, month, day, hour, min, sec = iso:match("(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
	if not year then
		return ""
	end
	local session_time = os.time({
		year = tonumber(year),
		month = tonumber(month),
		day = tonumber(day),
		hour = tonumber(hour),
		min = tonumber(min),
		sec = tonumber(sec),
	})
	local delta = math.max(0, ts - session_time)
	if delta < 60 then
		return "just now"
	end
	local minutes = math.floor(delta / 60)
	if minutes < 60 then
		return minutes .. "m ago"
	end
	local hours = math.floor(minutes / 60)
	if hours < 24 then
		return hours .. "h ago"
	end
	local days = math.floor(hours / 24)
	if days < 30 then
		return days .. "d ago"
	end
	return math.floor(days / 30) .. "mo ago"
end

---Acquire a connection capable of listing sessions. Prefers a live chat's connection.
---@param opts? { provider?: string }
---@return table|nil conn, string|nil provider, boolean|nil spawned
local function session_connection(opts)
	opts = opts or {}

	for _, bufnr in ipairs(_G.codecompanion_buffers or {}) do
		local chat = require("codecompanion.interactions.chat").buf_get_chat(bufnr)
		local conn = chat and chat.acp_connection
		if conn and conn:is_ready() and conn.session_id then
			local key = chat._ducktape_provider
				or require("ducktape.providers").provider_for_adapter(chat.adapter and chat.adapter.name)
			if key and (not opts.provider or opts.provider == key) then
				return conn, key
			end
		end
	end

	local providers = require("ducktape.providers")
	local adapters = require("codecompanion.adapters")
	local ACP = require("codecompanion.acp")

	local candidates = opts.provider and { opts.provider }
		or providers.names(function(_, name)
			return providers.resumable(name)
		end)

	for _, provider in ipairs(candidates) do
		local name = providers.acp_adapter(provider)
		if name then
			local adapter = adapters.resolve(name)
			if adapter then
				local conn = ACP.new({ adapter = adapter })
				if conn:connect_and_authenticate() then
					return conn, provider, true
				else
					pcall(conn.disconnect, conn)
				end
			end
		end
	end

	return nil, nil
end

---Fetch and cache resumable sessions filtered to the current project.
---@return { sessionId: string, title: string, updatedAt: string, cwd: string, provider: string }[]
local function resumable_sessions()
	if M._cached_sessions then
		return M._cached_sessions
	end

	local root = scope.root()
	if not root then
		return {}
	end

	local conn, provider, spawned = session_connection()
	if not conn then
		return {}
	end

	local raw = conn:session_list({ max_sessions = 500 })
	local renamed = require("ducktape.chat").saved_titles()
	local filtered = {}
	for _, s in ipairs(raw) do
		if scope.contains(s.cwd) then
			table.insert(filtered, {
				sessionId = s.sessionId,
				title = renamed[s.sessionId] or s.title or s.sessionId,
				updatedAt = s.updatedAt or "",
				cwd = s.cwd or "",
				provider = provider,
			})
		end
	end

	table.sort(filtered, function(a, b)
		return a.updatedAt > b.updatedAt
	end)

	M._cached_sessions = filtered
	if spawned and conn then
		pcall(conn.disconnect, conn)
	end

	return filtered
end

local STATE = {
	ready = { marker = "●", hl = "DucktapeListReady", label = "ready" },
	starting = { marker = "◌", hl = "DucktapeListStarting", label = "starting" },
	dead = { marker = "✕", hl = "DucktapeListDead", label = "agent gone" },
	none = { marker = "·", hl = "DucktapeListDim", label = "no agent" },
}

---Classify a chat's agent connection.
---@param chat table|nil
---@return "ready"|"starting"|"dead"|"none"
local function chat_state(chat)
	if not chat then
		return "none"
	end
	if not (chat.adapter and chat.adapter.type == "acp") then
		return "none"
	end

	local conn = chat.acp_connection
	if not conn then
		return "starting"
	end
	if conn:is_connected() then
		return "ready"
	end
	if conn._state and conn._state.handle ~= nil and conn.adapter_modified == nil then
		return "dead"
	end
	return "starting"
end

---@return { bufnr: number, title: string, session_id: string|nil, provider: string, model: string, state: string, visible: boolean }[]
local function live_chats()
	local out = {}
	local seen = {}
	for _, bufnr in ipairs(_G.codecompanion_buffers or {}) do
		if api.nvim_buf_is_valid(bufnr) and not seen[bufnr] then
			seen[bufnr] = true
			local chat = require("codecompanion.interactions.chat").buf_get_chat(bufnr)
			local title = (chat and chat.title) or (api.nvim_buf_get_name(bufnr):match("([^/]+)$") or "chat")
			local session_id = chat and chat.acp_connection and chat.acp_connection.session_id
			local provider = (chat and chat._ducktape_provider) or "?"
			local model = (chat and chat._ducktape_model) or "?"
			table.insert(out, {
				bufnr = bufnr,
				title = title,
				session_id = session_id,
				provider = provider,
				model = model,
				state = chat_state(chat),
				visible = #vim.fn.win_findbuf(bufnr) > 0,
			})
		end
	end
	return out
end

---@return table<string, string>
local function saved_titles()
	return require("ducktape.chat").saved_titles()
end

local render = ui.render

---@param opts? { current_buf?: number }
---@return table
local function picker(opts)
	opts = opts or {}
	local live = live_chats()
	local sessions = resumable_sessions()

	local entries = {}

	local live_session_ids = {}
	for _, chat in ipairs(live) do
		if chat.session_id then
			live_session_ids[chat.session_id] = true
		end
	end

	for _, chat in ipairs(live) do
		local is_current = opts.current_buf ~= nil and chat.bufnr == opts.current_buf
		local state = STATE[chat.state] or STATE.none

		local note = ""
		if chat.state ~= "ready" then
			note = ("  (%s)"):format(state.label)
		elseif not chat.visible then
			note = "  (hidden)"
		end

		local text, highlights = render({
			{ is_current and "▶ " or "  ", is_current and "DucktapeListCurrent" or nil },
			{ state.marker .. " ", state.hl },
			{ chat.title, is_current and "DucktapeListCurrent" or "DucktapeWinBarTitle" },
			{ "  " },
			{ chat.provider, "DucktapeWinBarProvider" },
			{ " · " },
			{ chat.model, "DucktapeWinBarModel" },
			{ note, "DucktapeListDim" },
		})

		local entry = {
			value = chat,
			ordinal = (is_current and "0" or "1") .. chat.title,
			text = text,
			highlights = highlights,
			kind = "live",
		}
		if is_current then
			table.insert(entries, 1, entry)
		else
			table.insert(entries, entry)
		end
	end

	local listed_titles = {}
	for _, s in ipairs(sessions) do
		listed_titles[s.sessionId] = s.title
	end

	local pending_ids = {}
	for _, entry in ipairs(require("ducktape.chat").pending_chats()) do
		if not (entry.session_id and live_session_ids[entry.session_id]) then
			if entry.session_id then
				pending_ids[entry.session_id] = true
			end
			local sid = entry.session_id
			local title = (sid and saved_titles()[sid]) or entry.title or (sid and listed_titles[sid])
			local text, highlights = render({
				{ "  ○ ", "DucktapeListDim" },
				{ title or "untitled chat" },
				{ "  " .. tostring(entry.provider or "?"), "DucktapeWinBarProvider" },
				{ " · " },
				{ tostring(entry.model or "?"), "DucktapeWinBarModel" },
				{ entry.session_id and "  (from last session)" or "  (from last session, empty)", "DucktapeListDim" },
			})
			table.insert(entries, {
				value = entry,
				ordinal = "2" .. (title or ""),
				text = text,
				highlights = highlights,
				kind = "pending",
			})
		end
	end

	for _, s in ipairs(sessions) do
		if not live_session_ids[s.sessionId] and not pending_ids[s.sessionId] then
			local text, highlights = render({
				{ "  ○ ", "DucktapeListDim" },
				{ s.title },
				{ "  " .. relative_time(s.updatedAt), "DucktapeListDim" },
			})
			table.insert(entries, {
				value = s,
				ordinal = "3" .. s.title .. (s.updatedAt or ""),
				text = text,
				highlights = highlights,
				kind = "session",
			})
		end
	end

	return entries
end

---@param entry table
local function focus_live(entry)
	if not api.nvim_buf_is_valid(entry.bufnr) then
		return ui.say("[ducktape] that chat buffer is gone", vim.log.levels.WARN)
	end
	local chat = require("codecompanion.interactions.chat").buf_get_chat(entry.bufnr)
	if chat and chat.ui then
		chat.ui:open()
		if chat.ui.winnr and api.nvim_win_is_valid(chat.ui.winnr) then
			api.nvim_set_current_win(chat.ui.winnr)
		else
			api.nvim_set_current_buf(entry.bufnr)
		end
	else
		vim.cmd("buffer " .. entry.bufnr)
	end
end

---Open a session that is not currently a chat. This is where an agent process is finally spawned.
---@param entry table
---@param kind "session"|"pending"
local function restore_session(entry, kind)
	local args = kind == "pending" and entry
		or { session_id = entry.sessionId, title = entry.title, provider = entry.provider }

	require("ducktape.chat").restore_session(args)
	M.clear_cache()
end

---@param entry table
---@return string|nil
local function entry_session(entry)
	return entry.sessionId or entry.session_id
end

---Rename a session with no open chat. The agent names sessions from its own summary, so the
---chosen name is kept here and applied on display/reopen.
---@param entry table
local function rename_stored_session(entry)
	local sid = entry_session(entry)
	if not sid then
		return ui.say("[ducktape] this chat has no session yet — open it first, then rename", vim.log.levels.WARN)
	end
	local current = entry.title
	vim.ui.input({ prompt = "Rename session: ", default = current }, function(input)
		local name = input and vim.trim(input) or ""
		if name == "" or name == current then
			return
		end
		require("ducktape.chat").set_saved_title(sid, name)
		M.clear_cache()
		ui.say(("[ducktape] renamed to %s"):format(name), vim.log.levels.INFO)
	end)
end

---Delete a session with no open chat, agent-side copy included.
---@param entry table
local function delete_stored_session(entry)
	local sid = entry_session(entry)
	local label = entry.title or "this chat"

	if not sid then
		if not ui.confirm(("Forget %s? It has no saved transcript."):format(label)) then
			return
		end
		require("ducktape.chat").forget_pending(entry)
		M.clear_cache()
		return ui.say(("[ducktape] forgot %s"):format(label), vim.log.levels.INFO)
	end

	if not ui.confirm(("Delete %s and its saved transcript? This cannot be undone."):format(label)) then
		return
	end

	local conn, _, spawned = session_connection({ provider = entry.provider })
	if not conn then
		return ui.say(
			("[ducktape] no %s connection to delete the session with"):format(tostring(entry.provider)),
			vim.log.levels.ERROR
		)
	end

	local deleted = require("ducktape.chat").delete_session(sid, conn)
	if spawned then
		pcall(conn.disconnect, conn)
	end
	if deleted then
		M.clear_cache()
		ui.say(("[ducktape] deleted %s"):format(label), vim.log.levels.INFO)
	end
end

---Help rows built per call so configurable keymaps stay honest in the legend.
---@return table[]
local function help_rows()
	local keys = require("ducktape.keys")
	local K = keys.label
	local P = function(action)
		return keys.panel_label("chat_list", action)
	end
	return {
		{ header = "Selection" },
		{ key = "<CR>", desc = "open it — a stored session is restored first" },
		{ key = P("rename"), desc = "rename; kept against the session, so it survives reopening" },
		{ key = P("delete"), desc = "close a live chat, or drop a pending one — session stays" },
		{ key = P("kill"), desc = "delete for good, the agent's own transcript included" },
		{},
		{ header = "Chats" },
		{ key = K("chat_toggle"), desc = "toggle the last chat, reopening it after a restart" },
		{ key = K("chat_new"), desc = "new chat on the current provider" },
		{ key = K("chat_rename"), desc = "rename the current chat" },
		{ key = K("chat_delete"), desc = "delete the current chat" },
		{ key = K("chat_close_all"), desc = "close every chat" },
		{ key = K("chat_list"), desc = "this list" },
		{},
		{ header = "Markers" },
		{ key = "▶", key_hl = "DucktapeListCurrent", desc = "the chat you were in" },
		{ key = "●", key_hl = "DucktapeListReady", desc = "agent up and ready" },
		{ key = "◌", key_hl = "DucktapeListStarting", desc = "agent still connecting" },
		{ key = "✕", key_hl = "DucktapeListDead", desc = "agent gone; opening it starts a new one" },
		{ key = "·", key_hl = "DucktapeListDim", desc = "live chat with no agent yet" },
		{ key = "○", key_hl = "DucktapeListDim", desc = "not started — costs nothing until opened" },
		{},
		{ header = "Navigate" },
		{ key = "<C-n> <C-p>", desc = "move the selection (j and k in normal mode)" },
		{ key = "<Esc> q ?", desc = "close this help, keeping the list" },
		{ key = "<C-c>", desc = "close the list" },
	}
end

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

local function toggle_help()
	if help_is_open() then
		return close_help()
	end
	help = ui.help(help_rows(), { title = " Chat list " })
end

function M.open()
	ensure_highlights()

	-- Capture the current chat before the picker prompt becomes the current buffer.
	local current = require("ducktape.chat").current_chat()
	local current_buf = current and api.nvim_buf_is_valid(current.bufnr) and current.bufnr or nil

	local function selected_chat(entry)
		if not (entry.bufnr and api.nvim_buf_is_valid(entry.bufnr)) then
			return nil
		end
		return require("codecompanion.interactions.chat").buf_get_chat(entry.bufnr)
	end

	local handle
	handle = require("ducktape.picker").open({
		title = "Chats & Sessions",
		results_title = "?  help",
		panel = "chat_list",
		entries = function()
			return picker({ current_buf = current_buf })
		end,

		on_select = function(selection)
			local entry, kind = selection.value, selection.kind
			if kind == "live" then
				focus_live(entry)
			else
				restore_session(entry, kind)
			end
		end,

		actions = {
			help = function()
				toggle_help()
			end,
			close = function(_, ctx)
				ctx.close()
			end,

			-- Stop this chat coming back without deleting its stored session.
			delete = function(selection, ctx)
				if selection.kind == "live" then
					local chat = selected_chat(selection.value)
					if chat then
						chat:close()
					elseif selection.value.bufnr then
						pcall(api.nvim_buf_delete, selection.value.bufnr, { force = true })
					end
				elseif selection.kind == "pending" then
					require("ducktape.chat").forget_pending(selection.value)
					M.clear_cache()
				else
					return
				end
				ctx.refresh()
			end,

			rename = function(selection, ctx)
				-- Close first: vim.ui.input fights the picker for the prompt.
				ctx.close()
				if selection.kind == "live" then
					local chat = selected_chat(selection.value)
					if chat then
						require("ducktape.chat").rename(chat)
					end
				else
					rename_stored_session(selection.value)
				end
			end,

			kill = function(selection, ctx)
				ctx.close()
				if selection.kind == "live" then
					local chat = selected_chat(selection.value)
					if chat then
						require("ducktape.chat").delete(chat)
					end
				else
					delete_stored_session(selection.value)
				end
			end,
		},

		on_attach = function(prompt_bufnr, map, picker_handle)
			api.nvim_create_autocmd({ "BufLeave", "BufWipeout" }, {
				buffer = prompt_bufnr,
				once = true,
				callback = close_help,
			})

			-- Replace telescope's `?` which_key: it lists keys but cannot explain markers.
			map("n", "?", toggle_help)

			local actions = require("telescope.actions")
			local function dismiss_help_or(fallback)
				return function(prompt_buf)
					if help_is_open() then
						return close_help()
					end
					return fallback(prompt_buf)
				end
			end
			map("n", "<Esc>", dismiss_help_or(actions.close))
			map("n", "q", dismiss_help_or(actions.close))
			map(
				"i",
				"<Esc>",
				dismiss_help_or(function()
					vim.cmd("stopinsert")
				end)
			)
			map("n", "r", function()
				local selection = require("telescope.actions.state").get_selected_entry()
				if selection then
					picker_handle.close()
					if selection.kind == "live" then
						local chat = selected_chat(selection.value)
						if chat then
							require("ducktape.chat").rename(chat)
						end
					else
						rename_stored_session(selection.value)
					end
				end
			end)
		end,
	})
end

function M.clear_cache()
	M._cached_sessions = nil
end

return M
