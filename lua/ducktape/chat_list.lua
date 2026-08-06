-- Chat list: a picker over live chats and resumable sessions, including sessions started outside
-- nvim. Scoped to the project so sessions don't vanish when nvim is opened in a subdirectory; what
-- counts as the project is `ducktape.scope`, and configurable.

local M = {}

local api = vim.api
local ui = require("ducktape.ui")
local scope = require("ducktape.scope")

-- List colours come from ducktape.ui, which owns the palette for every ducktape surface. Scheduled
-- because resolving it before catppuccin has loaded would latch the stand-in colours in.
local function ensure_highlights()
	vim.schedule(function()
		ui.ensure_highlights()
	end)
end

--=============================================================================
-- Helpers
--=============================================================================

---A relative timestamp like "(2m ago)".
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
	-- Simple parse: "2024-01-15T10:30:00Z"
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

---Acquire a connection capable of listing sessions. Prefers a live chat's
---connection; falls back to spawning one through the pool's adapter resolution.
---@param opts? { provider?: string } provider: insist on an agent that can see a
---particular session — one agent's store is not another's, so a session listed by claude
---cannot be loaded or deleted over an opencode connection.
---@return table|nil conn, string|nil provider, boolean|nil spawned
local function session_connection(opts)
	opts = opts or {}

	-- Try an existing chat's ACP connection first
	for _, bufnr in ipairs(_G.codecompanion_buffers or {}) do
		local chat = require("codecompanion.interactions.chat").buf_get_chat(bufnr)
		local conn = chat and chat.acp_connection
		if conn and conn:is_ready() and conn.session_id then
			-- Report the ducktape.providers key rather than the CodeCompanion adapter name —
			-- callers feed it back into provider-keyed lookups.
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

	-- The requested agent, or every provider that can hold a session, in registry order when it
	-- makes no difference. Derived rather than listed: a provider added through config can resume
	-- its own sessions, and a hardcoded pair could not see it.
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
					-- connect_and_authenticate can fail after the child process has
					-- already spawned (e.g. initialize RPC or auth failure); avoid
					-- leaking that subprocess before trying the next provider.
					pcall(conn.disconnect, conn)
				end
			end
		end
	end

	return nil, nil
end

---Fetch and cache resumable sessions, filtered to the current project.
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
	-- A name the user gave the session outranks the agent's own summary of it, which is
	-- what session/list reports and what it would otherwise be shown under.
	local renamed = require("ducktape.chat").saved_titles()
	local filtered = {}
	for _, s in ipairs(raw) do
		-- `scope.contains` resolves both sides, so a symlinked checkout on one and the agent's own
		-- resolved path on the other still match. A plain prefix compare filtered them all out.
		if scope.contains(s.cwd) then
			table.insert(filtered, {
				sessionId = s.sessionId,
				title = renamed[s.sessionId] or s.title or s.sessionId,
				updatedAt = s.updatedAt or "",
				cwd = s.cwd or "",
				-- The agent that listed the session is the one that can load it
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

-- How alive a chat's agent is. A chat buffer existing says nothing about this: startup
-- restores spend a second or two handshaking, and a crashed agent leaves the buffer
-- behind intact, so "there is a chat here" and "you can send it a message" are different
-- facts and the list shows both.
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
	-- Only ACP chats have an agent process at all; an ollama chat is plain HTTP.
	if not (chat.adapter and chat.adapter.type == "acp") then
		return "none"
	end

	local conn = chat.acp_connection
	if not conn then
		-- Chat.new schedules the connection, so this is the first instant of a new chat
		return "starting"
	end
	if conn:is_connected() then
		return "ready"
	end
	-- handle_process_exit clears adapter_modified but leaves the handle set, which is what
	-- separates an agent that died from one that has not finished starting.
	if conn._state and conn._state.handle ~= nil and conn.adapter_modified == nil then
		return "dead"
	end
	return "starting"
end

---Live nvim chats, in the order the plugin tracks them.
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

--=============================================================================
-- Picker
--=============================================================================

---@return table<string, string> session ID → the name the user gave it
local function saved_titles()
	return require("ducktape.chat").saved_titles()
end

-- Shared with the provider picker, which builds its rows the same way.
local render = ui.render

---@param opts? { current_buf?: number } current_buf: the chat to mark, captured by the
---caller before the picker took focus
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

	-- Live chats first
	for _, chat in ipairs(live) do
		local is_current = opts.current_buf ~= nil and chat.bufnr == opts.current_buf
		local state = STATE[chat.state] or STATE.none

		-- The state marker earns its column: a chat can be listed and still not be able to
		-- take a message. Anything other than ready is spelled out, since a coloured glyph
		-- alone does not say what is wrong.
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

		-- The leading digit is what keeps the current chat on top, and live chats above
		-- stored sessions, once a filter is typed and the sorter starts ranking.
		local entry = {
			value = chat,
			ordinal = (is_current and "0" or "1") .. chat.title,
			text = text,
			highlights = highlights,
			kind = "live",
		}
		-- With an empty prompt every entry scores the same, so the sorter leaves them in
		-- finder order and the ordinal alone would not put the current chat first. Hoist it.
		if is_current then
			table.insert(entries, 1, entry)
		else
			table.insert(entries, entry)
		end
	end

	-- Chats from the last session, not started yet. Listed above the general session list
	-- because they are the ones the user actually left open, and read straight from
	-- chat_sessions.json — no agent has to be running for these to appear.
	-- A saved entry only carries a title if the agent had generated one before nvim quit,
	-- which it does asynchronously at turn end — so a chat closed promptly after its first
	-- reply has none. The session list has caught up by now, so borrow the title from there.
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

	-- Resumable sessions. Aligned with the live entries' marker column so both sections
	-- read as one list, and dimmed: there is no agent behind these until you open one.
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

---Focus a live chat buffer.
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

---Open a session that is not currently a chat: either one the agent listed, or one saved
---from the last nvim session. This is where an agent process is finally spawned — nothing
---before this point starts one.
---@param entry table
---@param kind "session"|"pending"
local function restore_session(entry, kind)
	-- A pending entry is already in ducktape.chat's own shape, carrying the model and options the
	-- chat originally had. A listed session has only what session/list reported, so its
	-- chat comes up on the current selection.
	local args = kind == "pending" and entry
		or { session_id = entry.sessionId, title = entry.title, provider = entry.provider }

	require("ducktape.chat").restore_session(args)

	-- Session is now live; drop the stale cache so it stops appearing
	-- under "resumable sessions" alongside its new live-chat entry.
	M.clear_cache()
end

---The session an entry refers to, whichever section it came from. Stored sessions carry
---the agent's own `sessionId`; live chats and pending ones carry our `session_id`.
---@param entry table
---@return string|nil
local function entry_session(entry)
	return entry.sessionId or entry.session_id
end

---Rename a session that has no chat open on it. Nothing is sent to the agent: it names
---sessions from its own summary of the conversation and offers no way to override that
---over ACP, so the chosen name is kept here and applied wherever the session is shown or
---reopened.
---@param entry table
local function rename_stored_session(entry)
	local sid = entry_session(entry)
	if not sid then
		-- No session yet means nothing to key a name to. It would be dropped on the next
		-- read, so promising otherwise would be a lie.
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

---Delete a session that has no chat open on it, agent-side copy included.
---@param entry table
local function delete_stored_session(entry)
	local sid = entry_session(entry)
	local label = entry.title or "this chat"

	-- A pending chat with no session was never stored by the agent, so there is nothing to
	-- delete — just stop offering it.
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

	-- Insist on the agent that listed the session: only it can see the session's file.
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

--=============================================================================
-- Help overlay
--=============================================================================

-- Everything the picker can do, plus what the markers mean. This exists because none of it
-- fits on the picker's borders: Telescope centres a title in a border line and silently
-- clips whatever is too long for the window, so a legend there is only as complete as the
-- terminal is wide. Here it is never truncated, and the borders only have to advertise `?`.
---The rows are built per call, not held as a constant: several of them name ducktape's own
---keymaps, which are configurable, and a legend that keeps naming the defaults after a remap is
---worse than no legend.
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

---Toggle the help overlay over an open picker. The window itself is `ui.help`, shared with the
---inline list — the only thing that differs is the rows and the title.
local function toggle_help()
	if help_is_open() then
		return close_help()
	end
	help = ui.help(help_rows(), { title = " Chat list " })
end

---Open the chat list.
---
---Goes through ducktape.picker, so telescope is no longer required for it: with telescope installed
---this is a telescope picker, and without it a built-in float. Everything below is written against
---that interface rather than against either backend.
function M.open()
	ensure_highlights()

	-- Resolved now, before a prompt buffer becomes the current one: the answer follows BufEnter, so
	-- asking again during a rebuild would give the prompt, not a chat.
	local current = require("ducktape.chat").current_chat()
	local current_buf = current and api.nvim_buf_is_valid(current.bufnr) and current.bufnr or nil

	---The chat behind a live entry, or nil if its buffer has gone.
	local function selected_chat(entry)
		if not (entry.bufnr and api.nvim_buf_is_valid(entry.bufnr)) then
			return nil
		end
		return require("codecompanion.interactions.chat").buf_get_chat(entry.bufnr)
	end

	local handle
	handle = require("ducktape.picker").open({
		title = "Chats & Sessions",
		-- The keys and the marker legend live in the help overlay rather than here: a border title is
		-- clipped to the window's width without saying so, and one of these mappings deletes a
		-- transcript for good.
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

			-- Stop this chat coming back, without touching its stored session — so it stays resumable
			-- from this same list. `kill` is the one that removes a session. On a live chat this means
			-- closing the buffer and freeing its agent process; on a pending one it means dropping it
			-- from the reopen set, which demotes it to an ordinary stored session.
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
					return -- a stored session has nothing to close
				end
				ctx.refresh()
			end,

			-- Rename. Works on a live chat and on a stored session alike — the name is remembered
			-- against the session ID either way, so it survives closing the chat and reopening later.
			rename = function(selection, ctx)
				-- The picker closes first: vim.ui.input over a picker fights it for the prompt, and
				-- the answer can land in the filter instead.
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

			-- Remove for good — the chat and the agent's own copy of the conversation, so it does not
			-- return as a resumable session. The picker closes first because the confirmation is a
			-- modal cmdline prompt.
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

		-- Telescope-only extras, ignored by a backend that does not offer the hook. Two things need
		-- its prompt buffer specifically: taking the help overlay down with the picker, and the
		-- normal-mode aliases telescope users expect.
		on_attach = function(prompt_bufnr, map, picker_handle)
			-- The overlay is a plain float, so nothing would otherwise take it down with the picker
			-- it belongs to.
			api.nvim_create_autocmd({ "BufLeave", "BufWipeout" }, {
				buffer = prompt_bufnr,
				once = true,
				callback = close_help,
			})

			-- `?` is telescope's own which_key, which lists keys but cannot explain the markers, so it
			-- is replaced. Normal mode only: in insert mode `?` has to stay a literal `?`, which is
			-- what the configured <C-_>/<C-/> pair is for.
			map("n", "?", toggle_help)

			-- <Esc> and q otherwise close the picker, which took the list away along with the help it
			-- was showing. While the overlay is up they dismiss it and stop there; with it down they
			-- keep their usual meaning.
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
					vim.cmd("stopinsert") -- telescope leaves <Esc> alone in insert mode
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

---Clear the cached session list; the next open re-queries.
function M.clear_cache()
	M._cached_sessions = nil
end

return M
