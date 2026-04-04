local M = {}

local defaults = {
  gh_cli_path = "gh",
  base_branch = "main",
  remote = "origin",
}

M.options = vim.deepcopy(defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", defaults, opts or {})
end

return M