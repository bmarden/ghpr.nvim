-- Snacks-based PR picker: list on the left, description preview on the right.
local gh = require("ghpr.gh")

local M = {}

---Build the preview text for a PR item.
---@param pr table
---@return string[]
local function preview_lines(pr)
	local lines = {
		string.format("#%d  %s", pr.number, pr.title or ""),
		string.format(
			"%s%s  ·  %s → %s  ·  @%s",
			pr.state or "",
			pr.isDraft and " (draft)" or "",
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
	return lines
end

---Fetch the PR's head branch, check it out, then open the codediff review.
---@param pr table
local function checkout_and_review(pr)
	local branch = pr.headRefName
	local pr_number = pr.number

	vim.notify(string.format("Checking out PR #%d (%s)...", pr_number, branch), vim.log.levels.INFO)

	vim.system({ "git", "fetch", "origin", branch }, { text = true }, function(fetch_result)
		vim.schedule(function()
			if fetch_result.code ~= 0 then
				vim.notify("Failed to fetch branch: " .. (fetch_result.stderr or ""), vim.log.levels.ERROR)
				return
			end

			-- Try checkout; if local branch doesn't exist, create a tracking branch.
			vim.system({ "git", "checkout", branch }, { text = true }, function(co_result)
				vim.schedule(function()
					if co_result.code ~= 0 then
						vim.system(
							{ "git", "checkout", "-b", branch, "origin/" .. branch },
							{ text = true },
							function(create_result)
								vim.schedule(function()
									if create_result.code ~= 0 then
										vim.notify(
											"Failed to checkout branch: " .. (create_result.stderr or ""),
											vim.log.levels.ERROR
										)
										return
									end
									require("ghpr.review.session").review_pr(pr_number)
								end)
							end
						)
					else
						require("ghpr.review.session").review_pr(pr_number)
					end
				end)
			end)
		end)
	end)
end

-- Available actions on a focused PR. `run(pr)` performs the action; `name` is
-- the snacks action id; `key` is the quick shortcut shown in the menu.
---@type { name: string, label: string, key: string, run: fun(pr: table) }[]
local ACTIONS = {
	{
		name = "view_desc",
		label = "View description",
		key = "<CR>",
		run = function(pr)
			require("ghpr.description").view(pr.number)
		end,
	},
	{
		name = "review",
		label = "Review (checkout + CodeDiff)",
		key = "<C-r>",
		run = function(pr)
			checkout_and_review(pr)
		end,
	},
	{
		name = "edit_desc",
		label = "Edit description",
		key = "<C-e>",
		run = function(pr)
			require("ghpr.description").edit(pr.number)
		end,
	},
	{
		name = "add_reviewer",
		label = "Add reviewer",
		key = "<C-a>",
		run = function(pr)
			require("ghpr.reviewers").add(pr.number)
		end,
	},
}

-- Show a menu of available actions for the focused PR (bound to <CR>).
---@param pr table
local function open_action_menu(pr)
	local labels = {}
	for _, a in ipairs(ACTIONS) do
		table.insert(labels, a)
	end
	vim.ui.select(labels, {
		prompt = string.format("PR #%d — actions", pr.number),
		format_item = function(a)
			return string.format("%-32s %s", a.label, a.key)
		end,
	}, function(choice)
		if choice then
			choice.run(pr)
		end
	end)
end

---Open the PR picker.
function M.open()
	local ok_snacks, Snacks = pcall(require, "snacks")
	if not ok_snacks then
		vim.notify("ghpr: snacks.nvim is required for the PR picker", vim.log.levels.ERROR)
		return
	end

	vim.notify("Loading PRs...", vim.log.levels.INFO)
	gh.list_prs(function(prs, err)
		if err or not prs then
			vim.notify("ghpr: failed to list PRs: " .. (err or "unknown"), vim.log.levels.ERROR)
			return
		end
		if #prs == 0 then
			vim.notify("ghpr: no open PRs", vim.log.levels.INFO)
			return
		end

		local items = {}
		for _, pr in ipairs(prs) do
			table.insert(items, {
				text = string.format("#%d %s %s", pr.number, pr.title or "", (pr.author and pr.author.login) or ""),
				pr = pr,
				preview = { text = table.concat(preview_lines(pr), "\n"), ft = "markdown" },
			})
		end

		-- Build snacks action handlers + quick-key bindings from the registry.
		local actions = {}
		local keys = {}
		for _, a in ipairs(ACTIONS) do
			actions[a.name] = function(picker, item)
				picker:close()
				if item and item.pr then
					a.run(item.pr)
				end
			end
			-- <CR> is reserved for the action menu (confirm); others get a quick key.
			if a.key ~= "<CR>" then
				keys[a.key:lower()] = { a.name, mode = { "n", "i" }, desc = a.label }
			end
		end

		Snacks.picker.pick({
			title = "Pull Requests",
			items = items,
			format = function(item)
				local pr = item.pr
				return {
					{ string.format("#%-5d ", pr.number), "Number" },
					{ (pr.title or "") .. " ", "Normal" },
					{ "@" .. ((pr.author and pr.author.login) or "?"), "Comment" },
				}
			end,
			preview = "preview",
			-- <CR> opens an action menu listing every action and its shortcut.
			confirm = function(picker, item)
				picker:close()
				if item and item.pr then
					open_action_menu(item.pr)
				end
			end,
			-- Quick-action keys: each runs its action directly on the focused PR.
			actions = actions,
			win = {
				input = {
					keys = keys,
				},
			},
		})
	end)
end

return M
