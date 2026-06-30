-- Visual indicators for viewed/unviewed state in CodeDiff explorer
local M = {}

local ns_id = vim.api.nvim_create_namespace("ghpr_indicators")

-- Debug flag - set to true to enable logging
local DEBUG = false

local function debug_log(...)
	if DEBUG then
		print("[Ghpr]", ...)
	end
end

-- Track if we've hooked into CodeDiff
local codediff_hooked = false
local original_prepare_node = nil

-- Parse filename from explorer line
local function parse_filename_from_line(line)
	-- Skip empty lines
	if not line or line == "" then
		return nil
	end

	-- Skip group headers (Changes, Staged Changes, etc.)
	if line:match("Changes") then
		return nil
	end

	-- Split line into non-whitespace parts
	local parts = {}
	for part in line:gmatch("%S+") do
		table.insert(parts, part)
	end

	-- Need at least: icon, filename, something-else
	if #parts < 3 then
		return nil
	end

	local filename = parts[2]

	return filename
end

-- Build a lookup table of file paths by filename
local function build_filename_lookup(pr)
	local state = require("ghpr.review.state")
	local files = state.get_files(pr.owner, pr.repo, pr.number)
	local lookup = {}

	for _, file in ipairs(files) do
		local filename = file.path:match("([^/]+)$")
		if filename then
			-- Store all paths that have this filename
			if not lookup[filename] then
				lookup[filename] = {}
			end
			table.insert(lookup[filename], file.path)
		end
	end

	return lookup
end

-- Update indicators for a single buffer
function M.update_buffer(bufnr)
	debug_log("update_buffer called for bufnr:", bufnr)

	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		debug_log("  Buffer invalid")
		return
	end

	local pr = vim.g.ghpr_active_pr
	if not pr then
		debug_log("  No active PR")
		return
	end

	-- Check if buffer has content
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	debug_log("  Line count:", line_count)

	if line_count == 0 or line_count == 1 then
		-- Buffer might still be loading, defer update
		debug_log("  Buffer loading, deferring...")
		vim.defer_fn(function()
			if vim.api.nvim_buf_is_valid(bufnr) then
				M.update_buffer(bufnr)
			end
		end, 50)
		return
	end

	local state = require("ghpr.review.state")
	local config = require("ghpr.config")

	-- Clear existing extmarks
	local old_marks = vim.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {})
	debug_log("  Clearing", #old_marks, "old extmarks")
	vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

	-- Build filename lookup for tree mode
	local filename_lookup = build_filename_lookup(pr)

	-- Get all lines in the buffer
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	debug_log("  Processing", #lines, "lines")

	local marks_added = 0
	for i, line in ipairs(lines) do
		local filename = parse_filename_from_line(line)
		if filename then
			-- Look up all files that match this filename
			local matches = filename_lookup[filename]
			if matches and #matches > 0 then
				local is_viewed = false

				if #matches == 1 then
					-- Unique filename, use the full path
					is_viewed = state.is_viewed(pr.owner, pr.repo, pr.number, matches[1])
				else
					-- Multiple files with same filename
					local all_viewed = true

					for _, full_path in ipairs(matches) do
						if not state.is_viewed(pr.owner, pr.repo, pr.number, full_path) then
							all_viewed = false
							break
						end
					end

					is_viewed = all_viewed
				end

				local icon = is_viewed and config.options.signs.viewed or config.options.signs.unviewed
				local hl = is_viewed and "GhprViewed" or "GhprUnviewed"

				-- Add virtual text at the beginning of the line
				vim.api.nvim_buf_set_extmark(bufnr, ns_id, i - 1, 0, {
					virt_text = { { icon .. " ", hl } },
					virt_text_pos = "inline",
					priority = 100,
				})
				marks_added = marks_added + 1
			end
		end
	end
	debug_log("  Added", marks_added, "extmarks")
end

-- Update indicators by triggering CodeDiff refresh
function M.update()
	debug_log("Triggering CodeDiff refresh to update indicators")
	-- Get the explorer object and trigger refresh
	local ok, lifecycle = pcall(require, "codediff.ui.lifecycle.accessors")
	if not ok then
		debug_log("Could not load lifecycle module")
		return
	end

	local tabpage = vim.api.nvim_get_current_tabpage()
	local explorer = lifecycle.get_explorer(tabpage)
	if not explorer then
		debug_log("No explorer found for current tab")
		return
	end

	local ok_refresh, explorer_refresh = pcall(require, "codediff.ui.explorer.refresh")
	if ok_refresh and explorer_refresh.refresh then
		vim.schedule(function()
			explorer_refresh.refresh(explorer)
		end)
	end
end

-- Setup highlight groups
function M.setup_highlights()
	local config = require("ghpr.config")

	-- Create highlight groups that link to configured highlights
	vim.api.nvim_set_hl(0, "GhprViewed", { link = config.options.highlights.viewed })
	vim.api.nvim_set_hl(0, "GhprUnviewed", { link = config.options.highlights.unviewed })
end

-- Hook into CodeDiff's prepare_node to add indicators during rendering
local function hook_codediff_rendering()
	if codediff_hooked then
		return
	end

	local ok, nodes_module = pcall(require, "codediff.ui.explorer.nodes")
	if not ok then
		debug_log("Could not load CodeDiff nodes module")
		return
	end

	-- Save original prepare_node
	original_prepare_node = nodes_module.prepare_node

	-- Wrap prepare_node to add our indicators
	---@diagnostic disable-next-line: duplicate-set-field
	nodes_module.prepare_node = function(node, max_width, selected_path, selected_group)
		-- Call original to get the Line object
		local line = original_prepare_node(node, max_width, selected_path, selected_group)

		-- Only add indicators for file nodes (not groups or directories)
		if node.data and node.data.path and not node.data.type then
			local pr = vim.g.ghpr_active_pr
			if pr then
				local state = require("ghpr.review.state")
				local config = require("ghpr.config")

				-- Add viewed/unviewed indicator
				local is_viewed = state.is_viewed(pr.owner, pr.repo, pr.number, node.data.path)
				local icon = is_viewed and config.options.signs.viewed or config.options.signs.unviewed
				local hl = is_viewed and "GhprViewed" or "GhprUnviewed"
				table.insert(line._segments, 1, { text = icon .. " ", hl = hl })

				-- Add comment count badge if there are comments
				local ok_comments, comments = pcall(require, "ghpr.review.comments")
				if ok_comments then
					local threads = comments.get_threads_for_file(pr.owner, pr.repo, pr.number, node.data.path)
					if threads and #threads > 0 then
						-- Add comment count badge after the icon
						local badge = string.format("[%d] ", #threads)
						table.insert(line._segments, 2, { text = badge, hl = "GhprCommentCount" })
					end
				end
			end
		end

		return line
	end

	codediff_hooked = true
	debug_log("Hooked into CodeDiff prepare_node")
end

-- Unhook from CodeDiff
local function unhook_codediff_rendering()
	if not codediff_hooked then
		return
	end

	local ok, nodes_module = pcall(require, "codediff.ui.explorer.nodes")
	if ok and original_prepare_node then
		nodes_module.prepare_node = original_prepare_node
		codediff_hooked = false
		debug_log("Unhooked from CodeDiff")
	end
end

-- Setup autocmds to auto-update indicators
function M.setup()
	M.setup_highlights()

	-- Hook into CodeDiff's rendering to add indicators inline
	hook_codediff_rendering()

	local augroup = vim.api.nvim_create_augroup("GhprIndicators", { clear = true })

	-- Trigger CodeDiff refresh when viewed state changes
	vim.api.nvim_create_autocmd("User", {
		group = augroup,
		pattern = "GhprViewedStateChanged",
		callback = function()
			debug_log("Viewed state changed, triggering CodeDiff refresh")
			-- Get the explorer object and trigger refresh
			local ok, lifecycle = pcall(require, "codediff.ui.lifecycle.accessors")
			if not ok then
				debug_log("Could not load lifecycle module")
				return
			end

			local tabpage = vim.api.nvim_get_current_tabpage()
			local explorer = lifecycle.get_explorer(tabpage)
			if not explorer then
				debug_log("No explorer found for current tab")
				return
			end

			local ok_refresh, explorer_refresh = pcall(require, "codediff.ui.explorer.refresh")
			if ok_refresh and explorer_refresh.refresh then
				vim.schedule(function()
					explorer_refresh.refresh(explorer)
				end)
			end
		end,
	})
end

-- Clear all indicators
function M.clear()
	unhook_codediff_rendering()
end

return M
