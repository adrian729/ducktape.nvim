-- Run at startup (-c luafile), before VeryLazy: verify lazy-loading state and keymaps.
local pass, fail = 0, 0
local function check(ok, what)
	if ok then
		pass = pass + 1
	else
		fail = fail + 1
		print("FAIL " .. what)
	end
end

check(vim.g.loaded_ducktape == true, "plugin/ducktape.lua ran")
check(package.loaded["codecompanion"] == nil, "codecompanion not loaded")
check(package.loaded["ducktape.chat"] == nil, "ducktape.chat not loaded")
check(package.loaded["ducktape.inline"] == nil, "ducktape.inline not loaded")
check(package.loaded["ducktape.providers"] == nil, "ducktape.providers not loaded")

local expected = {
	["<leader>cc"] = { "n" },
	["<leader>cn"] = { "n", "x" },
	["<leader>cq"] = { "n" },
	["<leader>cr"] = { "n" },
	["<leader>cd"] = { "n" },
	["<leader>cl"] = { "n" },
	["<leader>cmc"] = { "n" },
	["<leader>ca"] = { "n", "x" },
	["<leader>ci"] = { "n", "x" },
	["<leader>cI"] = { "n", "x" },
	["<leader>cmi"] = { "n" },
	["<leader>cmr"] = { "n" },
	["<leader>cL"] = { "n" },
	["<leader>cA"] = { "n" },
	["<leader>cR"] = { "n" },
	["<leader>cx"] = { "n" },
	["<leader>cX"] = { "n" },
	["<leader>cs"] = { "n" },
}
local n = 0
for lhs, modes in pairs(expected) do
	n = n + 1
	for _, mode in ipairs(modes) do
		local rhs = vim.fn.maparg(lhs:gsub("<leader>", " "), mode)
		check(rhs ~= "" and rhs:match("^<Plug>%(Ducktape"), ("%s in %s -> %s"):format(lhs, mode, rhs))
	end
end
check(n == 18, "18 global keys expected, got " .. n)

local plugs = {
	"ChatToggle",
	"ChatNew",
	"ChatCloseAll",
	"ChatRename",
	"ChatDelete",
	"ChatList",
	"ChatPick",
	"Actions",
	"Inline",
	"InlineDeep",
	"InlinePick",
	"ModelsRefresh",
	"InlineList",
	"InlineAcceptAll",
	"InlineAskAgain",
	"Cancel",
	"CancelAll",
	"Status",
}
local mapped = {}
for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
	mapped[m.lhs] = true
end
for _, name in ipairs(plugs) do
	local lhs = ("<Plug>(Ducktape%s)"):format(name)
	check(mapped[lhs] == true, lhs .. " mapped")
end
check(#plugs == 18, "18 <Plug> maps expected, got " .. #plugs)

check(vim.o.statusline:find("ducktape.statusline", 1, true) ~= nil, "statusline segment injected")
check(vim.o.statusline:find("%{% &ruler ?", 1, true) ~= nil, "nvim's own statusline default kept")
check(vim.fn.exists(":Ducktape") == 2, ":Ducktape command exists")

check(package.loaded["codecompanion"] == nil, "codecompanion still not loaded at the end")

print(("startup: %d passed, %d failed"):format(pass, fail))
