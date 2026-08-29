-- Chat surface: toggle, new, close-all, and prose-float open-with-context.
--
-- Chat connections stay out of the inline pool: a shared connection restoring history would
-- swallow inline updates — the session-loading branch outranks `_active_prompt`.

local M = {}

local api = vim.api
local ui = require("ducktape.ui")

local last_chat_buf = nil
local spinner_group
local pending_agents = {} -- bufnr → agent name, applied once the session exists

-- Chats that were open when nvim last quit and have not been reopened yet. Read from
-- chat_sessions.json at startup and drained as the user picks them. Nothing here holds an
-- agent process — that is the point: a pending chat costs a JSON entry, not a subprocess.
---@type table[]
local pending = {}

local function ensure_winbar_highlights()
	ui.ensure_highlights()
end

-- Footer tiers, widest-first. `?` survives every tier because it opens CodeCompanion's
-- own keymap list; the footer only has to get you there.
---Built per call: configurable ducktape keymaps must not keep naming defaults after a remap.
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
---Tiers are rendered and measured: a hand-written width would silently break when labels change.
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
	return "" -- blank beats clipped
end

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

			-- category=nil options can only be set once the session exists
			local agent = pending_agents[bufnr]
			if agent then
				pending_agents[bufnr] = nil
				local conn = chat and chat.acp_connection
				if conn and conn.set_config_option then
					pcall(conn.set_config_option, conn, "agent", agent)
				end
			end

			-- ChatSubmitted fires before a prompt exists on setup failure, but RequestFinished
			-- only comes from the prompt builder, so a spinner started here would never stop.
			-- Chat:done clears current_request synchronously before the event, which is the signal.
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

	-- Deleted before first submit never fires ChatSubmitted; clean up the stale entry.
	api.nvim_create_autocmd("BufWipeout", {
		group = spinner_group,
		callback = function(args)
			pending_agents[args.buf] = nil
		end,
	})
end

---Swap the provider's inline guard env for its chat guard env.
---Dropping the env gave chat silent write access; `ask` mirrors claude's `default` confirm-first
---behaviour. Driven by `guard.chat_env` so config-added providers work without code changes.
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
---Generated adapters default to inline; redirect every chat option, applying `to_schema` when the
---stored value and schema field differ in type.
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

---Resolve a chat adapter for a saved chat, where the current selection may not match.
---@param provider string
---@param model string|nil
---@param saved_opts table
---@return table|nil
local function resolve_chat_adapter_for(provider, model, saved_opts)
	local providers = require("ducktape.providers")
	local adapters = require("codecompanion.adapters")

	if not providers.resumable(provider) then
		return nil -- nothing to persist against
	end

	local session_opts = {}
	local spec = providers.providers[provider]
	if not spec then
		return nil
	end
	-- `keep` lets saved effort/fast override defaults.
	local opts = vim.tbl_extend("keep", saved_opts, (providers.defaults.chat.opts or {})[provider] or {})
	if model then
		opts.model = model
	end

	-- `mode` is not inherited: it controls write permission, a machine-level choice, not a
	-- property of one conversation. Inheriting it once kept old chats on `acceptEdits` forever.
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

-- User-chosen titles keyed by ACP session ID. Kept apart from chat_sessions.json because they
-- outlive the buffer and must survive the agent's own auto-generated titles.
local titles_file = vim.fn.stdpath("state") .. "/ducktape/chat_titles.json"

---@return table<string, string> session ID → user-chosen title
function M.saved_titles()
	return read_json(titles_file)
end

---Record or forget a user-chosen title for a session.
---@param sid string|nil No-op without a session ID; save_open_chats backfills it later.
---@param title string|nil
function M.set_saved_title(sid, title)
	if not sid then
		return
	end
	local titles = M.saved_titles()
	titles[sid] = title
	write_json(titles_file, titles)
end

---A minimal buffer context: Chat.new only needs `bufnr`.
---@return table
local function current_buffer_context()
	return { bufnr = api.nvim_get_current_buf() }
end

---Stash options that can only be set once the session exists.
---These have category=nil in the agent schema and need `conn:set_config_option`. The provider
---spec's `after_session` flag decides which, so config-added providers are carried too.
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

---Track the new chat, set its title, stash after-session options, and record provider/model.
---@param chat table|nil
---@param override? { provider: string, model?: string, opts?: table } Restored chats carry their original values.
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

	-- End of turn means the buffer is the record again; tell chat_edit to rebase there.
	-- on_ready also fires at the end of restore_session.
	chat:add_callback("on_ready", function(c)
		require("ducktape.chat_edit").rebase(c)
	end)

	-- Winbar header pinned to every window showing this chat. BufFilePost fires on auto-title
	-- (set_title → nvim_buf_set_name), so the title updates soon after the first response.
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

	---Winbar and footer per window: footer tier depends on window width.
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
	end, 10) -- let the window materialise

	api.nvim_create_autocmd("BufWinEnter", {
		group = augroup,
		buffer = chat.bufnr,
		callback = function()
			update_chrome(chat.bufnr)
		end,
	})
	-- Re-tier on resize so a narrowed window does not keep a clipped wider line.
	api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
		group = augroup,
		callback = function()
			update_chrome(chat.bufnr)
		end,
	})
	-- Window options outlive the buffer; clear them when the chat leaves a window so a
	-- replacement file does not wear the chat chrome.
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
	-- Defend user-chosen titles: the agent pushes an auto-title every turn and does not ask
	-- whether the name was the user's. set_title renames the buffer, so this fires for our
	-- writes too — hence the re-entrancy guard.
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

---The most recently created live chat.
---Falls back to walking codecompanion_buffers (tail is newest) because restored chats are created
---hidden and never entered, so the plugin's `last_chat` bookkeeping misses them.
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

---The chat `M.toggle` would reach. Exposed for the chat list; read before opening a picker,
---since last_chat follows BufEnter and a Telescope prompt changes the answer.
---@return table|nil
function M.current_chat()
	return newest_chat()
end

---Chats saved from the last session that have not been reopened yet, oldest first.
---@return table[]
function M.pending_chats()
	return pending
end

---Remove an entry from the pending set before it becomes live.
---Without this, reopened chats are counted twice on quit and deliberately closed chats come back.
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

---Toggle the last chat buffer.
---Delegates to the plugin's toggle only once a real chat exists; otherwise it would create a new
---chat with adapter=nil, bypassing ducktape's provider/model setup.
function M.toggle()
	local chat = newest_chat()
	if not chat then
		-- Nothing live: revive a pending chat before creating a blank one.
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
	-- `:hide` on the last window raises E444. This branch is reached when the chat was left
	-- deliberately (`:only` or `close_with_last_file=false`).
	if
		chat.ui
		and chat.ui:is_visible()
		and chat.ui.winnr
		and require("ducktape.chat_window").is_last_window(chat.ui.winnr)
	then
		return ui.say(
			"[ducktape] the chat is the only window — there is nothing to toggle back to. Open a file, or `:q` to quit.",
			vim.log.levels.WARN
		)
	end
	-- The plugin's toggle uses its own last_chat, nil for restored chats, so it would shadow
	-- them with a new chat. Open the found chat directly; entering sets last_chat for next time.
	if not require("codecompanion.interactions.chat").last_chat() then
		chat.ui:open()
		if chat.ui.winnr and api.nvim_win_is_valid(chat.ui.winnr) then
			pcall(api.nvim_set_current_win, chat.ui.winnr)
		end
		return
	end
	vim.cmd("CodeCompanionChat Toggle")
end

---Focus the chat, opening it if hidden. Never hides: that is `M.toggle`'s job.
function M.focus()
	local chat = newest_chat()
	if not chat then
		-- Nothing live: reviving a pending chat or starting a fresh one is what toggle already
		-- decides between, and the answer does not change here.
		return M.toggle()
	end
	if not chat.ui then
		return ui.say("[ducktape] the last chat has no window to focus", vim.log.levels.WARN)
	end
	if not chat.ui:is_visible() then
		chat.ui:open()
	end
	if chat.ui.winnr and api.nvim_win_is_valid(chat.ui.winnr) then
		pcall(api.nvim_set_current_win, chat.ui.winnr)
	end
end

---Start a new chat with the current provider and preset options.
---Extra keys pass through to Chat.new.
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

---Close every chat buffer.
function M.close_all()
	local closed = 0
	-- Snapshot first: Chat:close() mutates codecompanion_buffers during iteration.
	local bufs = vim.list_extend({}, _G.codecompanion_buffers or {})
	for _, buf in ipairs(bufs) do
		if api.nvim_buf_is_valid(buf) then
			-- Route through Chat:close() so the ACP connection disconnects and bookkeeping stays
			-- in sync; a raw buf_delete would leak the subprocess.
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

---Stop the running request in the last active chat.
function M.stop()
	local chat = require("codecompanion.interactions.chat").last_chat()
	if not chat or not api.nvim_buf_is_valid(chat.bufnr) then
		return ui.say("[ducktape] no chat to stop", vim.log.levels.INFO)
	end
	if chat.current_request or chat.tool_orchestrator then
		-- CodeCompanion's stop does not reliably fire RequestFinished, so clear our spinner here.
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

---Apply a user-chosen title and make it stick in chat, `_ducktape_user_title`, and the store.
---@param chat table
---@param title string
function M.apply_title(chat, title)
	chat._ducktape_user_title = title
	pcall(chat.set_title, chat, title)
	local conn = chat.acp_connection
	M.set_saved_title(conn and conn.session_id, title)
end

---Rename the current chat, or the chat passed by the chat list.
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

---Open a chat pre-loaded with messages (prose-float). Adapter resolved from current selection.
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

-- Persist the agent's own session ID, not a private transcript copy. Replaying saved messages
-- into a fresh session leaves the agent with no memory; the durable record is the session ID.

local state_file = vim.fn.stdpath("state") .. "/ducktape/chat_sessions.json"

---@return table<string, table[]> project key → saved chat entries
local function read_state()
	return read_json(state_file)
end

---@param data table<string, table[]>
local function write_state(data)
	write_json(state_file, data)
end

---Key for this project's saved chats.
---Defaults to cwd; subdirectories keep their own sets. Separate from `session.scope` because
---resumable sessions and saved chats want different granularity.
---@return string
local function state_key()
	return require("ducktape.scope").key(require("ducktape.config").get().session.chats)
end

---Read this project's saved entries and the key they should be written back under.
---When `session.chats` is coarser than cwd, merge every key at or under it. First-wins would lose
---chats from sibling subdirectories.
---@param data table<string, table[]>
---@param override_key? string The key to read for, instead of the configured one. Tests only.
---@return table[]|nil entries, string key
local function read_entries(data, override_key)
	local key = override_key or state_key()
	local cwd = vim.fn.getcwd()

	-- Default: key is the directory, so there is only one bucket.
	if key == cwd then
		local entries = data[key]
		return type(entries) == "table" and entries or nil, key
	end

	-- Coarser key: gather its own bucket plus every directory-scoped one beneath it.
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
			-- Deduplicate by session ID; the same chat can appear under two subdirectory keys.
			local id = entry.session_id
			if id == nil or not seen[id] then
				seen[id or entry] = true
				table.insert(merged, entry)
			end
		end
	end

	return #merged > 0 and merged or nil, key
end

---Has the chat completed at least one exchange?
---The agent only commits the session after an LLM reply; saving an unused ID raises "Resource not
---found" on restore. LLM presence is the provider-agnostic proxy.
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

---Record every live ACP chat under the current cwd, replacing what was stored before.
---Closed chats are absent and do not come back. Empty chats are stored without a session_id and
---reopen empty.
local function save_open_chats()
	local entries = {}
	for _, bufnr in ipairs(_G.codecompanion_buffers or {}) do
		if api.nvim_buf_is_valid(bufnr) then
			local chat = require("codecompanion.interactions.chat").buf_get_chat(bufnr)
			local is_acp = chat and chat.adapter and chat.adapter.type == "acp"
			if is_acp and chat._ducktape_provider then
				-- Read the session ID from the live connection; Chat.new establishes it on a
				-- scheduled tick, so synchronous capture after it returns is nil. `_ducktape_resumable`
				-- covers restored chats, whose transcript is replayed into the buffer without
				-- repopulating chat.messages, so has_exchange would see them as empty.
				local conn = chat.acp_connection
				local resumable = conn and conn.session_id and (chat._ducktape_resumable or has_exchange(chat))

				-- The auto-title only lands after the first response; before that the title is the
				-- `provider · model` placeholder. Saving it would pin the placeholder forever.
				local title = chat.title
				if title == ("%s · %s"):format(tostring(chat._ducktape_provider), tostring(chat._ducktape_model)) then
					title = nil
				end

				-- Backfill: a chat renamed before its first exchange had no session ID to key to.
				if chat._ducktape_user_title and conn and conn.session_id then
					M.set_saved_title(conn.session_id, chat._ducktape_user_title)
				end

				-- `mode` is left out so the file carries no permission setting. Copy rather than
				-- edit in place because `_ducktape_opts` is live state the UI reads.
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

	-- Carry forward pending entries so untouched chats are not forgotten. Entries leave
	-- `pending` when reopened or deleted, so this cannot resurrect a closed chat or duplicate a
	-- live one.
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
	-- Drop directory-scoped buckets merged from so the two forms do not accumulate.
	for stored in pairs(data) do
		if stored ~= key and vim.startswith(stored, key .. "/") then
			data[stored] = nil
		end
	end
	write_state(data)
end

---Drop every local trace of a session once the agent has deleted it.
---Forgetting before deletion lets it reappear in the chat list from session/list.
---@param sid string
local function forget_session(sid)
	-- Pending first: it is written back on quit, so pruning only the file would resurrect it.
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

---Stop offering a pending chat without deleting its session.
---The session stays resumable from the chat list; this just says "do not reopen this one for me".
---@param entry table
function M.forget_pending(entry)
	consume_pending(entry)

	-- Write now so the decision survives a crash and matches what the user just saw.
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

---Whether the agent advertises session/delete.
---Read from the cached initialize response: CodeCompanion wraps list/load but not delete, and
---calling an unadvertised method raises a JSON-RPC error the notify handler renders on screen.
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
		-- Cannot verify; claiming a delete that did not happen is the worse mistake.
		return true
	end
	for _, s in ipairs(conn:session_list({ max_sessions = 500 }) or {}) do
		if s.sessionId == sid then
			return true
		end
	end
	return false
end

---Delete a session from the agent's own store, then forget it here.
---Any ready connection to the right agent works: deletion is by ID, not by the connection's session.
---@param sid string
---@param conn table A ready ACP connection to the agent that owns the session
---@return boolean deleted
function M.delete_session(sid, conn)
	if not can_delete_sessions(conn) then
		ui.say("[ducktape] this agent cannot delete sessions", vim.log.levels.WARN)
		return false
	end

	-- send_rpc_request maps JSON-RPC errors and timeouts to nil, so nil is not proof of survival.
	local answered = conn:send_rpc_request("session/delete", { sessionId = sid }) ~= nil

	-- Verify: a refusal means the session was never stored (nothing to delete); an ack is not
	-- proof because anything still holding the session writes it back. Measured — hence the
	-- connection rules in connection_for_cleanup.
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

---Whether the agent is still working on this chat's turn.
---`chat.current_request` only covers HTTP adapters; ACP uses `_active_prompt`.
---@param chat table
---@return boolean
local function in_flight(chat)
	local conn = chat.acp_connection
	return chat.current_request ~= nil or (conn ~= nil and conn._active_prompt ~= nil)
end

---Find a ready connection that does not hold `sid`.
---Deleting over the owning connection does not stick: the live session writes the transcript back.
---Prefer another live chat's connection; spawn only as a fallback.
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

---Delete a chat and its stored session. Irreversible, so confirm first.
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
	-- A session ID alone does not mean there is a transcript to lose; the agent writes it only
	-- after an exchange. Same test save_open_chats uses. This only informs wording; deletion still
	-- runs on the session ID (the test is false mid-answer, when there *is* a file to lose).
	local stored = sid ~= nil and (chat._ducktape_resumable or has_exchange(chat))
	local question = stored and ("Delete %s and its saved transcript? This cannot be undone."):format(title)
		or ("Close %s? It has no saved transcript."):format(title)
	if not ui.confirm(question) then
		return
	end

	-- End the turn before closing so the agent is not mid-write.
	if sid and in_flight(chat) then
		pcall(chat.stop, chat)
		vim.wait(2000, function()
			return not in_flight(chat)
		end, 50)
	end

	-- Closing releases the session; deletion must happen afterward over a different connection.
	chat:close()
	require("ducktape.chat_list").clear_cache()

	if not sid then
		return ui.say(("[ducktape] closed %s"):format(title), vim.log.levels.INFO)
	end

	-- Let the close land before deleting, so the agent finishes flushing the transcript.
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
		-- The chat is gone but the agent still holds the session; it will show up as resumable.
		ui.say(("[ducktape] closed %s, but the agent kept its session"):format(title), vim.log.levels.WARN)
	end
end

---Poll until the chat's ACP connection finishes its handshake.
---Chat.new schedules setup, so nothing is usable synchronously.
---@param chat table
---@param cb fun(conn: table|nil)
---@param tries? number
local function await_connection(chat, cb, tries)
	tries = tries or 150 -- ~15s
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

---Reopen a saved chat. With a session_id the agent's session is resumed; without one the chat
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

	-- Correct here too: post_create records these as `_ducktape_opts`, which the status panel and
	-- winbar read, and reporting the wrong mode is its own bug.
	local saved_opts = vim.deepcopy(entry.opts or {})
	saved_opts.mode = (require("ducktape.providers").opts_for("chat", provider) or {}).mode

	local adapter = resolve_chat_adapter_for(provider, entry.model, saved_opts)
	if not adapter then
		return ui.say(("[ducktape] could not resolve adapter for %s"):format(tostring(provider)), vim.log.levels.ERROR)
	end

	-- Hidden restores avoid stealing focus from a Telescope picker or hitting `E21` with in-flight
	-- keystrokes. `newest_chat()` covers the last_chat bookkeeping Chat.new skips for hidden chats.
	local Chat = require("codecompanion.interactions.chat")
	local chat = Chat.new({
		adapter = adapter,
		buffer_context = current_buffer_context(),
		hidden = opts.hide or nil,
	})
	if not chat then
		return
	end

	-- Chat.new schedules treesitter without a language; the filetype is normally set by ui:open().
	-- Hidden chats have no window, so the scheduled call fails and leaves no markdown highlight.
	-- Set it synchronously here to get ahead of that callback.
	if opts.hide then
		vim.bo[chat.bufnr].filetype = "codecompanion"
	end

	post_create(chat, { provider = provider, model = entry.model, opts = saved_opts })

	-- A user-saved title outranks the entry's auto-generated title. Mark it as user-owned so the
	-- agent does not take it back mid-session; inherited auto-titles are left free to change.
	local user_title = sid and M.saved_titles()[sid] or nil
	local title = user_title or entry.title
	if user_title then
		chat._ducktape_user_title = user_title
	end

	-- Reapply wherever something else may install a title: post_create's placeholder or the
	-- agent's session_info_update auto-title would otherwise overwrite the user's name.
	local function apply_saved_title()
		if title then
			pcall(chat.set_title, chat, title)
		end
	end

	apply_saved_title()

	-- No exchange behind it: reopen empty. Loading here used to raise "Resource not found".
	if not sid then
		return chat
	end

	-- History is unreachable, but keep the chat so it never silently disappears. The fallback
	-- session has no exchange, so it is saved without a session ID and cannot breed dead entries.
	local function no_history(reason)
		ui.say(("[ducktape] %s — reopened without history"):format(reason), vim.log.levels.WARN)
	end

	await_connection(chat, function(conn)
		-- Closed while loading: no need to report a load failure the user caused.
		if not api.nvim_buf_is_valid(chat.bufnr) then
			return
		end
		if not conn then
			return no_history("ACP connection never came up")
		end

		-- List first: session/load for an unknown ID raises a JSON-RPC error CodeCompanion renders
		-- as a red box — noise for a case we can detect quietly.
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

		-- _establish_session falls back to session/new on failure, so the only reliable signal is
		-- whether the session ID survived.
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

	-- Hold saved entries as pending; they become real only when picked, so startup costs no
	-- agent subprocesses.
	local saved = read_entries(read_state())
	if type(saved) == "table" then
		pending = vim.deepcopy(saved)
	end
end

setup_persistence()

---The saved-chat read path, exposed for tests.
---Reimplementing it would not catch the first-wins migration bug that dropped subdirectory chats.
---@param data table<string, table[]>
---@param key string
---@return table[]|nil entries, string key
function M._read_entries_for_test(data, key)
	return read_entries(data, key)
end

return M
