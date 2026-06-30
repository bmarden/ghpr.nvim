local M = {}

local defaults = {
	gh_cli_path = "gh",
	base_branch = "main",
	remote = "origin",

	-- Review feature (codediff) data cache TTL in seconds.
	cache_ttl = 300,

	codediff = {
		show_viewed_files = true, -- Show viewed files in explorer
		use_merge_base = true, -- Use base...HEAD syntax
		explorer_position = "left",
	},

	-- Global keymaps set in setup(). Set a value to false to disable.
	keymaps = {
		pick_prs = "<leader>gp", -- Open the PR picker
	},

	-- Buffer-local keymaps active only during a codediff review session.
	review_keymaps = {
		toggle_viewed = "<leader>gv",
		next_unviewed = "]u",
		prev_unviewed = "[u",
		close_review = "<leader>gq",
		add_comment = "a",
		delete_comment = "d",
		edit_comment = "e",
		show_thread_detail = "t",
	},

	notifications = {
		enabled = true,
		level = vim.log.levels.INFO,
	},

	signs = {
		viewed = "✓",
		unviewed = "○",
	},

	highlights = {
		viewed = "Comment",
		unviewed = "Normal",
	},

	comments = {
		show_resolved = true,
		show_outdated = false,
		inline_max_length = 80,
	},
}

M.options = vim.deepcopy(defaults)

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", defaults, opts or {})
end

return M
