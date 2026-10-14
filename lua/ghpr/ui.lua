local git = require("ghpr.git")
local gh = require("ghpr.gh")
local config = require("ghpr.config")

local M = {}

local ns = vim.api.nvim_create_namespace("ghpr")

local SEPARATOR =
	"──────────────────────────────────────────────────"
local FILES_HEADER = "Changed files:"

--- Try to get PR template content from .github/pull_request_template.md in repo root.
--- @returns string[]|nil lines, string|nil err
local get_pr_template = function()
	local root, err = git.repo_root()
	if not root then
		return nil, err
	end

	local template_path = root .. "/.github/pull_request_template.md"
	if vim.fn.filereadable(template_path) == 1 then
		return vim.fn.readfile(template_path), nil
	end

	return nil, "No PR template found at " .. template_path
end

---Build the initial buffer lines for the PR body form.
---The body is everything above the separator; the summary region below it is
---locked read-only. Title is collected separately via a prompt.
---@param branch string
---@param base string
---@param files string[]
---@return string[]
local function build_lines(branch, base, files)
	local body_lines = {}
	local pr_template, _ = get_pr_template()
	if pr_template then
		vim.list_extend(body_lines, pr_template)
	else
		table.insert(body_lines, "")
	end

	local lines = vim.deepcopy(body_lines)
	table.insert(lines, SEPARATOR)
	table.insert(lines, string.format("Base: %s/%s  ←  Head: %s", config.options.remote, base, branch))
	table.insert(lines, "")
	table.insert(lines, FILES_HEADER)

	if #files == 0 then
		table.insert(lines, "  (no changed files)")
	else
		for _, f in ipairs(files) do
			table.insert(lines, "  " .. f)
		end
	end
	table.insert(lines, SEPARATOR)
	table.insert(lines, "")
	table.insert(lines, "Submit: <C-s>  |  Cancel: q")
	return lines
end

---Find the separator line index (1-based) in buffer.
---@param buf integer
---@return integer
local function find_separator(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	for i, line in ipairs(lines) do
		if line == SEPARATOR then
			return i
		end
	end
	return #lines
end

---Parse the body: everything above the first separator, trailing blanks trimmed.
---@param buf integer
---@return string body
local function parse_body(buf)
	local sep = find_separator(buf)
	local body_lines = vim.api.nvim_buf_get_lines(buf, 0, sep - 1, false)

	while #body_lines > 0 and vim.trim(body_lines[#body_lines]) == "" do
		table.remove(body_lines)
	end

	return table.concat(body_lines, "\n")
end

---Lock lines from `start` (0-indexed) to end of buffer as read-only via extmarks.
---@param buf integer
---@param start integer
local function lock_summary_region(buf, start)
	local line_count = vim.api.nvim_buf_line_count(buf)
	for i = start, line_count - 1 do
		vim.api.nvim_buf_set_extmark(buf, ns, i, 0, {
			hl_group = "Comment",
			end_row = i,
			end_col = #vim.api.nvim_buf_get_lines(buf, i, i + 1, false)[1],
		})
	end

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = buf,
		callback = function()
			local cursor = vim.api.nvim_win_get_cursor(0)
			local sep = find_separator(buf)
			if cursor[1] >= sep then
				vim.cmd("silent! undo")
			end
		end,
	})
end

---Offer to add reviewers to a freshly created PR.
---@param number integer?
local function prompt_reviewers(number)
	vim.ui.select({ "Yes", "No" }, { prompt = "Add reviewers to this PR?" }, function(choice)
		if choice == "Yes" then
			require("ghpr.reviewers").add(number)
		end
	end)
end

---Submit the PR with the given title.
---@param buf integer
---@param win integer
---@param branch string
---@param base string
---@param title string
local function submit(buf, win, branch, base, title)
	local body = parse_body(buf)

	vim.notify("Creating PR...", vim.log.levels.INFO)

	gh.create_pr({
		title = title,
		body = body,
		base = base,
		head = branch,
	}, function(url, err)
		if err then
			vim.notify("PR creation failed: " .. err, vim.log.levels.ERROR)
			return
		end
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
		vim.notify("PR created: " .. (url or ""), vim.log.levels.INFO)
		prompt_reviewers(nil)
	end)
end

---Open the PR body float after the title has been collected.
---@param branch string
---@param base string
---@param files string[]
---@param title string
local function open_body_form(branch, base, files, title)
	local lines = build_lines(branch, base, files)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].bufhidden = "wipe"

	local width = math.min(90, math.floor(vim.o.columns * 0.8))
	local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.8))

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = math.floor((vim.o.columns - width) / 2),
		row = math.floor((vim.o.lines - height) / 2),
		style = "minimal",
		border = "rounded",
		title = string.format(" Create PR: %s ", title),
		title_pos = "center",
	})

	local sep = find_separator(buf)
	lock_summary_region(buf, sep - 1)

	-- Place cursor on the first body line.
	vim.api.nvim_win_set_cursor(win, { 1, 0 })

	vim.keymap.set("n", "<C-s>", function()
		submit(buf, win, branch, base, title)
	end, { buffer = buf, desc = "Submit PR" })

	vim.keymap.set("n", "q", function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end, { buffer = buf, desc = "Cancel PR creation" })
end

---Open the PR creation flow: prompt for a title, then open the body float.
function M.open()
	local branch, branch_err = git.current_branch()
	if not branch or branch == "" then
		vim.notify("ghpr: not on a branch (" .. (branch_err or "unknown error") .. ")", vim.log.levels.ERROR)
		return
	end

	local base = config.options.base_branch

	if branch == base then
		vim.notify("ghpr: already on base branch " .. base .. ", switch to a feature branch first", vim.log.levels.WARN)
		return
	end

	local files, files_err = git.changed_files()
	if not files then
		vim.notify("ghpr: failed to get changed files: " .. (files_err or ""), vim.log.levels.ERROR)
		return
	end

	vim.ui.input({ prompt = "PR title: ", default = "" }, function(title)
		if not title or vim.trim(title) == "" then
			vim.notify("ghpr: PR creation cancelled (title required)", vim.log.levels.WARN)
			return
		end
		open_body_form(branch, base, files, vim.trim(title))
	end)
end

return M
