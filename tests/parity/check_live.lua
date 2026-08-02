-- Real round trips, in the throwaway config: an ACP agent through the pool, and the ollama HTTP
-- transport inline requests use by default. This is the part no unit test can stand in for — it is
-- what proves the adapters ducktape installs actually work, not merely that they resolve.
local pass, fail = 0, 0
local function check(ok, what)
	if ok then
		pass = pass + 1
	else
		fail = fail + 1
		print("FAIL " .. what)
	end
end

assert(require("ducktape").bootstrap(), "bootstrap failed")
local pool = require("ducktape.acp_pool")

local function acp(provider)
	local reply, err, done = nil, nil, false
	pool.send({
		provider = provider,
		prompt = "Reply with exactly one word: pong",
		on_done = function(text)
			reply, done = text, true
		end,
		on_error = function(msg)
			err, done = msg, true
		end,
	})
	vim.wait(120000, function()
		return done
	end, 200)

	check(done, provider .. ": the request completed")
	check(err == nil, provider .. ": no error" .. (err and (" — " .. tostring(err)) or ""))
	check(
		type(reply) == "string" and #reply > 0,
		provider .. ": got a reply — " .. tostring(reply and reply:sub(1, 60))
	)

	local rows = pool.status()
	local mine = vim.tbl_filter(function(r)
		return r.provider == provider
	end, rows)
	check(#mine > 0, provider .. ": the pool holds a live connection")
	if #mine > 0 then
		check(mine[1].pid ~= nil, provider .. ": the agent really is a subprocess, pid " .. tostring(mine[1].pid))
		check(mine[1].session_id ~= nil, provider .. ": a session was established")
		check(mine[1].state == "ready", provider .. ": connection state is ready, got " .. tostring(mine[1].state))
	end
end

acp("claude")
acp("opencode")

-- The ollama HTTP transport, which is what <leader>ci uses out of the box.
do
	local http = require("ducktape.inline.http")
	local reply, err, done = nil, nil, false
	http.send({ prompt = "Reply with exactly one word: pong", bufnr = vim.api.nvim_get_current_buf() }, {
		on_done = function(text)
			reply, done = text, true
		end,
		on_error = function(msg)
			err, done = msg, true
		end,
	})
	vim.wait(120000, function()
		return done
	end, 200)
	check(done, "ollama: the request completed")
	check(err == nil, "ollama: no error" .. (err and (" — " .. tostring(err)) or ""))
	check(type(reply) == "string" and #reply > 0, "ollama: got a reply — " .. tostring(reply and reply:sub(1, 60)))
end

-- Draining is what a session end does, and it must not leave orphans behind.
pool.shutdown()
vim.wait(5000, function()
	return #pool.status() == 0
end, 100)
check(#pool.status() == 0, "the pool drained on shutdown, left " .. #pool.status())

print(("live: %d passed, %d failed"):format(pass, fail))
