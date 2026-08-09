-- The keymap hedge: the three ways a user's own mapping is meant to win, and what `false` does.
local pass, fail = 0, 0
local function check(ok, what)
	if ok then
		pass = pass + 1
	else
		fail = fail + 1
		print("FAIL " .. what)
	end
end

local variant = os.getenv("DT_VARIANT")
local keys = require("ducktape.keys")

local function plug_count()
	local n = 0
	for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
		if m.lhs:match("^<Plug>%(Ducktape") then
			n = n + 1
		end
	end
	return n
end

local function leader_count()
	local n = 0
	for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
		if m.lhs:match("^ c") and tostring(m.rhs or ""):match("^<Plug>%(Ducktape") then
			n = n + 1
		end
	end
	return n
end

if variant == "keymaps_false" or variant == "globals_false" then
	check(keys.globals_enabled() == false, "globals disabled")
	check(leader_count() == 0, "no <leader>c* defaults, got " .. leader_count())
	check(plug_count() == 19, "all 19 <Plug> maps still there, got " .. plug_count())

	-- A hand-rolled binding onto a <Plug> map has to work, or `false` costs the user the plugin.
	vim.keymap.set("n", "<leader>zz", "<Plug>(DucktapeChatToggle)", { remap = true })
	check(vim.fn.maparg(" zz", "n") ~= "", "own mapping onto a <Plug> map works")

	-- `false` must not reach the buffer-local set, nor leave a message interpolating nil.
	check(keys.lhs("diff_accept") == "g2", "diff_accept still resolves, got " .. tostring(keys.lhs("diff_accept")))
	check(keys.label("diff_next_hunk") == "<leader>cj", "diff_next_hunk still resolves")
	check(keys.label("cancel") == "<leader>cx", "a suppressed global still has a printable name")
elseif variant == "taken_key" then
	local rhs = vim.fn.maparg(" ci", "n")
	check(rhs:find("mine", 1, true) ~= nil, "their <leader>ci survived, got " .. rhs)
	check(vim.fn.maparg(" ci", "n"):match("Ducktape") == nil, "ducktape did not take it")
	check(leader_count() == 17, "the other 17 defaults are there, got " .. leader_count())
	check(plug_count() == 19, "all 19 <Plug> maps there")
elseif variant == "own_plug" then
	check(vim.fn.maparg(" zi", "n"):find("DucktapeInline", 1, true) ~= nil, "their own key points at the action")
	check(vim.fn.maparg(" ci", "n") == "", "ducktape skipped its own <leader>ci default")
	check(leader_count() == 17, "the other 17 defaults are there, got " .. leader_count())
elseif variant == "default" then
	check(keys.globals_enabled() == true, "globals enabled")
	check(leader_count() == 19, "all 19 defaults, got " .. leader_count())
	check(plug_count() == 19, "all 19 <Plug> maps")
end

print(("keymaps[%s]: %d passed, %d failed"):format(variant, pass, fail))
