-- The picker contract: backend resolution, the entry shape both backends render, panel key
-- binding, and the built-in float end to end.
--
-- The bug this suite exists for: chat list entries carried a `display` closure reading the
-- argument — which telescope calls with the picker, not the entry — so rows came up blank, and
-- the spec had no `panel`, so <C-x> fell through to telescope's select_horizontal and crashed.
-- Every entry here goes through the real `ducktape.picker` interface against the built-in
-- backend, which is the only one the bare harness can run; the telescope backend's wrapper is
-- exercised by the parity config, where telescope is actually installed.

local REPORT = "/tmp/picker.out"
local passed, failed, lines = 0, 0, {}
local function flush()
	local f = io.open(REPORT, "w")
	f:write(table.concat(lines, "\n"), "\n\n", ("%d passed, %d failed\n"):format(passed, failed))
	f:close()
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
local function eq(name, got, want)
	ok(vim.deep_equal(got, want), name, ("got %s want %s"):format(vim.inspect(got), vim.inspect(want)))
end

local api = vim.api
local picker = require("ducktape.picker")

--=============================================================================
-- Backend resolution
--=============================================================================

do
	-- Nothing set up yet, so this is the default "auto" route: telescope is not on the bare
	-- runtimepath, and the built-in float is the fallback.
	local name, reason = picker.resolve()
	ok(name == "default", "bare harness resolves to the built-in float", reason)
	ok(reason:find("no picker plugin found") ~= nil, "and says telescope is missing", reason)
end

-- The telescope backend may not even load here, so the built-in float is the only one that can
-- be exercised; pin the choice rather than letting "auto" pick it implicitly.
require("ducktape.config").setup({ ui = { picker = "default" } })

do
	local name, reason = picker.resolve()
	ok(name == "default" and reason == "opts.ui.picker", "explicit default is taken without the warning")
	require("ducktape.config").setup({ ui = { picker = function() end } })
	ok(picker.resolve() == "custom", "a function backend is handed straight through")
	require("ducktape.config").setup({ ui = { picker = "default" } })
end

do
	local said = {}
	local real_say = require("ducktape.ui").say
	require("ducktape.ui").say = function(m)
		table.insert(said, m)
	end
	require("ducktape.config").setup({ ui = { picker = "telescope" } })
	local name, reason = picker.resolve()
	require("ducktape.ui").say = real_say
	ok(name == "default", "explicit telescope falls back to the float when it is missing", reason)
	ok((said[1] or ""):find("not available", 1, true) ~= nil, "and says why instead of substituting silently")
	require("ducktape.config").setup({ ui = { picker = "default" } })
end

--=============================================================================
-- Entry shape: what both backends render, and nothing else
--=============================================================================

-- `display` is the trap that blanked the chat list: it read the argument, and telescope calls
-- it with the picker. Entries must carry text and highlights; backends own any wrapping.
for _, scope in ipairs({ "chat", "inline" }) do
	local entries = require("ducktape.pick")._entries_for_test(scope)
	ok(#entries > 0, scope .. " picker produces rows")
	for i, entry in ipairs(entries) do
		local label = ("%s entry %d"):format(scope, i)
		ok(type(entry.text) == "string" and entry.text ~= "", label .. " has non-empty text")
		ok(type(entry.ordinal) == "string", label .. " has a searchable ordinal")
		ok(type(entry.highlights) == "table", label .. " carries highlights")
		ok(entry.value ~= nil, label .. " carries a value for the caller")
		ok(entry.display == nil, label .. " does not carry a display closure", vim.inspect(entry))
		for j, hl in ipairs(entry.highlights) do
			ok(
				type(hl) == "table"
					and type(hl[1]) == "table"
					and type(hl[1][1]) == "number"
					and type(hl[1][2]) == "number"
					and type(hl[2]) == "string",
				("%s highlight %d has the { {start, finish}, group } shape"):format(label, j)
			)
		end
	end
end

--=============================================================================
-- Panel key binding (the <C-x> crash class)
--=============================================================================

do
	local keys = require("ducktape.keys")
	local calls = {}
	-- A spec without a panel must not bind anything: those keys belong to the user's own
	-- mappings, and a picker stealing them was what let <C-x> die in telescope internals.
	local ok_open, handle = pcall(picker.open, {
		title = "no panel",
		entries = function()
			return { { value = 1, text = "one", highlights = {}, ordinal = "one" } }
		end,
		actions = {
			delete = function(e)
				table.insert(calls, e)
			end,
		},
	})
	ok(ok_open and type(handle) == "table", "a spec without panel opens", handle)
	for _, action in ipairs({ "delete", "rename", "kill", "help" }) do
		for _, lhs in ipairs(keys.panel("chat_list", action)) do
			local mapped = vim.fn.maparg(lhs, "i")
			ok(mapped == "", "no panel: " .. lhs .. " is not mapped", mapped)
		end
	end
	ok(#calls == 0, "no panel: the action never fired")
	handle.close()
	vim.wait(30)

	local ok_open2, handle2 = pcall(picker.open, {
		title = "no panel 2",
		entries = function()
			return { { value = 1, text = "one", highlights = {}, ordinal = "one" } }
		end,
	})
	ok(ok_open2 and type(handle2) == "table", "no panel: a spec without actions opens too", handle2)
	handle2.close()
	vim.wait(30)
end

--=============================================================================
-- The built-in float, end to end
--=============================================================================

local entries = {
	{ value = "alpha", text = "  row alpha", highlights = { { { 2, 7 }, "DucktapeListCurrent" } }, ordinal = "alpha" },
	{ value = "beta", text = "  row beta", highlights = {}, ordinal = "beta" },
	{ value = "gamma", text = "  row gamma", highlights = {}, ordinal = "gamma" },
}
local selected, actions_hit, ctx_close
local handle = picker.open({
	title = "contract",
	results_title = "probe",
	panel = "chat_list",
	entries = function()
		return entries
	end,
	on_select = function(entry)
		selected = entry
	end,
	actions = {
		delete = function(entry, ctx)
			actions_hit = entry
			ctx_close = ctx.close
		end,
	},
})

ok(handle.is_open(), "handle reports open")
ok(selected == nil, "nothing selected yet")

do
	local results_buf, results_win
	local current = api.nvim_get_current_win()
	for _, win in ipairs(api.nvim_list_wins()) do
		local bufnr = api.nvim_win_get_buf(win)
		if api.nvim_win_get_config(win).relative ~= "" and win ~= current then
			results_win, results_buf = win, bufnr
		end
	end
	ok(results_win ~= nil, "the results float is up")
	local content = api.nvim_buf_get_lines(results_buf, 0, -1, false)
	-- The built-in float draws its border on the window, not in the buffer: one row per entry.
	ok(#content == #entries, "one buffer line per entry", #content)
	for i, entry in ipairs(entries) do
		ok(content[i] == entry.text, "row " .. i .. " renders the entry text", content[i])
	end
	local border = api.nvim_win_get_config(results_win).border
	ok(type(border) == "table" and #border == 8, "the float carries the configured border", vim.inspect(border))
	local marks = api.nvim_buf_get_extmarks(results_buf, -1, 0, -1, {})
	ok(#marks > 0, "highlights arrive as extmarks", #marks)
end

-- Only what the spec declares: this one has `delete`, so <C-d> is bound and the rest of the
-- panel's keys are left alone.
ok(vim.fn.maparg("<C-d>", "i") ~= "", "panel key <C-d> is bound on the prompt")
for _, lhs in ipairs({ "<C-r>", "<C-x>", "<C-_>" }) do
	ok(vim.fn.maparg(lhs, "i") == "", "panel key " .. lhs .. " is not bound when undeclared", vim.fn.maparg(lhs, "i"))
end

entries = {
	{ value = "delta", text = "  row delta", highlights = {}, ordinal = "delta" },
	{ value = "epsilon", text = "  row epsilon", highlights = {}, ordinal = "epsilon" },
}
handle.refresh()
vim.wait(50)
ok(handle.is_open(), "refresh keeps it open")
do
	local current = api.nvim_get_current_win()
	for _, win in ipairs(api.nvim_list_wins()) do
		local bufnr = api.nvim_win_get_buf(win)
		if api.nvim_win_get_config(win).relative ~= "" and win ~= current then
			local content = api.nvim_buf_get_lines(bufnr, 0, -1, false)
			ok(#content == #entries, "refresh re-renders one row per new entry", #content)
			ok(content[1] == "  row delta" and content[2] == "  row epsilon", "refresh shows the new entries")
		end
	end
end

-- Headless nvim never leaves normal mode and control keys only reach mappings through
-- Vimscript feedkeys with the typed flag; Lua nvim_feedkeys will not do it.
vim.cmd("call feedkeys(\"\\<C-d>\", 'xt')")
vim.wait(50)
ok(actions_hit ~= nil, "<C-d> fires the panel action", actions_hit and vim.inspect(actions_hit.value))
ok(
	actions_hit and actions_hit.value == "delta",
	"with the selected entry",
	actions_hit and vim.inspect(actions_hit.value)
)
ok(type(ctx_close) == "function", "and a working close in the context")
ok(handle.is_open(), "and the picker stays up for the action to answer")

vim.cmd("call feedkeys(\"\\<CR>\", 'xt')")
vim.wait(50)
ok(selected ~= nil, "<CR> selects", selected and vim.inspect(selected.value))
ok(
	selected and selected.value == "delta",
	"and hands over the entry at the cursor",
	selected and vim.inspect(selected.value)
)
ok(not handle.is_open(), "selecting closes the picker")

handle.close()
ok(not handle.is_open(), "close reports closed")
handle.close()
ok(true, "closing twice is harmless")
vim.wait(30)

--=============================================================================
-- The chat list itself, on the built-in backend
--=============================================================================

do
	-- resumable_sessions() would otherwise spawn a real agent to list sessions; the cache is
	-- exactly the seam a unit suite must take, and everything downstream is then exercised
	-- for real.
	require("ducktape.chat_list")._cached_sessions = {
		{
			sessionId = "s1",
			title = "Alpha session",
			updatedAt = "2020-01-01T10:00:00Z",
			cwd = "/",
			provider = "claude",
		},
		{
			sessionId = "s2",
			title = "Beta session",
			updatedAt = "2020-01-01T11:00:00Z",
			cwd = "/",
			provider = "claude",
		},
	}
	local ok_open, err_open = pcall(require("ducktape.chat_list").open)
	ok(ok_open and err_open == nil, "chat list opens on the built-in backend", err_open)

	local rendered = {}
	for _, win in ipairs(api.nvim_list_wins()) do
		local bufnr = api.nvim_win_get_buf(win)
		if api.nvim_win_get_config(win).relative ~= "" and api.nvim_win_get_config(win).enter ~= true then
			rendered = api.nvim_buf_get_lines(bufnr, 0, -1, false)
		end
	end
	local joined = table.concat(rendered, "\n")
	ok(joined:find("Alpha session", 1, true) ~= nil, "a seeded session is listed", joined)
	ok(joined:find("Beta session", 1, true) ~= nil, "the other one too", joined)
	ok(joined:find("○", 1, true) ~= nil, "with the not-started marker")
	ok(vim.fn.maparg("<C-x>", "i") ~= "", "and the chat list's own <C-x> is bound", vim.fn.maparg("<C-x>", "i"))

	-- Leaving the prompt takes the whole picker down.
	local main_win
	for _, win in ipairs(api.nvim_list_wins()) do
		if api.nvim_win_get_config(win).relative == "" then
			main_win = win
			break
		end
	end
	api.nvim_set_current_win(main_win)
	vim.wait(50)
	local floats = 0
	for _, win in ipairs(api.nvim_list_wins()) do
		if api.nvim_win_get_config(win).relative ~= "" then
			floats = floats + 1
		end
	end
	ok(floats == 0, "leaving the prompt closes the chat list", floats)
end

flush()
