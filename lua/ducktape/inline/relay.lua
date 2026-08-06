-- A provider's tool-free relay subprocess.
--
-- Guaranteed tool-free, no repo access. The contract is content on stdin, the request as
-- arguments, the answer on stdout — anything meeting it can stand in, which is why the command is
-- configurable and nothing is vendored.
--
-- Which command, and what its exit codes mean, comes from the provider spec's `relay` block. So a
-- second provider with a relay of its own needs no edit here.

local M = {}

---@param ctx { instruction: string, content: string, provider: string, timeout?: number }
---@param cb { on_done: fun(text: string), on_error: fun(msg: string) }
---@return table handle
function M.send(ctx, cb)
	local providers = require("ducktape.providers")
	local relay = providers.relay(ctx.provider)
	if not relay or not relay.cmd then
		cb.on_error(("%s has no relay transport"):format(tostring(ctx.provider)))
		return { cancel = function() end }
	end

	local cmd = relay.cmd
	if vim.fn.executable(cmd) == 0 then
		cb.on_error(("%s is not on PATH"):format(cmd))
		return { cancel = function() end }
	end

	local timeout = ctx.timeout or require("ducktape.config").get().inline.timeout_ms
	local args = { cmd, "-T", tostring(math.floor(timeout / 1000)) }

	-- The AUTO sentinel means "walk the fallback list", which is the relay's own default, so only
	-- pin a model when the user picked one. Pinning disables the walk, which is the right trade for
	-- inline: a dead model should surface as an error rather than silently change the model.
	local model = (providers.opts_for("inline", ctx.provider) or {}).model
	if model and model ~= providers.AUTO then
		vim.list_extend(args, { "-m", model })
	end
	table.insert(args, ctx.instruction)

	local cancelled = false
	local job = vim.system(args, { text = true, stdin = ctx.content }, function(out)
		vim.schedule(function()
			if cancelled then
				return
			end
			if out.code ~= 0 then
				local reason = (relay.exits or {})[out.code] or ("exit %d"):format(out.code)
				local stderr = vim.trim(out.stderr or "")
				return cb.on_error(("relay: %s%s"):format(reason, stderr ~= "" and (" — " .. stderr) or ""))
			end
			cb.on_done(out.stdout or "")
		end)
	end)

	return {
		cancel = function()
			cancelled = true
			pcall(function()
				job:kill(15)
			end)
		end,
	}
end

return M
