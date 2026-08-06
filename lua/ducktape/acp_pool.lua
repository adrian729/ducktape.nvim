-- A pool of independent ACP connections, one session each.
--
-- CodeCompanion's ACP client holds `session_id` as a scalar and `_active_prompt` as a single
-- slot, and drops every message whose sessionId isn't the active one. So concurrency cannot be
-- sessions on one process; it has to be processes. This module owns that: one warm primary per
-- provider, overflow spawned on demand and reaped when idle.

local ACP = require("codecompanion.acp")
local acp_defaults = require("codecompanion.interactions.chat.acp.defaults")
local adapters = require("codecompanion.adapters")
local async = require("codecompanion.utils.async")
local providers = require("ducktape.providers")
local ui = require("ducktape.ui")

local M = {}

---Providers whose inline-over-ACP path is withheld, and why.
---
---Set when a connection could not be given a verified write defence. Nothing else about the
---provider is affected — chat still works, and so does a relay or HTTP transport if it has one —
---so this is a withheld capability rather than a broken provider. `:checkhealth ducktape` reads it,
---and so does the model picker, which is where a user would otherwise pick it and wonder.
---@type table<string, string>
M.withheld = {}

---Pool sizing and lifetimes. Read per call rather than latched, so `opts.pool` lands without a
---restart and a provider with a lighter footprint than opencode's ~536 MB idle can be given room.
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

--=============================================================================
-- Connection lifecycle
--=============================================================================

---Refuse client-mediated writes on every inline connection.
---
---Nothing exercises this path today — neither agent ever sends `fs/write_text_file` — so this
---is insurance against a future version or a third agent, not the thing keeping us safe. It
---works because DISPATCH invokes the handler as a method on the connection, so an
---instance-level override wins. It fails open if upstream ever inlines the write logic into
---DISPATCH, hence the assertion rather than a silent no-op.
---Checked before every spawn rather than assumed: if upstream renames or inlines the handler
---the override silently stops working, so fail loudly rather than fail open.
---@return string|nil error
local function write_guard_available()
	if type(ACP.handle_fs_write_file_request) ~= "function" then
		return "CodeCompanion's ACP client no longer exposes handle_fs_write_file_request — "
			.. "the inline write guard would fail open, so no connection will be started"
	end
end

---What a live session currently reports for each option category.
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

---Set an option by its category, which is what a guard is written in terms of.
---
---`set_config_option` wants the agent's own option *id*, and only the live session knows what that
---is — the category is the stable name across agents, the id is not.
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
---Two halves, and only the second is enforcement:
---
---  request  `acp_defaults.apply` has already pushed whatever the adapter asked for, but it is
---           best-effort — it gives up with a `log:warn` when the agent advertised no configOptions
---           or when the value is not one it offers. On claude that silently leaves the session in
---           its default, write-capable mode with only a line in codecompanion.log to show it.
---  verify   the values are read back off the live session, and a connection that did not take
---           them is refused. Since the mode *is* the defence — neither shipped agent uses the
---           client-mediated `fs/*` path, so the write guard above covers nothing in practice —
---           this is the part that actually keeps writes out.
---
---A provider whose spec names no requirement has one *derived* from what the agent itself
---advertises, so a provider nobody has ever heard of is guarded without any configuration. When no
---write-denying mode exists at all, this refuses — and the caller withholds inline for that
---provider rather than failing setup or letting an unguarded agent through.
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
		-- `guard.unguarded = true`, or a spec that opted out of deriving. Said once per connection
		-- rather than silently, because this is the one path where an agent keeps its write tools.
		if providers.effective_guard(provider).unguarded then
			notify(
				("%s runs inline with no write defence (guard.unguarded = true)"):format(provider),
				vim.log.levels.WARN
			)
		end
		return nil
	end

	-- Push anything the adapter's own defaults did not land. A derived requirement is not in those
	-- defaults at all — it could not be, since it is only knowable once the agent has answered.
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
		-- disconnect() is `assert(self._state.handle):kill(9)`. kill(9) on a process that has
		-- already exited is a no-op, so the throw only happens when no process was ever started —
		-- a spawn that failed at connect_and_authenticate. Worth the pcall for that one case.
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

---Declared before spawn() so the process-exit hook can reach it.
local pump

---The agent process went away — because it crashed, or because someone killed it. Take the
---connection out of service and fail only the request that was riding on it; the whole point
---of one session per connection is that its neighbours are unaffected.
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

	-- Bound the setup below. Inside a coroutine send_rpc_request has no timeout of its own, so an
	-- agent that starts, answers `initialize` and then goes quiet suspends this body forever — and
	-- a suspended body means an entry that stays `busy` and `spawning`: the reaper only considers
	-- `ready` entries, and a request's watchdog can only clean up an entry that was handed to it.
	-- Three of those and the provider's cap is gone for the rest of the session. Killing the
	-- process routes the entry through the same death path as a crash, which frees the slot and
	-- pumps the queue.
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

	-- Every exit from the setup body reports through cb, so disarming here covers success and
	-- failure alike without threading a call into each branch.
	local report = cb
	cb = function(entry_or_nil, err)
		disarm()
		return report(entry_or_nil, err)
	end

	-- resolve() merges session_config_options into adapter.defaults itself
	-- (adapters/acp/init.lua:126), which is where acp_defaults.apply reads them from.
	local adapter = adapters.resolve(adapter_name, {
		session_config_options = providers.inline_session_options(provider),
	})

	-- The adapter's own public exit hook, on a per-spawn copy of the adapter. prepare_adapter
	-- deepcopies it, and deepcopy keeps function references, so this closure survives.
	adapter.handlers.on_exit = function()
		-- Flagged synchronously so the completion path can tell a dead process from a real
		-- cancel: handle_process_exit calls this hook first, but then also fires
		-- _active_prompt:handle_done("canceled"), which would otherwise be the story we tell.
		entry.exited = true
		vim.schedule(function()
			on_process_exit(entry)
		end)
	end

	-- All connection and session setup must run inside a coroutine: outside one,
	-- send_rpc_request falls back to a vim.wait busy-loop up to the 90s timeout.
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
			-- Remembered so the surfaces can say inline is unavailable for this provider before the
			-- user pays for another spawn to be told the same thing.
			M.withheld[provider] = unmet
			drop(entry)
			pump(provider)
			return cb(nil, unmet)
		end
		M.withheld[provider] = nil

		-- The agent knows its own model list, including anything released since this spec was
		-- written. Free to take now that a session exists, and the only source for a provider whose
		-- models strategy is `live_session`.
		providers.enrich_from_session(provider, conn)

		-- The process can die at any point above; on_process_exit has already dropped the entry
		-- and reported it, so do not hand a corpse back as ready.
		if entry.state == "dead" then
			return cb(nil, ("%s: the agent process exited during setup"):format(provider))
		end

		entry.state = "ready"
		entry.session_id = conn.session_id
		entry.ready_at = now()
		cb(entry)
	end)(function() end)
end

--=============================================================================
-- Acquire / release
--=============================================================================

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

	-- Nothing to reuse, but the cap may have room again — every entry for this provider can die
	-- or be dropped while a request is queued, and without this the waiter has no way to ask for
	-- a fresh process and just burns its whole deadline in the queue.
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

--=============================================================================
-- Idle reaping
--=============================================================================

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

---Tear the whole pool down. Uses our own augroup: the plugin registers a VimLeavePre autocmd
---per connection in a group it never clears, and those are not ours to remove.
function M.shutdown()
	for _, pool in pairs(pools) do
		for i = #pool, 1, -1 do
			teardown(table.remove(pool, i))
		end
	end
	queues = {}
	M.stop_reaper()
end

---Tear down every connection for a provider. Used when the model changes, so the
---next request gets a fresh process with the new model.
---@param provider string
function M.drain_provider(provider)
	local pool = pools[provider]
	if pool then
		for i = #pool, 1, -1 do
			teardown(table.remove(pool, i))
		end
	end
	-- Fire queued waiters so they don't hang forever without an error
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

--=============================================================================
-- Sending
--=============================================================================

---Send a prompt through the pool.
---@param opts { provider: string, prompt: string, timeout?: number, on_chunk?: fun(text: string), on_tool?: fun(name: string), on_done: fun(text: string), on_error: fun(msg: string) }
---@return table handle A handle with a `cancel` method
function M.send(opts)
	local handle = { cancelled = false, finished = false }
	local chunks = {}
	local tools = {}
	local entry

	-- Deferred out of the caller's stack on purpose. PromptBuilder:handle_done() invokes the
	-- completion handler and only *then* clears connection._active_prompt, so a callback that
	-- starts the next prompt inline would have that new prompt nulled out from under it and
	-- every subsequent session/update dropped. Releasing the connection here has the same
	-- hazard, since it can pump a queued request.
	local function finish(fn, arg)
		if handle.finished then
			return
		end
		handle.finished = true
		vim.schedule(function()
			if entry then
				local dead = entry.state == "dead"
				entry.death_cb = nil
				-- A connection whose prompt we cancelled must not go back into the pool.
				-- PromptBuilder:cancel() sends session/cancel and clears _active_prompt
				-- synchronously without waiting for the agent, and the client routes later
				-- session/updates to whatever _active_prompt happens to be by then — so the
				-- cancelled turn's trailing chunks would be appended to the *next* request's
				-- reply and applied to the buffer. Paying a respawn is the cheaper mistake.
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

	-- One deadline covering the whole request, armed before the connection exists. Spawning is
	-- inside it deliberately: a stale or wedged agent can accept `initialize` and then never
	-- answer `session/new`, which without this bound is an unreported hang forever. The deadline
	-- is pushed out again once the prompt actually goes on the wire, so time spent queued behind
	-- other requests does not eat into the reply's own budget.
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
		-- Already resolved before a connection came free: cancelled, or timed out while still in
		-- the queue. Hand the connection straight back — without this the waiter went on to send
		-- the prompt anyway, and because `finished` was already set, `finish` returned early and
		-- never released it. Three of those and the provider's cap is gone until nvim restarts.
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
		-- The reply gets the full budget from here, and the watchdog re-arms itself to match.
		-- It also bounds the case where a permission request arrives with no active prompt and
		-- is dropped without any reply, leaving the agent waiting forever on an idle-looking
		-- connection.
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
			-- Poisons the connection: see finish(). A prompt already on the wire keeps arriving
			-- after session/cancel, and there is no turn id to match it against.
			handle.poisoned = true
			pcall(function()
				handle.builder:cancel()
			end)
		end
		finish(function() end)
	end

	return handle
end

--=============================================================================
-- Introspection
--=============================================================================

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
