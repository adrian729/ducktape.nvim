pcall(function()
	require("lazy").load({ plugins = { "codecompanion.nvim", "plenary.nvim" } })
end)
package.loaded["ducktape.inline.http"] = {
	send = function(_, _)
		return { cancel = function() end }
	end,
}
local list = require("ducktape.inline.list")
local out = {}
list.open()
local win = nil
for _, w in ipairs(vim.api.nvim_list_wins()) do
	if vim.api.nvim_win_get_config(w).relative ~= "" then
		win = w
	end
end
if not win then
	table.insert(out, "FAIL: no window opened")
else
	local cfg = vim.api.nvim_win_get_config(win)
	table.insert(
		out,
		("window opened: %dx%d  title=%q  footer=%q"):format(
			cfg.width,
			cfg.height,
			type(cfg.title) == "table" and cfg.title[1][1] or tostring(cfg.title),
			type(cfg.footer) == "table" and cfg.footer[1][1] or tostring(cfg.footer)
		)
	)
	table.insert(
		out,
		"contents: " .. vim.inspect(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false))
	)
	-- every key, on a list with no rows
	local keys = { "a", "r", "x", "A", "X", "j", "k", "<CR>", "g2", "g3", "?" }
	local maps = {}
	for _, m in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_win_get_buf(win), "n")) do
		maps[m.lhs] = m.callback
	end
	for _, key in ipairs(keys) do
		local cb = maps[key] or maps[vim.keycode(key)]
		if cb then
			local ok, err = pcall(cb)
			table.insert(out, ("  %-4s %s"):format(key, ok and "ok" or ("ERROR: " .. tostring(err))))
		else
			table.insert(out, ("  %-4s (not bound)"):format(key))
		end
	end
	table.insert(out, "still open after all of them: " .. tostring(list.is_open()))
end
local f = io.open("/tmp/empty_list.txt", "w")
f:write(table.concat(out, "\n"), "\n")
f:close()
vim.cmd("qa!")
