-- Does editing chat history above header_line corrupt what the next submit parses?
local parser = require("codecompanion.interactions.chat.parser")
local cfg = require("codecompanion.config")

local lines = {
	"## Me", -- 1
	"", -- 2
	"first question", -- 3
	"", -- 4
	"## CC (claude_code)", -- 5
	"", -- 6
	"first answer", -- 7
	"", -- 8
	"## Me", -- 9  <- header_line for the new prompt
	"", -- 10
	"second question", -- 11
	"", -- 12
}

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
vim.bo[bufnr].filetype = "markdown"
local md = vim.treesitter.get_parser(bufnr, "markdown")

local chat = { bufnr = bufnr, parsers = { markdown = md } }

local function ask(header_line)
	md:parse(true)
	local m = parser.messages(chat, header_line)
	return m and m.content or "<nil>"
end

print("user role config: " .. tostring(cfg.interactions.chat.roles.user))
print("correct header_line=9  -> " .. vim.inspect(ask(9)))
print("stale  header_line=11 (2 lines deleted above) -> " .. vim.inspect(ask(11)))
print("stale  header_line=5  (4 lines added above)   -> " .. vim.inspect(ask(5)))
print("stale  header_line=1                          -> " .. vim.inspect(ask(1)))
