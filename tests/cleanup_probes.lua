-- Delete the probe sessions from claude's own store, over a connection holding none of them.
require("lazy").load({ plugins = { "codecompanion.nvim" } })
local chat = require("ducktape.chat")
local TARGETS = {
	"c7ebbc01-4d56-4c50-a7ec-d4f4990682d9",
	"b23948c4-3524-432c-a636-52ece699aed3",
	"6dfc0f41-0817-4cef-9ded-0144863aae99",
	"73594f2b-92db-427f-a5fe-7aa801dfd630",
}

local adapter = require("codecompanion.adapters").resolve("claude_code")
local conn = require("codecompanion.acp").new({ adapter = adapter })
if not conn:connect_and_authenticate() then
	print("could not connect")
	return vim.cmd("qa!")
end

local listed = {}
for _, s in ipairs(conn:session_list({ max_sessions = 500 }) or {}) do
	listed[s.sessionId] = true
end
for _, sid in ipairs(TARGETS) do
	if not listed[sid] then
		print(("%s  already gone"):format(sid:sub(1, 8)))
	else
		print(("%s  deleted: %s"):format(sid:sub(1, 8), tostring(chat.delete_session(sid, conn))))
	end
end
pcall(conn.disconnect, conn)
vim.cmd("qa!")
