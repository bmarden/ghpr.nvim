local M = {}

function M.setup(opts)
  require("ghpr.config").setup(opts)
end

function M.create()
  require("ghpr.ui").open()
end

return M
