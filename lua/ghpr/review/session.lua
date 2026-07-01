-- PR review session orchestration (codediff-based review)
local M = {}

-- Extract the repo-relative file path from a CodeDiff buffer.
-- Works for both virtual codediff:// URIs (left/old side) and real file
-- buffers (right/new side when the head branch is checked out locally).
local codediff_pattern = "^codediff:////.-///[^/]+/(.+)$"

function M.get_codediff_file_path(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end

	local bufname = vim.api.nvim_buf_get_name(bufnr)

	-- Virtual codediff:// buffer (old/left side)
	local path = bufname:match(codediff_pattern)
	if path then
		return path
	end

	-- For real file buffers (right/new side when head is checked out locally),
	-- check if the buffer is displayed in a CodeDiff diff window.
	local ok, lifecycle = pcall(require, "codediff.ui.lifecycle.accessors")
	if not ok then
		return nil
	end

	local tabpage = vim.api.nvim_get_current_tabpage()
	local orig_win, mod_win = lifecycle.get_windows(tabpage)
	if not orig_win and not mod_win then
		return nil
	end

	-- Check if this buffer is in one of the diff windows
	local buf_in_diff = false
	if orig_win and vim.api.nvim_win_is_valid(orig_win) and vim.api.nvim_win_get_buf(orig_win) == bufnr then
		buf_in_diff = true
	end
	if mod_win and vim.api.nvim_win_is_valid(mod_win) and vim.api.nvim_win_get_buf(mod_win) == bufnr then
		buf_in_diff = true
	end

	if not buf_in_diff then
		return nil
	end

	-- Derive repo-relative path from the absolute file path
	local git_root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]
	if not git_root or git_root == "" then
		return nil
	end

	local rel_path = bufname:gsub("^" .. vim.pesc(git_root) .. "/", "")
	if rel_path ~= bufname then
		return rel_path
	end

	return nil
end

-- Setup buffer-local keymaps for PR review
local function setup_buffer_keymaps(bufnr)
	-- Skip if already set up
	if vim.b[bufnr].ghpr_review_active then
		return
	end

	local config = require("ghpr.config")
	local actions = require("ghpr.review.actions")
	local comments_actions = require("ghpr.review.comments_actions")

	local keymap_opts = { buffer = bufnr, silent = true, noremap = true }
	local km = config.options.review_keymaps

	-- Toggle viewed state
	vim.keymap.set("n", km.toggle_viewed, function()
		actions.toggle_viewed()
	end, vim.tbl_extend("force", keymap_opts, { desc = "Toggle file viewed state" }))

	-- Navigate unviewed files
	vim.keymap.set("n", km.next_unviewed, function()
		actions.next_unviewed()
	end, vim.tbl_extend("force", keymap_opts, { desc = "Next unviewed file" }))

	vim.keymap.set("n", km.prev_unviewed, function()
		actions.prev_unviewed()
	end, vim.tbl_extend("force", keymap_opts, { desc = "Previous unviewed file" }))

	-- Close review
	vim.keymap.set("n", km.close_review, function()
		M.close_review()
	end, vim.tbl_extend("force", keymap_opts, { desc = "Close review session" }))

	-- Comment actions
	vim.keymap.set({ "n", "v" }, km.add_comment, function()
		comments_actions.add_comment()
	end, vim.tbl_extend("force", keymap_opts, { desc = "Add comment or reply" }))

	vim.keymap.set("n", km.delete_comment, function()
		comments_actions.delete_comment()
	end, vim.tbl_extend("force", keymap_opts, { desc = "Delete comment" }))

	vim.keymap.set("n", km.edit_comment, function()
		comments_actions.edit_comment()
	end, vim.tbl_extend("force", keymap_opts, { desc = "Edit comment" }))

	vim.keymap.set("n", km.show_thread_detail, function()
		comments_actions.toggle_thread_detail()
	end, vim.tbl_extend("force", keymap_opts, { desc = "Show thread detail" }))

	-- Mark buffer as part of review session
	vim.b[bufnr].ghpr_review_active = true
end

-- Clear all review keymaps from buffers that have ghpr_review_active flag
local function clear_all_keymaps()
	local config = require("ghpr.config")
	local count = 0
	local buffers_cleared = {}
	local km = config.options.review_keymaps

	local keymaps_to_delete = {
		km.toggle_viewed,
		km.next_unviewed,
		km.prev_unviewed,
		km.close_review,
		km.add_comment,
		km.delete_comment,
		km.edit_comment,
		km.show_thread_detail,
	}

	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].ghpr_review_active then
			count = count + 1
			table.insert(buffers_cleared, bufnr)

			-- Delete each keymap (try each mode separately so a missing mode
			-- does not block another).
			for _, keymap in ipairs(keymaps_to_delete) do
				for _, mode in ipairs({ "n", "v" }) do
					pcall(vim.keymap.del, mode, keymap, { buffer = bufnr })
				end
			end
		end
	end

	vim.notify(string.format("Cleared keymaps from %d buffers", count), vim.log.levels.DEBUG)
end

-- Open a PR for review
function M.review_pr(pr_number)
	if not pr_number then
		vim.notify("PR number is required", vim.log.levels.ERROR)
		return
	end

	-- Detect PR context from git
	local pr_ctx, err = require("ghpr.git").detect_context(pr_number)
	if not pr_ctx then
		vim.notify("Failed to detect PR context: " .. err, vim.log.levels.ERROR)
		return
	end

	vim.notify(string.format("Loading PR #%d from %s/%s...", pr_number, pr_ctx.owner, pr_ctx.repo), vim.log.levels.INFO)

	-- Fetch PR files from GitHub
	require("ghpr.review.api").get_pr_files(pr_ctx.owner, pr_ctx.repo, pr_number, function(data, fetch_err)
		if fetch_err then
			vim.notify("Failed to fetch PR data: " .. fetch_err, vim.log.levels.ERROR)
			return
		end

		if not data or not data.files then
			vim.notify("No files found in PR", vim.log.levels.WARN)
			return
		end

		-- Initialize state tracking
		require("ghpr.review.state").initialize(pr_ctx.owner, pr_ctx.repo, pr_number, data)

		-- Helper to render comments on all open CodeDiff buffers
		local function render_all_comments()
			local pr = vim.g.ghpr_active_pr
			if not pr then
				return
			end
			for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
				if vim.api.nvim_buf_is_valid(bufnr) then
					local file_path = M.get_codediff_file_path(bufnr)
					if file_path then
						require("ghpr.review.comments_ui").render_inline_comments(
							bufnr, pr.owner, pr.repo, pr.number, file_path
						)
					end
				end
			end
		end

		-- Fetch and initialize comments
		require("ghpr.review.comments").fetch_comments(
			pr_ctx.owner,
			pr_ctx.repo,
			pr_number,
			function(threads, comment_err)
				if comment_err then
					vim.notify("Warning: Failed to fetch comments: " .. comment_err, vim.log.levels.WARN)
					return
				end

				vim.notify(
					string.format("Loaded %d comment threads", threads and #threads or 0),
					vim.log.levels.INFO
				)

				-- Render on any buffers that already exist, plus a deferred
				-- pass for buffers CodeDiff may still be creating
				render_all_comments()
				vim.defer_fn(render_all_comments, 500)
			end
		)

		-- Open CodeDiff with PR context
		local success = require("ghpr.review.diff").open_pr_diff(pr_ctx, data)

		if success then
			-- Clear any existing autocmds first to prevent duplicates
			local augroup = vim.api.nvim_create_augroup("Ghpr", { clear = true })

			vim.api.nvim_create_autocmd("BufEnter", {
				group = augroup,
				callback = function(args)
					local pr = vim.g.ghpr_active_pr
					-- Skip compose windows
					if vim.b[args.buf].ghpr_compose_window then
						return
					end
					if not pr then
						return
					end

					if not vim.b[args.buf].ghpr_review_active then
						setup_buffer_keymaps(args.buf)
					end

					-- Render comments for diff buffers on every BufEnter
					local file_path = M.get_codediff_file_path(args.buf)

					if file_path then
						vim.defer_fn(function()
							require("ghpr.review.comments_ui").render_inline_comments(
								args.buf,
								pr.owner,
								pr.repo,
								pr.number,
								file_path
							)
						end, 100)
					end
				end,
			})

			-- Also set up TabClosed to clean up when user presses 'q' in CodeDiff
			vim.api.nvim_create_autocmd("TabClosed", {
				group = augroup,
				callback = function()
					if vim.g.ghpr_active_pr then
						vim.defer_fn(function()
							M.close_review()
						end, 0)
					end
				end,
			})

			-- Update indicators after CodeDiff renders
			vim.defer_fn(function()
				require("ghpr.review.indicators").update()
			end, 150)
			vim.defer_fn(function()
				require("ghpr.review.indicators").update()
			end, 500)
		end
	end)
end

-- Close the current review session
function M.close_review()
	local pr = vim.g.ghpr_active_pr

	if pr then
		-- Clear state
		require("ghpr.review.state").clear(pr.owner, pr.repo, pr.number)

		-- Clear comments state
		require("ghpr.review.comments").clear(pr.owner, pr.repo, pr.number)

		-- Clear all review keymaps (from tracked buffers)
		clear_all_keymaps()

		-- Clear buffer-local flags and comment UI from ALL buffers
		for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(bufnr) then
				vim.b[bufnr].ghpr_review_active = nil
				vim.b[bufnr].ghpr_compose_window = nil
				require("ghpr.review.comments_ui").clear_comments(bufnr)
			end
		end
	end

	-- Clear the autocmds to prevent re-application
	pcall(vim.api.nvim_clear_autocmds, { group = "Ghpr" })

	-- Clear the global PR variable
	vim.g.ghpr_active_pr = nil

	-- Close CodeDiff (this will close the tab and delete buffers)
	require("ghpr.review.diff").close_review()

	vim.notify("Review session closed", vim.log.levels.INFO)
end

-- Refresh PR data from GitHub
function M.refresh()
	local active_pr = vim.g.ghpr_active_pr
	if not active_pr then
		vim.notify("No active PR review session", vim.log.levels.WARN)
		return
	end

	-- Invalidate cache and reload
	require("ghpr.review.api").invalidate_cache(active_pr.owner, active_pr.repo, active_pr.number)
	vim.notify("Cache invalidated. Use :GhprReviewPR to reload.", vim.log.levels.INFO)
end

return M
