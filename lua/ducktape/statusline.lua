-- The one always-visible signal that inline has something in play.
--
-- Everything else inline does is either where the edit is (marks, signs, the diff) or behind a key
-- (the list). Neither answers "did something arrive while I was in another file?", and a notify
-- does not either: there is no notification plugin here, so it is one line in the message area that
-- scrolls away. This segment is the standing answer, and it is empty whenever there is nothing to
-- say, so it costs nothing the rest of the time.

local M = {}

-- The icons, their order and the leading label come from `opts.statusline`, so the segment can be
-- made to match a nerd-font set or dropped to plain letters. Read at redraw, inside the pcall below.

---The `%{%...%}` expression nvim evaluates on every redraw, for every window.
---
---Wrapped in pcall and returning nothing on failure, deliberately: this runs inside the statusline,
---where an error is not a message but a broken bar on every redraw for the rest of the session.
---@return string
function M.render()
	local ok, out = pcall(function()
		local inline = package.loaded["ducktape.inline"]
		-- Never required from here. The statusline is evaluated long before anything AI-related is
		-- touched, and loading the whole inline stack — providers, adapters, the pool — to draw an
		-- empty segment would put that cost on every startup.
		if not inline then
			return ""
		end

		local counts = inline.counts()
		if counts.total == 0 then
			return ""
		end

		local cfg = require("ducktape.config").get().statusline
		local segments = {}
		if cfg.label and cfg.label ~= "" then
			table.insert(segments, ("%%#DucktapeListDim#%s%%*"):format(cfg.label))
		end
		for _, part in ipairs(cfg.icons or {}) do
			local n = counts[part.key]
			if n and n > 0 then
				table.insert(segments, ("%%#%s#%d%s%%*"):format(part.hl, n, part.icon))
			end
		end
		if #segments == 0 then
			return ""
		end
		return " " .. table.concat(segments, " ") .. " "
	end)
	return ok and out or ""
end

---What the counts mean, for `<leader>cL`'s footer and the docs to stay honest about.
---
---Built from the configured icons rather than written out, so a customised segment does not get a
---legend explaining symbols it no longer uses.
---@return string
function M.legend()
	local ok, out = pcall(function()
		local icons = {}
		for _, part in ipairs(require("ducktape.config").get().statusline.icons or {}) do
			icons[part.key] = part.icon
		end
		return (" %s running · %s answered or waiting on you · %s failed "):format(
			icons.running or "↻",
			icons.answered or "◆",
			icons.failed or "✖"
		)
	end)
	return ok and out or " ↻ running · ◆ answered or waiting on you · ✖ failed "
end

return M
