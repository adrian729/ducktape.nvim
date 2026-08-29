-- Parse an agent reply into replacement code or a decision to leave the buffer alone.
-- Prose must be positively recognised: a false code classification costs one undo, but a false
-- prose classification costs a whole retry.

local M = {}

---@class ducktape.parse.Ctx
---@field filetype string|nil Buffer filetype
---@field selection string[]|nil Original selection lines

---@class ducktape.parse.Result
---@field kind "code"|"prose"|"noop"
---@field lines string[]|nil Replacement lines, when kind == "code"
---@field text string|nil The reply as prose, when kind ~= "code"
---@field reason string|nil Why the reply was not treated as code
---@field fenced boolean Whether the code came out of a fenced block
---@field preamble string|nil Prose outside the fenced block, if any

-- Each list is additive through `opts.inline.parse`; `parse.replace = true` opts out.

-- Tool-call markup that leaked as unfenced text.
local LEAK_PATTERNS = { "<tool_call>", "</tool_call>", "<function=", "<parameter=" }

-- Filetypes whose correct answer is prose.
local PROSE_FILETYPES = {
	"",
	"markdown",
	"md",
	"text",
	"txt",
	"rst",
	"org",
	"asciidoc",
	"tex",
	"plaintex",
	"gitcommit",
	"mail",
	"help",
	"norg",
}

-- A line starting with one is source, however sentence-like the rest is.
local COMMENT_PREFIXES = { "--", "//", "#", "/*", "*", "%", "<!--", '"' }

-- Sentence openers that begin a refusal or answer, matched case-insensitively.
local REFUSAL_OPENERS = {
	"^i can'?t%f[%A]",
	"^i cannot%f[%A]",
	"^i am unable%f[%A]",
	"^i'?m unable%f[%A]",
	"^i won'?t%f[%A]",
	"^i will not%f[%A]",
	"^i don'?t%f[%A]",
	"^i do not%f[%A]",
	"^i need%f[%A]",
	"^i'?d need%f[%A]",
	"^sorry%f[%A]",
	"^unfortunately%f[%A]",
	"^there is no%f[%A]",
	"^there'?s no%f[%A]",
	"^it'?s not possible%f[%A]",
	"^that'?s not possible%f[%A]",
	-- Lua patterns have no optional group; `(are |is )?` matches nothing at all.
	"^no changes? needed%f[%A]",
	"^no changes? are needed%f[%A]",
	"^no changes? is needed%f[%A]",
	"^nothing to change%f[%A]",
}

-- Preamble phrases that carry no information.
local LEAD_INS = {
	"^here'?s?%f[%A]",
	"^here is%f[%A]",
	"^sure%f[%A]",
	"^certainly%f[%A]",
	"^of course%f[%A]",
	"^ok%f[%A]",
	"^okay%f[%A]",
	"^the updated%f[%A]",
	"^updated%f[%A]",
	"^done%f[%A]",
}

-- Shipped lists, by the config key that extends each.
local SHIPPED = {
	refusal_openers = REFUSAL_OPENERS,
	lead_ins = LEAD_INS,
	prose_filetypes = PROSE_FILETYPES,
	comment_prefixes = COMMENT_PREFIXES,
	leak_patterns = LEAK_PATTERNS,
}

---One heuristic list, with the user's entries added.
---@param key string
---@return string[]
local function list(key)
	local ok, cfg = pcall(function()
		return require("ducktape.config").get().inline.parse
	end)
	local configured = (ok and type(cfg) == "table" and cfg[key]) or {}
	if ok and type(cfg) == "table" and cfg.replace then
		return configured
	end
	if #configured == 0 then
		return SHIPPED[key]
	end
	local out = vim.list_extend({}, configured)
	return vim.list_extend(out, SHIPPED[key])
end

---@param filetype string|nil
---@return boolean
local function is_prose_filetype(filetype)
	return vim.tbl_contains(list("prose_filetypes"), filetype or "")
end

---Drop the empty element a trailing newline leaves behind. Agents end replies with a newline,
---so taking it literally appends a blank line on every edit.
---@param text string
---@return string[]
local function split(text)
	local lines = vim.split(text, "\n", { plain = true })
	if #lines > 1 and lines[#lines] == "" then
		table.remove(lines)
	end
	return lines
end

---Locate the first fenced block.
---@param lines string[]
---@return string[]|nil body
---@return string[] outside Lines that were not part of the block
local function first_fence(lines)
	local open
	for i, line in ipairs(lines) do
		if line:match("^%s*```") then
			open = i
			break
		end
	end
	if not open then
		return nil, lines
	end

	local close
	for i = open + 1, #lines do
		if lines[i]:match("^%s*```%s*$") then
			close = i
			break
		end
	end
	-- An unterminated fence means a truncated reply; the caller can still reject it as prose.
	close = close or (#lines + 1)

	local body, outside = {}, {}
	for i = open + 1, close - 1 do
		table.insert(body, lines[i])
	end
	for i = 1, #lines do
		if i < open or i > close then
			table.insert(outside, lines[i])
		end
	end
	return body, outside
end

---@param lines string[]
---@return string|nil marker
local function find_leak(lines)
	local joined = table.concat(lines, "\n")
	for _, pattern in ipairs(list("leak_patterns")) do
		if joined:find(pattern, 1, true) then
			return pattern
		end
	end
end

local function is_blank(lines)
	for _, line in ipairs(lines) do
		if vim.trim(line) ~= "" then
			return false
		end
	end
	return true
end

---@param lines string[]
---@return string|nil
local function first_content_line(lines)
	for _, line in ipairs(lines) do
		if vim.trim(line) ~= "" then
			return vim.trim(line)
		end
	end
end

---Does this line carry a source signal rather than reading as a sentence?
---Comment markers are included because a rewritten comment is both sentence and code.
---@param line string
---@return boolean
local function is_codey(line)
	if line:match("^[ \t]") then
		return true
	end
	local trimmed = vim.trim(line)
	if trimmed == "" then
		return false
	end
	if trimmed:find("[{}%[%]();=<>|\\`]") or trimmed:find("::") then
		return true
	end
	for _, prefix in ipairs(list("comment_prefixes")) do
		if trimmed:sub(1, #prefix) == prefix then
			return true
		end
	end
	return false
end

---True when no line of the reply carries a code signal at all.
---@param lines string[]
---@return boolean
local function unstructured(lines)
	for _, line in ipairs(lines) do
		if vim.trim(line) ~= "" and is_codey(line) then
			return false
		end
	end
	return true
end

---Does this line read as an English sentence rather than source?
---Terminal punctuation is required on every line; exempting the last made one-line SQL read
---as prose.
---@param line string
---@return boolean
local function is_sentence(line)
	if is_codey(line) then
		return false
	end
	local trimmed = vim.trim(line)
	if trimmed == "" then
		return false
	end
	if (select(2, trimmed:gsub("%S+", "")) or 0) < 4 then
		return false
	end
	return trimmed:find("[%.%?!:]$") ~= nil
end

---@param lines string[]
---@return boolean
local function all_sentences(lines)
	local seen = false
	for _, line in ipairs(lines) do
		if vim.trim(line) ~= "" then
			seen = true
			if not is_sentence(line) then
				return false
			end
		end
	end
	return seen
end

---@param first string Lowercased first content line
---@param patterns string[]
---@return boolean
local function matches_any(first, patterns)
	for _, pattern in ipairs(patterns) do
		if first:match(pattern) then
			return true
		end
	end
	return false
end

---Does the reply reuse any line of the selection verbatim?
---@param lines string[]
---@param selection string[]|nil
---@return boolean
local function shares_a_line(lines, selection)
	if not selection or #selection == 0 then
		return false
	end
	local seen = {}
	for _, line in ipairs(selection) do
		local t = vim.trim(line)
		if t ~= "" then
			seen[t] = true
		end
	end
	for _, line in ipairs(lines) do
		local t = vim.trim(line)
		if t ~= "" and seen[t] then
			return true
		end
	end
	return false
end

---Prose outside a fence, minus content-free lead-ins.
---@param outside string[]
---@return string|nil
local function meaningful_preamble(outside)
	local kept = {}
	for _, line in ipairs(outside) do
		local trimmed = vim.trim(line)
		if trimmed ~= "" and not matches_any(trimmed:lower(), list("lead_ins")) then
			table.insert(kept, trimmed)
		end
	end
	if #kept == 0 then
		return nil
	end
	return table.concat(kept, "\n")
end

---Parse an agent reply.
---@param reply string
---@param ctx ducktape.parse.Ctx|nil
---@return ducktape.parse.Result
function M.parse(reply, ctx)
	reply = reply or ""
	ctx = ctx or {}

	local lines = split(reply)
	local body, outside = first_fence(lines)

	-- Search outside the fence only: legitimate code can contain the markup as a string.
	local marker = find_leak(outside)
	if marker then
		return {
			kind = "prose",
			text = reply,
			reason = ("the reply contains %s markup — a failed tool attempt, not code"):format(marker),
			fenced = body ~= nil,
		}
	end

	if body then
		if is_blank(body) then
			return { kind = "noop", text = reply, reason = "the reply's code block is empty", fenced = true }
		end
		-- A fence is the model saying "this part is code".
		return { kind = "code", lines = body, fenced = true, preamble = meaningful_preamble(outside) }
	end

	if is_blank(lines) then
		return { kind = "noop", text = reply, reason = "the reply is empty", fenced = false }
	end

	local first = (first_content_line(lines) or ""):lower()
	local plain = unstructured(lines)

	if plain and matches_any(first, list("refusal_openers")) then
		return { kind = "prose", text = reply, reason = "the reply declines to make the edit", fenced = false }
	end

	-- Only decide prose in code files: in prose files the correct replacement *is* a sentence.
	if
		plain
		and all_sentences(lines)
		and not is_prose_filetype(ctx.filetype)
		and not shares_a_line(lines, ctx.selection)
	then
		return {
			kind = "prose",
			text = reply,
			reason = "the reply answers in prose instead of returning code",
			fenced = false,
		}
	end

	return { kind = "code", lines = lines, fenced = false }
end

return M
