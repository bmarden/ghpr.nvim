local config = require("ghpr.config")

local M = {}

---Create a PR via `gh pr create` asynchronously.
---@param opts { title: string, body: string, base: string, head: string }
---@param callback fun(url: string?, err: string?)
function M.create_pr(opts, callback)
  local cmd = {
    config.options.gh_cli_path,
    "pr",
    "create",
    "--title", opts.title,
    "--body", opts.body,
    "--base", opts.base,
    "--head", opts.head,
  }

  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, vim.trim(result.stderr or "gh pr create failed"))
      else
        local url = vim.trim(result.stdout or "")
        callback(url, nil)
      end
    end)
  end)
end

return M