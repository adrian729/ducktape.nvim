-- claude and opencode over ACP, through the connection pool. Tool use is controlled by the
-- adapter's permissions.

local pool = require("ducktape.acp_pool")

local M = {}

---@param ctx { prompt: string, provider: string, timeout?: number }
---@param cb { on_done: fun(text: string), on_error: fun(msg: string), on_tool?: fun(name: string) }
---@return table handle
function M.send(ctx, cb)
	local handle = pool.send({
		provider = ctx.provider,
		prompt = ctx.prompt,
		timeout = ctx.timeout,
		on_tool = cb.on_tool,
		on_done = cb.on_done,
		on_error = cb.on_error,
	})

	return {
		cancel = function()
			handle.cancel()
		end,
	}
end

return M
