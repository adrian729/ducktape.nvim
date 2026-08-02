-- opencode through the `opencode-llm` relay script.
--
-- Guaranteed tool-free, no repo access, free model. We shell out to the script rather than
-- composing `opencode run` ourselves because it already owns the free-model fallback walk from
-- opencode-models.json, the neutral cwd, the portable timeout wrapper and --format json
-- parsing — and its contract is exactly what inline needs: content on stdin, request as args,
-- answer on stdout.
--
-- Why this and not ACP for `<leader>ci`: `opencode acp` has no --agent flag, and denying a tool
-- the model wants stops the execution but not the attempt, so tool-call markup leaks into the
-- reply as text. The relay pairs the same deny set with a prompt telling the model it has no
-- tools, which stops the attempt at source.

local providers = require("ducktape.providers")

local M = {}

local EXIT = {
	[1] = "usage error",
	[2] = "empty prompt and empty input",
	[3] = "opencode or jq is not installed",
	[5] = "no free relay model available",
	[6] = "the provider returned an API error",
	[124] = "timed out",
}

---@param ctx { instruction: string, content: string, timeout?: number }
---@param cb { on_done: fun(text: string), on_error: fun(msg: string) }
---@return table handle
function M.send(ctx, cb)
	if vim.fn.executable("opencode-llm") == 0 then
		cb.on_error("opencode-llm is not on PATH")
		return { cancel = function() end }
	end

	local secs = math.floor((ctx.timeout or 120000) / 1000)
	local args = { "opencode-llm", "-T", tostring(secs) }

	-- `auto` means "walk the fallback list", which is the script's own default, so only pin a
	-- model when the user picked one. Pinning disables the walk, which is the right trade for
	-- inline: a dead model should surface as an error rather than silently change the model.
	local model = providers.current("inline").opts.model
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
				local reason = EXIT[out.code] or ("exit %d"):format(out.code)
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
