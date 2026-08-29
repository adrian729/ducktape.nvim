-- Pool of independent ACP connections, one session each.
--
-- CodeCompanion's ACP client keeps one `session_id` and `_active_prompt`, dropping messages for
-- other sessions. Concurrency needs processes, not sessions: one warm primary per provider, overflow
-- spawned on demand and reaped when idle.

local ACP = require("codecompanion.acp")
local acp_defaults = require("codecompanion.interactions.chat.acp.defaults")
local adapters = require("codecompanion.adapters")
local async = require("codecompanion.utils.async")
local providers = require("ducktape.providers")
local ui = require("ducktape.ui")

local M = {}

---Providers whose inline-over-ACP path is withheld, and why.
---Set when a write defence could not be verified. Chat, relay, and HTTP still work; this is a
---withheld capability, not a broken provider. Read by `:checkhealth ducktape` and the picker.
---@type table<string, string>
M.withheld = {}

---Pool sizing and lifetimes. Read per call so `opts.pool` changes without restart.
---@return table
local function tuning()
	return require("ducktape.config").get().pool
end

---@type table<string, table[]>
local pools = {}
---@type table<string, function[]>
local queues = {}
local next_id = 0
local reaper = nil

local function now()
	return vim.uv.now()
end

local function notify(msg, level)
	ui.say("[ducktape.pool] " .. msg, level or vim.log.levels.ERROR)
end

---Refuse client-mediated writes on every inline connection.
---Insurance against future agents: neither current agent sends `fs/write_text_file`. The override
---wins because DISPATCH invokes it as a method on the connection. Checked before each spawn so a
---renamed or inlined handler fails loudly instead of failing open.
---@return string|nil error
local function write_guard_available()
	if type(ACP.handle_fs_write_file_request) ~= "function" then
		return "CodeCompanion's ACP client no longer exposes handle_fs_write_file_request — "
			.. "the inline write guard would fail open, so no connection will be started"
	end
end

---Read each option's current value keyed by category.
---@param conn table
---@return table<string, string>
local function current_options(conn)
	local current = {}
	for _, opt in ipairs(conn:get_config_options()) do
		if opt.category then
			current[opt.category] = opt.currentValue
		end
	end
	return current
end

---Set an option by category (stable) rather than by agent-specific option id.
---@param conn table
---@param category string
---@param value string
---@return boolean
local function set_by_category(conn, category, value)
	for _, opt in ipairs(conn:get_config_options()) do
		if opt.category == category and opt.type == "select" then
			if opt.currentValue == value then
				return true -- already there; acp_defaults.apply got it
			end
			local ok, set = pcall(conn.set_config_option, conn, opt.id, value)
			return ok and set ~= false
		end
	end
	return false
end

---Establish and verify the write defence on a fresh inline connection.
---
---`acp_defaults.apply` is best-effort: it warns and gives up when the agent rejects a value, leaving
---claude in its default write-capable mode. Verification reads values back and refuses connections
---that did not take them. Since the mode is the real defence — neither agent uses the client-mediated
---`fs/*` path — verification is what actually keeps writes out.
---
---Providers with no spec requirement derive one from what the agent advertises. When no write-denying
---mode exists, inline is withheld rather than letting an unguarded agent through.
---@param provider string
---@param conn table
---@return string|nil error
local function establish_guard(provider, conn)
	local required, why = providers.derive_guard(provider, conn)
	if not required then
		return ("%s: %s. Inline is withheld for this provider; chat is unaffected. Set "):format(provider, why)
			.. ("providers.%s.guard.required to name one, or guard.unguarded = true to accept the risk."):format(
				provider
			)
	end
	if vim.tbl_isempty(required) then
		-- `guard.unguarded = true` or opted-out deriving: say once per connection because this is the
		-- one path where an agent keeps its write tools.
		if providers.effective_guard(provider).unguarded then
			notify(
				("%s runs inline with no write defence (guard.unguarded = true)"):format(provider),
				vim.log.levels.WARN
			)
		end
		return nil
	end

	-- Push anything the adapter defaults missed. A derived requirement cannot be in those defaults
	-- because it is only knowable once the agent answers.
	local current = current_options(conn)
	for category, want in pairs(required) do
		if current[category] ~= want then
			set_by_category(conn, category, want)
		end
	end

	current = current_options(conn)
	for category, want in pairs(required) do
		if current[category] ~= want then
			return ("%s: the session did not accept %s=%s (it reports %s), so writes would not be "):format(
				provider,
				category,
				want,
				tostring(current[category])
			) .. "denied — refusing to use this connection"
		end
	end
end

---@param conn table
local function install_write_guard(conn)
	conn.handle_fs_write_file_request = function(self, id, params)
		local path = type(params) == "table" and params.path or "?"
		notify(("refused an agent write to %s"):format(path), vim.log.levels.WARN)
		if id then
			self:send_error(id, "fs/write_text_file is refused by this client")
		end
	end
end

local function teardown(entry)
	entry.state = "dead"
	if entry.conn then
		-- kill(9) on an exited process is a no-op; the throw only happens when spawn failed before
		-- a process started. Worth the pcall for that case.
		pcall(function()
			entry.conn:disconnect()
		end)
	end
	entry.conn = nil
end

local function drop(entry)
	local pool = pools[entry.provider] or {}
	for i, e in ipairs(pool) do
		if e == entry then
			table.remove(pool, i)
			break
		end
	end
	teardown(entry)
end

local pump -- forward declaration for the process-exit hook

---Handle an agent process exit. Drop the connection and fail only its own request; neighbours are
---unaffected because each connection holds one session.
---@param entry table
local function on_process_exit(entry)
	if entry.reaped then
		return
	end
	entry.reaped = true
	drop(entry)
	local died = entry.death_cb
	entry.death_cb = nil
	if died then
		died()
	end
	pump(entry.provider)
end

---@param provider string
---@param cb fun(entry: table|nil, err: string|nil)
local function spawn(provider, cb)
	local adapter_name = providers.acp_adapter(provider)
	if not adapter_name then
		return cb(nil, ("provider %s has no ACP adapter"):format(provider))
	end

	local guard_err = write_guard_available()
	if guard_err then
		return cb(nil, guard_err)
	end

	local pool = pools[provider]
	next_id = next_id + 1
	local entry = {
		id = next_id,
		provider = provider,
		primary = #pool == 0,
		busy = true,
		state = "spawning",
		created = now(),
		last_used = now(),
	}
	table.insert(pool, entry)

	-- Bound setup: in a coroutine send_rpc_request has no timeout, so an agent that answers
	-- initialize then goes quiet suspends this body forever. The suspended entry stays `busy` and
	-- `spawning`, so neither the reaper nor the watchdog can clean it up, consuming the provider cap.
	-- Killing the process routes it through the crash death path, freeing the slot and pumping the queue.
	local function disarm()
		local timer = entry.spawn_timer
		entry.spawn_timer = nil
		if timer and not timer:is_closing() then
			timer:stop()
			timer:close()
		end
	end
	entry.spawn_timer = vim.defer_fn(function()
		entry.spawn_timer = nil -- defer_fn closes its own timer before calling back
		if entry.state == "spawning" then
			on_process_exit(entry)
		end
	end, tuning().timeout_ms)

	-- Disarm on every setup exit so success and failure paths do not each thread a call.
	local report = cb
	cb = function(entry_or_nil, err)
		disarm()
		return report(entry_or_nil, err)
	end

	-- resolve() merges session_config_options into adapter.defaults, where acp_defaults.apply reads them.
	local adapter = adapters.resolve(adapter_name, {
		session_config_options = providers.inline_session_options(provider),
	})

	-- Per-spawn adapter exit hook. prepare_adapter deepcopies the adapter, keeping this closure.
	adapter.handlers.on_exit = function()
		-- Flagged synchronously so the completion path can distinguish a dead process from a real
		-- cancel: handle_process_exit also fires _active_prompt:handle_done("canceled").
		entry.exited = true
		vim.schedule(function()
			on_process_exit(entry)
		end)
	end

	-- Run setup in a coroutine: outside one, send_rpc_request busy-waits up to 90s.
	async.sync(function()
		local conn = ACP.new({ adapter = adapter })
		install_write_guard(conn)
		entry.conn = conn

		if not conn:connect_and_authenticate() then
			drop(entry)
			pump(provider)
			return cb(nil, ("%s: failed to start the agent process"):format(provider))
		end
		if not conn:ensure_session() then
			drop(entry)
			pump(provider)
			return cb(nil, ("%s: failed to create a session"):format(provider))
		end

		acp_defaults.apply(adapter, conn)

		local unmet = establish_guard(provider, conn)
		if unmet then
			-- Remember so surfaces can say inline is unavailable without another spawn.
			M.withheld[provider] = unmet
			drop(entry)
			pump(provider)
			return cb(nil, unmet)
		end
		M.withheld[provider] = nil

		-- The live session knows its own model list and is the only source for `live_session` providers.
		providers.enrich_from_session(provider, conn)

		-- on_process_exit may have already dropped the entry; do not hand back a corpse.
		if entry.state == "dead" then
			return cb(nil, ("%s: the agent process exited during setup"):format(provider))
		end

		entry.state = "ready"
		entry.session_id = conn.session_id
		entry.ready_at = now()
		cb(entry)
	end)(function() end)
end

function pump(provider)
	local queue = queues[provider]
	if not queue or #queue == 0 then
		return
	end

	local pool = pools[provider] or {}
	for _, entry in ipairs(pool) do
		if entry.state == "ready" and not entry.busy then
			entry.busy = true
			local waiter = table.remove(queue, 1)
			return waiter(entry)
		end
	end

	-- Cap may have room again after entries died while queued; without this the waiter burns its
	-- deadline with no way to spawn.
	if pools[provider] and #pool < tuning().cap then
		local waiter = table.remove(queue, 1)
		return spawn(provider, waiter)
	end
end

local function release(entry)
	entry.busy = false
	entry.last_used = now()
	pump(entry.provider)
end

---@param provider string
---@param cb fun(entry: table|nil, err: string|nil)
local function acquire(provider, cb)
	pools[provider] = pools[provider] or {}
	queues[provider] = queues[provider] or {}
	M.start_reaper()

	for _, entry in ipairs(pools[provider]) do
		if entry.state == "ready" and not entry.busy then
			entry.busy = true
			return cb(entry)
		end
	end

	if #pools[provider] < tuning().cap then
		return spawn(provider, cb)
	end

	table.insert(queues[provider], cb)
end

function M.start_reaper()
	if reaper then
		return
	end
	reaper = vim.uv.new_timer()
	reaper:start(
		tuning().reap_interval_ms,
		tuning().reap_interval_ms,
		vim.schedule_wrap(function()
			local live = 0
			for _, pool in pairs(pools) do
				for i = #pool, 1, -1 do
					local entry = pool[i]
					local idle = now() - entry.last_used
					local limit = entry.primary and tuning().idle_primary_ms or tuning().idle_overflow_ms
					if not entry.busy and entry.state == "ready" and idle > limit then
						table.remove(pool, i)
						teardown(entry)
					else
						live = live + 1
					end
				end
			end
			if live == 0 then
				M.stop_reaper()
			end
		end)
	)
end

function M.stop_reaper()
	if not reaper then
		return
	end
	reaper:stop()
	if not reaper:is_closing() then
		reaper:close()
	end
	reaper = nil
end

---Tear the whole pool down. Uses our own augroup; the plugin's per-connection VimLeavePre group is
---not ours to remove.
function M.shutdown()
	for _, pool in pairs(pools) do
		for i = #pool, 1, -1 do
			teardown(table.remove(pool, i))
		end
	end
	queues = {}
	M.stop_reaper()
end

---Tear down every connection for a provider, e.g. when the model changes.
---@param provider string
function M.drain_provider(provider)
	local pool = pools[provider]
	if pool then
		for i = #pool, 1, -1 do
			teardown(table.remove(pool, i))
		end
	end
	-- Fail queued waiters so they do not hang.
	local q = queues[provider]
	queues[provider] = nil
	if q then
		for _, cb in ipairs(q) do
			vim.schedule(function()
				cb(nil, "pool was drained — the model changed")
			end)
		end
	end
end

vim.api.nvim_create_autocmd("VimLeavePre", {
	group = vim.api.nvim_create_augroup("DucktapeAcpPool", { clear = true }),
	callback = function()
		M.shutdown()
	end,
})

---Send a prompt through the pool.
---@param opts { provider: string, prompt: string, timeout?: number, on_chunk?: fun(text: string), on_tool?: fun(name: string), on_done: fun(text: string), on_error: fun(msg: string) }
---@return table handle Handle with `cancel`
function M.send(opts)
	local handle = { cancelled = false, finished = false }
	local chunks = {}
	local tools = {}
	local entry

	-- Defer off the caller's stack. PromptBuilder:handle_done() calls the completion handler before
	-- clearing _active_prompt, so an inline next-prompt or release would null it out and drop updates.
	local function finish(fn, arg)
		if handle.finished then
			return
		end
		handle.finished = true
		vim.schedule(function()
			if entry then
				local dead = entry.state == "dead"
				entry.death_cb = nil
				-- Cancelled prompts must not return to the pool. PromptBuilder:cancel() clears
				-- _active_prompt synchronously and the client routes later session/updates to whatever
				-- _active_prompt is current then, so a cancelled turn's trailing chunks would land in the
				-- next request. Respawning is the cheaper mistake.
				if handle.poisoned and not dead then
					drop(entry)
					pump(entry.provider)
				elseif not dead then
					release(entry)
				end
				entry = nil
			end
			if not handle.cancelled then
				fn(arg)
			end
		end)
	end

	local function fail(msg)
		finish(opts.on_error, msg)
	end

	-- Deadline covers the whole request, including spawning, so a wedged agent cannot hang forever.
	-- It resets once the prompt is on the wire so queue time does not eat the reply budget.
	local timeout = opts.timeout or tuning().timeout_ms
	handle.deadline = now() + timeout
	handle.stage = "connecting"

	local function arm_watchdog(after)
		vim.defer_fn(function()
			if handle.finished then
				return
			end
			local remaining = handle.deadline - now()
			if remaining > 0 then
				return arm_watchdog(remaining)
			end
			if handle.builder then
				handle.poisoned = true
				pcall(function()
					handle.builder:cancel()
				end)
			end
			fail(
				handle.stage == "connecting"
						and ("%s: no usable connection within %ds"):format(opts.provider, timeout / 1000)
					or ("%s: no reply within %ds"):format(opts.provider, timeout / 1000)
			)
		end, after)
	end
	arm_watchdog(timeout)

	acquire(opts.provider, function(acquired, err)
		if err or not acquired then
			return fail(err or "could not acquire a connection")
		end
		-- Cancelled or timed out while queued: hand the connection back. Without this the waiter
		-- sends the prompt anyway, finish returns early, and the connection is leaked until restart.
		if handle.finished then
			release(acquired)
			return
		end

		entry = acquired
		entry.last_used = now()
		entry.prompt = opts.prompt
		entry.death_cb = function()
			fail(("%s: the agent process exited mid-request"):format(opts.provider))
		end

		local ok, builder = pcall(function()
			return acquired.conn:session_prompt({ { role = "user", content = opts.prompt, _meta = {} } })
		end)
		if not ok or not builder then
			drop(acquired)
			pump(acquired.provider)
			entry = nil
			return fail(("%s: could not build the prompt (%s)"):format(opts.provider, tostring(builder)))
		end

		builder
			:on_message_chunk(function(text)
				table.insert(chunks, text)
				if opts.on_chunk then
					opts.on_chunk(text)
				end
			end)
			:on_tool_call(function(tool)
				local name = type(tool) == "table" and (tool.title or tool.kind or tool.toolCallId) or tostring(tool)
				table.insert(tools, name)
				if opts.on_tool then
					opts.on_tool(name)
				end
			end)
			:on_error(function(msg)
				fail(("%s: %s"):format(opts.provider, tostring(msg)))
			end)
			:on_complete(function(stop_reason)
				if stop_reason == "canceled" then
					if acquired.exited then
						return fail(("%s: the agent process exited mid-request"):format(opts.provider))
					end
					return finish(opts.on_error, "cancelled")
				end
				finish(opts.on_done, table.concat(chunks))
			end)
			:with_options({ silent = true })

		handle.builder = builder
		handle.tools = tools
		-- Reset the deadline for the reply. Also bounds the case where a permission request arrives
		-- with no active prompt and is dropped, leaving the agent waiting forever.
		handle.stage = "prompting"
		handle.deadline = now() + timeout
		builder:send()
	end)

	function handle.cancel()
		if handle.finished then
			return
		end
		handle.cancelled = true
		if handle.builder then
			-- Poison the connection: a prompt on the wire keeps arriving after session/cancel with no
			-- turn id to match it.
			handle.poisoned = true
			pcall(function()
				handle.builder:cancel()
			end)
		end
		finish(function() end)
	end

	return handle
end

---@return table[] One row per live connection
function M.status()
	local rows = {}
	for provider, pool in pairs(pools) do
		for _, entry in ipairs(pool) do
			table.insert(rows, {
				provider = provider,
				id = entry.id,
				state = entry.state,
				session_id = entry.session_id,
				pid = entry.conn and entry.conn._state and entry.conn._state.handle and entry.conn._state.handle.pid,
				primary = entry.primary,
				busy = entry.busy,
				age_ms = now() - entry.created,
				idle_ms = entry.busy and 0 or (now() - entry.last_used),
				queued = #(queues[provider] or {}),
			})
		end
	end
	table.sort(rows, function(a, b)
		return a.id < b.id
	end)
	return rows
end

---@return table<string, number>
function M.queue_depths()
	local out = {}
	for provider, queue in pairs(queues) do
		out[provider] = #queue
	end
	return out
end

return M
