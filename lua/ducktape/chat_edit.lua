-- Editing a message that has already been sent, then asking again with it.
--
-- The transcript in the chat buffer is a rendering, not the record. An ACP agent keeps its own
-- copy of the conversation and form_messages (adapters/acp/helpers.lua) only ever forwards user
-- messages not yet marked sent, so text edited above the prompt reaches nobody; the HTTP adapters
-- send `chat.messages`, which add_message builds and nothing re-reads from the buffer. Reviving a
-- chat looks like the counter-example but runs the other way round — session/load asks the agent
-- to replay *its* memory to us, and ACP has no method for pushing ours back.
--
-- So an edit the user then asks about is answered with a session that has never seen the
-- conversation, carrying the edited one as its opening message. What that costs is said at the
-- prompt: the agent's past replies arrive as quoted text rather than as its own turns, and tool
-- calls in the transcript are prose, so there is no live tool state to resume.

local M = {}

local api = vim.api
local ui = require("ducktape.ui")

-- The history as it stood when the agent last finished, per chat buffer. The text is snapshotted
-- rather than diffed against `chat.messages`, because the user is free to edit the agent's words
-- too and those never round-trip through the message table — a restored chat has no message
-- table at all.
---@type table<number, string[]>
local baseline = {}

--=============================================================================
-- Where history ends
--=============================================================================

---0-indexed row of the last `## Me` header, which is also the number of history lines above it.
---
---Parsed rather than read from `chat.header_line`, because that field is the whole problem: it is
---a line number captured when the last reply landed, and every line added or removed above it
---leaves it pointing somewhere else.
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

---Take the buffer's history as the new baseline. Called whenever it becomes authoritative again:
---the end of every turn, and the end of a restore.
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
		-- No baseline to compare against — a chat restored with a transcript ending in a user
		-- message never reaches on_ready. Adopt what is there rather than guessing it was edited.
		baseline[chat.bufnr] = now
		return false, rows
	end
	return not vim.deep_equal(was, now), rows
end

--=============================================================================
-- The edited conversation, read back out of the buffer
--=============================================================================

---Every role section above the prompt, in order.
---
---One entry per header, not per block: the chat query captures each direct child of a section
---separately, so a reply made of three paragraphs arrives as three captures under one role.
---@param chat table
---@param rows number Stop at this 0-indexed row
---@return { role: string, content: string }[]
local function transcript(chat, rows)
	-- A zero-row range is not an empty one to Tree-sitter: `iter_captures(root, buf, 0, 0)` walks
	-- the whole tree (measured), which would hand a chat that has only a prompt its own prompt back
	-- as history. Nothing is above row 0 anyway.
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

---The edited conversation as one message, for an agent that has never seen it.
---
---Fenced in a tag and labelled by speaker because that is all a user turn can carry: ACP's
---session/prompt takes user content blocks and nothing else, so there is no way to hand the agent
---its own past replies as its own. Saying outright that the record has been edited is what stops
---it arguing with the transcript when its memory of the exchange would have differed.
---@param entries { role: string, content: string }[]
---@param user_role string The header text this chat gives the user
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

--=============================================================================
-- Replacing the session under the chat
--=============================================================================

---Keep the chat's name across the swap.
---
---The agent pushes a fresh auto-title at the end of every turn, and a new session's would be
---generated from the replayed transcript — so the name is pinned as `_ducktape_user_title`, which is what
---chat.lua's BufFilePost guard re-asserts over the agent's, and keyed to the new session ID so it
---survives a restart. The `provider · model` placeholder is not a name and is left to be replaced
---as usual, exactly as it would be on a chat that had never been edited.
---The name moves with the conversation, so it is taken off the session being left behind: that one
---is now a copy of what the user edited away, and two entries under one name in `<leader>cl` is
---worse than one of them falling back to the agent's own auto-title for it.
---@param chat table
---@param title string|nil The title as it stood before the swap
---@param sid string The new session
---@param old_sid string|nil The session being left behind
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

---Point the chat at a session carrying the edited conversation, in place of the one that remembers
---the original. Only the messages are prepared here; the question itself is still parsed out of the
---buffer by the submit that follows.
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

	-- Everything the buffer shows is being replaced by what the buffer now says, so the old
	-- user/LLM messages go. The system prompt is not part of the conversation and stays.
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
		-- Read before anything can change them: the swap is what renames the chat, and the old ID is
		-- needed both to put things back on failure and to drop the session afterwards.
		local old_sid = conn.session_id
		local title = chat.title

		-- Nilling the ID is what makes _establish_session create instead of load; the process and
		-- its handshake are reused, so this costs a session/new round trip and no subprocess.
		conn.session_id = nil
		if not conn:ensure_session() then
			conn.session_id = old_sid -- nothing has been touched yet, so the chat carries on as it was
			return false, "the agent would not start a new session"
		end
		require("codecompanion.interactions.chat.acp.commands").link_buffer_to_session(chat.bufnr, conn.session_id)
		-- The new session holds nothing until this turn completes, so it is not yet worth saving.
		chat._ducktape_resumable = nil

		-- The session left behind is not deleted, and cannot usefully be: a `session/delete` sent from
		-- the process that had it open is answered with success and then written straight back by that
		-- same still-live process (measured here, and the reason chat.lua's own delete insists on a
		-- different connection). Making it stick would mean respawning the agent mid-chat. So the
		-- pre-edit conversation stays resumable under `<leader>cl`, where `<C-x>` removes it.
		carry_title(chat, title, conn.session_id, old_sid)

		-- Invisible: the buffer already shows this conversation, in the form the user edited it into.
		chat:add_message({ role = constants.USER_ROLE, content = replay(entries, user_role) }, { visible = false })
	else
		-- HTTP adapters send the whole message table, so the edited transcript goes in as itself —
		-- no replay wrapper, and the roles survive as roles.
		for _, entry in ipairs(entries) do
			chat:add_message({
				role = entry.role == user_role and constants.USER_ROLE or constants.LLM_ROLE,
				content = entry.content,
			}, { visible = false })
		end
	end

	return true
end

--=============================================================================
-- Sending
--=============================================================================

---What `<CR>` does in a chat buffer, in place of the plugin's own send.
---
---Two things happen before the submit it wraps: `chat.header_line` is realigned, and an edited
---conversation is offered a session that can actually see it.
---@param chat table
function M.send(chat)
	-- Stock behaviour, and not optional: the buffer locks for the request, and staying in insert
	-- mode over a locked buffer earns "E21: 'modifiable' is off" on the next keystroke.
	vim.cmd("stopinsert")

	if chat.current_request then
		return chat:submit()
	end

	local edited, rows = history_edited(chat)

	-- The realignment is the fix for a mis-send that has nothing to do with forking: submit parses
	-- the new prompt from `header_line` down, and a stale one reads the wrong window. Measured on a
	-- two-turn chat — delete two lines of history and the prompt is skipped entirely (nothing is
	-- sent); add four and the previous prompt is concatenated onto it.
	if rows then
		chat.header_line = rows + 1
	end

	-- Nothing typed under the last header. Stock substitutes `blank_prompt` for the missing message
	-- and submits that, and the default blank_prompt is the empty string, which the API rejects
	-- outright — measured: "400 messages.6: user messages must have non-empty content", in a red box
	-- that costs a keypress to clear. Only bailed on when blank_prompt is in fact blank, so a config
	-- that gives it real text keeps being able to send on an empty prompt.
	--
	-- It also settles what an edit on its own means: nothing. The swap below belongs to the moment the
	-- user asks a question with the edit in place, which is the only moment it changes anything.
	local asked = require("codecompanion.interactions.chat.parser").messages(chat, chat.header_line)
	local blank = require("codecompanion.config").interactions.chat.opts.blank_prompt
	if not asked and (blank == nil or blank == "") then
		return ui.say("[ducktape] nothing to send — type your question under the last header", vim.log.levels.WARN)
	end

	if not (edited and rows and asked) then
		return chat:submit()
	end

	-- Not offered as a choice. The user edited the conversation and then asked about it, which says
	-- what they want; the session swap is how it is delivered, not a decision to hand back.
	local ok, reason = fork(chat, rows)
	if not ok then
		-- Deliberately not sent. Submitting anyway would answer the question against the conversation
		-- the agent still remembers and quietly ignore the edit, which is the behaviour this replaces.
		return ui.say(("[ducktape] could not carry your edits over — %s"):format(reason), vim.log.levels.ERROR)
	end

	ui.say("[ducktape] asking with your edited conversation")
	chat:submit()
end

-- Exposed for the tests. Each is reached only through M.send in real use, and each is worth
-- driving on its own: the boundary and the replay are Tree-sitter parses whose answers are
-- specific, and the fork's failure paths never run when the agent is behaving.
M._history_edited = history_edited
M._transcript = transcript
M._fork = fork

return M
