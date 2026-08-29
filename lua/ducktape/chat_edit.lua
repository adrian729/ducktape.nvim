-- Send an edited chat transcript by swapping to a fresh session. ACP agents keep their own
-- conversation copy (form_messages only forwards unsent user messages), so edits above the
-- prompt never reach the existing session; HTTP adapters send `chat.messages`, which is built
-- once and never re-read. The swap carries the edited transcript as the new session's opening
-- message.

local M = {}

local api = vim.api
local ui = require("ducktape.ui")

---Snapshot of history per chat buffer, taken at the end of each turn/restore. Snapshotted rather
---than diffed against `chat.messages` because restored chats have no message table.
---@type table<number, string[]>
local baseline = {}

---0-indexed row of the last `## Me` header. Parsed rather than read from `chat.header_line`, which
---goes stale when lines are added or removed above it.
---@param chat table
---@return number|nil
local function history_rows(chat)
	if not (chat.parsers and chat.parsers.markdown) then
		return nil
	end
	local ok, row = pcall(require("codecompanion.interactions.chat.parser").headers, chat)
	return ok and row or nil
end

---@param chat table
---@param rows number
---@return string[]
local function history_lines(chat, rows)
	return api.nvim_buf_get_lines(chat.bufnr, 0, rows, false)
end

---Snapshot the buffer history as the new baseline.
---@param chat table
function M.rebase(chat)
	if not (chat and chat.bufnr and api.nvim_buf_is_valid(chat.bufnr)) then
		return
	end
	local rows = history_rows(chat)
	baseline[chat.bufnr] = rows and history_lines(chat, rows) or nil
end

---@param bufnr number
function M.forget(bufnr)
	baseline[bufnr] = nil
end

---@param chat table
---@return boolean edited, number|nil rows
local function history_edited(chat)
	local rows = history_rows(chat)
	if not rows then
		return false, nil
	end
	local now = history_lines(chat, rows)
	local was = baseline[chat.bufnr]
	if not was then
		-- Restored transcripts ending in a user message never reach on_ready; adopt what is there.
		baseline[chat.bufnr] = now
		return false, rows
	end
	return not vim.deep_equal(was, now), rows
end

---Every role section above the prompt, one entry per header.
---@param chat table
---@param rows number Stop at this 0-indexed row
---@return { role: string, content: string }[]
local function transcript(chat, rows)
	-- A zero-row range walks the whole tree in Tree-sitter, handing back the prompt as history.
	if rows <= 0 then
		return {}
	end
	local query = vim.treesitter.query.get("markdown", "chat")
	if not query then
		return {}
	end
	local root = chat.parsers.markdown:parse({ 0, rows })[1]:root()
	local get_text = vim.treesitter.get_node_text
	local format_role = require("codecompanion.interactions.chat.helpers").format_role

	local out, role, chunks = {}, nil, {}
	local function flush()
		if role and #chunks > 0 then
			table.insert(out, { role = role, content = vim.trim(table.concat(chunks, "\n\n")) })
		end
		chunks = {}
	end

	for id, node in query:iter_captures(root, chat.bufnr, 0, rows) do
		local capture = query.captures[id]
		if capture == "role" then
			flush()
			role = format_role(get_text(node, chat.bufnr))
		elseif capture == "content" and role then
			table.insert(chunks, get_text(node, chat.bufnr))
		end
	end
	flush()

	return out
end

---Edited conversation as one user message for a session that never saw it. ACP session/prompt only
---takes user content blocks, so the agent's past replies cannot be handed back as its own turns.
---@param entries { role: string, content: string }[]
---@param user_role string
---@return string
local function replay(entries, user_role)
	local parts = {}
	for _, entry in ipairs(entries) do
		local who = entry.role == user_role and "User" or "Assistant"
		table.insert(parts, ("### %s\n\n%s"):format(who, entry.content))
	end
	return table.concat({
		"Below is our conversation so far, which has been edited since it happened.",
		"Treat it as the authoritative record — including the parts attributed to you —",
		"and answer the question that follows it.",
		"",
		"<transcript>",
		table.concat(parts, "\n\n"),
		"</transcript>",
	}, "\n")
end

---Carry the chat title across the session swap.
---@param chat table
---@param title string|nil
---@param sid string
---@param old_sid string|nil
local function carry_title(chat, title, sid, old_sid)
	local placeholder = ("%s · %s"):format(tostring(chat._ducktape_provider), tostring(chat._ducktape_model))
	if title == nil or title == "" or title == placeholder then
		return
	end
	chat._ducktape_user_title = title
	local chat_mod = require("ducktape.chat")
	chat_mod.set_saved_title(sid, title)
	if old_sid ~= nil then
		chat_mod.set_saved_title(old_sid, nil)
	end
end

---Point the chat at a new session carrying the edited conversation.
---@param chat table
---@param rows number
---@return boolean ok, string|nil reason
local function fork(chat, rows)
	local config = require("codecompanion.config")
	local constants = config.constants
	local user_role = config.interactions.chat.roles.user
	local entries = transcript(chat, rows)
	if #entries == 0 then
		return false, "the conversation above could not be read back"
	end

	-- Replace user/LLM messages; keep the system prompt.
	local kept = {}
	for _, message in ipairs(chat.messages or {}) do
		if message.role == constants.SYSTEM_ROLE then
			table.insert(kept, message)
		end
	end
	chat.messages = kept

	if chat.adapter and chat.adapter.type == "acp" then
		local conn = chat.acp_connection
		if not (conn and conn:is_ready()) then
			return false, "the agent connection is not up"
		end
		local old_sid = conn.session_id
		local title = chat.title

		-- Nilling the ID makes _establish_session create instead of load, reusing the process.
		conn.session_id = nil
		if not conn:ensure_session() then
			conn.session_id = old_sid
			return false, "the agent would not start a new session"
		end
		require("codecompanion.interactions.chat.acp.commands").link_buffer_to_session(chat.bufnr, conn.session_id)
		chat._ducktape_resumable = nil

		-- The old session cannot be usefully deleted from the process that still holds it open.
		carry_title(chat, title, conn.session_id, old_sid)

		chat:add_message({ role = constants.USER_ROLE, content = replay(entries, user_role) }, { visible = false })
	else
		-- HTTP adapters send the whole message table, so the edited transcript goes in as-is.
		for _, entry in ipairs(entries) do
			chat:add_message({
				role = entry.role == user_role and constants.USER_ROLE or constants.LLM_ROLE,
				content = entry.content,
			}, { visible = false })
		end
	end

	return true
end

---What `<CR>` does in a chat buffer.
---@param chat table
function M.send(chat)
	vim.cmd("stopinsert")

	if chat.current_request then
		return chat:submit()
	end

	local edited, rows = history_edited(chat)

	-- Realign `header_line` so submit parses the prompt from the right place. Measured: deleting
	-- two history lines skips the prompt entirely; adding four concatenates the previous prompt.
	if rows then
		chat.header_line = rows + 1
	end

	-- Bail on an empty prompt only when blank_prompt is blank, so a non-empty blank_prompt still
	-- works. Stock sends the empty string, which the API rejects with a red error box.
	local asked = require("codecompanion.interactions.chat.parser").messages(chat, chat.header_line)
	local blank = require("codecompanion.config").interactions.chat.opts.blank_prompt
	if not asked and (blank == nil or blank == "") then
		return ui.say("[ducktape] nothing to send — type your question under the last header", vim.log.levels.WARN)
	end

	if not (edited and rows and asked) then
		return chat:submit()
	end

	local ok, reason = fork(chat, rows)
	if not ok then
		-- Sending anyway would answer against the old session and quietly ignore the edit.
		return ui.say(("[ducktape] could not carry your edits over — %s"):format(reason), vim.log.levels.ERROR)
	end

	ui.say("[ducktape] asking with your edited conversation")
	chat:submit()
end

M._history_edited = history_edited
M._transcript = transcript
M._fork = fork

return M
