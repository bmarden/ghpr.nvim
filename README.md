# ghpr.nvim

A Neovim plugin for doing anything PR-related without leaving the editor:
create PRs, view/edit descriptions, add reviewers, pick PRs from a list, and
run a full file-by-file review with inline comments.

## Features

- 📝 Create a PR from the current branch (auto-pushes first)
- 👀 View a PR description in a floating window
- ✏️ Edit a PR description in place
- 👥 Add reviewers — users and org teams — via a picker
- 🔭 Pick a PR from a list with a live description preview (snacks)
- 🔍 Review a PR file-by-file in [CodeDiff](https://github.com/esmuellert/codediff.nvim)
  with viewed-state tracking and inline review comments

## Requirements

- Neovim 0.10+
- [gh CLI](https://cli.github.com/) (authenticated)
- [snacks.nvim](https://github.com/folke/snacks.nvim) — for the PR picker and reviewer picker
- [codediff.nvim](https://github.com/esmuellert/codediff.nvim) — for the review feature

## Installation

### lazy.nvim

```lua
{
  "bmarden/ghpr.nvim",
  dependencies = {
    "folke/snacks.nvim",
    "esmuellert/codediff.nvim",
  },
  -- Declare the commands/keys you use so lazy.nvim knows when to load the
  -- plugin. If you only set `opts`, lazy never loads it until something else
  -- requires it, and keymaps registered in setup() won't fire.
  cmd = {
    "GhPrCreate",
    "GhPrView",
    "GhPrEdit",
    "GhPrAddReviewer",
    "GhPrList",
    "GhPrReview",
  },
  keys = {
    { "<leader>gc", "<cmd>GhPrCreate<cr>", desc = "Create GitHub PR" },
    { "<leader>gp", "<cmd>GhPrList<cr>", desc = "Pick GitHub PR" },
    { "<leader>gr", "<cmd>GhPrReview<cr>", desc = "Review current branch PR" },
  },
  opts = {},
}
```

> **Note:** because lazy-loading is driven by the `cmd`/`keys` you declare, the
> keymaps in `keymaps`/`review_keymaps` below are most useful for non-lazy
> setups. With lazy.nvim, prefer declaring keys in the spec above.

## Commands

| Command                  | Description                                         |
| ------------------------ | --------------------------------------------------- |
| `:GhPrCreate`            | Create a PR from the current branch                 |
| `:GhPrView [n]`          | View a PR description (default: current branch PR)  |
| `:GhPrEdit [n]`          | Edit a PR description (`<C-s>` to save)             |
| `:GhPrAddReviewer [n]`   | Add reviewers from a picker (users + teams)         |
| `:GhPrList`              | Pick a PR from a list with description preview      |
| `:GhPrReview [n]`        | Open a PR for file-by-file review (CodeDiff)        |
| `:GhPrReviewClose`       | Close the active review session                     |
| `:GhPrReviewRefresh`     | Invalidate cached review data                       |
| `:GhPrReviewStats`       | Show review progress (viewed/unviewed)              |

`[n]` is an optional PR number; omit it to act on the PR for the current branch.

## Picker keymaps

In the `:GhPrList` picker, with a PR focused:

- `<CR>` — open an action menu listing every action and its shortcut
- `<C-r>` — review: check out the PR's branch and open the CodeDiff review
- `<C-e>` — edit the description
- `<C-a>` — add a reviewer

The quick keys above run their action directly; `<CR>` is the discoverable menu
for the same actions (it also includes "View description").

## Configuration

Defaults:

```lua
require("ghpr").setup({
  gh_cli_path = "gh",
  base_branch = "main",
  remote = "origin",

  cache_ttl = 300, -- review data cache TTL (seconds)

  codediff = {
    show_viewed_files = true,
    use_merge_base = true,
    explorer_position = "left",
  },

  -- Global keymaps. Set to false to disable.
  keymaps = {
    pick_prs = "<leader>gp",
  },

  -- Buffer-local keymaps active only during a CodeDiff review session.
  review_keymaps = {
    toggle_viewed = "<leader>gv",
    next_unviewed = "]u",
    prev_unviewed = "[u",
    close_review = "<leader>gq",
    add_comment = "a",
    delete_comment = "d",
    edit_comment = "e",
    show_thread_detail = "t",
  },

  notifications = { enabled = true, level = vim.log.levels.INFO },
  signs = { viewed = "✓", unviewed = "○" },
  highlights = { viewed = "Comment", unviewed = "Normal" },
  comments = { show_resolved = true, show_outdated = false, inline_max_length = 80 },
})
```

## Create-PR form

`:GhPrCreate` opens a buffer pre-filled with a title line, a description area
(seeded from `.github/pull_request_template.md` if present), and a read-only
summary of the base/head branches and changed files. Edit the title and body,
then submit with `<C-s>` (`q` cancels). The current branch is pushed to the
remote before the PR is created.
