-- lazy.nvim spec for this plugin.
--
-- `lazy = false` is required: lazy.nvim sources `plugin/` only when loading the plugin, and
-- plugin/ducktape.lua sets up keymaps, command, and statusline segment.
--
-- codecompanion is intentionally not a dependency: dependencies of a `lazy = false` plugin load
-- eagerly, which would defeat deferral. The user declares it separately and lists ducktape in its
-- `extensions`. See the README.
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
