if vim.g.loaded_ghpr then
  return
end
vim.g.loaded_ghpr = true

vim.api.nvim_create_user_command("GhPrCreate", function()
  require("ghpr").create()
end, { desc = "Create a GitHub PR from the current branch" })