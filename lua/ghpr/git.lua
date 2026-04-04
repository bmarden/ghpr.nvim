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

return M
