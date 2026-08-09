-- The codecompanion extension entry point. Thin on purpose: everything it does lives in
-- `ducktape.setup`, which is also reachable directly for anyone not routing through
-- codecompanion's `extensions` block.

---@class CodeCompanion.Extension
local Extension = {}

---@param opts table
function Extension.setup(opts)
	require("ducktape").setup(opts)
end

-- Closures, never resolved references. `exports = { run = require("ducktape.inline").run }` would
-- evaluate at this chunk's load time — which, for an action pressed before codecompanion has
-- loaded, is *while* `ducktape.inline` is still executing its own chunk, and re-entering a module
-- mid-load raises "loop or previous error loading module".
Extension.exports = {
	toggle_chat = function(...)
		return require("ducktape.chat").toggle(...)
	end,
	focus_chat = function(...)
		return require("ducktape.chat_window").focus(...)
	end,
	new_chat = function(...)
		return require("ducktape.chat").new(...)
	end,
	chat_list = function(...)
		return require("ducktape.chat_list").open(...)
	end,
	inline = function(...)
		return require("ducktape.inline").run(...)
	end,
	inline_list = function(...)
		return require("ducktape.inline.list").toggle(...)
	end,
	status = function(...)
		return require("ducktape.status").toggle(...)
	end,
	is_ready = function()
		return require("ducktape").is_ready()
	end,
}

return Extension
