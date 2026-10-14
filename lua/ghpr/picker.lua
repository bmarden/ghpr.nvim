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
	-- GitHub returns bodies with CRLF; strip \r so it doesn't render as ^M.
	for _, l in ipairs(vim.split((pr.body or ""):gsub("\r", ""), "\n")) do
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
-- the snacks action id; `key` is the quick shortcut. `<CR>` runs its action
-- directly (via the picker `confirm` handler); all others are bound as
-- quick-keys on both the input and list windows. `hint` is the short label
-- shown in the picker title so the shortcuts are discoverable.
--
-- Quick keys use Alt (<A-...>) rather than Ctrl: snacks binds most Ctrl-letter
-- keys by default (<c-g> = toggle_live/print_path, <c-r> = insert-register
-- prefix, etc.), and those defaults win over per-window overrides in the list
-- window. The chosen Alt keys are all unbound in snacks' defaults.
---@type { name: string, label: string, key: string, hint: string, run: fun(pr: table) }[]
local ACTIONS = {
	{
		name = "view_desc",
		label = "View description",
		key = "<A-d>",
		hint = "view",
		run = function(pr)
			require("ghpr.description").view(pr.number)
		end,
	},
	{
		name = "review",
		label = "Review (checkout + CodeDiff)",
		key = "<CR>",
		hint = "review",
		run = function(pr)
			checkout_and_review(pr)
		end,
	},
	{
		name = "edit_desc",
		label = "Edit description",
		key = "<A-e>",
		hint = "edit",
		run = function(pr)
			require("ghpr.description").edit(pr.number)
		end,
	},
	{
		name = "add_reviewer",
		label = "Add reviewer",
		key = "<A-g>",
		hint = "reviewer",
		run = function(pr)
			require("ghpr.reviewers").add(pr.number)
		end,
	},
	{
		name = "submit_review",
		label = "Submit review",
		key = "<A-s>",
		hint = "submit",
		run = function(pr)
			local owner, repo, err = require("ghpr.git").owner_repo()
			if not owner or not repo then
				vim.notify("ghpr: " .. (err or "could not resolve owner/repo"), vim.log.levels.ERROR)
				return
			end
			require("ghpr.review.actions").submit_review({
				owner = owner,
				repo = repo,
				pr_number = pr.number,
				pr_id = pr.id,
			})
		end,
	},
}

---Build the picker title with the quick-key hints appended, e.g.
---"Pull Requests  ·  <CR> view  <A-c> review  <A-e> edit  <A-g> reviewer".
---@return string
local function build_title()
	local parts = {}
	for _, a in ipairs(ACTIONS) do
		table.insert(parts, string.format("%s %s", a.key, a.hint))
	end
	return "Pull Requests  ·  " .. table.concat(parts, "  ")
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
		-- Every action runs directly on the focused PR. <CR> is wired via the
		-- picker `confirm` handler; the rest get quick-keys on both the input
		-- and list windows so they fire regardless of which window has focus.
		local actions = {}
		local keys = {}
		local confirm_action
		for _, a in ipairs(ACTIONS) do
			actions[a.name] = function(picker, item)
				picker:close()
				if item and item.pr then
					a.run(item.pr)
				end
			end
			if a.key == "<CR>" then
				confirm_action = a
			else
				keys[a.key:lower()] = { a.name, mode = { "n", "i" }, desc = a.label }
			end
		end

		Snacks.picker.pick({
			title = build_title(),
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
			-- <CR> runs the default action (view description) directly.
			confirm = function(picker, item)
				picker:close()
				if item and item.pr and confirm_action then
					confirm_action.run(item.pr)
				end
			end,
			-- Quick-action keys: each runs its action directly on the focused PR.
			actions = actions,
			win = {
				input = {
					keys = keys,
				},
				list = {
					keys = keys,
				},
			},
		})
	end)
end

return M
