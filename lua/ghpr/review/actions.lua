-- User actions for viewed state management
local M = {}

-- Get file path from CodeDiff explorer using the tree API
local function get_path_from_explorer()
	-- Check if we're in a CodeDiff explorer buffer
	local ft = vim.bo.filetype
	if ft ~= "codediff-explorer" then
		return nil
	end

	-- Get the explorer object for the current tab
	local ok, lifecycle = pcall(require, "codediff.ui.lifecycle.accessors")
	if not ok then
		return nil
	end

	local tabpage = vim.api.nvim_get_current_tabpage()
	local explorer = lifecycle.get_explorer(tabpage)
	if not explorer or not explorer.tree then
		return nil
	end

	-- Get the currently selected node
	local node = explorer.tree:get_node()
	if not node or not node.data then
		return nil
	end

	-- Only return path for file nodes (not groups or directories)
	if node.data.path and not node.data.type then
		return node.data.path
	end

	return nil
end

-- Extract file path from CodeDiff buffer name or regular buffer
-- Returns: (file_path, line_number, error)
local function get_current_file_path()
	local bufname = vim.fn.expand("%:p")
	local cursor = vim.api.nvim_win_get_cursor(0)
	local line = cursor[1] -- 1-indexed

	-- Check if this is a CodeDiff file buffer
	-- Format: codediff:////path/to/repo///commit_hash/relative/path
	local codediff_pattern = "^codediff:////.-///[^/]+/(.+)$"
	local codediff_path = bufname:match(codediff_pattern)

	if codediff_path then
		return codediff_path, line, nil
	end

	-- Check if we're in the CodeDiff explorer
	local explorer_path = get_path_from_explorer()
	if explorer_path then
		return explorer_path, nil, nil -- No line number in explorer
	end

	-- Check if buffer name is empty (unnamed buffer)
	if bufname == "" or bufname:match("^%s*$") then
		return nil, nil, "No file associated with current buffer"
	end

	-- Regular buffer - get git root and make path relative
	local git_root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]

	if not git_root or git_root == "" then
		return nil, nil, "Failed to get git root"
	end

	local rel_path = bufname:gsub("^" .. vim.pesc(git_root) .. "/", "")

	-- If path didn't change, it wasn't under git root
	if rel_path == bufname then
		return nil, nil, "File not in git repository"
	end

	return rel_path, line, nil
end

-- Toggle viewed state for current file
function M.toggle_viewed()
	local pr = vim.g.ghpr_active_pr
	if not pr then
		vim.notify("No active PR review session", vim.log.levels.WARN)
		return
	end

	-- Get current file path
	local file_path, err = get_current_file_path()
	if not file_path then
		---@diagnostic disable-next-line: param-type-mismatch
		vim.notify(err or "Failed to get file path", vim.log.levels.ERROR)
		return
	end

	-- Get current state
	local state = require("ghpr.review.state")
	local is_viewed = state.is_viewed(pr.owner, pr.repo, pr.number, file_path)
	local new_state = not is_viewed

	-- Optimistic update
	local success, previous_state = state.set_viewed_optimistic(pr.owner, pr.repo, pr.number, file_path, new_state)

	if not success then
		return
	end

	-- Refresh indicators immediately after optimistic update
	M.refresh_indicators()

	-- Sync with GitHub
	local api = require("ghpr.review.api")
	api.mark_file_viewed(pr.owner, pr.repo, pr.number, file_path, new_state, function(sync_err)
		if sync_err then
			-- Rollback on failure
			state.rollback_viewed(pr.owner, pr.repo, pr.number, file_path, previous_state)
			vim.notify("Failed to sync with GitHub: " .. sync_err, vim.log.levels.ERROR)
			-- Refresh again after rollback
			M.refresh_indicators()
		else
			-- Confirm success
			state.confirm_viewed(pr.owner, pr.repo, pr.number, file_path)
		end
	end)
end

-- Jump to next unviewed file
function M.next_unviewed()
	local pr = vim.g.ghpr_active_pr
	if not pr then
		vim.notify("No active PR review session", vim.log.levels.WARN)
		return
	end

	local state = require("ghpr.review.state")
	local unviewed = state.get_unviewed_files(pr.owner, pr.repo, pr.number)

	if #unviewed == 0 then
		vim.notify("No unviewed files remaining", vim.log.levels.INFO)
		return
	end

	-- Get current file using shared helper
	local current_file = get_current_file_path()
	local git_root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]

	-- Find next unviewed file after current
	local found_current = false
	local next_file = nil

	for _, file in ipairs(unviewed) do
		if found_current then
			next_file = file.path
			break
		end
		if file.path == current_file then
			found_current = true
		end
	end

	-- Wrap around to first if we didn't find one after current
	if not next_file then
		next_file = unviewed[1].path
	end

	-- Open the file
	vim.cmd("edit " .. vim.fn.fnameescape(git_root .. "/" .. next_file))
	vim.notify(string.format("Next unviewed: %s", next_file), vim.log.levels.INFO)
end

-- Jump to previous unviewed file
function M.prev_unviewed()
	local pr = vim.g.ghpr_active_pr
	if not pr then
		vim.notify("No active PR review session", vim.log.levels.WARN)
		return
	end

	local state = require("ghpr.review.state")
	local unviewed = state.get_unviewed_files(pr.owner, pr.repo, pr.number)

	if #unviewed == 0 then
		vim.notify("No unviewed files remaining", vim.log.levels.INFO)
		return
	end

	-- Get current file using shared helper
	local current_file = get_current_file_path()
	local git_root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]

	-- Find previous unviewed file before current
	local prev_file = nil

	for i = #unviewed, 1, -1 do
		if unviewed[i].path == current_file then
			break
		end
		prev_file = unviewed[i].path
	end

	-- Wrap around to last if we didn't find one before current
	if not prev_file then
		prev_file = unviewed[#unviewed].path
	end

	-- Open the file
	vim.cmd("edit " .. vim.fn.fnameescape(git_root .. "/" .. prev_file))
	vim.notify(string.format("Previous unviewed: %s", prev_file), vim.log.levels.INFO)
end

-- Show review statistics
function M.show_stats()
	local pr = vim.g.ghpr_active_pr
	if not pr then
		vim.notify("No active PR review session", vim.log.levels.WARN)
		return
	end

	local state = require("ghpr.review.state")
	local stats = state.get_stats(pr.owner, pr.repo, pr.number)

	local message = string.format(
		"PR #%d Review Progress:\n  Total: %d files\n  Viewed: %d\n  Unviewed: %d\n  Pending sync: %d",
		pr.number,
		stats.total,
		stats.viewed,
		stats.unviewed,
		stats.pending
	)

	vim.notify(message, vim.log.levels.INFO)
end

-- Refresh visual indicators
function M.refresh_indicators()
	require("ghpr.review.indicators").update()
end

return M
