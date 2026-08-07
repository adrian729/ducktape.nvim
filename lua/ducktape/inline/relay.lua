-- OpenCode's tool-free relay: `opencode run` composed directly, no external command.
--
-- Guaranteed tool-free, no repo access. The agent it runs under is self-provisioned into a
-- project-local opencode.json under `AGENT_DIR` (below), so this never depends on the user's own
-- ~/.config/opencode having anything defined — a colleague with a bare `opencode` install gets the
-- same path with nothing to configure.

local M = {}

local AGENT_NAME = "ducktape-relay"
local AGENT_DIR = vim.fn.stdpath("state") .. "/ducktape/opencode-relay"

-- Every tool denied and a prompt saying so: denying tools alone stops the write but not the
-- attempt, and an attempt with nothing to parse it leaks <tool_call> markup into the reply as
-- text (see providers.lua's `guard` comment on the ACP path, which found the same failure mode).
local AGENT_CONFIG = vim.json.encode({
	agent = {
		[AGENT_NAME] = {
			description = "ducktape's tool-free relay: answers from the given text only.",
			mode = "primary",
			hidden = true,
			permission = {
				edit = "deny",
				bash = "deny",
				read = "deny",
				glob = "deny",
				grep = "deny",
				webfetch = "deny",
				websearch = "deny",
				task = "deny",
				todowrite = "deny",
				lsp = "deny",
				skill = "deny",
				external_directory = "deny",
			},
			prompt = "You are a text-only relay. Answer the request using only the text given to you "
				.. "in the message. You have no tools and no file, repo, or web access — never claim "
				.. "to check or fetch anything, just answer directly.",
		},
	},
})

-- Written once per nvim session rather than once per request: the content is fixed, so a
-- module-local flag beats a stat+read on every inline call. Comparing before writing still
-- matters across sessions, since a stale copy from an older ducktape version should self-heal.
local provisioned = false
local function ensure_agent_dir()
	if provisioned then
		return
	end
	vim.fn.mkdir(AGENT_DIR, "p")
	local path = AGENT_DIR .. "/opencode.json"
	local current = vim.fn.filereadable(path) == 1 and table.concat(vim.fn.readfile(path), "\n") or nil
	if current ~= AGENT_CONFIG then
		vim.fn.writefile({ AGENT_CONFIG }, path)
	end
	provisioned = true
end

-- Wrapping content in `<content>` tags rather than a JSON envelope is deliberate: an earlier
-- revision's envelope made the same model return the whole enclosing function instead of the
-- selected lines, because "emit the code" reframes the task away from honouring the region
-- boundary (see docs/implementation.md). `opencode run` takes the whole thing as one argument, so
-- content and instruction fold into a single message rather than travelling as separate stdin/arg
-- channels.
---@param instruction string
---@param content string
---@return string
local function full_prompt(instruction, content)
	if content == "" then
		return instruction
	end
	return table.concat({
		instruction,
		"",
		"<content>",
		content,
		"</content>",
		"",
		"Answer the request above the content.",
	}, "\n")
end

-- `--format json` streams one JSON object per line. A `text` part can arrive more than once with
-- growing content under the same id, so a later occurrence replaces an earlier one rather than
-- appending — only the final text per id counts, concatenated in first-seen order.
---@param stdout string
---@return string? text
---@return string? err
local function parse_events(stdout)
	local order, by_id, err = {}, {}, nil
	for line in (stdout or ""):gmatch("[^\r\n]+") do
		local ok, event = pcall(vim.json.decode, line)
		if ok and type(event) == "table" then
			if event.type == "error" then
				local data = event.error or {}
				err = err or (data.data and data.data.message) or data.name or "unknown error"
			elseif event.type == "text" and event.part and event.part.id and event.part.text then
				if not by_id[event.part.id] then
					table.insert(order, event.part.id)
				end
				by_id[event.part.id] = event.part.text
			end
		end
	end
	if err then
		return nil, err
	end
	local parts = {}
	for _, id in ipairs(order) do
		table.insert(parts, by_id[id])
	end
	return table.concat(parts, "\n"), nil
end

---@param ctx { instruction: string, content: string, provider: string, timeout?: number }
---@param cb { on_done: fun(text: string), on_error: fun(msg: string) }
---@return table handle
function M.send(ctx, cb)
	local providers = require("ducktape.providers")
	if not providers.relay(ctx.provider) then
		cb.on_error(("%s has no relay transport"):format(tostring(ctx.provider)))
		return { cancel = function() end }
	end
	if vim.fn.executable("opencode") == 0 then
		cb.on_error("opencode is not on PATH")
		return { cancel = function() end }
	end

	-- The AUTO sentinel means "walk the fallback list", which is the relay's own default, so only
	-- pin a model when the user picked one. Pinning disables the walk, which is the right trade for
	-- inline: a dead model should surface as an error rather than silently change the model.
	local pinned = (providers.opts_for("inline", ctx.provider) or {}).model
	local models = (pinned and pinned ~= providers.AUTO) and { pinned } or providers.relay_models(ctx.provider)
	if #models == 0 then
		cb.on_error(("%s: no free relay model configured"):format(ctx.provider))
		return { cancel = function() end }
	end

	ensure_agent_dir()
	local prompt = full_prompt(ctx.instruction, ctx.content or "")
	local timeout = ctx.timeout or require("ducktape.config").get().inline.timeout_ms

	local cancelled = false
	local job
	local tried = {}

	local attempt
	attempt = function(i)
		local model = models[i]
		table.insert(tried, model)
		job = vim.system({
			"opencode",
			"run",
			"-m",
			model,
			"--agent",
			AGENT_NAME,
			"--dir",
			AGENT_DIR,
			"--format",
			"json",
			"--",
			prompt,
		}, { text = true, timeout = timeout }, function(out)
			vim.schedule(function()
				if cancelled then
					return
				end
				-- Terminal, not walked past: `vim.system`'s own timeout kill reports exit 124, and a
				-- slow model is a reason to stop rather than a reason to try the next one.
				if out.code == 124 then
					return cb.on_error(
						("relay: timed out after %ds (model %s)"):format(math.floor(timeout / 1000), model)
					)
				end
				local text, err = parse_events(out.stdout)
				if out.code == 0 and not err and text and text ~= "" then
					return cb.on_done(text)
				end
				if i < #models then
					return attempt(i + 1)
				end
				local reason = err or vim.trim(out.stderr or "")
				if reason == "" then
					reason = ("exit %d"):format(out.code)
				end
				cb.on_error(
					("relay: no candidate model available (tried: %s) — %s"):format(table.concat(tried, ", "), reason)
				)
			end)
		end)
	end
	attempt(1)

	return {
		cancel = function()
			cancelled = true
			if job then
				pcall(function()
					job:kill(15)
				end)
			end
		end,
	}
end

return M
