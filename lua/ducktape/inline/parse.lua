-- Turn an arbitrary agent reply into either code to place or a decision not to touch the buffer.
--
-- The bar for refusing is deliberately high. A reply wrongly treated as code costs one keystroke:
-- it lands in a diff the user must accept, and `g3` puts the buffer back. A reply wrongly treated
-- as prose costs the whole request — the edit silently does not happen and the user pays the
-- model's latency again to retry. So prose must be *positively* recognised, never merely inferred
-- from code not being recognised.

local M = {}

---@class ducktape.parse.Ctx
---@field filetype string|nil Buffer filetype, so prose files are not judged by code's rules
---@field selection string[]|nil The lines the model was asked to replace

---@class ducktape.parse.Result
---@field kind "code"|"prose"|"noop"
---@field lines string[]|nil Replacement lines, when kind == "code"
---@field text string|nil The reply as prose, when kind ~= "code"
---@field reason string|nil Why the reply was not treated as code
---@field fenced boolean Whether the code came out of a fenced block
---@field preamble string|nil Prose that sat outside the fenced block, if any

-- A failed tool attempt that nothing parsed, leaking into the message as text. Measured on
-- opencode under a deny-everything permission set; the markup is unfenced.
local LEAK_PATTERNS = { "<tool_call>", "</tool_call>", "<function=", "<parameter=" }

-- Filetypes whose content *is* prose. Judging a reply here by "does it look like code" rejects
-- every correct answer, because the correct answer is a sentence.
local PROSE_FILETYPES = {
	[""] = true,
	markdown = true,
	md = true,
	text = true,
	txt = true,
	rst = true,
	org = true,
	asciidoc = true,
	tex = true,
	plaintex = true,
	gitcommit = true,
	mail = true,
	help = true,
	norg = true,
}

-- Comment markers. A line starting with one is source, however sentence-like the rest of it is.
-- `"` is vimscript's; `;` needs no entry because it is already in the punctuation test below.
local COMMENT_PREFIXES = { "--", "//", "#", "/*", "*", "%", "<!--", '"' }

-- Openers that only ever begin a refusal or an answer, never a line of source. Anchored to the
-- reply's first non-blank line and matched case-insensitively.
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
	-- Spelled out rather than `(are |is )?`: Lua patterns have no optional group, and that form
	-- matches nothing at all — including the plain "no changes needed" it was meant to cover.
	"^no changes? needed%f[%A]",
	"^no changes? are needed%f[%A]",
	"^no changes? is needed%f[%A]",
	"^nothing to change%f[%A]",
}

-- Lead-ins that carry no information. A preamble made only of these is not an explanation, so
-- surfacing it in a float would be noise.
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

---Split a reply into lines, dropping the empty element a trailing newline leaves behind.
---
---Agents end their replies with a newline; taking that literally appends a blank line to the
---buffer on every single edit. Exactly one is dropped, so a reply that deliberately ends with a
---blank line still gets it.
---@param text string
---@return string[]
local function split(text)
	local lines = vim.split(text, "\n", { plain = true })
	if #lines > 1 and lines[#lines] == "" then
		table.remove(lines)
	end
	return lines
end

---Locate the first fenced block. Returns the body lines, or nil when there is no fence.
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
	-- An unterminated fence means a truncated reply. Take the rest rather than discarding it;
	-- the caller still gets a chance to reject it as prose.
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
	for _, pattern in ipairs(LEAK_PATTERNS) do
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

---Is there anything about this line that marks it as source rather than a sentence?
---
---One signal is enough. Comment markers are in here because a rewritten comment is the one kind
---of edit that is *both* a sentence and code — `-- Returns the sum of the two arguments.` reads
---as prose by every other measure.
---@param line string
---@return boolean
local function is_codey(line)
	-- Indentation is source's own signal; prose replies start at the margin
	if line:match("^[ \t]") then
		return true
	end
	local trimmed = vim.trim(line)
	if trimmed == "" then
		return false
	end
	-- Punctuation that appears in code and effectively never in a plain sentence
	if trimmed:find("[{}%[%]();=<>|\\`]") or trimmed:find("::") then
		return true
	end
	for _, prefix in ipairs(COMMENT_PREFIXES) do
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

---Does this line read as a sentence of English rather than a line of source?
---
---A *positive* test, on purpose. "Not obviously code" is not evidence of prose — most lines of
---most languages match no code pattern at all (`end`, `FROM users`, `fi`). Terminal punctuation
---is required of every line, with no exemption for the last: dropping it there is what made a
---one-line reply like `SELECT id, email FROM users` read as prose.
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
---
---The contract tells the model to reproduce unchanged lines exactly, so a real edit almost always
---shares lines with what it replaces. An answer or a refusal shares none.
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

---Prose that sat outside a fence, minus content-free lead-ins. Returns nil when nothing of
---substance is left, so "Here's the updated code:" never gets surfaced as an explanation.
---@param outside string[]
---@return string|nil
local function meaningful_preamble(outside)
	local kept = {}
	for _, line in ipairs(outside) do
		local trimmed = vim.trim(line)
		if trimmed ~= "" and not matches_any(trimmed:lower(), LEAD_INS) then
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

	-- Checked outside the fence on purpose. The measured leak is unfenced message text, and
	-- searching the whole reply would reject legitimate code that merely contains the markup
	-- as a string — including this repository's own source.
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
		-- A fence is the model saying "this part is code". Take it at its word; the prose around
		-- it is kept only so a refusal that echoes the selection back can still be explained.
		return { kind = "code", lines = body, fenced = true, preamble = meaningful_preamble(outside) }
	end

	if is_blank(lines) then
		return { kind = "noop", text = reply, reason = "the reply is empty", fenced = false }
	end

	local first = (first_content_line(lines) or ""):lower()
	-- Both tests below need the reply to carry no code signal anywhere. Nothing that looks even
	-- slightly like source is ever withheld from the buffer on the strength of a heuristic.
	local plain = unstructured(lines)

	-- An explicit refusal, in any filetype. Unambiguous enough to act on by itself, and it does
	-- not require full sentences — a declining model does not always punctuate.
	if plain and matches_any(first, REFUSAL_OPENERS) then
		return { kind = "prose", text = reply, reason = "the reply declines to make the edit", fenced = false }
	end

	-- An answer rather than an edit. Only decidable in a file whose content is code: in a prose
	-- file the correct replacement *is* a sentence, so this test would reject every good reply.
	if
		plain
		and all_sentences(lines)
		and not PROSE_FILETYPES[ctx.filetype or ""]
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
