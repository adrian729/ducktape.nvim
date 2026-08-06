-- The provider/model chooser behind <leader>cmi and <leader>cmc.
--
-- One flat list of every provider/model pair rather than a provider prompt followed by a
-- model prompt: picking is one search and one keypress, so typing "opus" gets you there.
-- Inline and chat share this module — each used to carry its own copy of the same two chained
-- vim.ui.select calls, differing only in the scope name, the notification and inline's pool
-- drain.
--
-- The list is followed by the provider's other options, and the whole run is one decision:
-- nothing reaches ducktape.providers until <CR> in that window, so backing out at any point leaves
-- the provider, model and options exactly as they were.
--
-- The list itself goes through ducktape.picker, so telescope is not required for it: with telescope
-- installed the layout comes from the user's own config, deliberately unset here, and without it a
-- built-in float takes over. The options step below is always this plugin's own float — three
-- options at most, so there is nothing to fuzzy-search.

local M = {}

local api = vim.api

--=============================================================================
-- Entries
--=============================================================================

local ui = require("ducktape.ui")
local keys = require("ducktape.keys")

-- Shared with the chat list, which builds its rows the same way.
local render = ui.render
local pad = ui.pad

---Every provider/model pair that can be selected right now.
---
---A provider with endpoints contributes one row per endpoint per model, because its endpoint is
---part of which model you get rather than a separate question — ollama's two lists barely overlap.
---
---Built by walking the registry, so a provider added through config appears here with no edit. It
---used to enumerate the three shipped providers by hand, which meant a fourth was selectable
---everywhere except the one place you would go to select it.
---@param scope "inline"|"chat"
---@param lists table<string, string[]> cache key → models, only what has arrived so far
---@return table[]
local function build_entries(scope, lists)
	local providers = require("ducktape.providers")
	local withheld = require("ducktape.acp_pool").withheld
	local current = providers.current(scope)

	local rows = {}
	---@param model string|nil Nil for a provider whose model list has not arrived
	local function add(provider, model, endpoint)
		local is_current = provider == current.provider
			and model == current.opts.model
			and endpoint == current.opts.endpoint
		-- What a row draws on belongs on the row, not in the docs: nothing in these names says
		-- whether picking one consumes a usage budget or nothing at all. providers.model_tier is
		-- where that is decided, and where each claim's source is recorded.
		local tier = providers.model_tier(provider, model, endpoint)
		table.insert(rows, {
			provider = provider,
			model = model,
			endpoint = endpoint,
			is_current = is_current,
			tier = tier and tier.label or nil,
			free = tier and tier.free or false,
			-- Said on the row rather than discovered after picking it. Two different reasons a row
			-- may not be usable, and they need different words.
			unavailable = (not model and "no models discovered yet")
				or (scope == "inline" and withheld[provider] and "inline unavailable")
				or nil,
		})
	end

	for _, provider in ipairs(providers.names()) do
		local contributed = false
		for _, entry in ipairs(providers.cache_keys(provider)) do
			for _, model in ipairs(lists[entry.key] or providers.models(provider, entry.endpoint)) do
				add(provider, model, entry.endpoint)
				contributed = true
			end
		end
		-- A provider whose list has not arrived still gets a row, saying so. Without one it is
		-- invisible in the only place you would go to select it — and "this provider does not exist"
		-- and "its model list is still on the way" look identical from the outside. The row cannot be
		-- committed; `commit` sends the user to :Ducktape models instead.
		if not contributed then
			add(provider, nil, providers.endpoint_names(provider)[1])
		end
	end

	-- Widest name and model columns, so both line up in one column across providers and the
	-- tier annotations form a column of their own rather than trailing each name's length.
	local name_width, model_width = 0, 0
	for _, row in ipairs(rows) do
		local name = row.endpoint and (row.provider .. " " .. row.endpoint) or row.provider
		row.name = name
		name_width = math.max(name_width, vim.fn.strdisplaywidth(name))
		model_width = math.max(model_width, vim.fn.strdisplaywidth(row.model or "—"))
	end

	local entries = {}
	for _, row in ipairs(rows) do
		local marker = row.is_current and "▶ " or "  "
		local text, highlights = render({
			{ marker, row.is_current and "DucktapeListCurrent" or nil },
			{ pad(row.name, name_width + 2), "DucktapeWinBarProvider" },
			{ "· ", "DucktapeListDim" },
			{ pad(row.model or "—", model_width), row.model and "DucktapeWinBarModel" or "DucktapeListDim" },
			-- Anything drawing on a plan is highlighted rather than dimmed, so it registers
			-- without being read for.
			{ row.tier and ("   " .. row.tier) or "", row.free and "DucktapeListDim" or "DucktapeListStarting" },
			{ row.unavailable and ("   " .. row.unavailable) or "", "DucktapeListDead" },
			{ row.is_current and "   current" or "", "DucktapeListCurrent" },
		})
		table.insert(entries, {
			value = row,
			-- Provider, model and tier are all searchable, so "ollama gpt", "opus" and
			-- "subscription" each narrow the list
			ordinal = ("%s %s %s"):format(row.name, row.model or "", row.tier or ""),
			text = text,
			highlights = highlights,
		})
	end

	-- Telescope's default sorting_strategy renders the first entry nearest the prompt, so
	-- hoisting the current selection puts it under the cursor when the picker opens.
	for i, entry in ipairs(entries) do
		if entry.value.is_current then
			table.insert(entries, 1, table.remove(entries, i))
			break
		end
	end
	return entries
end

---The rows the picker would show, for the suite that checks a newly added provider appears in it.
---
---Exposed rather than reached into: `build_entries` is a local, and the alternative was a test that
---opened a real picker and read its finder.
---@param scope "inline"|"chat"
---@return table[]
function M._entries_for_test(scope)
	return build_entries(scope, {})
end

--=============================================================================
-- Settings step
--=============================================================================

---The options worth offering for a provider once its model is settled.
---
---`model` and `endpoint` are excluded because the flat list already answered them. Options
---with no enumerable values are excluded too: claude's `agent` list only exists on a running
---agent, so `<leader>cs` is where it belongs — that panel can read the live connection.
---
---Nothing here is provider-specific: the schema in providers.lua decides, so a new option on
---a provider shows up in the float without an edit to this file.
---@param scope "inline"|"chat"
---@param provider string
---@return table[]
local function settings_for(scope, provider)
	local providers = require("ducktape.providers")
	local spec = providers.providers[provider]
	if not spec then
		return {}
	end
	local option_keys = scope == "inline" and spec.inline_options or spec.chat_options

	local out = {}
	for _, key in ipairs(option_keys or {}) do
		local option = spec.options[key]
		if option and key ~= "model" and key ~= "endpoint" and option.values then
			table.insert(out, { key = key, option = option })
		end
	end
	return out
end

---What a value means where the name does not say it, and where getting it wrong is expensive.
---
---Comes from the provider spec's `value_notes` and `option_notes`, so a provider knows what its own
---values mean. These used to be one table keyed only by option name, which merged two providers'
---`mode` values into a single list and could only be right for one of them.
---@param provider string
---@param key string
---@param value string
---@return string
local function note_for(provider, key, value)
	local spec = require("ducktape.providers").spec(provider) or {}
	-- A standing caveat about the option outranks a per-value note: claude's `fast` is
	-- model-dependent and there is no per-model list to filter by, so the row says so rather than
	-- pretending to.
	local standing = (spec.option_notes or {})[key]
	if standing then
		return standing
	end
	return ((spec.value_notes or {})[key] or {})[value] or ""
end

local function notify_current(scope)
	local providers = require("ducktape.providers")
	local current = providers.current(scope)
	local spec = current.spec or {}
	local bits = {}
	-- Every option the provider offers for this scope except the model, which is named on its own
	-- ahead of them. Listed from the spec rather than by name, so an option a provider adds shows up
	-- in the confirmation instead of being applied silently.
	for _, key in ipairs((scope == "inline" and spec.inline_options or spec.chat_options) or {}) do
		if key ~= "model" and current.opts[key] then
			table.insert(bits, ("%s=%s"):format(key, current.opts[key]))
		end
	end
	ui.say(
		("[ducktape] %s → %s · %s%s"):format(
			scope,
			current.provider,
			tostring(current.opts.model),
			#bits > 0 and ("   " .. table.concat(bits, " ")) or ""
		)
	)
end

local function notify_unchanged(scope)
	local providers = require("ducktape.providers")
	local current = providers.current(scope)
	ui.say(("[ducktape] %s unchanged — still %s · %s"):format(scope, current.provider, tostring(current.opts.model)))
end

---Write a pending selection into providers, all of it or none of it.
---
---Nothing reaches providers before this: a run through the picker is one decision, so
---abandoning it half-way has to leave the previous provider, model and options exactly as
---they were rather than stranding a provider switch whose model was never confirmed.
---
---Inline's pooled connections were built with the previous values, so they have to go here —
---otherwise the next inline request silently uses the old ones. Chat sessions are not
---touched: this sets the default for new chats, and `<leader>cs` is what reaches into a
---conversation already in progress.
---@param scope "inline"|"chat"
---@param pending { provider: string, model: string, endpoint: string|nil, options: table<string, string>|nil }
local function commit(scope, pending)
	local providers = require("ducktape.providers")
	-- A placeholder row: the provider is real but nothing is known about its models yet, so there is
	-- no model to apply. Committing `nil` would leave the scope pointing at a provider with no model
	-- and fail at the first request instead of here.
	if pending.model == nil then
		return ui.say(
			("[ducktape] no models known for %s yet — :Ducktape models asks every provider what it can reach"):format(
				pending.provider
			),
			vim.log.levels.WARN
		)
	end
	providers.set_provider(scope, pending.provider)
	-- Endpoint first: on ollama it decides which models exist, so a model is only meaningful
	-- against one.
	if pending.endpoint then
		providers.set_option(scope, "endpoint", pending.endpoint)
	end
	providers.set_option(scope, "model", pending.model)
	for key, value in pairs(pending.options or {}) do
		providers.set_option(scope, key, value)
	end
	if scope == "inline" then
		require("ducktape.acp_pool").drain_provider(providers.current(scope).provider)
	end
	notify_current(scope)
end

--=============================================================================
-- Settings float
--=============================================================================

-- Deliberately not a picker. There are three options at most, so there is nothing to
-- fuzzy-search, and a list-per-option meant a nested picker to change one enum. Here every
-- option and its current value is visible at once and `h`/`l` cycles the one under the
-- cursor in place — the same idiom the status panel uses for the same kind of value.

local float = { win = nil, buf = nil, cursor = 1 }

local function close_float()
	if float.win and api.nvim_win_is_valid(float.win) then
		pcall(api.nvim_win_close, float.win, true)
	end
	if float.buf and api.nvim_buf_is_valid(float.buf) then
		pcall(api.nvim_buf_delete, float.buf, { force = true })
	end
	float.win, float.buf = nil, nil
end

---Where a value sits in its option's list, or 1 when the stored value is not one of them.
local function value_index(option, value)
	for i, candidate in ipairs(option.values) do
		if candidate == value then
			return i
		end
	end
	return 1
end

---Confirm a pending provider/model by way of its other options.
---
---The pending selection is held here and only written on `<CR>`, so leaving any other way
---keeps what was in use before — including the model, which has not been applied yet either.
---@param scope "inline"|"chat"
---@param pending { provider: string, model: string, endpoint: string|nil, options: table|nil }
local function open_settings(scope, pending)
	local providers = require("ducktape.providers")
	local settings = settings_for(scope, pending.provider)

	if #settings == 0 then
		-- inline+opencode is the real case: model is the only option it has, so the list's own
		-- <CR> was already the whole decision and there is nothing left to confirm.
		return commit(scope, pending)
	end

	-- Seeded from whatever this provider last used — its options are stored per provider, so
	-- switching to it brings its own settings rather than the outgoing provider's.
	--
	-- An option with no stored value is left absent rather than defaulted to its first value.
	-- Some are deliberately unset: claude's `fast` is, and its first value is `on`, so filling
	-- the gap in would turn it on for every provider switch — an option nobody asked for,
	-- silently, on a model that may not even offer it.
	pending.options = {}
	local stored = providers.opts_for(scope, pending.provider) or {}
	for _, setting in ipairs(settings) do
		pending.options[setting.key] = stored[setting.key]
	end

	ui.ensure_highlights()
	close_float() -- reopening rather than stacking, if one is somehow still up
	float.cursor = 1
	float.committed = false

	local ns = api.nvim_create_namespace("DucktapePickSettings")
	local label_width = 0
	for _, setting in ipairs(settings) do
		label_width = math.max(label_width, vim.fn.strdisplaywidth(setting.option.label or setting.key))
	end

	---Whatever is worth saying about a row at a given value, from the provider's own spec.
	local function note(setting, value)
		return note_for(pending.provider, setting.key, value)
	end

	-- Columns are sized from every value each option *could* take, not the ones showing now:
	-- padding to the current value would slide the notes sideways on every keypress, and a
	-- window sized to the current row would clip the moment you cycled to a longer note.
	local value_width, widest_row = 0, 0
	for _, setting in ipairs(settings) do
		for _, value in ipairs(setting.option.values) do
			value_width = math.max(value_width, vim.fn.strdisplaywidth(value))
		end
	end
	for _, setting in ipairs(settings) do
		for _, value in ipairs(setting.option.values) do
			local note_text = note(setting, value)
			widest_row = math.max(
				widest_row,
				2
					+ label_width
					+ 2
					+ 2
					+ value_width
					+ 2
					+ (note_text ~= "" and 3 + vim.fn.strdisplaywidth(note_text) or 0)
			)
		end
	end

	local function lines()
		local out, all_highlights = {}, {}
		for i, setting in ipairs(settings) do
			local value = tostring(pending.options[setting.key] or "unset")
			local on_cursor = i == float.cursor
			local note_text = note(setting, value)
			local text, highlights = render({
				{ "  " },
				{ pad(setting.option.label or setting.key, label_width) .. "  ", "DucktapeListKey" },
				-- The arrows mark the row h/l acts on, so cyclability is visible rather than
				-- something the footer has to be read for. They sit tight against the value,
				-- with the padding that lines the notes up placed after them — padding the
				-- value itself would strand the closing arrow a column away from short values,
				-- since the column is as wide as the longest value any of these options takes.
				{ on_cursor and "◂ " or "  ", "DucktapeListDim" },
				{ value, on_cursor and "DucktapeListCurrent" or "DucktapeWinBarModel" },
				{ on_cursor and " ▸" or "  ", "DucktapeListDim" },
				{ string.rep(" ", value_width - vim.fn.strdisplaywidth(value)) },
				{ note_text ~= "" and ("   " .. note_text) or "", "DucktapeListDim" },
			})
			table.insert(out, text)
			table.insert(all_highlights, highlights)
		end
		return out, all_highlights
	end

	local function draw()
		if not (float.buf and api.nvim_buf_is_valid(float.buf)) then
			return
		end
		local text, all_highlights = lines()
		vim.bo[float.buf].modifiable = true
		api.nvim_buf_set_lines(float.buf, 0, -1, false, text)
		vim.bo[float.buf].modifiable = false
		api.nvim_buf_clear_namespace(float.buf, ns, 0, -1)
		for lnum, highlights in ipairs(all_highlights) do
			for _, hl in ipairs(highlights) do
				pcall(api.nvim_buf_set_extmark, float.buf, ns, lnum - 1, hl[1][1], {
					end_col = hl[1][2],
					hl_group = hl[2],
				})
			end
		end
		if float.win and api.nvim_win_is_valid(float.win) then
			pcall(api.nvim_win_set_cursor, float.win, { float.cursor, 0 })
		end
	end

	local width = math.min(math.max(widest_row + 2, 34), vim.o.columns - 4)
	local height = #settings

	float.buf = api.nvim_create_buf(false, true)
	float.win = api.nvim_open_win(float.buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0),
		col = math.max(math.floor((vim.o.columns - width) / 2), 0),
		style = "minimal",
		border = require("ducktape.config").get().ui.border,
		title = (" %s · %s "):format(pending.provider, tostring(pending.model)),
		title_pos = "center",
		-- Named from the bindings, so a remapped panel does not advertise keys that do nothing.
		footer = (" %s/%s cycle · %s/%s move · %s apply · %s discard "):format(
			keys.panel_label("picker", "prev_value"),
			keys.panel_label("picker", "next_value"),
			keys.panel_label("picker", "down"),
			keys.panel_label("picker", "up"),
			keys.panel_label("picker", "apply"),
			keys.panel_label("picker", "discard")
		),
		footer_pos = "center",
	})
	vim.wo[float.win].cursorline = true
	vim.bo[float.buf].modifiable = false

	local function move(delta)
		float.cursor = ((float.cursor - 1 + delta) % #settings) + 1
		draw()
	end

	---Cycle the value under the cursor within the pending copy. Nothing is written until
	---`<CR>`, so a discarded run leaves no trace of the values that were scrolled past.
	local function cycle(delta)
		local setting = settings[float.cursor]
		local values = setting.option.values
		local current_value = pending.options[setting.key]
		if current_value == nil then
			-- Entering the list from "unset" should land on an end of it, not one step past the
			-- first value. There is no way back to unset afterwards, same as the status panel.
			pending.options[setting.key] = delta > 0 and values[1] or values[#values]
		else
			local idx = ((value_index(setting.option, current_value) - 1 + delta) % #values) + 1
			pending.options[setting.key] = values[idx]
		end
		draw()
	end

	local function apply()
		float.committed = true
		close_float()
		commit(scope, pending)
	end

	---Every other way out. The provider and model were never written either, so there is
	---nothing to roll back — saying what is still in force is the whole job.
	local function discard()
		if float.committed then
			return
		end
		float.committed = true -- keeps the WinLeave hook from reporting a second time
		close_float()
		notify_unchanged(scope)
	end

	keys.bind_panel("picker", float.buf, {
		down = function()
			move(1)
		end,
		up = function()
			move(-1)
		end,
		next_value = function()
			cycle(1)
		end,
		prev_value = function()
			cycle(-1)
		end,
		apply = apply,
		discard = discard,
	})

	-- Clicking away counts as leaving without confirming, so it discards like the rest
	api.nvim_create_autocmd("WinLeave", {
		buffer = float.buf,
		once = true,
		callback = function()
			vim.schedule(discard)
		end,
	})

	draw()
end

--=============================================================================
-- Pickers
--=============================================================================

---Choose a scope's provider and model, then confirm through its other options.
---@param scope "inline"|"chat"
function M.open(scope)
	ui.ensure_highlights()

	local providers = require("ducktape.providers")
	-- Cache key → models, holding whatever has arrived so far. Starts at what each provider can
	-- answer without being asked — a persisted list, a sentinel, a static seed — and each entry is
	-- replaced as its query lands.
	local lists = {}
	local picker

	-- Every list is queried, and the picker opens without waiting on any of them: some come off the
	-- network and some out of a subprocess, so blocking until they arrive together would make every
	-- switch feel slow — including switches to a provider that needs neither. Rows appear as each
	-- answers, and all of them are cached for the session.
	--
	-- Driven off the registry, so a provider added through config is queried too. A hardcoded loop
	-- meant its list was never asked for and its rows never appeared.
	for _, target in ipairs(providers.discoverable()) do
		providers.models_async(target.provider, target.endpoint, function(models, err)
			if models and #models > 0 then
				lists[target.key] = models
				if picker then
					picker.refresh()
				end
			end
			if err then
				-- Still usable: `models` falls back to what was already known, so the warning is
				-- about that one list being incomplete rather than the picker being broken.
				ui.say(("[ducktape] %s not listed: %s"):format(target.label, err), vim.log.levels.WARN)
			end
		end)
	end

	picker = require("ducktape.picker").open({
		title = scope == "chat" and "Chat provider & model" or "Inline provider & model",
		results_title = "<CR> continue to options",
		entries = function()
			return build_entries(scope, lists)
		end,
		-- The row is carried forward as a pending selection rather than written now, so abandoning
		-- the options step leaves the old provider and model in place instead of switching to a
		-- model whose options were never confirmed.
		on_select = function(selection)
			local row = selection.value
			open_settings(scope, { provider = row.provider, model = row.model, endpoint = row.endpoint })
		end,
	})
end

return M
