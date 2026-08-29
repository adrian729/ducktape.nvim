-- Mappings, command, and statusline segment are set up before the core loads so keys exist
-- even when the plugin is deferred (:h lua-plugin-lazy).

if vim.g.loaded_ducktape then
	return
end
vim.g.loaded_ducktape = true

if vim.fn.has("nvim-0.11") == 0 then
	return vim.notify("ducktape.nvim requires Neovim 0.11+", vim.log.levels.ERROR)
end

local keys = require("ducktape.keys")

---Action registry. Requires are deferred so bootstrap runs before any agent is reached.
---@type table<string, fun()>
local actions = {
	chat_toggle = function()
		require("ducktape.chat").toggle()
	end,
	chat_focus = function()
		require("ducktape.chat_window").focus()
	end,
	chat_new = function()
		require("ducktape.chat").new()
	end,
	chat_close_all = function()
		require("ducktape.chat").close_all()
	end,
	chat_rename = function()
		require("ducktape.chat").rename()
	end,
	chat_delete = function()
		require("ducktape.chat").delete()
	end,
	chat_list = function()
		require("ducktape.chat_list").open()
	end,
	chat_pick = function()
		require("ducktape.chat").pick()
	end,
	actions = function()
		vim.cmd("CodeCompanionActions")
	end,
	inline = function()
		require("ducktape.inline").run(false)
	end,
	inline_deep = function()
		require("ducktape.inline").run(true)
	end,
	inline_pick = function()
		require("ducktape.inline").pick()
	end,
	models_refresh = function()
		require("ducktape.debug").refresh_models()
	end,
	inline_list = function()
		require("ducktape.inline.list").toggle()
	end,
	inline_accept_all = function()
		require("ducktape.inline").accept_all()
	end,
	inline_ask_again = function()
		require("ducktape.inline").ask_again_here()
	end,
	cancel = function()
		require("ducktape.inline").cancel()
	end,
	cancel_all = function()
		require("ducktape.inline").cancel_all()
	end,
	status = function()
		require("ducktape.status").toggle()
	end,
}

-- <Plug> mappings let users bind actions without calling setup (:h lua-plugin-keymaps).
for action, fn in pairs(actions) do
	local name = ("<Plug>(Ducktape%s)"):format(action
		:gsub("_(%l)", function(c)
			return c:upper()
		end)
		:gsub("^%l", string.upper))
	vim.keymap.set(keys.modes(action), name, function()
		if require("ducktape").bootstrap() then
			fn()
		end
	end, { desc = keys.desc(action) })

	if keys.globals_enabled() then
		local lhs = keys.lhs(action)
		-- hasmapto checks rhs (user bound this action); maparg checks lhs (key taken).
		-- Both are needed so ducktape doesn't clobber user mappings.
		local claimed_action = vim.fn.hasmapto(name) == 1
		local claimed_key = lhs and vim.fn.maparg(lhs, "n") ~= ""
		if lhs and not claimed_action and not claimed_key then
			vim.keymap.set(keys.modes(action), lhs, name, { desc = keys.desc(action), remap = true })
		end
	end
end

-- Inject the statusline segment early so it appears on the first redraw. Append to nvim's default
-- rather than replacing it, which would discard existing segments.
if require("ducktape.config").get().statusline.enabled then
	local segment = "%{%v:lua.require'ducktape.statusline'.render()%}"
	local current = vim.o.statusline
	if not current:find("ducktape.statusline", 1, true) then
		-- Place just left of the ruler when present.
		local at = current:find("%{% &ruler ?", 1, true)
		vim.o.statusline = at and (current:sub(1, at - 1) .. segment .. current:sub(at)) or (current .. segment)
	end
end

-- One command with subcommands (:h lua-plugin-keymaps).
local subcommands = {
	pool = function()
		require("ducktape.debug").pool_status()
	end,
	send = function(args)
		require("ducktape.debug").send_command(args)
	end,
	models = function()
		require("ducktape.debug").refresh_models()
	end,
}

vim.api.nvim_create_user_command("Ducktape", function(cmd)
	local sub = cmd.fargs[1]
	local fn = sub and subcommands[sub]
	if not fn then
		return vim.notify(
			("[ducktape] usage: :Ducktape {%s}"):format(table.concat(vim.tbl_keys(subcommands), "|")),
			vim.log.levels.ERROR
		)
	end
	if require("ducktape").bootstrap() then
		fn(vim.list_slice(cmd.fargs, 2))
	end
end, {
	nargs = "*",
	desc = "ducktape: pool status and raw sends",
	complete = function(lead)
		return vim.tbl_filter(function(name)
			return vim.startswith(name, lead)
		end, vim.tbl_keys(subcommands))
	end,
})
