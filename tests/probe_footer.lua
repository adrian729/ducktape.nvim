pcall(function()
	require("lazy").load({ plugins = { "codecompanion.nvim", "plenary.nvim" } })
end)
package.loaded["ducktape.inline.http"] = {
	send = function(_, _)
		return { cancel = function() end }
	end,
}
local api = vim.api
local inline = require("ducktape.inline")
local buf = api.nvim_create_buf(true, false)
api.nvim_buf_set_lines(buf, 0, -1, false, { "l1", "l2", "l3", "l4", "l5" })
api.nvim_buf_set_name(buf, "retry.lua")
vim.bo[buf].filetype = "lua"
api.nvim_set_current_buf(buf)
inline.submit({ bufnr = buf, range = { s0 = 1, e0 = 4, has_selection = true }, instruction = "add a backoff" })
require("ducktape.inline.list").open()
