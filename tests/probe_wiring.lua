require("lazy").load({ plugins = { "codecompanion.nvim" } })
local cfg = require("codecompanion.config")
local send = cfg.interactions.chat.keymaps.send
print("callback type: " .. type(send.callback))
print("modes kept:    " .. vim.inspect(send.modes))
print("index kept:    " .. tostring(send.index))
print("desc kept:     " .. tostring(send.description))

-- What the keymap layer would actually bind.
local Keymaps = require("codecompanion.utils.keymaps")
local km = Keymaps.new({
	bufnr = 0,
	callbacks = require("codecompanion.interactions.chat.keymaps"),
	keymaps = cfg.interactions.chat.keymaps,
	data = {},
})
local rhs = km:resolve(send.callback)
print("resolves to a function: " .. tostring(type(rhs) == "function"))
print("is ours (not stock):    " .. tostring(rhs ~= require("codecompanion.interactions.chat.keymaps").send.callback))
print("chat_edit loads:        " .. tostring(pcall(require, "ducktape.chat_edit")))
