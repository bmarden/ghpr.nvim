-- Add reviewers (users and org teams) to a PR via a snacks picker.
local gh = require("ghpr.gh")

local M = {}

---Gather selectable reviewer candidates: collaborators + org teams.
---@param callback fun(items: table[]?, err: string?)
local function gather_candidates(callback)
	local git = require("ghpr.git")
	local owner = git.owner_repo()

	gh.list_collaborators(function(logins, col_err)
		if col_err then
			callback(nil, col_err)
			return
		end

		gh.list_teams(function(teams)
			local items = {}
			for _, login in ipairs(logins or {}) do
				table.insert(items, {
					text = login,
					kind = "user",
					-- gh expects a bare login for users
					value = login,
					display = "👤 " .. login,
				})
			end
			for _, slug in ipairs(teams or {}) do
				table.insert(items, {
					text = slug,
					kind = "team",
					-- gh expects "owner/slug" for teams
					value = (owner and (owner .. "/" .. slug)) or slug,
					display = "👥 " .. slug .. " (team)",
				})
			end
			callback(items, nil)
		end)
	end)
end

---Apply the chosen reviewers to the PR.
---@param number integer?
---@param values string[]
local function apply(number, values)
	if #values == 0 then
		return
	end
	vim.notify("Adding reviewers: " .. table.concat(values, ", "), vim.log.levels.INFO)
	gh.add_reviewers(number, values, function(ok, err)
		if not ok then
			vim.notify("ghpr: failed to add reviewers: " .. (err or ""), vim.log.levels.ERROR)
			return
		end
		vim.notify("Reviewers added", vim.log.levels.INFO)
	end)
end

---Open a picker to add one or more reviewers. nil number -> current branch PR.
---@param number integer?
function M.add(number)
	local ok_snacks, Snacks = pcall(require, "snacks")
	if not ok_snacks then
		vim.notify("ghpr: snacks.nvim is required for the reviewer picker", vim.log.levels.ERROR)
		return
	end

	vim.notify("Fetching collaborators...", vim.log.levels.INFO)
	gather_candidates(function(items, err)
		if err or not items then
			vim.notify("ghpr: failed to fetch reviewers: " .. (err or "unknown"), vim.log.levels.ERROR)
			return
		end
		if #items == 0 then
			vim.notify("ghpr: no candidate reviewers found", vim.log.levels.WARN)
			return
		end

		Snacks.picker.pick({
			title = "Add Reviewers",
			items = items,
			format = function(item)
				return { { item.display, "Normal" } }
			end,
			confirm = function(picker)
				local selected = picker:selected({ fallback = true })
				picker:close()
				local values = {}
				for _, item in ipairs(selected) do
					table.insert(values, item.value)
				end
				apply(number, values)
			end,
		})
	end)
end

return M
