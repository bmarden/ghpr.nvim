local config = require("ghpr.config")

local M = {}

---Run a `gh` command asynchronously, parsing stdout as JSON if requested.
---@param args string[]
---@param opts { json?: boolean, stdin?: string }
---@param callback fun(result: any?, err: string?)
local function gh(args, opts, callback)
	opts = opts or {}
	local cmd = vim.list_extend({ config.options.gh_cli_path }, args)

	local system_opts = { text = true }
	if opts.stdin then
		system_opts.stdin = opts.stdin
	end

	vim.system(cmd, system_opts, function(result)
		vim.schedule(function()
			if result.code ~= 0 then
				callback(nil, vim.trim(result.stderr or "gh command failed"))
				return
			end

			local stdout = result.stdout or ""
			if opts.json then
				local ok, data = pcall(vim.json.decode, stdout)
				if not ok then
					callback(nil, "Failed to parse gh JSON output")
					return
				end
				callback(data, nil)
			else
				callback(vim.trim(stdout), nil)
			end
		end)
	end)
end

---Create a PR via `gh pr create` asynchronously.
---@param opts { title: string, body: string, base: string, head: string }
---@param callback fun(url: string?, err: string?)
function M.create_pr(opts, callback)
	-- First push the current branch to the remote
	local git = require("ghpr.git")

	local push_output, push_err = git.push_branch(opts.head)
	if push_err then
		callback(nil, "Failed to push branch: " .. push_err)
		return
	end

	vim.notify("Branch pushed successfully: " .. push_output, vim.log.levels.TRACE)

	local cmd = {
		"pr",
		"create",
		"--title",
		opts.title,
		"--body",
		opts.body,
		"--base",
		opts.base,
		"--head",
		opts.head,
	}

	gh(cmd, {}, function(url, err)
		if err then
			callback(nil, err)
		else
			callback(url, nil)
		end
	end)
end

local PR_VIEW_FIELDS =
	"number,title,body,url,state,headRefName,baseRefName,author,reviewRequests,isDraft,updatedAt"

---Fetch a single PR. With no number, resolves the PR for the current branch.
---@param number integer?
---@param callback fun(pr: table?, err: string?)
function M.get_pr(number, callback)
	local args = { "pr", "view" }
	if number then
		table.insert(args, tostring(number))
	end
	vim.list_extend(args, { "--json", PR_VIEW_FIELDS })
	gh(args, { json = true }, callback)
end

---Update a PR's body. Passes the body on stdin via --body-file -.
---@param number integer?
---@param body string
---@param callback fun(ok: boolean, err: string?)
function M.update_body(number, body, callback)
	local args = { "pr", "edit" }
	if number then
		table.insert(args, tostring(number))
	end
	vim.list_extend(args, { "--body-file", "-" })
	gh(args, { stdin = body }, function(_, err)
		if err then
			callback(false, err)
		else
			callback(true, nil)
		end
	end)
end

---List PRs for the current repo.
---@param callback fun(prs: table[]?, err: string?)
function M.list_prs(callback)
	local fields = "number,title,author,headRefName,baseRefName,state,isDraft,updatedAt,url,body"
	gh({ "pr", "list", "--json", fields, "--limit", "50" }, { json = true }, callback)
end

---List repo collaborator logins.
---@param callback fun(logins: string[]?, err: string?)
function M.list_collaborators(callback)
	local git = require("ghpr.git")
	local owner, repo, err = git.owner_repo()
	if not owner then
		callback(nil, err)
		return
	end

	local endpoint = string.format("repos/%s/%s/collaborators", owner, repo)
	gh({ "api", "--paginate", endpoint, "--jq", ".[].login" }, {}, function(out, api_err)
		if api_err then
			callback(nil, api_err)
			return
		end
		local logins = {}
		for line in tostring(out):gmatch("[^\n]+") do
			local trimmed = vim.trim(line)
			if trimmed ~= "" then
				table.insert(logins, trimmed)
			end
		end
		callback(logins, nil)
	end)
end

---List org team slugs (best-effort; returns empty list if owner is not an org
---or the caller lacks permission).
---@param callback fun(teams: string[]?, err: string?)
function M.list_teams(callback)
	local git = require("ghpr.git")
	local owner, _, err = git.owner_repo()
	if not owner then
		callback(nil, err)
		return
	end

	local endpoint = string.format("orgs/%s/teams", owner)
	gh({ "api", "--paginate", endpoint, "--jq", ".[].slug" }, {}, function(out, api_err)
		if api_err then
			-- Best-effort: not an org, or no access. Return empty list silently.
			callback({}, nil)
			return
		end
		local teams = {}
		for line in tostring(out):gmatch("[^\n]+") do
			local trimmed = vim.trim(line)
			if trimmed ~= "" then
				table.insert(teams, trimmed)
			end
		end
		callback(teams, nil)
	end)
end

---Add reviewers to a PR. Users are plain logins; teams must be "owner/slug".
---@param number integer?
---@param reviewers string[]
---@param callback fun(ok: boolean, err: string?)
function M.add_reviewers(number, reviewers, callback)
	if not reviewers or #reviewers == 0 then
		callback(false, "No reviewers given")
		return
	end

	local args = { "pr", "edit" }
	if number then
		table.insert(args, tostring(number))
	end
	for _, r in ipairs(reviewers) do
		vim.list_extend(args, { "--add-reviewer", r })
	end

	gh(args, {}, function(_, err)
		if err then
			callback(false, err)
		else
			callback(true, nil)
		end
	end)
end

return M
