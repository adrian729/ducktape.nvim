-- ducktape.keys: the strings that name keys must read exactly as they did when they were
-- hardcoded, and must follow a remap rather than keep naming the defaults.
--
-- The expected values below are copied from the pre-extraction source. They are the whole point of
-- this suite: threading keys through a lookup is only safe if it is invisible by default.

local REPORT = "/tmp/keys.out"
local passed, failed, lines = 0, 0, {}
local function flush()
	local f = io.open(REPORT, "w")
	f:write(table.concat(lines, "\n"), "\n\n", ("%d passed, %d failed\n"):format(passed, failed))
	f:close()
end
local function section(t)
	table.insert(lines, "\n=== " .. t .. " ===")
end
local function ok(cond, what, detail)
	if cond then
		passed = passed + 1
		table.insert(lines, "  ok   " .. what)
	else
		failed = failed + 1
		table.insert(lines, "  FAIL " .. what .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
	end
	flush()
end
local function eq(what, got, want)
	ok(got == want, what, ("got %q want %q"):format(tostring(got), tostring(want)))
end

local keys = require("ducktape.keys")
local config = require("ducktape.config")

section("every shipped key is what it was")
local shipped = {
	chat_toggle = "<leader>cc",
	chat_new = "<leader>cn",
	chat_close_all = "<leader>cq",
	chat_rename = "<leader>cr",
	chat_delete = "<leader>cd",
	chat_list = "<leader>cl",
	chat_pick = "<leader>cmc",
	actions = "<leader>ca",
	inline = "<leader>ci",
	inline_deep = "<leader>cI",
	inline_pick = "<leader>cmi",
	inline_list = "<leader>cL",
	inline_accept_all = "<leader>cA",
	inline_ask_again = "<leader>cR",
	cancel = "<leader>cx",
	cancel_all = "<leader>cX",
	status = "<leader>cs",
	diff_accept = "g2",
	diff_reject = "g3",
	diff_next_hunk = "<leader>cj",
	diff_prev_hunk = "<leader>ck",
}
for action, lhs in pairs(shipped) do
	eq(action, keys.lhs(action), lhs)
end

section("all 17 global actions are present, and the diff keys are not among them")
local globals = keys.global_actions()
eq("17 global actions", #globals, 17)
ok(
	not vim.tbl_contains(globals, "diff_accept") and not vim.tbl_contains(globals, "diff_next_hunk"),
	"the buffer-local diff set is excluded"
)

section("dual-mode actions keep both modes")
for _, action in ipairs({ "actions", "inline", "inline_deep", "chat_new" }) do
	local modes = keys.modes(action)
	ok(vim.tbl_contains(modes, "n") and vim.tbl_contains(modes, "x"), action .. " is n and x")
end
eq("and a normal-only one stays normal-only", #keys.modes("cancel"), 1)

section("the messages that name keys are byte-identical to the hardcoded originals")
-- Rendered by the same expressions the source uses, so a change to either side shows up here.
local K = keys.label
eq(
	"in-flight collision",
	("[ducktape] %s already has an inline request in flight%s — "):format("init.lua", "")
		.. K("cancel")
		.. " cancels it, "
		.. K("inline_list")
		.. " lists them all",
	"[ducktape] init.lua already has an inline request in flight — <leader>cx cancels it, <leader>cL lists them all"
)
eq(
	"held lines",
	"[ducktape] those lines are held by an inline request — " .. K("cancel") .. " cancels it",
	"[ducktape] those lines are held by an inline request — <leader>cx cancels it"
)
eq(
	"undo lock",
	"[ducktape] undo is held off while an inline request runs here — " .. K("cancel") .. " cancels it",
	"[ducktape] undo is held off while an inline request runs here — <leader>cx cancels it"
)
eq(
	"the diff banner",
	("%s Accept | %s Reject | %s/%s Hunk"):format(
		K("diff_accept"),
		K("diff_reject"),
		K("diff_next_hunk"),
		(K("diff_prev_hunk"):gsub("^<[lL]eader>", ""))
	),
	"g2 Accept | g3 Reject | <leader>cj/ck Hunk"
)

section("a remap carries into the messages")
config.setup({ keymaps = { cancel = { "<leader>zz", mode = { "n" }, desc = "cancel" } } })
eq("the lookup follows it", keys.lhs("cancel"), "<leader>zz")
eq(
	"and so does the message",
	"[ducktape] those lines are held by an inline request — " .. K("cancel") .. " cancels it",
	"[ducktape] those lines are held by an inline request — <leader>zz cancels it"
)
eq("while an untouched action is unchanged", keys.lhs("inline_list"), "<leader>cL")

section("keymaps = false suppresses the globals without losing the names")
config.setup({ keymaps = false })
ok(not keys.globals_enabled(), "globals are off")
eq("but a key still has a name to print", keys.lhs("cancel"), "<leader>cx")
eq("and the diff keys are untouched", keys.lhs("diff_accept"), "g2")
