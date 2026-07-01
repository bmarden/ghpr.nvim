local M = {}

local did_setup = false

function M.setup(opts)
	require("ghpr.config").setup(opts)

	if did_setup then
		return
	end
	did_setup = true

	local config = require("ghpr.config")

	-- Review feature: highlights + comment highlights + codediff hook.
	require("ghpr.review.indicators").setup()
	require("ghpr.review.comments_ui").setup_highlights()

	-- Global keymaps.
	local keys = config.options.keymaps or {}
	if keys.pick_prs then
		vim.keymap.set("n", keys.pick_prs, function()
			M.pick()
		end, { desc = "ghpr: pick PRs" })
	end
end

-- Create a PR from the current branch.
function M.create()
	require("ghpr.ui").open()
end

-- View a PR description (nil -> current branch PR).
function M.view(number)
	require("ghpr.description").view(number)
end

-- Edit a PR description.
function M.edit(number)
	require("ghpr.description").edit(number)
end

-- Add reviewers to a PR.
function M.add_reviewer(number)
	require("ghpr.reviewers").add(number)
end

-- Open the snacks PR picker.
function M.pick()
	require("ghpr.picker").open()
end

-- Open a PR for codediff review. With no number, resolves the PR for the
-- current branch.
function M.review(number)
	if number then
		require("ghpr.review.session").review_pr(number)
		return
	end

	require("ghpr.gh").get_pr(nil, function(pr, err)
		if err or not pr then
			vim.notify("ghpr: no PR found for the current branch (" .. (err or "unknown") .. ")", vim.log.levels.ERROR)
			return
		end
		require("ghpr.review.session").review_pr(pr.number)
	end)
end

-- Close the active review session.
function M.close_review()
	require("ghpr.review.session").close_review()
end

-- Refresh review data.
function M.refresh()
	require("ghpr.review.session").refresh()
end

return M
