-- Comment UI rendering and display
local M = {}

-- Namespace for comment extmarks
local ns_comments = vim.api.nvim_create_namespace("ghpr_comments")

-- Setup highlight groups
function M.setup_highlights()
	vim.api.nvim_set_hl(0, "GhprCommentThread", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "GhprCommentAuthor", { link = "Special", default = true })
	vim.api.nvim_set_hl(0, "GhprCommentBody", { link = "Normal", default = true })
	vim.api.nvim_set_hl(0, "GhprCommentUnresolved", { link = "WarningMsg", default = true })
	vim.api.nvim_set_hl(0, "GhprCommentCount", { link = "DiagnosticHint", default = true })
end

-- Format a comment for display
local function format_comment(comment, max_length)
	local author = comment.author and comment.author.login or "unknown"
	local body = comment.body or ""

	-- Truncate body if too long
	if max_length and #body > max_length then
		body = body:sub(1, max_length) .. "..."
	end

	-- Replace newlines with spaces for inline display
	body = body:gsub("\n", " ")

	return string.format("@%s: %s", author, body)
end

-- Format thread for inline display
local function format_thread(thread, config)
	if not thread or not thread.comments or #thread.comments == 0 then
		return nil
	end

	local max_length = config.options.comments.inline_max_length or 80
	local first_comment = thread.comments[1]
	local formatted = format_comment(first_comment, max_length)

	-- Add reply indicator if there are more comments
	if #thread.comments > 1 then
		formatted = formatted .. string.format(" (+ %d replies)", #thread.comments - 1)
	end

	-- Add resolution status
	if not thread.isResolved then
		formatted = "⚠️ " .. formatted
	else
		formatted = "💬 " .. formatted
	end

	return formatted
end

-- Determine if a buffer is the original (LEFT) or modified (RIGHT) side in CodeDiff
local function get_buf_diff_side(bufnr)
	local ok, lifecycle = pcall(require, "codediff.ui.lifecycle.accessors")
	if not ok then
		return nil
	end
	local tabpage = vim.api.nvim_get_current_tabpage()
	local original_bufnr, modified_bufnr = lifecycle.get_buffers(tabpage)
	if bufnr == original_bufnr then
		return "LEFT"
	elseif bufnr == modified_bufnr then
		return "RIGHT"
	end
	return nil
end

-- Format an ISO 8601 timestamp as a relative "time ago" string.
---@param created_at string|nil ISO 8601 timestamp from GitHub (e.g. "2026-04-15T14:23:11Z")
---@return string
local function format_time_ago(created_at)
	if created_at == nil then
		return "unknown time"
	end

	local pattern = "(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)"
	local year, month, day, hour, min, sec = created_at:match(pattern)
	if not (year and month and day and hour and min and sec) then
		return "invalid time"
	end
	local y = tonumber(year)
	local mo = tonumber(month)
	local d = tonumber(day)
	local h = tonumber(hour)
	local mi = tonumber(min)
	local s = tonumber(sec)
	if not (y and mo and d and h and mi and s) then
		return "invalid time"
	end

	local created_time = os.time({
		year = y,
		month = mo,
		day = d,
		hour = h,
		min = mi,
		sec = s,
		isdst = false, -- treat fields as non-DST local
	})
	local now = os.time()
	local utc_now_components = os.date("!*t", now)
	utc_now_components.isdst = false -- treat as non-DST UTC
	---@diagnostic disable-next-line: param-type-mismatch
	local utc_offset = os.difftime(now, os.time(utc_now_components))
	created_time = created_time + utc_offset

	local diff = os.time() - created_time

	local local_str = os.date("%Y-%m-%d %H:%M:%S", created_time)
	if diff < 60 then
		return string.format("%ds ago (%s)", diff, local_str)
	elseif diff < 3600 then
		return string.format("%dm ago (%s)", math.floor(diff / 60), local_str)
	elseif diff < 86400 then
		return string.format("%dh ago (%s)", math.floor(diff / 3600), local_str)
	elseif diff < 2592000 then
		return string.format("%dd ago (%s)", math.floor(diff / 86400), local_str)
	else
		return string.format("%s", local_str)
	end
end

M._format_time_ago = format_time_ago

-- Render inline comments for a diff buffer (as virtual lines, not end-of-line text)
function M.render_inline_comments(bufnr, owner, repo, pr_number, file_path)
	local config = require("ghpr.config")
	local comments = require("ghpr.review.comments")

	-- Skip if comments are not configured to show
	if not config.options.comments then
		return
	end

	-- Validate buffer
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- Clear existing comment marks
	vim.api.nvim_buf_clear_namespace(bufnr, ns_comments, 0, -1)

	-- Get threads for this file
	local threads = comments.get_threads_for_file(owner, repo, pr_number, file_path)

	-- Determine which diff side this buffer represents so we only render matching threads
	local buf_side = get_buf_diff_side(bufnr)

	if not threads or #threads == 0 then
		return
	end

	-- Sort threads by line number (descending so we render from bottom to top)
	table.sort(threads, function(a, b)
		return (a.line or 0) > (b.line or 0)
	end)

	-- Render each thread
	for _, thread in ipairs(threads) do
		-- Skip resolved/outdated threads if configured
		if config.options.comments.show_resolved == false and thread.isResolved then
			goto continue
		end

		if config.options.comments.show_outdated == false and thread.isOutdated then
			goto continue
		end

		-- Only render thread on the correct diff side
		if buf_side and thread.diffSide and thread.diffSide ~= buf_side then
			goto continue
		end

		if thread.line and thread.comments and #thread.comments > 0 then
			local line_num = thread.line - 1 -- Convert to 0-indexed

			-- Ensure line exists in buffer
			local line_count = vim.api.nvim_buf_line_count(bufnr)

			if line_num >= 0 and line_num < line_count then
				-- Build comment box lines with proper borders
				local comment_lines = {}
				local box_width = 80
				local content_width = box_width - 4 -- Account for "│ " and " │"

				local border_hl = thread.isResolved and "GhprCommentThread" or "GhprCommentUnresolved"

				-- Helper function to wrap text to fit within content_width
				local function wrap_text(text, width)
					local lines = {}
					-- First split by existing newlines
					for line in text:gmatch("[^\r\n]+") do
						-- Then wrap long lines
						while #line > 0 do
							if #line <= width then
								table.insert(lines, line)
								break
							else
								-- Find last space within width
								local break_at = width
								local last_space = line:sub(1, width):match("^.*()%s")
								if last_space and last_space > width * 0.6 then -- Only break at space if it's not too early
									break_at = last_space - 1
								end
								table.insert(lines, line:sub(1, break_at))
								line = line:sub(break_at + 1):match("^%s*(.*)") -- Trim leading space on next line
							end
						end
					end
					return lines
				end

				-- Helper to create a bordered line
				local function bordered_line(content, hl)
					local padding = content_width - vim.fn.strwidth(content)
					return {
						{ "  │ ", border_hl },
						{ content .. string.rep(" ", padding), hl },
						{ " │", border_hl },
					}
				end

				-- Top border
				table.insert(comment_lines, {
					{ "  ╭" .. string.rep("─", content_width + 2) .. "╮", border_hl },
				})

				-- Render each comment
				for i, comment in ipairs(thread.comments) do
					local author = comment.author and comment.author.login or "unknown"
					local time_ago = format_time_ago(comment.createdAt)

					-- Header line
					local header = string.format("💬 @%s  ·  %s", author, time_ago)
					table.insert(comment_lines, bordered_line(header, "GhprCommentAuthor"))

					-- Empty line after header
					table.insert(comment_lines, bordered_line("", "Normal"))

					-- Body lines (wrapped)
					local body = comment.body or ""
					local wrapped_lines = wrap_text(body, content_width)

					for _, body_line in ipairs(wrapped_lines) do
						table.insert(comment_lines, bordered_line(body_line, "GhprCommentBody"))
					end

					-- Add spacing between comments in thread
					if i < #thread.comments then
						table.insert(comment_lines, bordered_line("", "Normal"))
						table.insert(comment_lines, {
							{ "  ├" .. string.rep("─", content_width + 2) .. "┤", border_hl },
						})
						table.insert(comment_lines, bordered_line("", "Normal"))
					end
				end

				-- Bottom border
				table.insert(comment_lines, {
					{ "  ╰" .. string.rep("─", content_width + 2) .. "╯", border_hl },
				})

				-- Add extmark with virt_lines to show the comment box
				vim.api.nvim_buf_set_extmark(bufnr, ns_comments, line_num, 0, {
					virt_lines = comment_lines,
					virt_lines_above = false, -- Show below the line
				})
			end
		end

		::continue::
	end
end

-- Clear all comment marks from a buffer
function M.clear_comments(bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr, ns_comments, 0, -1)
end

-- Get thread at cursor position (if any)
function M.get_thread_at_cursor(bufnr, owner, repo, pr_number, file_path)
	local comments = require("ghpr.review.comments")
	local cursor = vim.api.nvim_win_get_cursor(0)
	local line = cursor[1] -- 1-indexed

	return comments.get_thread_at_line(owner, repo, pr_number, file_path, line)
end

-- Show detailed thread view in floating window
function M.show_thread_detail(owner, repo, pr_number, thread_id)
	local comments = require("ghpr.review.comments")
	local thread = comments.get_thread(owner, repo, pr_number, thread_id)

	if not thread then
		vim.notify("Thread not found", vim.log.levels.ERROR)
		return
	end

	-- Build content lines
	local lines = {}
	local highlights = {}

	-- Header
	local header = string.format(
		"Thread: %s:%d (%s)",
		thread.path or "unknown",
		thread.line or 0,
		thread.isResolved and "resolved" or "unresolved"
	)
	table.insert(lines, header)
	table.insert(lines, string.rep("─", #header))
	table.insert(lines, "")

	-- Comments
	for i, comment in ipairs(thread.comments) do
		local author = comment.author and comment.author.login or "unknown"
		local created = comment.createdAt or ""

		-- Author line
		local author_line = string.format("@%s · %s", author, created)
		table.insert(highlights, { #lines, "GhprCommentAuthor" })
		table.insert(lines, author_line)

		-- Body lines (split by newline)
		for body_line in comment.body:gmatch("[^\r\n]+") do
			table.insert(lines, "  " .. body_line)
		end

		-- Separator between comments
		if i < #thread.comments then
			table.insert(lines, "")
			table.insert(lines, "---")
			table.insert(lines, "")
		end
	end

	-- Create floating window
	local width = math.min(80, vim.o.columns - 10)
	local height = math.min(#lines + 2, vim.o.lines - 10)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = math.floor((vim.o.columns - width) / 2),
		row = math.floor((vim.o.lines - height) / 2),
		style = "minimal",
		border = "rounded",
		title = " Comment Thread ",
		title_pos = "center",
	})

	-- Apply highlights using nvim_buf_set_extmark
	local hl_ns = vim.api.nvim_create_namespace("ghpr_thread_detail_hl")
	for _, hl in ipairs(highlights) do
		vim.api.nvim_buf_set_extmark(buf, hl_ns, hl[1], 0, {
			end_col = -1,
			hl_group = hl[2],
		})
	end

	-- Close on q or <Esc>
	vim.api.nvim_buf_set_keymap(buf, "n", "q", "<cmd>close<cr>", { noremap = true, silent = true })
	vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", "<cmd>close<cr>", { noremap = true, silent = true })

	return win, buf
end

return M
