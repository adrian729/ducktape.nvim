-- An HTTP provider, through codecompanion's own client. Structurally tool-free: no tool plumbing
-- exists on this path, so the text-only contract is guaranteed rather than merely asked for.
--
-- Which adapter is resolved comes from the provider spec — including its endpoint, where it has
-- one — so this serves any HTTP provider, not just the one that shipped first.

local adapters = require("codecompanion.adapters")
local client = require("codecompanion.http")
local providers = require("ducktape.providers")

local M = {}

---@param ctx { prompt: string, bufnr: number, provider?: string, timeout?: number }
---@param cb { on_done: fun(text: string), on_error: fun(msg: string) }
---@return table handle
function M.send(ctx, cb)
	local name = providers.http_adapter("inline")
	if not name then
		cb.on_error(("%s has no HTTP adapter"):format(tostring(ctx.provider)))
		return { cancel = function() end }
	end
	local ok, adapter = pcall(adapters.resolve, name)
	if not ok or not adapter then
		cb.on_error(("could not resolve the %s adapter (%s)"):format(name, tostring(adapter)))
		return { cancel = function() end }
	end

	-- Inline needs one complete reply, not a stream of chunks to reassemble. The ollama adapter's
	-- own setup() handler reads opts.stream and mirrors it into parameters.stream, so setting it
	-- here is enough.
	adapter.opts.stream = false
	-- Must run before the request: setup() assigns into adapter.parameters, and this is what
	-- creates that table — along with model, think, num_ctx and keep_alive from the schema.
	adapter:map_schema_to_params()

	local timeout = ctx.timeout or require("ducktape.config").get().inline.timeout_ms
	local job, watchdog

	-- The client invokes this callback twice on an HTTP error: once with the 4xx body as though
	-- it were a reply, then again with an error table. Settle on the first one that decides.
	local settled = false
	local function done(fn, arg)
		if settled then
			return
		end
		settled = true
		if watchdog then
			watchdog:stop()
			watchdog = nil
		end
		fn(arg)
	end

	---Body text of an error response, which providers use to explain themselves
	---@param data table|nil
	---@return string
	local function error_detail(data)
		local body = type(data) == "table" and data.body or nil
		if type(body) ~= "string" or body == "" then
			return ""
		end
		local ok, json = pcall(vim.json.decode, body)
		if ok and type(json) == "table" and type(json.error) == "string" then
			return json.error
		end
		return vim.trim(body):sub(1, 200)
	end

	-- Ours, because the client has none on this path: Client:request builds its curl options with
	-- no timeout key, so the `opts.timeout` it documents is only read on plenary's synchronous
	-- branch, which this never takes. Without this a wedged ollama spins the spinner forever.
	watchdog = vim.defer_fn(function()
		watchdog = nil
		if job then
			pcall(function()
				job.cancel()
			end)
		end
		done(cb.on_error, ("%s: no reply within %ds"):format(name, math.floor(timeout / 1000)))
	end, timeout)

	job = client.new({ adapter = adapter }):request({
		messages = adapter:map_roles({ { role = "user", content = ctx.prompt } }),
	}, {
		callback = function(err, data, resolved)
			if err then
				local msg = type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)
				local detail = error_detail(type(err) == "table" and err.stderr or nil)
				return done(
					cb.on_error,
					("%s: %s%s"):format(name, vim.trim(msg), detail ~= "" and (" " .. detail) or "")
				)
			end
			if not data then
				return
			end

			-- Checked before the adapter's own parser, which assumes a well-formed reply and
			-- errors out indexing the error body instead
			local status = type(data) == "table" and data.status or nil
			if status and status >= 400 then
				local detail = error_detail(data)
				return done(
					cb.on_error,
					("%s: HTTP %d%s"):format(name, status, detail ~= "" and (" — " .. detail) or "")
				)
			end

			local ok, parsed = pcall(adapters.call_handler, resolved, "parse_inline", data, {})
			if not ok then
				return done(cb.on_error, ("%s: could not read the reply (%s)"):format(name, tostring(parsed)))
			end
			if not parsed then
				return done(cb.on_error, ("%s: no usable reply"):format(name))
			end
			if parsed.status ~= "success" then
				return done(cb.on_error, ("%s: %s"):format(name, tostring(parsed.output)))
			end
			done(cb.on_done, parsed.output)
		end,
	}, { bufnr = ctx.bufnr, interaction = "inline" })

	if not job then
		done(cb.on_error, ("%s: the request could not be started"):format(name))
		return { cancel = function() end }
	end

	return {
		cancel = function()
			if watchdog then
				watchdog:stop()
				watchdog = nil
			end
			settled = true
			pcall(function()
				job.cancel()
			end)
		end,
	}
end

return M
