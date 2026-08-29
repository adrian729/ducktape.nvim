-- Standing signal for inline activity; empty when there is nothing to say.

local M = {}

---Statusline expression evaluated on every redraw. Returns nothing on failure: an error here
---would break the bar for the rest of the session.
---@return string
function M.render()
	local ok, out = pcall(function()
		local inline = package.loaded["ducktape.inline"]
		-- Avoid loading the inline stack during startup just to draw an empty segment.
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

---Legend for `<leader>cL`'s footer, built from configured icons so remapped symbols stay honest.
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
