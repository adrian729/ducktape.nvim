-- A/B the ducktape ACP pool against the pre-extraction nvim_main pool with the same adapters.
local function ab(label, pool_module, prompt)
	local reply, err, done = nil, nil, false
	local started = vim.uv.now()
	require(pool_module).send({
		provider = "opencode",
		prompt = prompt,
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
	print(
		("%s: %s after %.0fs%s"):format(
			label,
			reply and "REPLY" or (err and "ERROR" or "TIMEOUT"),
			(vim.uv.now() - started) / 1000,
			err and (" — " .. tostring(err)) or (reply and (" — " .. reply:sub(1, 40)) or "")
		)
	)
	pcall(function()
		require(pool_module).shutdown()
	end)
	vim.wait(3000, function()
		return #require(pool_module).status() == 0
	end, 100)
end

assert(require("ducktape").bootstrap(), "bootstrap failed")

-- The original tree, whose modules are named ai.* and are otherwise the same code.
vim.opt.runtimepath:append(vim.fn.expand("~/dotfiles/nvim_main/.config/nvim"))

ab("ducktape", "ducktape.acp_pool", "Reply with exactly one word: pong")
ab("original", "ai.acp_pool", "Reply with exactly one word: pong")
