-- Comment input UI (compose window)
local M = {}

-- Track active compose window
local active_compose = {
	win = nil,
	buf = nil,
	callback = nil,
	context = nil,
}

-- Close the active compose window
local function close_compose()
	if active_compose.win and vim.api.nvim_win_is_valid(active_compose.win) then
		vim.api.nvim_win_close(active_compose.win, true)
	end

	if active_compose.buf and vim.api.nvim_buf_is_valid(active_compose.buf) then
		vim.api.nvim_buf_delete(active_compose.buf, { force = true })
	end

	active_compose.win = nil
	active_compose.buf = nil
	active_compose.callback = nil
	active_compose.context = nil
end

-- Submit the comment
local function submit_comment()
	if not active_compose.buf or not vim.api.nvim_buf_is_valid(active_compose.buf) then
		return
	end

	-- Get the buffer content
	local lines = vim.api.nvim_buf_get_lines(active_compose.buf, 0, -1, false)
	local body = table.concat(lines, "\n")

	-- Trim whitespace
	body = body:gsub("^%s+", ""):gsub("%s+$", "")

	if body == "" then
		vim.notify("Comment body cannot be empty", vim.log.levels.WARN)
		return
	end

	-- Call the callback with the body
	if active_compose.callback then
		active_compose.callback(body, active_compose.context)
	end

	-- Close the compose window
	close_compose()
end

-- Open compose window for entering comment text
function M.open_compose_window(context, callback, initial_body)
	-- Close any existing compose window
	close_compose()

	-- Create buffer
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "acwrite", { buf = buf })
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

	-- Set initial content if provided
	if initial_body then
		local lines = vim.split(initial_body, "\n")
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	end

	-- Calculate window dimensions
	local width = math.min(80, vim.o.columns - 10)
	local height = math.min(20, vim.o.lines - 10)

	-- Create floating window
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = math.floor((vim.o.columns - width) / 2),
		row = math.floor((vim.o.lines - height) / 2),
		style = "minimal",
		border = "rounded",
		title = " Write Comment ",
		title_pos = "center",
		footer = " <C-s> to submit | <C-c> to cancel ",
		footer_pos = "center",
	})

	-- Store active compose state
	active_compose.win = win
	active_compose.buf = buf
	active_compose.callback = callback
	active_compose.context = context

	-- Setup keybindings
	local opts = { noremap = true, silent = true, buffer = buf }

	-- Submit with <C-s> or :w
	vim.keymap.set("n", "<C-s>", submit_comment, opts)
	vim.keymap.set("i", "<C-s>", submit_comment, opts)

	-- Cancel with <C-c> or <Esc> in normal mode
	vim.keymap.set("n", "<C-c>", close_compose, opts)
	vim.keymap.set("n", "<Esc>", close_compose, opts)
	vim.keymap.set("n", "q", close_compose, opts)

	-- Mark buffer as compose window to exclude from review keymaps
	vim.b[buf].ghpr_compose_window = true

	-- Setup BufWriteCmd autocmd for :w
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = buf,
		callback = function()
			submit_comment()
		end,
	})

	-- Auto-close on buffer leave (if they switch to another buffer)
	vim.api.nvim_create_autocmd("BufLeave", {
		buffer = buf,
		once = true,
		callback = function()
			vim.defer_fn(function()
				close_compose()
			end, 100)
		end,
	})

	-- Start in insert mode
	vim.cmd("startinsert")
end

---@class PromptNewCommentsOpts
---@field owner string
---@field repo string
---@field pr_number number
---@field file_path string
---@field line number
---@field side string
---@field start_line? number

-- Prompt for a new comment thread
---@param opts PromptNewCommentsOpts
---@param callback fun(body: string, ctx: PromptNewCommentsOpts)
function M.prompt_new_comment(opts, callback)
	local context = vim.tbl_extend("force", opts, { type = "new_thread" })

	M.open_compose_window(context, callback)
end

-- Prompt for a reply to existing thread
function M.prompt_reply(owner, repo, pr_number, thread_id, callback)
	local context = {
		type = "reply",
		owner = owner,
		repo = repo,
		pr_number = pr_number,
		thread_id = thread_id,
	}

	M.open_compose_window(context, callback)
end

-- Prompt to edit existing comment
function M.prompt_edit(owner, repo, pr_number, thread_id, comment_id, current_body, callback)
	local context = {
		type = "edit",
		owner = owner,
		repo = repo,
		pr_number = pr_number,
		thread_id = thread_id,
		comment_id = comment_id,
	}

	M.open_compose_window(context, callback, current_body)
end

return M
