-- Chat surface: toggle, new with preset options, close-all, and the prose-float upgrade
-- that opens a chat pre-loaded with the exchange.
--
-- Chat connections stay out of the inline pool because a shared connection restoring
-- history would swallow inline updates — the session-loading branch (`_loading_session and
-- _on_session_update`, acp/init.lua:660) outranks `_active_prompt`.

local M = {}

local api = vim.api
local ui = require("ducktape.ui")

local last_chat_buf = nil
local spinner_group
local pending_agents = {} -- bufnr → agent name, applied on first ChatSubmitted

-- Chats that were open when nvim last quit and have not been reopened yet. Read from
-- chat_sessions.json at startup and drained as the user picks them. Nothing here holds an
-- agent process — that is the point: a pending chat costs a JSON entry, not a subprocess.
---@type table[]
local pending = {}

-- Winbar and footer colours come from ducktape.ui, which owns the palette for every ducktape surface.
local function ensure_winbar_highlights()
	ui.ensure_highlights()
end

--=============================================================================
-- Chat footer
--=============================================================================

-- The chat lives in a half-width vertical split, so the full line does not always fit.
-- Ordered widest-first; the first tier that measures small enough for the window wins.
-- `?` survives into every tier because it opens CodeCompanion's own list of every chat
-- keymap — the footer only has to get you there, not be exhaustive.
---Built per call rather than held as a constant: the two chat entries name ducktape's own keymaps,
---which are configurable, and a footer that keeps naming the defaults after a remap is worse than
---no footer at all. The chat-buffer keys on the left are codecompanion's and are fixed.
---@return table[]
local function footer_tiers()
	local K = require("ducktape.keys").label
	local cc = { { "<CR>", "send" }, { "q", "stop" }, { "ga", "model" }, { "?", "keys" } }
	return {
		{
			keys = cc,
			chat = { { K("chat_rename"), "rename" }, { K("chat_delete"), "delete" } },
		},
		{
			keys = cc,
			chat = { { K("chat_rename"), "rename" } },
		},
		{ keys = { { "<CR>", "send" }, { "q", "stop" }, { "?", "keys" } } },
		{ keys = { { "<CR>", "send" }, { "?", "keys" } } },
		{ keys = { { "?", "keys" } } },
	}
end

---Statusline string for a chat window of the given width.
---
---Each tier is rendered and measured rather than carrying a hand-written minimum width:
---editing a label would otherwise silently invalidate the number next to it, and the line
---would come back clipped mid-word.
---@param width number
---@return string
local function footer_text(width)
	local function group(items)
		local out = {}
		for _, item in ipairs(items) do
			table.insert(out, ("%%#DucktapeFooterKey#%s %%#DucktapeFooterLabel#%s"):format(item[1], item[2]))
		end
		return table.concat(out, "%#DucktapeFooterDim# · ")
	end

	for _, tier in ipairs(footer_tiers()) do
		local text = " " .. group(tier.keys)
		if tier.chat then
			text = text .. "%#DucktapeFooterDim#   │   " .. group(tier.chat)
		end
		text = text .. " "
		-- Statusline markup costs no columns, so it comes out of the measurement.
		if vim.fn.strdisplaywidth((text:gsub("%%#%w+#", ""))) <= width then
			return text
		end
	end
	return "" -- narrower than the shortest hint we have; better blank than clipped
end

--=============================================================================
-- Waiting indicator
--=============================================================================

local function ensure_spinner_group()
	if spinner_group then
		return
	end
	spinner_group = api.nvim_create_augroup("DucktapeChatSpinner", { clear = true })

	api.nvim_create_autocmd("User", {
		group = spinner_group,
		pattern = "CodeCompanionChatSubmitted",
		callback = function(args)
			local data = args.data
			if not data or not data.bufnr then
				return
			end
			local bufnr = data.bufnr
			if not api.nvim_buf_is_valid(bufnr) then
				return
			end

			local chat = require("codecompanion.interactions.chat").buf_get_chat(bufnr)

			-- Claude agent: must be applied after the session exists (category = nil)
			local agent = pending_agents[bufnr]
			if agent then
				pending_agents[bufnr] = nil
				local conn = chat and chat.acp_connection
				if conn and conn.set_config_option then
					pcall(conn.set_config_option, conn, "agent", agent)
				end
			end

			-- An ACP submit that fails before a prompt exists — connection or session setup — still
			-- fires ChatSubmitted, but RequestFinished only ever comes from the prompt builder, so a
			-- spinner started here would never be stopped. That failure clears current_request
			-- synchronously (Chat:done, before the event fires), which is how we recognise it.
			if chat and not chat.current_request then
				return
			end

			local spinner = ui.progress(bufnr, function()
				return api.nvim_buf_line_count(bufnr) - 1
			end, "thinking…")
			api.nvim_buf_set_var(bufnr, "ducktape_chat_spinner", spinner)
		end,
	})

	api.nvim_create_autocmd("User", {
		group = spinner_group,
		pattern = "CodeCompanionRequestFinished",
		callback = function(args)
			local data = args.data
			local bufnr = data and data.bufnr
			if bufnr and api.nvim_buf_is_valid(bufnr) then
				local ok, spinner = pcall(api.nvim_buf_get_var, bufnr, "ducktape_chat_spinner")
				if ok and spinner then
					spinner:stop()
					pcall(api.nvim_buf_del_var, bufnr, "ducktape_chat_spinner")
				end
			end
		end,
	})

	-- A chat buffer that was deleted before its first submit never fires
	-- ChatSubmitted, so the agent entry would leak forever.
	api.nvim_create_autocmd("BufWipeout", {
		group = spinner_group,
		callback = function(args)
			pending_agents[args.buf] = nil
		end,
	})
end

--=============================================================================
-- Adapter resolution
--=============================================================================

---Post-resolution tweak: a provider's inline guard environment denies writes, which is right for
---inline and too strict for chat — chat is supposed to be able to change things. It is swapped for
---the chat set rather than dropped: dropping it handed chat silent write access, so edits happened
---with nothing announcing them. opencode's `ask` gets the same confirm-first behaviour claude's
---`default` mode has.
---
---Driven by the provider's `guard.chat_env`, so a provider added through config gets the same
---treatment without an edit here.
---@param adapter table
---@param provider string
local function apply_chat_permissions(adapter, provider)
	if not adapter or not adapter.env then
		return
	end
	local providers = require("ducktape.providers")
	for name in pairs(providers.guard_env(provider, "chat")) do
		adapter.env[name] = function()
			return providers.guard_env(provider, "chat")[name]
		end
	end
end

---Re-point an HTTP adapter's schema defaults at the chat scope.
---
---The generated adapters read the inline selection, because that is the scope they are claimed for
---by default. A chat on the same provider has its own model and options, so the schema has to be
---told which scope it is serving. Every option the provider offers for chat is redirected, using
---the option's own `to_schema` where the stored value and the schema field disagree in type.
---@param adapter table
---@param provider string
local function redirect_schema_to_chat(adapter, provider)
	if not adapter.schema then
		return
	end
	local providers = require("ducktape.providers")
	local spec = providers.spec(provider) or {}
	for _, key in ipairs(spec.chat_options or {}) do
		local option = (spec.options or {})[key]
		if adapter.schema[key] and option then
			adapter.schema[key].default = function()
				local value = (providers.current("chat").opts or {})[key]
				if option.to_schema then
					return option.to_schema(value)
				end
				return value
			end
		end
	end
end

local function resolve_chat_adapter()
	local providers = require("ducktape.providers")
	local adapters = require("codecompanion.adapters")
	local sel = providers.current("chat")

	if not sel or not sel.provider then
		return nil
	end

	if providers.kind(sel.provider) == "http" then
		local name = providers.http_adapter("chat")
		local adapter = name and adapters.resolve(name)
		if not adapter then
			return nil
		end
		redirect_schema_to_chat(adapter, sel.provider)
		return adapter
	end

	local adapter_name = providers.acp_adapter(sel.provider)
	if not adapter_name then
		return nil
	end

	local session_opts = {}
	local spec = providers.providers[sel.provider]
	if not spec then
		return nil
	end
	local opts = sel.opts or {}

	for _, key in ipairs(spec.chat_options or {}) do
		local option = (spec.options or {})[key]
		local value = providers.resolve_chat_option_value(sel.provider, key, opts[key])
		if option and option.category and value then
			session_opts[option.category] = value
		end
	end

	local adapter = adapters.resolve(adapter_name, { session_config_options = session_opts })
	if not adapter then
		return nil
	end
	apply_chat_permissions(adapter, sel.provider)
	return adapter
end

---Like resolve_chat_adapter but for a specific provider, model, and saved opts,
---used during restore when the global selection may not match the saved chat.
---@param provider string
---@param model string|nil
---@param saved_opts table
---@return table|nil
local function resolve_chat_adapter_for(provider, model, saved_opts)
	local providers = require("ducktape.providers")
	local adapters = require("codecompanion.adapters")

	if not providers.resumable(provider) then
		return nil -- no agent session to reopen, so nothing to persist against
	end

	local session_opts = {}
	local spec = providers.providers[provider]
	if not spec then
		return nil
	end
	-- Merge saved opts over provider defaults so effort/fast from the original chat are
	-- preserved ("keep" means the saved value wins)
	local opts = vim.tbl_extend("keep", saved_opts, (providers.defaults.chat.opts or {})[provider] or {})
	if model then
		opts.model = model
	end

	-- `mode` is the exception, and deliberately not inherited: it decides whether the agent
	-- may write without asking, which is a standing decision about this machine rather than
	-- a property of one old conversation. Inheriting it meant chats created while the
	-- default was `acceptEdits` kept silent write access for good, so tightening the default
	-- appeared to do nothing — every existing chat reopened under the old, laxer setting.
	opts.mode = (providers.opts_for("chat", provider) or {}).mode

	for _, key in ipairs(spec.chat_options or {}) do
		local option = (spec.options or {})[key]
		local value = providers.resolve_chat_option_value(provider, key, opts[key])
		if option and option.category and value then
			session_opts[option.category] = value
		end
	end

	local adapter_name = providers.acp_adapter(provider)
	if not adapter_name then
		return nil
	end

	local adapter = adapters.resolve(adapter_name, { session_config_options = session_opts })
	apply_chat_permissions(adapter, provider)
	return adapter
end

--=============================================================================
-- On-disk state
--=============================================================================

---@param path string
---@return table
local function read_json(path)
	if vim.fn.filereadable(path) == 0 then
		return {}
	end
	local ok, content = pcall(vim.fn.readfile, path)
	if not ok then
		return {}
	end
	local ok_json, data = pcall(vim.json.decode, table.concat(content, "\n"))
	if not ok_json or type(data) ~= "table" then
		return {}
	end
	return data
end

---@param path string
---@param data table
local function write_json(path, data)
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local ok, encoded = pcall(vim.json.encode, data)
	if ok then
		pcall(vim.fn.writefile, { encoded }, path)
	end
end

-- Titles the user chose, keyed by ACP session ID. Kept apart from chat_sessions.json
-- because they outlive the chats that carried them: a renamed session still shows under
-- that name when it turns up in the chat list as resumable, long after its buffer is
-- gone. They also have to be distinguishable from titles the *agent* generated, which
-- arrive at every turn end and are free to change — a user's name is not.
local titles_file = vim.fn.stdpath("state") .. "/ducktape/chat_titles.json"

---@return table<string, string> session ID → user-chosen title
function M.saved_titles()
	return read_json(titles_file)
end

---Record a user-chosen title for a session, or forget it when title is nil.
---@param sid string|nil No-op without one — a chat with no exchange yet has no session
---to key the title to, and save_open_chats backfills it once there is.
---@param title string|nil
function M.set_saved_title(sid, title)
	if not sid then
		return
	end
	local titles = M.saved_titles()
	titles[sid] = title
	write_json(titles_file, titles)
end

--=============================================================================
-- Public API
--=============================================================================

---A minimal buffer context carrying only the fields Chat.new accesses directly
---(bufnr). The full editor context (n module) is assembled by the plugin itself
---from args.context if the caller provides one.
---@return table
local function current_buffer_context()
	return { bufnr = api.nvim_get_current_buf() }
end

---Stash any option that can only be applied once the session exists, for the first ChatSubmitted.
---
---Such an option has category = nil in the agent's own schema and can only reach the session via
---conn:set_config_option, which needs the live session that does not exist at Chat.new time. Which
---options those are comes from the provider spec's `after_session` flag rather than from the
---provider's name, so a provider with one of its own is carried too.
---@param bufnr number
---@param provider string
---@param opts table
local function stash_agent(bufnr, provider, opts)
	if not opts then
		return
	end
	for _, key in ipairs(require("ducktape.providers").after_session_options(provider, "chat")) do
		local value = opts[key]
		if value and value ~= "default" then
			pending_agents[bufnr] = value
		end
	end
end

---Post-creation guard: track the buffer, set an informative title, stash the agent, and
---record provider/model so the chat list can surface them without guessing from the adapter.
---@param chat table|nil
---@param override? { provider: string, model?: string, opts?: table } A restored chat
---carries the provider/model/opts it was originally created with, which need not
---match the current selection.
local function post_create(chat, override)
	if not chat then
		return
	end
	last_chat_buf = chat.bufnr

	local sel = require("ducktape.providers").current("chat")
	local provider = (override and override.provider) or sel.provider
	local opts = (override and override.opts) or sel.opts or {}
	local model = tostring((override and override.model) or opts.model)

	stash_agent(chat.bufnr, provider, opts)

	local display = ("%s · %s"):format(provider, model)
	pcall(chat.set_title, chat, display)

	chat._ducktape_provider = provider
	chat._ducktape_model = model
	chat._ducktape_opts = vim.deepcopy(opts) -- capture effort, mode, fast, etc.

	-- The end of a turn is when the transcript in the buffer becomes the record again, so it is
	-- also when ducktape.chat_edit stops treating anything above the prompt as an edit. on_ready covers
	-- the end of a restore too — acp/render.lua's restore_session finishes by calling it.
	chat:add_callback("on_ready", function(c)
		require("ducktape.chat_edit").rebase(c)
	end)

	-- Winbar header — stays pinned at the top of every window showing this chat.
	-- BufFilePost fires when CodeCompanion auto-titles the chat (set_title → nvim_buf_set_name),
	-- so the title field updates within a second of the first response landing.
	ensure_winbar_highlights()

	local function winbar_text(bufnr)
		local chat_obj = require("codecompanion.interactions.chat").buf_get_chat(bufnr)
		local title = (chat_obj and chat_obj.title) or "untitled"
		local prov = chat_obj and chat_obj._ducktape_provider or provider
		local mod = chat_obj and chat_obj._ducktape_model or model
		local D = "%#DucktapeWinBarDim#"
		local P = "%#DucktapeWinBarProvider#"
		local Mh = "%#DucktapeWinBarModel#"
		local T = "%#DucktapeWinBarTitle#"
		local S = "%#DucktapeWinBarSep#"
		return {
			("  %s%s%s · %s%s%s   │   %s%s%s  "):format(P, prov, D, Mh, mod, D, T, title, D),
			S .. string.rep("─", 120),
		}
	end

	---Winbar and footer for every window showing this chat. The footer tier depends on the
	---window's width, so this has to run per window rather than once per buffer.
	local function update_chrome(bufnr)
		if not api.nvim_buf_is_valid(bufnr) then
			return
		end
		local text = winbar_text(bufnr)
		for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
			local ok = pcall(function()
				vim.wo[win].winbar = text
			end)
			if not ok then
				pcall(function()
					vim.wo[win].winbar = text[1]
				end)
			end
			pcall(function()
				vim.wo[win].statusline = footer_text(api.nvim_win_get_width(win))
			end)
		end
	end

	local augroup = api.nvim_create_augroup("DucktapeChatWinbar" .. chat.bufnr, { clear = true })
	vim.defer_fn(function()
		update_chrome(chat.bufnr)
	end, 10) -- wait for the window to materialise

	api.nvim_create_autocmd("BufWinEnter", {
		group = augroup,
		buffer = chat.bufnr,
		callback = function()
			update_chrome(chat.bufnr)
		end,
	})
	-- Re-tier the footer when the window changes width: a narrowed window would otherwise
	-- keep the wider line it was given, clipped mid-word.
	api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
		group = augroup,
		callback = function()
			update_chrome(chat.bufnr)
		end,
	})
	-- Winbar and statusline are window options, so they outlive the buffer that asked for
	-- them: opening a file in the chat's window would otherwise leave that file wearing the
	-- chat's header and key line. Only the window the buffer is leaving is cleared — another
	-- split showing the same chat keeps its own.
	api.nvim_create_autocmd("BufWinLeave", {
		group = augroup,
		buffer = chat.bufnr,
		callback = function(args)
			local win = api.nvim_get_current_win()
			if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == args.buf then
				pcall(function()
					vim.wo[win].winbar = nil
					vim.wo[win].statusline = nil
				end)
			end
		end,
	})
	-- Also where a user-chosen title is defended. The agent pushes its own
	-- auto-generated title at the end of every turn (session_info_update →
	-- Chat:set_title, acp/init.lua:653) and nothing there asks whether the name was
	-- the user's, so a rename would otherwise survive only until the next message.
	-- set_title renames the buffer, so this fires for the agent's write as much as
	-- for our own — hence the re-entrancy guard on the correction.
	local reasserting = false
	api.nvim_create_autocmd("BufFilePost", {
		group = augroup,
		buffer = chat.bufnr,
		callback = function(args)
			local chat_obj = require("codecompanion.interactions.chat").buf_get_chat(args.buf)
			local want = chat_obj and chat_obj._ducktape_user_title
			if want and chat_obj.title ~= want and not reasserting then
				reasserting = true
				pcall(chat_obj.set_title, chat_obj, want)
				reasserting = false
			end
			update_chrome(args.buf)
		end,
	})
	api.nvim_create_autocmd("BufWipeout", {
		group = augroup,
		buffer = chat.bufnr,
		once = true,
		callback = function(args)
			for _, win in ipairs(vim.fn.win_findbuf(args.buf)) do
				vim.wo[win].winbar = nil
				vim.wo[win].statusline = nil
			end
			require("ducktape.chat_edit").forget(args.buf)
			pcall(api.nvim_del_augroup_by_id, augroup)
		end,
	})
end

---The most recently created live chat. Falls back to walking codecompanion_buffers
---(append-ordered, so the tail is newest) because the plugin only records `last_chat`
---for chats it opened a window for, plus on BufEnter — and a restored chat is created
---hidden and never entered, so it is invisible to that bookkeeping until first opened.
---@return table|nil
local function newest_chat()
	local Chat = require("codecompanion.interactions.chat")
	local chat = Chat.last_chat()
	if chat and api.nvim_buf_is_valid(chat.bufnr) then
		return chat
	end
	local bufs = _G.codecompanion_buffers or {}
	for i = #bufs, 1, -1 do
		if api.nvim_buf_is_valid(bufs[i]) then
			local found = Chat.buf_get_chat(bufs[i])
			if found then
				return found
			end
		end
	end
end

---The chat `M.toggle` would reach — i.e. the one the user thinks of as current. Exposed
---for the chat list, which marks it. Callers must read this *before* opening a picker:
---last_chat follows BufEnter, so once a Telescope prompt has focus the answer can change.
---@return table|nil
function M.current_chat()
	return newest_chat()
end

---Chats saved from the last session that have not been reopened yet, oldest first.
---@return table[]
function M.pending_chats()
	return pending
end

---Take an entry out of the pending set, because it is about to become a live chat and the
---live-chat scan governs it from then on. Without this a reopened chat would be counted
---twice on quit, and — worse — a chat reopened and then deliberately closed would be
---carried forward and come back anyway.
---@param entry table
local function consume_pending(entry)
	for i, p in ipairs(pending) do
		-- By identity for the entry we were handed, by session for one reconstructed
		-- elsewhere (the chat list rebuilds its own tables from the same JSON).
		if p == entry or (entry.session_id ~= nil and p.session_id == entry.session_id) then
			table.remove(pending, i)
			return
		end
	end
end

---Toggle the last chat buffer. Delegates to the plugin's own toggle, which
---tracks last_chat internally and is the authority on show/hide state — but
---only once a real chat exists. Without this guard, the plugin's own toggle
---creates a brand-new chat with adapter = nil when there is none, bypassing
---all of this repo's provider/model/effort/mode setup.
function M.toggle()
	local chat = newest_chat()
	if not chat then
		-- Nothing live, but something may be waiting to be reopened. Reviving beats
		-- creating a blank chat here: the whole promise of persistence is that this keymap
		-- reaches the work you left, and `<leader>cn` is what asks for a fresh one.
		local entry = pending[#pending]
		if entry then
			ui.say(("[ducktape] reopening %s…"):format(entry.title or "your last chat"), vim.log.levels.INFO)
			local revived = M.restore_session(entry)
			if revived then
				return
			end
		end
		return M.new()
	end
	-- The plugin's toggle acts on its own last_chat, which is nil for a restored
	-- chat — it would create a brand-new chat and shadow the restored one. Open the
	-- chat we found directly; entering the buffer sets last_chat, so subsequent
	-- toggles can go through the plugin as usual.
	if not require("codecompanion.interactions.chat").last_chat() then
		chat.ui:open()
		if chat.ui.winnr and api.nvim_win_is_valid(chat.ui.winnr) then
			pcall(api.nvim_set_current_win, chat.ui.winnr)
		end
		return
	end
	vim.cmd("CodeCompanionChat Toggle")
end

---Start a new chat with the current provider and its preset options.
---Extra keys (messages, auto_submit, etc.) are passed through to Chat.new.
---@param opts? table
function M.new(opts)
	opts = opts or {}
	ensure_spinner_group()

	local Chat = require("codecompanion.interactions.chat")
	local adapter = resolve_chat_adapter()
	if not adapter then
		return ui.say("[ducktape] could not resolve adapter for chat", vim.log.levels.ERROR)
	end

	local chat =
		Chat.new(vim.tbl_extend("keep", { adapter = adapter, buffer_context = current_buffer_context() }, opts))
	post_create(chat)
end

---Close every chat buffer the plugin knows about.
function M.close_all()
	local closed = 0
	-- Snapshot before iterating: Chat:close() mutates codecompanion_buffers
	-- via table.remove, and ipairs over the live table would skip elements
	-- as later entries shift down into already-visited slots.
	local bufs = vim.list_extend({}, _G.codecompanion_buffers or {})
	for _, buf in ipairs(bufs) do
		if api.nvim_buf_is_valid(buf) then
			-- Route through Chat:close() so the acp_connection gets
			-- disconnected and codecompanion_buffers/chats bookkeeping stays
			-- in sync; a raw buf_delete would leak the subprocess and leave
			-- the stale bufnr behind.
			local chat = require("codecompanion.interactions.chat").buf_get_chat(buf)
			if chat then
				chat:close()
			else
				pcall(api.nvim_buf_delete, buf, { force = true })
			end
			closed = closed + 1
		end
	end
	if closed > 0 then
		ui.say(("[ducktape] closed %d chat(s)"):format(closed), vim.log.levels.INFO)
	else
		ui.say("[ducktape] no chats to close", vim.log.levels.INFO)
	end
end

---Stop the running request in the last active chat. Works from anywhere —
---the chat buffer doesn't need to be focused.
function M.stop()
	local chat = require("codecompanion.interactions.chat").last_chat()
	if not chat or not api.nvim_buf_is_valid(chat.bufnr) then
		return ui.say("[ducktape] no chat to stop", vim.log.levels.INFO)
	end
	if chat.current_request or chat.tool_orchestrator then
		-- CodeCompanion's stop does not reliably fire RequestFinished, which is what
		-- clears our thinking spinner. Clear it here so the virtual text doesn't stay
		-- frozen on screen.
		local ok, spinner = pcall(api.nvim_buf_get_var, chat.bufnr, "ducktape_chat_spinner")
		if ok and spinner then
			spinner.stop()
			pcall(api.nvim_buf_del_var, chat.bufnr, "ducktape_chat_spinner")
		end
		chat:stop()
		ui.say("[ducktape] stopped", vim.log.levels.INFO)
	else
		ui.say("[ducktape] nothing in flight", vim.log.levels.INFO)
	end
end

---Give a chat a title of the user's choosing and make it stick. Three places have to
---agree for that: the chat itself (set_title, which also renames the buffer and so drags
---the winbar along), `_ducktape_user_title` so the agent's own auto-title is corrected rather
---than accepted, and the titles store so the name survives the buffer and the restart.
---@param chat table
---@param title string
function M.apply_title(chat, title)
	chat._ducktape_user_title = title
	pcall(chat.set_title, chat, title)
	local conn = chat.acp_connection
	M.set_saved_title(conn and conn.session_id, title)
end

---Rename the current chat.
---@param chat? table Passed by the chat list to rename a specific entry.
function M.rename(chat)
	chat = chat or require("codecompanion.interactions.chat").buf_get_chat(api.nvim_get_current_buf())
	if not chat then
		chat = newest_chat()
	end
	if not chat or not api.nvim_buf_is_valid(chat.bufnr) then
		return ui.say("[ducktape] no chat to rename", vim.log.levels.INFO)
	end

	local current = chat.title or ""
	vim.ui.input({ prompt = "Rename chat: ", default = current }, function(input)
		local name = input and vim.trim(input) or ""
		if name ~= "" and name ~= current then
			M.apply_title(chat, name)
		end
	end)
end

---Open a chat pre-loaded with messages — the prose-float upgrade. The caller
---passes `messages` and any other Chat.new argument, and the adapter is resolved
---from the current chat provider selection.
---@param opts? table
function M.open_with_context(opts)
	opts = opts or {}
	ensure_spinner_group()

	local Chat = require("codecompanion.interactions.chat")
	local adapter = resolve_chat_adapter()
	if not adapter then
		return ui.say("[ducktape] could not resolve adapter for chat", vim.log.levels.ERROR)
	end

	local chat_opts = vim.tbl_extend("keep", { adapter = adapter, buffer_context = current_buffer_context() }, opts)
	local chat = Chat.new(chat_opts)
	post_create(chat)
end

---Switch the chat provider and model. Shared with inline — see ducktape.pick.
function M.pick()
	require("ducktape.pick").open("chat")
end

--=============================================================================
-- Chat persistence — ACP session IDs saved per cwd, resumed via session/load
--=============================================================================
-- What persists is the agent's *own* session, not a private copy of the transcript.
-- Replaying saved `chat.messages` into a fresh session restores the buffer text but
-- leaves the agent with no memory of the conversation: the ACP adapter's
-- form_messages (adapters/acp/helpers.lua) forwards only user messages not yet
-- marked sent, and the agent holds its history server-side. claude-agent-acp
-- advertises loadSession, so the durable record is the session ID — persist that and
-- let session/load replay the transcript back to us.

local state_file = vim.fn.stdpath("state") .. "/ducktape/chat_sessions.json"

---@return table<string, table[]> project key → saved chat entries
local function read_state()
	return read_json(state_file)
end

---@param data table<string, table[]>
local function write_state(data)
	write_json(state_file, data)
end

---The key this project's saved chats are filed under.
---
---`opts.session.chats`, which is the working directory by default — what this has always used. Two
---subdirectories of one repository therefore keep their own sets of chats, which is the behaviour
---anyone with saved chats already has.
---
---It is deliberately a separate setting from `session.scope`, which decides which resumable *agent
---sessions* the chat list offers. Those two genuinely want different answers: sessions are filtered
---by repository root so they do not vanish when nvim is opened in a subdirectory, while chats have
---always been per directory. Collapsing them onto one setting would move somebody's saved chats
---without being asked to.
---@return string
local function state_key()
	return require("ducktape.scope").key(require("ducktape.config").get().session.chats)
end

---This project's saved entries, and the key they should be written back under.
---
---When `session.chats` is the working directory — the default — this is a plain lookup and there is
---nothing to migrate.
---
---When it is anything coarser, every existing key at or under the new one is *merged* rather than
---the first match winning. First-wins loses chats: with `/repo/frontend` and `/repo/backend` each
---holding their own set, opening one of them would claim the `/repo` key and leave the other's
---entries in the file with nothing that ever looks them up again.
---@param data table<string, table[]>
---@param override_key? string The key to read for, instead of the configured one. Tests only.
---@return table[]|nil entries, string key
local function read_entries(data, override_key)
	local key = override_key or state_key()
	local cwd = vim.fn.getcwd()

	-- The common case, and the default: the key is the directory, so there is only ever one bucket.
	if key == cwd then
		local entries = data[key]
		return type(entries) == "table" and entries or nil, key
	end

	-- A coarser key. Gather its own bucket plus every directory-scoped one beneath it, in a stable
	-- order so a merge is reproducible.
	local sources = {}
	for stored in pairs(data) do
		if stored == key or vim.startswith(stored, key .. "/") then
			table.insert(sources, stored)
		end
	end
	table.sort(sources)

	local merged, seen = {}, {}
	for _, stored in ipairs(sources) do
		for _, entry in ipairs(data[stored] or {}) do
			-- Deduplicated by session ID: the same chat can legitimately appear under two keys once
			-- a repository has been opened from two of its subdirectories.
			local id = entry.session_id
			if id == nil or not seen[id] then
				seen[id or entry] = true
				table.insert(merged, entry)
			end
		end
	end

	return #merged > 0 and merged or nil, key
end

---Has this chat completed at least one exchange? Only then has the agent committed
---the session to its own store, so only then is its session ID worth saving — an
---unused chat's ID resolves to "Resource not found" on the next start, which
---CodeCompanion reports as an error notification. Presence of an LLM reply is the
---provider-agnostic proxy for "the agent saved it".
---@param chat table
---@return boolean
local function has_exchange(chat)
	local llm_role = require("codecompanion.config").constants.LLM_ROLE
	for _, m in ipairs(chat.messages or {}) do
		if m.role == llm_role and type(m.content) == "string" and m.content:find("%S") then
			return true
		end
	end
	return false
end

---Record every live ACP chat under the current cwd, replacing whatever was stored
---for it before. A chat the user closed is simply absent from the new list, which
---is what stops it coming back on the next start.
---
---Every chat is remembered; only its `session_id` is conditional. A chat with no
---exchange behind it is stored without one and comes back as an empty chat — there
---is no history to lose, so it reopens rather than disappearing.
local function save_open_chats()
	local entries = {}
	for _, bufnr in ipairs(_G.codecompanion_buffers or {}) do
		if api.nvim_buf_is_valid(bufnr) then
			local chat = require("codecompanion.interactions.chat").buf_get_chat(bufnr)
			local is_acp = chat and chat.adapter and chat.adapter.type == "acp"
			if is_acp and chat._ducktape_provider then
				-- Read the session ID off the live connection rather than a value cached at
				-- creation time: Chat.new establishes the connection on a scheduled tick, so
				-- anything captured synchronously after it returns is still nil.
				-- `_ducktape_resumable` covers the restored-chat case: replaying a transcript goes
				-- through add_buf_message, which writes the buffer without repopulating
				-- chat.messages (and restore_session clears it first), so a chat resumed and
				-- not yet written to looks empty to has_exchange. Its session is known-good
				-- by definition — it was just loaded from the agent's own store.
				local conn = chat.acp_connection
				local resumable = conn and conn.session_id and (chat._ducktape_resumable or has_exchange(chat))

				-- The auto-title only lands after the first response; before that the title
				-- is the `provider · model` placeholder set at creation. Saving that would
				-- pin the placeholder forever, so leave it out and let the restore fall
				-- back to whatever the agent reports.
				local title = chat.title
				if title == ("%s · %s"):format(tostring(chat._ducktape_provider), tostring(chat._ducktape_model)) then
					title = nil
				end

				-- Backfill: a chat renamed before its first exchange had no session ID to
				-- key the name to, so M.apply_title could only record it on the chat.
				if chat._ducktape_user_title and conn and conn.session_id then
					M.set_saved_title(conn.session_id, chat._ducktape_user_title)
				end

				-- `mode` is left out on the way to disk too, so the file stops carrying a
				-- permission setting at all. Copied rather than edited in place: `_ducktape_opts`
				-- is live state the winbar and status panel read.
				local opts = vim.deepcopy(chat._ducktape_opts or {})
				opts.mode = nil

				table.insert(entries, {
					session_id = resumable and conn.session_id or nil,
					provider = chat._ducktape_provider,
					model = chat._ducktape_model,
					opts = opts,
					title = title,
				})
			end
		end
	end

	-- Carry forward everything still pending. Since nothing is restored at startup, the
	-- live scan above sees only what the user actually opened, and writing that alone would
	-- quietly forget every chat they left untouched. Entries are dropped from `pending` the
	-- moment they are reopened or deleted, so this cannot resurrect a chat that was
	-- reopened and then closed on purpose, and cannot duplicate one that is now live.
	local live_sessions = {}
	for _, e in ipairs(entries) do
		if e.session_id then
			live_sessions[e.session_id] = true
		end
	end
	for _, e in ipairs(pending) do
		if not (e.session_id and live_sessions[e.session_id]) then
			table.insert(entries, e)
		end
	end

	local data = read_state()
	local key = state_key()
	data[key] = #entries > 0 and entries or nil
	-- With a coarser `session.chats`, drop every directory-scoped bucket the read merged from, so the
	-- two forms do not both accumulate. Only the ones beneath this key: another repository's entries
	-- are none of our business.
	for stored in pairs(data) do
		if stored ~= key and vim.startswith(stored, key .. "/") then
			data[stored] = nil
		end
	end
	write_state(data)
end

--=============================================================================
-- Removing chats and the sessions behind them
--=============================================================================

---Drop every local trace of a session: its saved entry for this cwd, and any name the
---user gave it. Only correct once the agent has actually deleted it — forgetting a
---session the agent still holds just means it reappears in the chat list, sourced from
---session/list, under its agent-generated title.
---@param sid string
local function forget_session(sid)
	-- Pending first: it is written back over the state file on quit, so pruning only the
	-- file would see the deleted session reappear at the next start.
	for i = #pending, 1, -1 do
		if pending[i].session_id == sid then
			table.remove(pending, i)
		end
	end

	local data = read_state()
	local saved, key = read_entries(data)
	if saved then
		local kept = {}
		for _, entry in ipairs(saved) do
			if entry.session_id ~= sid then
				table.insert(kept, entry)
			end
		end
		data[key] = #kept > 0 and kept or nil
		write_state(data)
	end
	M.set_saved_title(sid, nil)
end

---Stop offering a pending chat without deleting anything. Its session, if it has one,
---stays in the agent's store and so stays resumable from the chat list — this only says
---"do not reopen this one for me". Defined here rather than beside the other pending
---helpers because it needs the state file, which is set up in this half of the module.
---@param entry table
function M.forget_pending(entry)
	consume_pending(entry)

	-- Written through now rather than left to the quit-time save, so the decision survives
	-- a crash and matches what the user just watched happen.
	local data = read_state()
	local saved, key = read_entries(data)
	if saved and entry.session_id ~= nil then
		local kept = {}
		for _, e in ipairs(saved) do
			if e.session_id ~= entry.session_id then
				table.insert(kept, e)
			end
		end
		data[key] = #kept > 0 and kept or nil
		write_state(data)
	end
end

---Whether the agent behind a connection advertises session/delete. Read straight off
---the initialize response the connection cached, because CodeCompanion wraps `list` and
---`load` in can_* helpers but not `delete` — and asking for an unadvertised method earns
---a JSON-RPC method-not-found, which its own notify handler turns into a red box on
---screen (acp/init.lua:596).
---@param conn table|nil
---@return boolean
local function can_delete_sessions(conn)
	local info = conn and conn._agent_info
	local caps = info and info.agentCapabilities and info.agentCapabilities.sessionCapabilities
	return type(caps) == "table" and caps.delete ~= nil
end

---Whether the agent still has this session in its store.
---@param conn table
---@param sid string
---@return boolean
local function session_is_listed(conn, sid)
	if not (conn.can_list_sessions and conn:can_list_sessions()) then
		-- No way to check, so take the agent at its word. Claiming a delete that did not
		-- happen is the worse of the two mistakes.
		return true
	end
	for _, s in ipairs(conn:session_list({ max_sessions = 500 }) or {}) do
		if s.sessionId == sid then
			return true
		end
	end
	return false
end

---Delete a session from the agent's own store, then forget it here. Any ready connection
---to the right agent will do: the agent deletes by ID, not by whatever session the
---connection itself is holding.
---@param sid string
---@param conn table A ready ACP connection to the agent that owns the session
---@return boolean deleted
function M.delete_session(sid, conn)
	if not can_delete_sessions(conn) then
		ui.say("[ducktape] this agent cannot delete sessions", vim.log.levels.WARN)
		return false
	end

	-- The agent answers with an empty object; send_rpc_request maps both a JSON-RPC error
	-- and a timeout to nil, so a nil answer is not by itself a surviving session.
	local answered = conn:send_rpc_request("session/delete", { sessionId = sid }) ~= nil

	-- Verify instead of trusting the answer, because neither answer means what it looks
	-- like. A refusal is what a session the agent never stored gets — a chat closed before
	-- its first exchange — and there is nothing to delete in that case anyway. An
	-- acknowledgement is not proof either: the agent unlinks the transcript, but anything
	-- still holding that session writes it straight back, and the RPC reports success
	-- regardless (measured — hence the connection rules on connection_for_cleanup).
	if session_is_listed(conn, sid) then
		ui.say(
			answered
					and ("[ducktape] session %s survived being deleted — something still has it open"):format(
						sid:sub(1, 8)
					)
				or ("[ducktape] the agent would not delete session %s"):format(sid:sub(1, 8)),
			vim.log.levels.ERROR
		)
		return false
	end

	forget_session(sid)
	return true
end

---Whether the agent is still working on this chat's turn. `_active_prompt` is the ACP
---side of it: chat.current_request only covers the HTTP adapters.
---@param chat table
---@return boolean
local function in_flight(chat)
	local conn = chat.acp_connection
	return chat.current_request ~= nil or (conn ~= nil and conn._active_prompt ~= nil)
end

---A ready connection able to delete `sid`, which means any connection except one holding
---it. Deleting a session over the connection that owns it does not stick: the agent
---unlinks the transcript, the live session writes it straight back, and the RPC reports
---success either way — measured, twice. Another live chat's connection will do; spawning
---one costs a subprocess and a handshake, which is why it is the fallback.
---@param provider string
---@param sid string
---@return table|nil conn, boolean spawned Caller disconnects it when spawned
local function connection_for_cleanup(provider, sid)
	for _, bufnr in ipairs(_G.codecompanion_buffers or {}) do
		local other = require("codecompanion.interactions.chat").buf_get_chat(bufnr)
		local conn = other and other.acp_connection
		if conn and conn:is_ready() and other._ducktape_provider == provider and conn.session_id ~= sid then
			return conn, false
		end
	end

	local adapter = resolve_chat_adapter_for(provider, nil, {})
	if not adapter then
		return nil, false
	end
	local conn = require("codecompanion.acp").new({ adapter = adapter })
	if conn:connect_and_authenticate() then
		return conn, true
	end
	pcall(conn.disconnect, conn)
	return nil, false
end

---Remove a chat for good: the buffer closes and the agent's stored copy of the
---conversation is deleted, so it does not come back as a resumable session. Irreversible
---— the agent unlinks the transcript — hence the confirmation.
---@param chat? table Defaults to the chat in the current buffer, else the newest one
function M.delete(chat)
	chat = chat or require("codecompanion.interactions.chat").buf_get_chat(api.nvim_get_current_buf()) or newest_chat()
	if not chat or not api.nvim_buf_is_valid(chat.bufnr) then
		return ui.say("[ducktape] no chat to delete", vim.log.levels.INFO)
	end

	local title = chat.title or "this chat"
	local provider = chat._ducktape_provider
	local conn = chat.acp_connection
	local sid = conn and conn.session_id
	-- A session ID alone does not mean there is anything to lose: session/new happens at
	-- creation, while the agent writes the transcript only once there has been an
	-- exchange. Same test save_open_chats uses to decide whether an ID is worth keeping.
	-- It informs the wording only — the deletion below still runs on the strength of the
	-- session ID, since this test reads as false mid-answer, when there *is* a file.
	local stored = sid ~= nil and (chat._ducktape_resumable or has_exchange(chat))
	local question = stored and ("Delete %s and its saved transcript? This cannot be undone."):format(title)
		or ("Close %s? It has no saved transcript."):format(title)
	if not ui.confirm(question) then
		return
	end

	-- End the turn before pulling the session out from under it, so the agent is not
	-- mid-write when its process goes away.
	if sid and in_flight(chat) then
		pcall(chat.stop, chat)
		vim.wait(2000, function()
			return not in_flight(chat)
		end, 50)
	end

	-- Closing disconnects the chat's ACP connection, which is what releases the session:
	-- the deletion below has to happen after that, and over a different connection.
	chat:close()
	require("ducktape.chat_list").clear_cache()

	if not sid then
		return ui.say(("[ducktape] closed %s"):format(title), vim.log.levels.INFO)
	end

	-- The agent flushes the transcript as its process winds down, so let the close land
	-- before asking for the file to go.
	vim.wait(600)

	local cleanup_conn, spawned = connection_for_cleanup(provider, sid)
	if not cleanup_conn then
		return ui.say(
			("[ducktape] closed %s, but no agent was available to delete its session"):format(title),
			vim.log.levels.WARN
		)
	end

	local deleted = M.delete_session(sid, cleanup_conn)
	if spawned then
		pcall(cleanup_conn.disconnect, cleanup_conn)
	end

	if deleted then
		ui.say(("[ducktape] deleted %s"):format(title), vim.log.levels.INFO)
	else
		-- The chat is gone but the agent still holds the session, so it will show up
		-- under <leader>cl as resumable. Say so rather than implying a clean delete.
		ui.say(("[ducktape] closed %s, but the agent kept its session"):format(title), vim.log.levels.WARN)
	end
end

---Poll until the chat's own ACP connection has finished its handshake. Chat.new
---kicks it off via vim.schedule and the initialize/authenticate round trip takes a
---second or more, so there is nothing usable when Chat.new returns.
---@param chat table
---@param cb fun(conn: table|nil)
---@param tries? number
local function await_connection(chat, cb, tries)
	tries = tries or 150 -- 150 × 100ms ≈ 15s
	if not api.nvim_buf_is_valid(chat.bufnr) then
		return cb(nil)
	end
	local conn = chat.acp_connection
	if conn and conn:is_ready() and conn.session_id then
		return cb(conn)
	end
	if tries <= 0 then
		return cb(nil)
	end
	vim.defer_fn(function()
		await_connection(chat, cb, tries - 1)
	end, 100)
end

---Reopen a saved chat. With a `session_id` the agent's own session is resumed and its
---transcript replayed; without one there is nothing to resume, so the chat simply
---reopens empty on its original provider/model.
---@param entry { session_id?: string, title?: string, provider?: string, model?: string, opts?: table }
---@param opts? { hide?: boolean } hide: park the chat out of sight once restored
---@return table|nil chat
function M.restore_session(entry, opts)
	opts = opts or {}
	ensure_spinner_group()

	local sid = entry.session_id
	local sel = require("ducktape.providers").current("chat")
	local provider = entry.provider or (sel and sel.provider)
	if not require("ducktape.providers").resumable(provider) then
		return ui.say(
			("[ducktape] %s chats have no agent session to resume"):format(tostring(provider)),
			vim.log.levels.WARN
		)
	end

	consume_pending(entry)

	-- Corrected here as well as inside resolve_chat_adapter_for, because these opts are also
	-- what post_create records as `_ducktape_opts` — the status panel and winbar read that, and
	-- reporting a mode the session is not actually running under is its own kind of wrong.
	local saved_opts = vim.deepcopy(entry.opts or {})
	saved_opts.mode = (require("ducktape.providers").opts_for("chat", provider) or {}).mode

	local adapter = resolve_chat_adapter_for(provider, entry.model, saved_opts)
	if not adapter then
		return ui.say(("[ducktape] could not resolve adapter for %s"):format(tostring(provider)), vim.log.levels.ERROR)
	end

	-- `hidden` matters for more than tidiness: these restores land on timers, and a
	-- chat created visible opens a window and takes focus whenever it happens to fire.
	-- Doing that under a Telescope picker dismisses it, and any in-flight insert-mode
	-- keystrokes then hit the locked chat buffer as `E21: 'modifiable' is off`.
	-- Creating it hidden touches no window at all; `newest_chat()` covers the
	-- last_chat bookkeeping that Chat.new skips for hidden chats.
	local Chat = require("codecompanion.interactions.chat")
	local chat = Chat.new({
		adapter = adapter,
		buffer_context = current_buffer_context(),
		hidden = opts.hide or nil,
	})
	if not chat then
		return
	end

	-- Chat.new schedules `vim.treesitter.start(bufnr)` with no language argument, so the
	-- parser is resolved from the buffer's filetype — and the only thing that sets that
	-- filetype is ui:open() (via shared/ui.lua's nvim_set_option_value). A hidden chat
	-- opens no window, so when that scheduled call fires the filetype is still empty, it
	-- fails inside its own pcall, and the buffer ends up with no markdown highlighting.
	-- Setting it here, synchronously, gets in ahead of that callback.
	if opts.hide then
		vim.bo[chat.bufnr].filetype = "codecompanion"
	end

	post_create(chat, { provider = provider, model = entry.model, opts = saved_opts })

	-- A name from the titles store is the user's and outranks the entry's own title,
	-- which is only ever whatever the agent had auto-generated by the last save. Marking
	-- it as such is what keeps the agent from taking the name back mid-session; an
	-- inherited auto-title is deliberately left free to change.
	local user_title = sid and M.saved_titles()[sid] or nil
	local title = user_title or entry.title
	if user_title then
		chat._ducktape_user_title = user_title
	end

	-- Reapplied at every point something else may install a title: post_create sets the
	-- `provider · model` placeholder, and during session/load the agent pushes its own
	-- auto-generated one via session_info_update (acp/init.lua:653). Either would
	-- otherwise replace a name the user chose with <leader>cr.
	local function apply_saved_title()
		if title then
			pcall(chat.set_title, chat, title)
		end
	end

	apply_saved_title()

	-- Nothing to resume: the chat had no exchange behind it, so it reopens empty.
	-- Attempting a load here is what used to raise "Resource not found".
	if not sid then
		return chat
	end

	-- The history is unreachable, but the chat itself stays — it just carries no
	-- transcript. Keeping it means a chat never silently disappears; it cannot breed
	-- dead entries either, because the fallback session it now holds has no exchange
	-- behind it and so is saved without a session ID.
	local function no_history(reason)
		ui.say(("[ducktape] %s — reopened without history"):format(reason), vim.log.levels.WARN)
	end

	await_connection(chat, function(conn)
		-- Closed while the history was still loading. Nothing to report: the chat is gone
		-- because the user shut it, not because the load failed.
		if not api.nvim_buf_is_valid(chat.bufnr) then
			return
		end
		if not conn then
			return no_history("ACP connection never came up")
		end

		-- Ask before loading. A session/load for an unknown ID is answered with a
		-- JSON-RPC error, which CodeCompanion logs at ERROR level and its notify
		-- handler turns into a full red box on screen — noise for a case we can
		-- detect quietly first.
		if conn.can_list_sessions and conn:can_list_sessions() then
			local known = false
			for _, s in ipairs(conn:session_list({ max_sessions = 500 }) or {}) do
				if s.sessionId == sid then
					known = true
					break
				end
			end
			if not known then
				return no_history(("session %s is gone"):format(sid:sub(1, 8)))
			end
		end

		local updates = {}
		local ok = conn:load_session(sid, {
			on_session_update = function(update)
				table.insert(updates, update)
			end,
		})

		-- _establish_session quietly falls back to session/new when session/load
		-- fails, so a true return does not mean the session was found — the surviving
		-- session ID is the only reliable signal.
		if not ok or conn.session_id ~= sid then
			return no_history(("session %s could not be loaded"):format(sid:sub(1, 8)))
		end

		require("codecompanion.interactions.chat.acp.commands").link_buffer_to_session(chat.bufnr, conn.session_id)
		require("codecompanion.interactions.chat.acp.render").restore_session(chat, updates)
		chat._ducktape_resumable = true

		apply_saved_title()
	end)

	return chat
end

local function setup_persistence()
	local augroup = api.nvim_create_augroup("DucktapeChatPersistence", { clear = true })

	api.nvim_create_autocmd("VimLeavePre", {
		group = augroup,
		callback = save_open_chats,
	})

	-- Nothing is restored here. The saved entries are simply held as pending, and each
	-- becomes a real chat only when the user picks it — which is why an nvim start costs no
	-- agent subprocesses at all, however many chats were open when it last quit.
	local saved = read_entries(read_state())
	if type(saved) == "table" then
		pending = vim.deepcopy(saved)
	end
end

setup_persistence()

---The saved-chat read path, for the suite that guards it against losing chats.
---
---Exposed rather than reimplemented in the test: the first-wins migration that dropped a
---subdirectory's chats would have passed any reimplementation of itself.
---@param data table<string, table[]>
---@param key string
---@return table[]|nil entries, string key
function M._read_entries_for_test(data, key)
	return read_entries(data, key)
end

return M
