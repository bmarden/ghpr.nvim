-- Comment actions and context detection
local M = {}

-- Get file path from CodeDiff explorer using the tree API
local function get_path_from_explorer()
  local ft = vim.bo.filetype
  if ft ~= "codediff-explorer" then
    return nil
  end

  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle.accessors")
  if not ok then
    return nil
  end

  local tabpage = vim.api.nvim_get_current_tabpage()
  local explorer = lifecycle.get_explorer(tabpage)
  if not explorer or not explorer.tree then
    return nil
  end

  local node = explorer.tree:get_node()
  if not node or not node.data then
    return nil
  end

  if node.data.path and not node.data.type then
    return node.data.path
  end

  return nil
end

-- Extract file path and line from buffer
local function get_current_file_and_line()
  local bufname = vim.fn.expand("%:p")
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1] -- 1-indexed

  -- Check if this is a CodeDiff file buffer
  local codediff_pattern = "^codediff:////.-///[^/]+/(.+)$"
  local codediff_path = bufname:match(codediff_pattern)

  if codediff_path then
    return codediff_path, line, nil
  end

  -- Check if we're in the CodeDiff explorer
  local explorer_path = get_path_from_explorer()
  if explorer_path then
    return explorer_path, nil, nil -- No line in explorer
  end

  if bufname == "" or bufname:match("^%s*$") then
    return nil, nil, "No file associated with current buffer"
  end

  -- Regular buffer
  local git_root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]
  if not git_root or git_root == "" then
    return nil, nil, "Failed to get git root"
  end

  local rel_path = bufname:gsub("^" .. vim.pesc(git_root) .. "/", "")
  if rel_path == bufname then
    return nil, nil, "File not in git repository"
  end

  return rel_path, line, nil
end

-- Detect context for comment actions
function M.get_context()
  local pr = vim.g.ghpr_active_pr
  if not pr then
    return { type = "no_pr" }
  end

  local file_path, line, err = get_current_file_and_line()
  if err then
    return { type = "error", error = err }
  end

  -- Check filetype to determine if we're in explorer or diff buffer
  local ft = vim.bo.filetype

  if ft == "codediff-explorer" then
    return {
      type = "explorer",
      owner = pr.owner,
      repo = pr.repo,
      pr_number = pr.number,
      file_path = file_path,
    }
  end

  -- Check if cursor is on a comment (extmark)
  if file_path and line then
    local comments = require("ghpr.review.comments")
    local thread = comments.get_thread_at_line(pr.owner, pr.repo, pr.number, file_path, line)

    if thread then
      return {
        type = "comment",
        owner = pr.owner,
        repo = pr.repo,
        pr_number = pr.number,
        file_path = file_path,
        line = line,
        thread = thread,
      }
    end

    -- No comment at this line - this is a diff line
    return {
      type = "diff_line",
      owner = pr.owner,
      repo = pr.repo,
      pr_number = pr.number,
      file_path = file_path,
      line = line,
    }
  end

  return { type = "unknown" }
end

-- Determine diff side (LEFT or RIGHT) for comment placement
-- For now, we'll default to RIGHT (new code) as that's most common
local function get_diff_side()
  return "RIGHT"
end

-- Add a new comment or reply based on context
-- When called from visual mode, comments span the selected line range
function M.add_comment()
  local mode = vim.fn.mode():sub(1, 1)
  local is_visual = vim.tbl_contains({ "v", "V", "\22" }, mode)
  local start_line = nil
  local end_line = nil
  if is_visual then
    vim.cmd("normal! " .. mode)
    local pos = vim.api.nvim_buf_get_mark(0, "<")[1]
    local end_pos = vim.api.nvim_buf_get_mark(0, ">")[1]
    if pos ~= end_pos then
      start_line = math.min(pos, end_pos)
      end_line = math.max(pos, end_pos)
    end
  end

  local context = M.get_context()

  if context.type == "no_pr" then
    vim.notify("No active PR review session", vim.log.levels.WARN)
    return
  end

  if context.type == "error" then
    vim.notify(context.error, vim.log.levels.ERROR)
    return
  end

  if context.type == "explorer" then
    vim.notify("Cannot add comment from explorer. Open a file first.", vim.log.levels.WARN)
    return
  end

  if context.type == "unknown" then
    vim.notify("Cannot determine context for adding comment", vim.log.levels.ERROR)
    return
  end

  local comments_input = require("ghpr.review.comments_input")
  local api = require("ghpr.review.api")
  local comments = require("ghpr.review.comments")
  local state = require("ghpr.review.state")

  if context.type == "comment" then
    -- Reply to existing thread
    local diff_bufnr = vim.api.nvim_get_current_buf()
    comments_input.prompt_reply(
      context.owner,
      context.repo,
      context.pr_number,
      context.thread.id,
      function(body, ctx)
        api.add_thread_reply(ctx.thread_id, body, function(comment, err)
          if err then
            vim.notify("Failed to add reply: " .. err, vim.log.levels.ERROR)
            return
          end

          -- Update local state
          comments.add_reply_optimistic(ctx.owner, ctx.repo, ctx.pr_number, ctx.thread_id, comment)

          -- Refresh UI in the captured diff buffer
          require("ghpr.review.comments_ui").render_inline_comments(
            diff_bufnr,
            ctx.owner,
            ctx.repo,
            ctx.pr_number,
            context.file_path
          )

          vim.notify("Reply added", vim.log.levels.INFO)
        end)
      end
    )
  elseif context.type == "diff_line" then
    -- New thread on diff line
    local pr_metadata = state.get_pr_metadata(context.owner, context.repo, context.pr_number)
    if not pr_metadata then
      vim.notify("PR metadata not available", vim.log.levels.ERROR)
      return
    end

    local side = get_diff_side()
    local diff_bufnr = vim.api.nvim_get_current_buf()

    -- The comment_line variable below should be end_line or context.line.
    local comment_line = end_line or context.line
    comments_input.prompt_new_comment({
      owner = context.owner,
      repo = context.repo,
      pr_number = context.pr_number,
      file_path = context.file_path,
      side = side,
      line = comment_line,
      start_line = start_line,
    }, function(body, ctx)
      api.add_review_thread({
        pr_id = pr_metadata.pr_id,
        path = ctx.file_path,
        line = ctx.line,
        side = ctx.side,
        body = body,
        start_line = start_line,
      }, function(thread, err)
        if err then
          vim.notify("Failed to add comment: " .. err, vim.log.levels.ERROR)
          return
        end

        if not thread or type(thread) ~= "table" then
          vim.notify("Failed to add comment: invalid response from API", vim.log.levels.ERROR)
          return
        end

        -- Update local state
        comments.add_thread_optimistic(ctx.owner, ctx.repo, ctx.pr_number, thread)

        -- Refresh UI in the captured diff buffer
        require("ghpr.review.comments_ui").render_inline_comments(
          diff_bufnr,
          ctx.owner,
          ctx.repo,
          ctx.pr_number,
          ctx.file_path
        )

        -- Update explorer indicators
        require("ghpr.review.indicators").update()

        vim.notify("Comment added", vim.log.levels.INFO)
      end)
    end)
  end
end

-- Delete a comment (only if viewer is the author)
function M.delete_comment()
  local context = M.get_context()

  if context.type ~= "comment" then
    vim.notify("No comment under cursor", vim.log.levels.WARN)
    return
  end

  local thread = context.thread
  if not thread or not thread.comments or #thread.comments == 0 then
    vim.notify("No comments in thread", vim.log.levels.ERROR)
    return
  end

  -- For now, delete the first comment in the thread (the root comment)
  local comment = thread.comments[1]

  if not comment.viewerDidAuthor then
    vim.notify("Can only delete your own comments", vim.log.levels.WARN)
    return
  end

  -- Confirm deletion
  vim.ui.input({ prompt = "Delete comment? (y/n): " }, function(input)
    if input ~= "y" and input ~= "Y" then
      vim.notify("Cancelled", vim.log.levels.INFO)
      return
    end

    local api = require("ghpr.review.api")
    local comments = require("ghpr.review.comments")

    api.delete_comment(comment.id, function(_, err)
      if err then
        vim.notify("Failed to delete comment: " .. err, vim.log.levels.ERROR)
        return
      end

      -- Update local state
      comments.delete_comment_optimistic(context.owner, context.repo, context.pr_number, thread.id, comment.id)

      -- Refresh UI
      local bufnr = vim.api.nvim_get_current_buf()
      require("ghpr.review.comments_ui").render_inline_comments(
        bufnr,
        context.owner,
        context.repo,
        context.pr_number,
        context.file_path
      )

      -- Update explorer indicators
      require("ghpr.review.indicators").update()

      vim.notify("Comment deleted", vim.log.levels.INFO)
    end)
  end)
end

-- Edit a comment (only if viewer is the author)
function M.edit_comment()
  local context = M.get_context()

  if context.type ~= "comment" then
    vim.notify("No comment under cursor", vim.log.levels.WARN)
    return
  end

  local thread = context.thread
  if not thread or not thread.comments or #thread.comments == 0 then
    vim.notify("No comments in thread", vim.log.levels.ERROR)
    return
  end

  -- For now, edit the first comment in the thread
  local comment = thread.comments[1]

  if not comment.viewerDidAuthor then
    vim.notify("Can only edit your own comments", vim.log.levels.WARN)
    return
  end

  local comments_input = require("ghpr.review.comments_input")
  local api = require("ghpr.review.api")
  local comments = require("ghpr.review.comments")

  comments_input.prompt_edit(
    context.owner,
    context.repo,
    context.pr_number,
    thread.id,
    comment.id,
    comment.body,
    function(body, ctx)
      api.update_comment(ctx.comment_id, body, function(_, err)
        if err then
          vim.notify("Failed to update comment: " .. err, vim.log.levels.ERROR)
          return
        end

        -- Update local state
        comments.update_comment_optimistic(ctx.owner, ctx.repo, ctx.pr_number, ctx.thread_id, ctx.comment_id, body)

        -- Refresh UI
        local bufnr = vim.api.nvim_get_current_buf()
        require("ghpr.review.comments_ui").render_inline_comments(
          bufnr,
          ctx.owner,
          ctx.repo,
          ctx.pr_number,
          context.file_path
        )

        vim.notify("Comment updated", vim.log.levels.INFO)
      end)
    end
  )
end

-- Toggle thread detail view
function M.toggle_thread_detail()
  local context = M.get_context()

  if context.type ~= "comment" then
    vim.notify("No comment under cursor", vim.log.levels.WARN)
    return
  end

  require("ghpr.review.comments_ui").show_thread_detail(
    context.owner,
    context.repo,
    context.pr_number,
    context.thread.id
  )
end

return M
