-- Standalone test launcher for ghpr.nvim.
--
-- Run from the repo root with an isolated config:
--   nvim -u test-setup.lua
--
-- It bootstraps lazy.nvim into a scratch dir, installs snacks.nvim and
-- codediff.nvim, and loads this checkout of ghpr.nvim from disk. Your normal
-- Neovim config is untouched.

local repo_root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":h")

-- Isolate state/data so this never touches your real config.
local scratch = repo_root .. "/.test-nvim"
vim.env.XDG_DATA_HOME = scratch .. "/data"
vim.env.XDG_STATE_HOME = scratch .. "/state"
vim.env.XDG_CACHE_HOME = scratch .. "/cache"

vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- Bootstrap lazy.nvim.
local lazypath = scratch .. "/data/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
	vim.fn.system({
		"git",
		"clone",
		"--filter=blob:none",
		"https://github.com/folke/lazy.nvim.git",
		"--branch=stable",
		lazypath,
	})
end
vim.opt.runtimepath:prepend(lazypath)

require("lazy").setup({
	{
		"folke/snacks.nvim",
		priority = 1000,
		lazy = false,
		opts = {
			picker = { enabled = true },
		},
	},
	{ "esmuellert/codediff.nvim", opts = {} },
	{
		-- Load this checkout from disk.
		dir = repo_root,
		name = "ghpr.nvim",
		dependencies = { "folke/snacks.nvim", "esmuellert/codediff.nvim" },
		opts = {
			gh_cli_path = "gh",
			base_branch = "main",
		},
	},
}, {
	root = scratch .. "/data/lazy",
})

vim.schedule(function()
	vim.notify(
		table.concat({
			"ghpr.nvim test harness loaded.",
			"",
			"Commands:",
			"  :GhPrList            picker + description preview",
			"  :GhPrView [n]        view description (e to edit)",
			"  :GhPrEdit [n]        edit description (<C-s> save)",
			"  :GhPrAddReviewer [n] add reviewers (users + teams)",
			"  :GhPrCreate          create PR from current branch",
			"  :GhPrReview <n>      file-by-file review (codediff)",
			"",
			"Keymap: <leader>gp opens the PR picker.",
			"Run nvim from inside a GitHub repo so gh can resolve the PR.",
		}, "\n"),
		vim.log.levels.INFO
	)
end)
