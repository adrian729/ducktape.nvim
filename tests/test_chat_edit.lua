-- ducktape.chat_edit: boundary detection, edit detection, header realignment, and session swap.

local ok_count, fail_count = 0, 0
local function check(name, cond, extra)
	if cond then
		ok_count = ok_count + 1
	else
		fail_count = fail_count + 1
		print(("FAIL: %s%s"):format(name, extra and (" — " .. tostring(extra)) or ""))
	end
end
local function eq(name, got, want)
	check(name, vim.deep_equal(got, want), ("got %s want %s"):format(vim.inspect(got), vim.inspect(want)))
end

local edit = require("ducktape.chat_edit")
local ui = require("ducktape.ui")
local chat_mod = require("ducktape.chat")
local constants = require("codecompanion.config").constants

-- Stub set_saved_title to inspect writes instead of touching chat_titles.json.
local titles = {}
chat_mod.set_saved_title = function(sid, title)
	titles[sid] = title
end

local TWO_TURNS = {
	"## Me", -- 1
	"", -- 2
	"first question", -- 3
	"", -- 4
	"## CodeCompanion (Claude Code)", -- 5
	"", -- 6
	"first answer", -- 7
	"", -- 8
	"## Me", -- 9  <- history is lines 1..8, rows = 8
	"", -- 10
	"second question", -- 11
	"", -- 12
}

local EMPTY_PROMPT = {
	"## Me",
	"",
	"question",
	"",
	"## CodeCompanion (Claude Code)",
	"",
	"answer",
	"",
	"## Me",
	"",
	"",
}

---@param lines string[]
---@param opts? { type?: string, ready?: boolean, new_session?: string|false, title?: string }
local function fake_chat(lines, opts)
	opts = opts or {}
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].filetype = "markdown"

	local chat = {
		bufnr = bufnr,
		header_line = 1,
		messages = {},
		parsers = { markdown = vim.treesitter.get_parser(bufnr, "markdown") },
		adapter = { type = opts.type or "acp" },
		title = opts.title ~= nil and opts.title or "A chat about colours",
		_ducktape_provider = "claude",
		_ducktape_model = "opus",
		submitted = 0,
		add_message = function(self, data, o)
			table.insert(self.messages, { role = data.role, content = data.content, _meta = {}, opts = o })
			return self
		end,
		submit = function(self)
			self.submitted = self.submitted + 1
		end,
	}

	if (opts.type or "acp") == "acp" then
		chat.rpc = {}
		chat.acp_connection = {
			session_id = "old-session",
			is_ready = function()
				return opts.ready ~= false
			end,
			ensure_session = function(self)
				if opts.new_session == false then
					return false
				end
				self.session_id = opts.new_session or "new-session"
				return true
			end,
			send_rpc_request = function(_, method, params)
				table.insert(chat.rpc, { method = method, params = params })
				return {}
			end,
		}
	end

	chat.parsers.markdown:parse(true)
	return chat
end

do
	local chat = fake_chat(TWO_TURNS)
	edit.rebase(chat)
	local before, rows = edit._history_edited(chat)
	check("unedited history reads as unedited", before == false)
	eq("boundary is the last user header", rows, 8)
end

do
	local chat = fake_chat({ "## Me", "", "" })
	edit.rebase(chat)
	local edited, rows = edit._history_edited(chat)
	check("a chat with no history is not edited", edited == false)
	eq("no history means a zero boundary", rows, 0)
end

do
	-- No user header: the parse finds nothing to anchor to.
	local chat = fake_chat({ "just some text" })
	local edited, rows = edit._history_edited(chat)
	check("no header, no edit", edited == false)
	eq("no header, no boundary", rows, nil)
end

do
	local chat = fake_chat(TWO_TURNS)
	edit.rebase(chat)
	vim.api.nvim_buf_set_lines(chat.bufnr, 2, 3, false, { "first question, reworded" })
	chat.parsers.markdown:parse(true)
	check("rewording a past question is an edit", edit._history_edited(chat) == true)
end

do
	local chat = fake_chat(TWO_TURNS)
	edit.rebase(chat)
	-- Rewording the agent's reply never round-trips through chat.messages; watch the buffer text.
	vim.api.nvim_buf_set_lines(chat.bufnr, 6, 7, false, { "an answer the agent never gave" })
	chat.parsers.markdown:parse(true)
	check("rewording the agent's reply is an edit", edit._history_edited(chat) == true)
end

do
	local chat = fake_chat(TWO_TURNS)
	edit.rebase(chat)
	vim.api.nvim_buf_set_lines(chat.bufnr, 10, 11, false, { "a much longer", "second question", "over three lines" })
	chat.parsers.markdown:parse(true)
	local edited, rows = edit._history_edited(chat)
	check("typing the prompt is not an edit", edited == false)
	eq("the boundary does not move when the prompt grows", rows, 8)
end

do
	local chat = fake_chat(TWO_TURNS)
	edit.rebase(chat)
	vim.api.nvim_buf_set_lines(chat.bufnr, 2, 4, false, {})
	chat.parsers.markdown:parse(true)
	local edited, rows = edit._history_edited(chat)
	check("deleting history is an edit", edited == true)
	eq("the boundary follows the deletion", rows, 6)
end

do
	local chat = fake_chat(TWO_TURNS)
	-- Without a baseline, adopt what is there.
	check("no baseline is not an edit", edit._history_edited(chat) == false)
	vim.api.nvim_buf_set_lines(chat.bufnr, 2, 3, false, { "changed" })
	chat.parsers.markdown:parse(true)
	check("the adopted baseline is then compared against", edit._history_edited(chat) == true)
end

do
	local chat = fake_chat(TWO_TURNS)
	edit.rebase(chat)
	vim.api.nvim_buf_set_lines(chat.bufnr, 2, 3, false, { "changed" })
	chat.parsers.markdown:parse(true)
	edit.forget(chat.bufnr)
	check("forgetting drops the baseline", edit._history_edited(chat) == false)
end

do
	local chat = fake_chat(TWO_TURNS)
	local entries = edit._transcript(chat, 8)
	eq("one entry per header", #entries, 2)
	eq("the user's turn", entries[1], { role = "Me", content = "first question" })
	eq("the agent's turn", entries[2], { role = "CodeCompanion (Claude Code)", content = "first answer" })
end

do
	-- A multi-block reply is one turn, not three.
	local chat = fake_chat({
		"## Me",
		"",
		"question",
		"",
		"## CodeCompanion (Claude Code)",
		"",
		"first paragraph",
		"",
		"second paragraph",
		"",
		"```lua",
		"print('hi')",
		"```",
		"",
		"## Me",
		"",
		"next",
	})
	local entries = edit._transcript(chat, 14)
	eq("a multi-block reply is one entry", #entries, 2)
	check("every block survives", entries[2].content:find("first paragraph", 1, true) ~= nil)
	check("the second block survives", entries[2].content:find("second paragraph", 1, true) ~= nil)
	check("the code block survives", entries[2].content:find("print('hi')", 1, true) ~= nil)
end

do
	local chat = fake_chat(TWO_TURNS)
	eq("nothing above a zero boundary", edit._transcript(chat, 0), {})
end

do
	titles = {}
	local chat = fake_chat(TWO_TURNS)
	chat.messages = {
		{ role = constants.SYSTEM_ROLE, content = "you are helpful", _meta = {} },
		{ role = constants.USER_ROLE, content = "first question", _meta = { sent = true } },
		{ role = constants.LLM_ROLE, content = "first answer", _meta = {} },
	}
	local ok = edit._fork(chat, 8)
	check("the acp swap succeeds", ok == true)
	eq("the connection moved to a new session", chat.acp_connection.session_id, "new-session")
	eq("one replay message on top of the system prompt", #chat.messages, 2)
	eq("the system prompt is kept", chat.messages[1].role, constants.SYSTEM_ROLE)
	eq("the replay is a user message", chat.messages[2].role, constants.USER_ROLE)
	check("the replay is invisible", chat.messages[2].opts.visible == false)
	check("the replay is unsent, so form_messages forwards it", chat.messages[2]._meta.sent == nil)
	local text = chat.messages[2].content
	check("the replay says the record was edited", text:find("edited", 1, true) ~= nil)
	check("the replay is fenced", text:find("<transcript>", 1, true) ~= nil)
	check("the user's turn is labelled", text:find("### User", 1, true) ~= nil)
	check("the agent's turn is labelled", text:find("### Assistant", 1, true) ~= nil)
	check("the replay carries the conversation", text:find("first answer", 1, true) ~= nil)
	check("the replay stops at the prompt", text:find("second question", 1, true) == nil)
	check("the chat is no longer treated as resumable", chat._ducktape_resumable == nil)

	-- The title is unchanged by the user, so it survives the swap.
	eq("the chat keeps its title", chat.title, "A chat about colours")
	eq("and it is pinned against the agent's next auto-title", chat._ducktape_user_title, "A chat about colours")
	eq("and re-keyed to the new session", titles["new-session"], "A chat about colours")

	-- The name moves with the conversation, so the old session loses it rather than duplicating it.
	eq("the old session loses the name", titles["old-session"], nil)
	-- Deletion is not attempted: the process that had the session open writes it straight back.
	eq("no session/delete is attempted", #chat.rpc, 0)
end

do
	-- The `provider · model` placeholder is not a name and must not be pinned.
	titles = {}
	local chat = fake_chat(TWO_TURNS, { title = "claude · opus" })
	check("the placeholder swap succeeds", edit._fork(chat, 8) == true)
	eq("the placeholder is not pinned", chat._ducktape_user_title, nil)
	eq("and nothing is saved for it", titles["new-session"], nil)
end

do
	local chat = fake_chat(TWO_TURNS, { type = "http" })
	chat.messages = { { role = constants.SYSTEM_ROLE, content = "sys", _meta = {} } }
	check("the http swap succeeds", edit._fork(chat, 8) == true)
	eq("http gets the turns as turns", #chat.messages, 3)
	eq("the user turn keeps its role", chat.messages[2].role, constants.USER_ROLE)
	eq("the user turn keeps its text", chat.messages[2].content, "first question")
	eq("the agent turn keeps its role", chat.messages[3].role, constants.LLM_ROLE)
	eq("the agent turn keeps its text", chat.messages[3].content, "first answer")
	check("no replay wrapper for http", chat.messages[2].content:find("<transcript>", 1, true) == nil)
end

do
	local chat = fake_chat(TWO_TURNS, { ready = false })
	local ok, reason = edit._fork(chat, 8)
	check("a swap with no live connection fails", ok == false)
	check("and says why", tostring(reason):find("connection") ~= nil)
	eq("and the chat keeps the session it had", chat.acp_connection.session_id, "old-session")
end

do
	local chat = fake_chat(TWO_TURNS, { new_session = false })
	local ok, reason = edit._fork(chat, 8)
	check("a refused session/new fails", ok == false)
	check("and says why", tostring(reason):find("session") ~= nil)
	-- Nothing had been touched yet, so the chat has to carry on with what it had.
	eq("the old session is put back", chat.acp_connection.session_id, "old-session")
end

do
	local chat = fake_chat({ "## Me", "", "only a prompt" })
	check("a swap with nothing to replay fails", edit._fork(chat, 0) == false)
end

local said
local real_say = ui.say
local function stub()
	said = {}
	ui.say = function(msg)
		table.insert(said, msg)
	end
end
local function unstub()
	ui.say = real_say
end

do
	stub()
	local chat = fake_chat(TWO_TURNS)
	edit.rebase(chat)
	edit.send(chat)
	eq("an unedited chat submits", chat.submitted, 1)
	eq("header_line is realigned to the prompt header", chat.header_line, 9)
	eq("and it keeps its session", chat.acp_connection.session_id, "old-session")
	eq("and says nothing", #said, 0)
	unstub()
end

do
	-- A stale header_line reads the prompt from the wrong window.
	stub()
	local chat = fake_chat(TWO_TURNS)
	edit.rebase(chat)
	chat.header_line = 9
	vim.api.nvim_buf_set_lines(chat.bufnr, 2, 4, false, {}) -- two lines of history gone
	chat.parsers.markdown:parse(true)
	local parser = require("codecompanion.interactions.chat.parser")
	check("the stale header_line loses the prompt", parser.messages(chat, chat.header_line) == nil)
	edit.send(chat)
	eq("header_line is corrected", chat.header_line, 7)
	local fixed = parser.messages(chat, chat.header_line)
	eq("and the prompt parses again", fixed and fixed.content, "second question")
	unstub()
end

do
	stub()
	titles = {}
	local chat = fake_chat(TWO_TURNS)
	edit.rebase(chat)
	vim.api.nvim_buf_set_lines(chat.bufnr, 2, 3, false, { "reworded" })
	chat.parsers.markdown:parse(true)
	edit.send(chat)
	eq("an edited chat is not asked about, it just goes", chat.submitted, 1)
	eq("on a session carrying the edits", chat.acp_connection.session_id, "new-session")
	eq("keeping its title", titles["new-session"], "A chat about colours")
	eq("with one line said about it", #said, 1)
	check("naming the edits", said[1]:find("edited conversation", 1, true) ~= nil)
	unstub()
end

do
	-- An edit with no question belongs to "edit and ask", not send.
	stub()
	local chat = fake_chat(EMPTY_PROMPT)
	edit.rebase(chat)
	vim.api.nvim_buf_set_lines(chat.bufnr, 2, 3, false, { "reworded" })
	chat.parsers.markdown:parse(true)
	edit.send(chat)
	eq("nothing is sent", chat.submitted, 0)
	eq("the session is untouched", chat.acp_connection.session_id, "old-session")
	check("and it says there is nothing to send", said[1] ~= nil and said[1]:find("nothing to send", 1, true) ~= nil)
	unstub()
end

do
	-- Stock substitutes an empty blank_prompt and submits it, which the API rejects.
	stub()
	local chat = fake_chat(EMPTY_PROMPT)
	edit.rebase(chat)
	edit.send(chat)
	eq("an empty prompt sends nothing even unedited", chat.submitted, 0)
	check("and says so", said[1] ~= nil and said[1]:find("nothing to send", 1, true) ~= nil)
	unstub()
end

do
	-- A non-empty blank_prompt still allows sending on an empty prompt.
	stub()
	local opts = require("codecompanion.config").interactions.chat.opts
	local saved = opts.blank_prompt
	opts.blank_prompt = "carry on"
	local chat = fake_chat(EMPTY_PROMPT)
	edit.rebase(chat)
	edit.send(chat)
	eq("a meaningful blank_prompt still sends", chat.submitted, 1)
	eq("and says nothing", #said, 0)
	opts.blank_prompt = saved
	unstub()
end

do
	stub()
	local chat = fake_chat(TWO_TURNS)
	edit.rebase(chat)
	chat.current_request = {} -- a turn already in flight
	vim.api.nvim_buf_set_lines(chat.bufnr, 2, 3, false, { "reworded" })
	chat.parsers.markdown:parse(true)
	edit.send(chat)
	eq("an in-flight chat is handed straight to submit", chat.submitted, 1)
	eq("with its session untouched", chat.acp_connection.session_id, "old-session")
	unstub()
end

do
	stub()
	local chat = fake_chat(TWO_TURNS, { new_session = false })
	edit.rebase(chat)
	vim.api.nvim_buf_set_lines(chat.bufnr, 2, 3, false, { "reworded" })
	chat.parsers.markdown:parse(true)
	edit.send(chat)
	-- Submitting anyway would answer against the agent's remembered conversation and ignore the edit.
	eq("a failed swap sends nothing", chat.submitted, 0)
	check("and says why", said[1] ~= nil and said[1]:find("could not carry", 1, true) ~= nil)
	unstub()
end

print(("\n%d assertions, %d failures"):format(ok_count + fail_count, fail_count))
