-- What counts as "this project", and what that must not do to saved chats.
--
-- The bug this suite exists for: unifying the two scopes moved saved chats from the working
-- directory onto the repository root, and the migration took the *first* directory it found. With
-- `/repo/frontend` and `/repo/backend` each holding a set, opening one claimed the `/repo` key and
-- left the other's chats in the file with nothing that ever looked them up again.
--
-- So: the default must key chats exactly where it always did, and opting into a coarser key must
-- merge every bucket beneath it rather than pick one.

local REPORT = "/tmp/scope.out"
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

vim.env.XDG_STATE_HOME = vim.fn.tempname()

local config = require("ducktape.config")
local scope = require("ducktape.scope")

section("the shipped defaults are the pre-existing behaviour")
config.setup({})
eq("resumable sessions are scoped to the repository", config.get().session.scope, "git")
eq("saved chats are scoped to the working directory", config.get().session.chats, "cwd")

section("the two are resolved independently")
-- One cache slot for both would answer the second question with the first's answer.
scope.clear()
local cwd = vim.fn.getcwd()
eq("the chats strategy gives the directory", scope.key("cwd"), cwd)
local repo = scope.key("git")
ok(repo ~= nil, "the sessions strategy gives something")
ok(repo ~= cwd or vim.fn.getcwd() == repo, "and it is the repository root where those differ")
eq("asking for the directory again is unaffected", scope.key("cwd"), cwd)

section("a function strategy is honoured")
scope.clear()
eq(
	"its answer is used",
	scope.key(function()
		return "/somewhere/else"
	end),
	"/somewhere/else"
)
scope.clear()

section("a coarser chat key merges every bucket beneath it, rather than first-wins")
-- Driven through the real read/write pair rather than a copy of it: this is the logic that lost
-- chats, so a reimplementation in the test would prove nothing.
local chat = require("ducktape.chat")
ok(type(chat._read_entries_for_test) == "function", "the read path is reachable")

local data = {
	["/repo/frontend"] = { { session_id = "A" } },
	["/repo/backend"] = { { session_id = "B" } },
	["/elsewhere"] = { { session_id = "C" } },
}
local merged, key = chat._read_entries_for_test(data, "/repo")
eq("it files under the coarse key", key, "/repo")
eq("and carries both subdirectories", #merged, 2)
local ids = {}
for _, entry in ipairs(merged) do
	ids[entry.session_id] = true
end
ok(ids.A and ids.B, "both chats survive")
ok(not ids.C, "another project's chats are left alone")

section("the merge deduplicates by session, and is stable")
local dupes = {
	["/repo/frontend"] = { { session_id = "A" } },
	["/repo/backend"] = { { session_id = "A" }, { session_id = "B" } },
}
local deduped = chat._read_entries_for_test(dupes, "/repo")
eq("a chat reachable from two directories appears once", #deduped, 2)

section("the default path is a plain lookup, with nothing to migrate")
local plain = { [cwd] = { { session_id = "D" } }, ["/repo"] = { { session_id = "E" } } }
local entries, plain_key = chat._read_entries_for_test(plain, cwd)
eq("it reads the directory's own bucket", plain_key, cwd)
eq("and only that one", #entries, 1)
eq("with the entry it holds", entries[1].session_id, "D")

section("nothing is found where nothing was saved")
local empty, empty_key = chat._read_entries_for_test({}, "/repo")
ok(empty == nil, "an absent key reads as nil rather than an empty list")
eq("and still reports where a write would go", empty_key, "/repo")

flush()
