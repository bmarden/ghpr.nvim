if vim.g.loaded_ghpr then
	return
end
vim.g.loaded_ghpr = true

---Parse an optional PR number from a command's args.
---@param args string
---@return integer?
local function pr_number(args)
	if args == nil or args == "" then
		return nil
	end
	return tonumber(args)
end

vim.api.nvim_create_user_command("GhPrCreate", function()
	require("ghpr").create()
end, { desc = "Create a GitHub PR from the current branch" })

vim.api.nvim_create_user_command("GhPrView", function(o)
	require("ghpr").view(pr_number(o.args))
end, { nargs = "?", desc = "View a PR description (default: current branch PR)" })

vim.api.nvim_create_user_command("GhPrEdit", function(o)
	require("ghpr").edit(pr_number(o.args))
end, { nargs = "?", desc = "Edit a PR description (default: current branch PR)" })

vim.api.nvim_create_user_command("GhPrAddReviewer", function(o)
	require("ghpr").add_reviewer(pr_number(o.args))
end, { nargs = "?", desc = "Add a reviewer to a PR (default: current branch PR)" })

vim.api.nvim_create_user_command("GhPrList", function()
	require("ghpr").pick()
end, { desc = "Pick a PR from a list with description preview" })

vim.api.nvim_create_user_command("GhPrReview", function(o)
	require("ghpr").review(pr_number(o.args))
end, { nargs = "?", desc = "Open a PR for review (codediff; default: current branch PR)" })

vim.api.nvim_create_user_command("GhPrReviewClose", function()
	require("ghpr").close_review()
end, { desc = "Close the current PR review session" })

vim.api.nvim_create_user_command("GhPrReviewRefresh", function()
	require("ghpr").refresh()
end, { desc = "Refresh PR review data from GitHub" })

vim.api.nvim_create_user_command("GhPrReviewStats", function()
	require("ghpr.review.actions").show_stats()
end, { desc = "Show review statistics" })
