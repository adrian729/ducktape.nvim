-- The spec lazy.nvim reads for this plugin, so a user only has to name it.
--
-- `lazy = false` is required, not a preference: lazy.nvim sources a plugin's `plugin/` directory
-- only when it loads the plugin, and `plugin/ducktape.lua` is what creates the keymaps, the command
-- and the statusline segment. It is a cheap file — mappings and a string append, no require of the
-- core — so being a start plugin costs nothing measurable.
--
-- codecompanion is deliberately NOT a dependency here. Dependencies of a `lazy = false` plugin load
-- eagerly at startup, which would drag codecompanion's whole setup into the startup path. It is
-- meant to stay deferred and be pulled in by the first ducktape action, so the user declares it
-- themselves with its own trigger and lists ducktape in its `extensions`. See the README.
return {
	{
		"adrian729/ducktape.nvim",
		lazy = false,
		dependencies = {
			"nvim-lua/plenary.nvim",
			-- Not optional: Neovim ships no markdown parser, and without markdown/markdown_inline
			-- the chat does not render and editing a sent message silently does nothing.
			"nvim-treesitter/nvim-treesitter",
			-- The chat list and both model pickers need it; everything else works without it.
			"nvim-telescope/telescope.nvim",
		},
	},
}
