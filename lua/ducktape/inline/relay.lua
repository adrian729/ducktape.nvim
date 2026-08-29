-- OpenCode tool-free relay: composes `opencode run` directly. The agent is self-provisioned
-- into a project-local config, so no user setup is required.

local M = {}

local AGENT_NAME = "ducktape-relay"
local AGENT_DIR = vim.fn.stdpath("state") .. "/ducktape/opencode-relay"

-- Deny every tool and say so in the prompt; denial alone still leaks <tool_call> markup.
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

-- Write once per nvim session; compare first so an older version self-heals.
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

-- Wrap in <content> tags: an earlier JSON envelope made the model return the surrounding function.
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

-- `--format json` streams one JSON object per line; later text for the same id replaces earlier.
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

	-- Pin a model only when the user picked one; AUTO walks the fallback list.
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
				-- vim.system's own timeout kill reports exit 124; a slow model stops here.
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
