-- Smoke harness for the connection pool.
--
-- This is the seam where a transport problem is distinguishable from a parsing or placement
-- problem: :Ducktape send does no parsing, no placement and no buffer mutation. It is the first
-- thing to reach for when something downstream misbehaves.

local providers = require("ducktape.providers")
local ui = require("ducktape.ui")

local M = {}

---Required lazily, not at the top of the file. `setup()` runs from the plugin's own `config()`,
---and the pool's first statement is `require("codecompanion.acp")` — which, reached from a cold
---`require("ducktape.acp_pool")`, makes lazy.nvim load the plugin, run `config()`, and come straight
---back here into a module that is still loading. Deferring the require breaks that cycle and is
---what lets the pool be loaded on its own, which is exactly what debugging it starts with.
local function pool()
	return require("ducktape.acp_pool")
end

---@param lines string[]
---@param title string
local function scratch(lines, title)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = false

	local width = math.min(vim.o.columns - 8, 100)
	local height = math.min(vim.o.lines - 6, math.max(#lines + 1, 5))
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " " .. title .. " ",
		title_pos = "center",
	})
	vim.wo[win].wrap = true
	vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf })
	vim.keymap.set("n", "<esc>", "<cmd>close<cr>", { buffer = buf })
	return buf
end

local function secs(ms)
	return ("%.1fs"):format(ms / 1000)
end

function M.pool_status()
	local rows = pool().status()
	local lines = {}

	if #rows == 0 then
		lines = { "No live connections." }
	else
		for _, r in ipairs(rows) do
			table.insert(
				lines,
				("%-9s #%d %-8s %-10s age %-7s idle %-7s %s%s"):format(
					r.provider,
					r.id,
					r.primary and "primary" or "overflow",
					r.state,
					secs(r.age_ms),
					secs(r.idle_ms),
					r.busy and "BUSY" or "idle",
					r.session_id and ("  " .. r.session_id:sub(1, 12)) or ""
				)
			)
		end
	end

	local queued = {}
	for provider, depth in pairs(pool().queue_depths()) do
		if depth > 0 then
			table.insert(queued, ("%s: %d"):format(provider, depth))
		end
	end
	table.insert(lines, "")
	table.insert(lines, "queued — " .. (#queued > 0 and table.concat(queued, ", ") or "nothing"))

	scratch(lines, "AI pool")
end

---@param provider string
---@param prompt string
function M.send(provider, prompt)
	if not providers.providers[provider] then
		return ui.say(
			("unknown provider %q — try %s"):format(provider, table.concat(vim.tbl_keys(providers.providers), ", ")),
			vim.log.levels.ERROR
		)
	end
	if not providers.acp_adapter(provider) then
		return ui.say(("%s has no ACP transport — nothing for the pool to do"):format(provider), vim.log.levels.WARN)
	end

	local started = vim.uv.now()
	ui.say(("[ducktape] sending to %s…"):format(provider))

	pool().send({
		provider = provider,
		prompt = prompt,
		on_done = function(text)
			local header = {
				("provider  %s"):format(provider),
				("elapsed   %s"):format(secs(vim.uv.now() - started)),
				("prompt    %s"):format(prompt),
				string.rep("─", 40),
			}
			local lines = vim.list_extend(header, vim.split(text, "\n", { plain = true }))
			scratch(lines, "DucktapeDebugSend")
		end,
		on_error = function(msg)
			ui.say(
				("[ducktape] %s failed after %s: %s"):format(provider, secs(vim.uv.now() - started), msg),
				vim.log.levels.ERROR
			)
		end,
	})
end

---`:Ducktape send {provider} {prompt}`. The command itself lives in plugin/ducktape.lua, which
---registers it without loading this module; this is only the argument handling.
---@param args string[] Everything after the subcommand
function M.send_command(args)
	local provider = args[1]
	local prompt = table.concat(vim.list_slice(args, 2), " ")
	if not provider or prompt == "" then
		return ui.say("usage: :Ducktape send {provider} {prompt}", vim.log.levels.ERROR)
	end
	M.send(provider, prompt)
end

---`:Ducktape models`. Throws away everything known about which models exist and asks every provider
---again, then says what came back.
---
---The only thing that picks up a model added since the lists were last discovered — a newly pulled
---ollama model, a subscription that started, an `opencode auth login` — since the lists are
---otherwise read from disk and never expire.
function M.refresh_models()
	local providers = require("ducktape.providers")
	providers.forget_models()
	ui.say("[ducktape] asking every provider what it can reach…")

	local pending, found = 3, {}
	local function done(label, models, err)
		if models then
			found[label] = #models
		elseif err then
			ui.say(("[ducktape] %s: %s"):format(label, err), vim.log.levels.WARN)
		end
		pending = pending - 1
		if pending > 0 then
			return
		end
		local parts = {}
		for _, label in ipairs({ "opencode", "ollama cloud", "ollama local" }) do
			if found[label] then
				table.insert(parts, ("%s %d"):format(label, found[label]))
			end
		end
		if #parts == 0 then
			return ui.say("[ducktape] no provider answered — nothing was written", vim.log.levels.WARN)
		end
		ui.say(
			("[ducktape] models: %s — written to %s"):format(
				table.concat(parts, " · "),
				vim.fn.fnamemodify(require("ducktape.model_cache").path(), ":~")
			)
		)
	end

	providers.opencode_models_async(function(models, err)
		done("opencode", models, err)
	end)
	for _, endpoint in ipairs({ "cloud", "local" }) do
		providers.ollama_models(endpoint, function(models, err)
			done("ollama " .. endpoint, models, err)
		end)
	end
end

-- Nothing to register any more: every entry point is a subcommand of `:Ducktape`. Kept as a no-op
-- so the setup sequence reads the same for every module it initialises.
function M.setup() end

return M
