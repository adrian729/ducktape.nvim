-- Provider/model chooser behind `<leader>cmi` and `<leader>cmc`. One flat list of every
-- provider/model pair, then the provider's other options. Nothing reaches `ducktape.providers`
-- until `<CR>`, so backing out leaves everything as it was.

local M = {}

local api = vim.api

local ui = require("ducktape.ui")
local keys = require("ducktape.keys")
local render = ui.render
local pad = ui.pad

---Every provider/model pair selectable right now. Endpoint providers contribute one row per
-- endpoint per model.
---@param scope "inline"|"chat"
---@param lists table<string, string[]>
---@return table[]
local function build_entries(scope, lists)
	local providers = require("ducktape.providers")
	local withheld = require("ducktape.acp_pool").withheld
	local current = providers.current(scope)

	local rows = {}
	---@param model string|nil
	local function add(provider, model, endpoint)
		local is_current = provider == current.provider
			and model == current.opts.model
			and endpoint == current.opts.endpoint
		local tier = providers.model_tier(provider, model, endpoint)
		table.insert(rows, {
			provider = provider,
			model = model,
			endpoint = endpoint,
			is_current = is_current,
			tier = tier and tier.label or nil,
			free = tier and tier.free or false,
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
		-- Show a provider with no list yet so it is not invisible; committing it routes to
		-- `:Ducktape models`.
		if not contributed then
			add(provider, nil, providers.endpoint_names(provider)[1])
		end
	end

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
			{ row.tier and ("   " .. row.tier) or "", row.free and "DucktapeListDim" or "DucktapeListStarting" },
			{ row.unavailable and ("   " .. row.unavailable) or "", "DucktapeListDead" },
			{ row.is_current and "   current" or "", "DucktapeListCurrent" },
		})
		table.insert(entries, {
			value = row,
			ordinal = ("%s %s %s"):format(row.name, row.model or "", row.tier or ""),
			text = text,
			highlights = highlights,
		})
	end

	-- Hoist the current selection to the top so it sits under the prompt.
	for i, entry in ipairs(entries) do
		if entry.value.is_current then
			table.insert(entries, 1, table.remove(entries, i))
			break
		end
	end
	return entries
end

---@param scope "inline"|"chat"
---@return table[]
function M._entries_for_test(scope)
	return build_entries(scope, {})
end

---Other options worth offering for a provider once its model is settled. `model` and `endpoint`
-- are excluded; dynamic options with no enumerable values (e.g. claude's `agent`) belong in the
-- status panel.
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

---Caveat for a value where the name is misleading or the cost is high.
---@param provider string
---@param key string
---@param value string
---@return string
local function note_for(provider, key, value)
	local spec = require("ducktape.providers").spec(provider) or {}
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
---@param scope "inline"|"chat"
---@param pending { provider: string, model: string, endpoint: string|nil, options: table<string, string>|nil }
local function commit(scope, pending)
	local providers = require("ducktape.providers")
	if pending.model == nil then
		return ui.say(
			("[ducktape] no models known for %s yet — :Ducktape models asks every provider what it can reach"):format(
				pending.provider
			),
			vim.log.levels.WARN
		)
	end
	providers.set_provider(scope, pending.provider)
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

local function value_index(option, value)
	for i, candidate in ipairs(option.values) do
		if candidate == value then
			return i
		end
	end
	return 1
end

---Confirm a pending provider/model through its other options. Held here and only written on
-- `<CR>`, so leaving another way keeps the previous selection.
---@param scope "inline"|"chat"
---@param pending { provider: string, model: string, endpoint: string|nil, options: table|nil }
local function open_settings(scope, pending)
	local providers = require("ducktape.providers")
	local settings = settings_for(scope, pending.provider)

	if #settings == 0 then
		return commit(scope, pending)
	end

	-- Seed from the provider's stored options; leave absent values unset rather than defaulting
	-- them (e.g. claude's `fast` would silently turn on for every switch).
	pending.options = {}
	local stored = providers.opts_for(scope, pending.provider) or {}
	for _, setting in ipairs(settings) do
		pending.options[setting.key] = stored[setting.key]
	end

	ui.ensure_highlights()
	close_float()
	float.cursor = 1
	float.committed = false

	local ns = api.nvim_create_namespace("DucktapePickSettings")
	local label_width = 0
	for _, setting in ipairs(settings) do
		label_width = math.max(label_width, vim.fn.strdisplaywidth(setting.option.label or setting.key))
	end

	local function note(setting, value)
		return note_for(pending.provider, setting.key, value)
	end

	-- Size columns from every possible value so cycling does not slide notes or clip rows.
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

	local function cycle(delta)
		local setting = settings[float.cursor]
		local values = setting.option.values
		local current_value = pending.options[setting.key]
		if current_value == nil then
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

	local function discard()
		if float.committed then
			return
		end
		float.committed = true
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

	api.nvim_create_autocmd("WinLeave", {
		buffer = float.buf,
		once = true,
		callback = function()
			vim.schedule(discard)
		end,
	})

	draw()
end

---@param scope "inline"|"chat"
function M.open(scope)
	ui.ensure_highlights()

	local providers = require("ducktape.providers")
	local lists = {}
	local picker

	-- Query every discoverable list and open without waiting. Rows fill in as answers arrive.
	for _, target in ipairs(providers.discoverable()) do
		providers.models_async(target.provider, target.endpoint, function(models, err)
			if models and #models > 0 then
				lists[target.key] = models
				if picker then
					picker.refresh()
				end
			end
			if err then
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
		on_select = function(selection)
			local row = selection.value
			open_settings(scope, { provider = row.provider, model = row.model, endpoint = row.endpoint })
		end,
	})
end

return M
