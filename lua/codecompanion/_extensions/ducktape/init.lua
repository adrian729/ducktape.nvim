-- CodeCompanion extension entry point. Thin wrapper around `ducktape.setup`.

---@class CodeCompanion.Extension
local Extension = {}

---@param opts table
function Extension.setup(opts)
	require("ducktape").setup(opts)
end

-- Closures prevent resolving `ducktape.inline` at chunk load time, which would re-enter a module
-- mid-load and raise "loop or previous error loading module".
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
