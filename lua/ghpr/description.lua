-- View and edit a PR's description (body).
local gh = require("ghpr.gh")

local M = {}

---Open a centered floating window for the given buffer.
---@param buf integer
---@param title string
---@param footer string?
---@return integer win
local function open_float(buf, title, footer)
	local width = math.min(90, math.floor(vim.o.columns * 0.8))
	local height = math.min(30, math.floor(vim.o.lines * 0.8))

	local win_opts = {
		relative = "editor",
		width = width,
		height = height,
		col = math.floor((vim.o.columns - width) / 2),
		row = math.floor((vim.o.lines - height) / 2),
		style = "minimal",
		border = "rounded",
		title = title,
		title_pos = "center",
	}
	if footer then
		win_opts.footer = footer
		win_opts.footer_pos = "center"
	end

	return vim.api.nvim_open_win(buf, true, win_opts)
end

---View a PR description read-only. nil number resolves the current branch's PR.
---@param number integer?
function M.view(number)
	gh.get_pr(number, function(pr, err)
		if err or not pr then
			vim.notify("ghpr: failed to load PR: " .. (err or "unknown"), vim.log.levels.ERROR)
			return
		end

		local lines = {
			string.format("#%d  %s", pr.number, pr.title or ""),
			string.format(
				"%s  ·  %s → %s  ·  @%s",
				pr.state or "",
				pr.headRefName or "",
				pr.baseRefName or "",
				(pr.author and pr.author.login) or "?"
			),
			pr.url or "",
			string.rep("─", 60),
			"",
		}
		for _, l in ipairs(vim.split(pr.body or "", "\n")) do
			table.insert(lines, l)
		end

		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].filetype = "markdown"
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].modifiable = false

		local win = open_float(buf, string.format(" PR #%d ", pr.number), " q / <Esc> to close  |  e to edit ")

		local function close()
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
		end

		vim.keymap.set("n", "q", close, { buffer = buf })
		vim.keymap.set("n", "<Esc>", close, { buffer = buf })
		vim.keymap.set("n", "e", function()
			close()
			M.edit(pr.number)
		end, { buffer = buf, desc = "Edit PR description" })
	end)
end

---Edit a PR description in an editable float; submit with <C-s>.
---@param number integer?
function M.edit(number)
	gh.get_pr(number, function(pr, err)
		if err or not pr then
			vim.notify("ghpr: failed to load PR: " .. (err or "unknown"), vim.log.levels.ERROR)
			return
		end

		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(pr.body or "", "\n"))
		vim.bo[buf].filetype = "markdown"
		vim.bo[buf].bufhidden = "wipe"

		local win = open_float(
			buf,
			string.format(" Edit PR #%d Description ", pr.number),
			" <C-s> to save  |  q / <Esc> to cancel "
		)

		local function close()
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
		end

		local function submit()
			local body = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
			vim.notify("Updating PR description...", vim.log.levels.INFO)
			gh.update_body(pr.number, body, function(ok, update_err)
				if not ok then
					vim.notify("ghpr: failed to update description: " .. (update_err or ""), vim.log.levels.ERROR)
					return
				end
				close()
				vim.notify("PR #" .. pr.number .. " description updated", vim.log.levels.INFO)
			end)
		end

		vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = buf, desc = "Save PR description" })
		vim.keymap.set("n", "q", close, { buffer = buf })
		vim.keymap.set("n", "<Esc>", close, { buffer = buf })
	end)
end

return M
