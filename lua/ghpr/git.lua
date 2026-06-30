local config = require("ghpr.config")

local M = {}

---Run a git command synchronously and return stdout trimmed.
---@param args string[]
---@return string? output
---@return string? err
local function git(args)
	local cmd = vim.list_extend({ "git" }, args)
	local result = vim.system(cmd, { text = true }):wait()
	if result.code ~= 0 then
		return nil, vim.trim(result.stderr or "")
	end
	return vim.trim(result.stdout or ""), nil
end

---@return string? branch, string? err
function M.current_branch()
	return git({ "branch", "--show-current" })
end

---@return string? toplevel, string? err
function M.repo_root()
	return git({ "rev-parse", "--show-toplevel" })
end

---Push the current branch to the remote, setting upstream.
---@param branch string
---@return string? output, string? err
function M.push_branch(branch)
	local remote = config.options.remote
	return git({ "push", "--set-upstream", remote, branch })
end

---Get the list of changed files between base branch and HEAD.
---@return string[]? files, string? err
function M.changed_files()
	local remote = config.options.remote
	local base = config.options.base_branch
	local base_ref = remote .. "/" .. base

	-- Fetch the base branch so the diff is up to date
	git({ "fetch", remote, base })

	local merge_base, err = git({ "merge-base", base_ref, "HEAD" })
	if not merge_base then
		return nil, err
	end

	local output, diff_err = git({ "diff", "--name-status", merge_base, "HEAD" })
	if not output then
		return nil, diff_err
	end

	if output == "" then
		return {}, nil
	end

	local files = {}
	for line in output:gmatch("[^\n]+") do
		table.insert(files, line)
	end
	return files, nil
end

---Parse a git remote URL into owner/repo. Supports SSH and HTTPS forms.
---@param url string
---@return string? owner, string? repo
local function parse_remote_url(url)
	local owner, repo

	-- SSH: git@github.com:owner/repo.git
	owner, repo = url:match("git@github%.com:([^/]+)/(.+)%.git$")
	if owner and repo then
		return owner, repo
	end

	-- HTTPS with .git: https://github.com/owner/repo.git
	owner, repo = url:match("github%.com/([^/]+)/(.+)%.git$")
	if owner and repo then
		return owner, repo
	end

	-- Without .git suffix
	owner, repo = url:match("github%.com/([^/]+)/([^/]+)$")
	if owner and repo then
		return owner, repo
	end

	return nil, nil
end

---Get the remote URL for the configured remote.
---@return string? url, string? err
function M.remote_url()
	return git({ "config", "--get", "remote." .. config.options.remote .. ".url" })
end

---@return string? owner, string? repo, string? err
function M.owner_repo()
	local url, err = M.remote_url()
	if not url then
		return nil, nil, err or "no remote URL"
	end
	local owner, repo = parse_remote_url(url)
	if not owner or not repo then
		return nil, nil, "could not parse owner/repo from remote URL: " .. url
	end
	return owner, repo, nil
end

---Merge-base between base branch and HEAD (or given head).
---@param base string
---@param head string?
---@return string? sha, string? err
function M.merge_base(base, head)
	return git({ "merge-base", base, head or "HEAD" })
end

---Detect PR context from the git repository.
---@param pr_number integer?
---@return table? ctx, string? err
function M.detect_context(pr_number)
	local root, root_err = M.repo_root()
	if not root then
		return nil, "Not in a git repository (" .. (root_err or "unknown") .. ")"
	end

	local owner, repo, or_err = M.owner_repo()
	if not owner then
		return nil, or_err
	end

	local branch, branch_err = M.current_branch()
	if not branch then
		return nil, "Could not determine current branch (" .. (branch_err or "unknown") .. ")"
	end

	local base_branch = config.options.base_branch
	local mb = M.merge_base(base_branch, "HEAD")

	return {
		pr_number = pr_number,
		owner = owner,
		repo = repo,
		git_root = root,
		base_branch = base_branch,
		head_branch = branch,
		merge_base = mb,
	}
end

return M
