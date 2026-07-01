-- CodeDiff integration layer
local M = {}

-- Launch CodeDiff with PR context
function M.open_pr_diff(pr_ctx, files_data)
	local config = require("ghpr.config")

	-- Get base and head refs from PR metadata (these are the actual branch refs from GitHub)
	local base_ref = files_data.pr_metadata.base_ref or pr_ctx.base_branch
	local head_ref = files_data.pr_metadata.head_ref or pr_ctx.head_branch

	-- Store PR context globally for the session
	vim.g.ghpr_active_pr = {
		number = pr_ctx.pr_number,
		owner = pr_ctx.owner,
		repo = pr_ctx.repo,
		base_branch = base_ref,
		head_branch = head_ref,
	}

	-- Build revision string
	-- Check if the head ref matches the currently checked-out branch.
	-- If so, use single-revision syntax (base only) so CodeDiff compares
	-- against the working tree. This allows LSP to attach to the real file
	-- buffers on the right side, since two-revision syntax makes both sides
	-- virtual codediff:// buffers that LSP won't attach to.
	local current_branch = vim.fn
		.system(string.format("git -C %s rev-parse --abbrev-ref HEAD", vim.fn.shellescape(pr_ctx.git_root)))
		:gsub("%s+$", "")
	local head_is_local = current_branch == head_ref

	local base_revision = "origin/" .. base_ref
	local revision
	if head_is_local then
		-- Single-revision: compare merge-base against working tree
		revision = base_revision
	elseif config.options.codediff.use_merge_base then
		revision = string.format("%s...%s", base_revision, "origin/" .. head_ref)
	else
		revision = string.format("%s..%s", base_revision, "origin/" .. head_ref)
	end

	-- Fetch latest from origin to ensure we have the refs
	vim.notify("Fetching latest changes from origin...", vim.log.levels.INFO)
	vim.fn.system(
		string.format(
			"git -C %s fetch origin %s %s 2>/dev/null",
			vim.fn.shellescape(pr_ctx.git_root),
			base_ref,
			head_ref
		)
	)

	-- Launch CodeDiff from git root so it can find files
	local original_cwd = vim.fn.getcwd()
	vim.cmd("cd " .. vim.fn.fnameescape(pr_ctx.git_root))

	vim.notify(string.format("Opening diff: %s", revision), vim.log.levels.DEBUG)
	local ok, err = pcall(function()
		vim.cmd("CodeDiff " .. revision)
	end)

	-- Restore global cwd, then set tab-local cwd for the CodeDiff tab
	-- This keeps LSP working by giving the tab the correct project root
	vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
	vim.cmd("tcd " .. vim.fn.fnameescape(pr_ctx.git_root))

	if not ok then
		vim.notify("Failed to launch CodeDiff: " .. tostring(err), vim.log.levels.ERROR)
		vim.g.ghpr_active_pr = nil
		return false
	end

	vim.notify(
		string.format("Opened PR #%d for review (%d files)", pr_ctx.pr_number, #files_data.files),
		vim.log.levels.INFO
	)

	return true
end

-- Close PR review session
function M.close_review()
	-- Try to close the CodeDiff tab by sending 'q' command
	local ok = pcall(vim.cmd, "tabclose")

	if not ok then
		vim.notify("Could not close diff tab", vim.log.levels.DEBUG)
	end
end

return M
