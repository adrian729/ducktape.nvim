-- Everything that has to exist before the plugin is loaded: the mappings, the command, and the
-- statusline segment. Nothing here requires the plugin itself — the requires live inside the
-- callbacks, so pressing a key is what pulls it in (:h lua-plugin-lazy).

if vim.g.loaded_ducktape then
	return
end
vim.g.loaded_ducktape = true

if vim.fn.has("nvim-0.11") == 0 then
	return vim.notify("ducktape.nvim requires Neovim 0.11+", vim.log.levels.ERROR)
end

local keys = require("ducktape.keys")

---What each action does. The require is inside the function, and `bootstrap()` runs first so the
---action cannot reach an agent before the adapters that deny writes are installed.
---@type table<string, fun()>
local actions = {
	chat_toggle = function()
		require("ducktape.chat").toggle()
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

-- A <Plug> mapping per action, so a user can bind their own key in one line without a setup call
-- and without an error if the plugin is disabled (:h lua-plugin-keymaps).
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
		-- Two different questions, and only asking one of them is the classic mistake here.
		-- `hasmapto` is "has the user already bound this action to a key of their own?", since it
		-- searches the *rhs* of existing mappings. `maparg` is "is this key already taken?".
		-- Without the second, whichever of us ran last would win, which is a coin flip rather
		-- than a promise that their mapping survives.
		local claimed_action = vim.fn.hasmapto(name) == 1
		local claimed_key = lhs and vim.fn.maparg(lhs, "n") ~= ""
		if lhs and not claimed_action and not claimed_key then
			vim.keymap.set(keys.modes(action), lhs, name, { desc = keys.desc(action), remap = true })
		end
	end
end

-- The inline counters. Injected here rather than from setup so the segment is present on the very
-- first redraw, as it was when this lived in the user's own options file — deferring it to
-- codecompanion's load would leave a window with no segment at all.
--
-- Appended into whatever nvim's default already is rather than replacing it. That default is not
-- empty on current versions — it carries the terminal exit code, vim.ui.progress_status(), the busy
-- indicator, vim.diagnostic.status() and the ruler — and writing the documented "equivalent" over
-- it would quietly throw all of that away. The expression itself is evaluated at redraw, so nothing
-- is required until there is something to show.
if require("ducktape.config").get().statusline.enabled then
	local segment = "%{%v:lua.require'ducktape.statusline'.render()%}"
	local current = vim.o.statusline
	if not current:find("ducktape.statusline", 1, true) then
		-- Just left of the ruler, so it sits at the right-hand end of the real content. Appended
		-- if that chunk is ever renamed, which puts it in the wrong place but never breaks the bar.
		local at = current:find("%{% &ruler ?", 1, true)
		vim.o.statusline = at and (current:sub(1, at - 1) .. segment .. current:sub(at)) or (current .. segment)
	end
end

-- One command with subcommands rather than several top-level ones (:h lua-plugin-keymaps).
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
