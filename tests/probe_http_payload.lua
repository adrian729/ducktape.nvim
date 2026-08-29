-- What a forked HTTP chat puts on the wire, read from a real Chat's on_submitted payload.
require("lazy").load({ plugins = { "codecompanion.nvim" } })

local edit = require("ducktape.chat_edit")
local ui = require("ducktape.ui")
local Chat = require("codecompanion.interactions.chat")
local adapter = require("codecompanion.adapters").resolve("ollama")

local chat = Chat.new({ adapter = adapter, buffer_context = { bufnr = vim.api.nvim_get_current_buf() } })
assert(chat, "no chat")
assert(chat.adapter.type == "http", "expected an http adapter, got " .. tostring(chat.adapter.type))

local TRANSCRIPT = {
	"## Me",
	"",
	"My favourite colour is green.",
	"",
	"## CodeCompanion (Ollama)",
	"",
	"Noted.",
	"",
	"## Me",
	"",
	"What is my favourite colour?",
}
vim.bo[chat.bufnr].modifiable = true
vim.api.nvim_buf_set_lines(chat.bufnr, 0, -1, false, TRANSCRIPT)
chat.parsers.markdown:parse(true)

-- The message table as a real first turn leaves it.
local constants = require("codecompanion.config").constants
chat.messages = {
	{ role = constants.SYSTEM_ROLE, content = "system prompt", _meta = { sent = true } },
	{ role = constants.USER_ROLE, content = "My favourite colour is green.", _meta = { sent = true } },
	{ role = constants.LLM_ROLE, content = "Noted.", _meta = {} },
}
edit.rebase(chat)

-- Edit the history, then ask.
vim.api.nvim_buf_set_lines(chat.bufnr, 2, 3, false, { "My favourite colour is purple." })
chat.parsers.markdown:parse(true)

local captured
chat:add_callback("on_submitted", function(_, args)
	captured = args.payload
end)

ui.choose = function()
	return 1
end -- fork
ui.say = function() end

edit.send(chat)
pcall(chat.stop, chat)

print("payload captured: " .. tostring(captured ~= nil))
for i, m in ipairs((captured or {}).messages or {}) do
	print(("  %d  %-10s %s"):format(i, tostring(m.role), vim.inspect(m.content)))
end
vim.cmd("qa!")
