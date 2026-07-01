-- PR review comments state management
local M = {}

---@class Comment
---@field id string
---@field body string
---@field createdAt string ISO 8601 timestamp from GitHub GraphQL
---@field author { login: string }
---@field viewerDidAuthor boolean

---@class ReviewThread
---@field id string
---@field path string
---@field line integer
---@field isResolved boolean
---@field isOutdated boolean
---@field diffSide "LEFT"|"RIGHT"
---@field comments Comment[]

local comment_cache = {}

-- Generate cache key for a PR
local function get_pr_key(owner, repo, pr_number)
  return string.format("%s/%s#%d", owner, repo, pr_number)
end

-- Generate line key for by_line lookup
local function get_line_key(path, line)
  return string.format("%s:%d", path, line)
end

-- Initialize comment state for a PR from API data
function M.initialize(owner, repo, pr_number, threads_data)
  local pr_key = get_pr_key(owner, repo, pr_number)

  -- Create state structure
  comment_cache[pr_key] = {
    threads = {},
    by_file = {},
    by_line = {},
  }

  local cache = comment_cache[pr_key]

  -- Process each thread
  for _, thread in ipairs(threads_data) do
    -- Store thread
    cache.threads[thread.id] = thread

    -- Index by file
    if thread.path then
      if not cache.by_file[thread.path] then
        cache.by_file[thread.path] = {}
      end
      table.insert(cache.by_file[thread.path], thread.id)

      -- Index by line
      if thread.line then
        local line_key = get_line_key(thread.path, thread.line)
        if not cache.by_line[line_key] then
          cache.by_line[line_key] = {}
        end
        table.insert(cache.by_line[line_key], thread.id)
      end
    end
  end

  vim.notify(
    string.format("Initialized comments: %d threads", #threads_data),
    vim.log.levels.DEBUG
  )
end

-- Fetch comments from GitHub API
function M.fetch_comments(owner, repo, pr_number, callback)
  local api = require("ghpr.review.api")

  api.fetch_review_threads(owner, repo, pr_number, function(threads, err)
    if err then
      callback(nil, err)
      return
    end

    -- Initialize state with fetched threads
    M.initialize(owner, repo, pr_number, threads)
    callback(threads)
  end)
end

-- Get all threads for a file
function M.get_threads_for_file(owner, repo, pr_number, file_path)
  local pr_key = get_pr_key(owner, repo, pr_number)
  local cache = comment_cache[pr_key]

  if not cache or not cache.by_file[file_path] then
    return {}
  end

  local threads = {}
  for _, thread_id in ipairs(cache.by_file[file_path]) do
    table.insert(threads, cache.threads[thread_id])
  end

  return threads
end

-- Get thread at specific line in file
function M.get_thread_at_line(owner, repo, pr_number, file_path, line)
  local pr_key = get_pr_key(owner, repo, pr_number)
  local cache = comment_cache[pr_key]

  if not cache then
    return nil
  end

  local line_key = get_line_key(file_path, line)
  local thread_ids = cache.by_line[line_key]

  if not thread_ids or #thread_ids == 0 then
    return nil
  end

  -- Return first thread at this line
  return cache.threads[thread_ids[1]]
end

-- Get single thread by ID
function M.get_thread(owner, repo, pr_number, thread_id)
  local pr_key = get_pr_key(owner, repo, pr_number)
  local cache = comment_cache[pr_key]

  if not cache then
    return nil
  end

  return cache.threads[thread_id]
end

-- Add a new thread optimistically
function M.add_thread_optimistic(owner, repo, pr_number, thread_data)
  local pr_key = get_pr_key(owner, repo, pr_number)
  local cache = comment_cache[pr_key]

  if not cache then
    return false
  end

  -- Store thread
  cache.threads[thread_data.id] = thread_data

  -- Index by file
  if thread_data.path then
    if not cache.by_file[thread_data.path] then
      cache.by_file[thread_data.path] = {}
    end
    table.insert(cache.by_file[thread_data.path], thread_data.id)

    -- Index by line
    if thread_data.line then
      local line_key = get_line_key(thread_data.path, thread_data.line)
      if not cache.by_line[line_key] then
        cache.by_line[line_key] = {}
      end
      table.insert(cache.by_line[line_key], thread_data.id)
    end
  end

  return true
end

-- Add a reply to an existing thread
function M.add_reply_optimistic(owner, repo, pr_number, thread_id, comment_data)
  local pr_key = get_pr_key(owner, repo, pr_number)
  local cache = comment_cache[pr_key]

  if not cache or not cache.threads[thread_id] then
    return false
  end

  table.insert(cache.threads[thread_id].comments, comment_data)
  return true
end

-- Update a comment in a thread
function M.update_comment_optimistic(owner, repo, pr_number, thread_id, comment_id, new_body)
  local pr_key = get_pr_key(owner, repo, pr_number)
  local cache = comment_cache[pr_key]

  if not cache or not cache.threads[thread_id] then
    return false
  end

  local thread = cache.threads[thread_id]
  for i, comment in ipairs(thread.comments) do
    if comment.id == comment_id then
      thread.comments[i].body = new_body
      return true
    end
  end

  return false
end

-- Delete a comment from a thread
function M.delete_comment_optimistic(owner, repo, pr_number, thread_id, comment_id)
  local pr_key = get_pr_key(owner, repo, pr_number)
  local cache = comment_cache[pr_key]

  if not cache or not cache.threads[thread_id] then
    return false
  end

  local thread = cache.threads[thread_id]
  for i, comment in ipairs(thread.comments) do
    if comment.id == comment_id then
      table.remove(thread.comments, i)

      -- If thread is now empty, remove it entirely
      if #thread.comments == 0 then
        M.delete_thread(owner, repo, pr_number, thread_id)
      end

      return true
    end
  end

  return false
end

-- Delete entire thread
function M.delete_thread(owner, repo, pr_number, thread_id)
  local pr_key = get_pr_key(owner, repo, pr_number)
  local cache = comment_cache[pr_key]

  if not cache or not cache.threads[thread_id] then
    return false
  end

  local thread = cache.threads[thread_id]

  -- Remove from by_file index
  if thread.path and cache.by_file[thread.path] then
    for i, id in ipairs(cache.by_file[thread.path]) do
      if id == thread_id then
        table.remove(cache.by_file[thread.path], i)
        break
      end
    end
  end

  -- Remove from by_line index
  if thread.path and thread.line then
    local line_key = get_line_key(thread.path, thread.line)
    if cache.by_line[line_key] then
      for i, id in ipairs(cache.by_line[line_key]) do
        if id == thread_id then
          table.remove(cache.by_line[line_key], i)
          break
        end
      end
    end
  end

  -- Remove thread
  cache.threads[thread_id] = nil
  return true
end

-- Clear comments for a PR
function M.clear(owner, repo, pr_number)
  local pr_key = get_pr_key(owner, repo, pr_number)
  comment_cache[pr_key] = nil
end

-- Get statistics for comments in a PR
function M.get_stats(owner, repo, pr_number)
  local pr_key = get_pr_key(owner, repo, pr_number)
  local cache = comment_cache[pr_key]

  if not cache then
    return {
      total_threads = 0,
      total_comments = 0,
      unresolved_threads = 0,
      outdated_threads = 0,
    }
  end

  local total_threads = 0
  local total_comments = 0
  local unresolved = 0
  local outdated = 0

  for _, thread in pairs(cache.threads) do
    total_threads = total_threads + 1
    total_comments = total_comments + #thread.comments

    if not thread.isResolved then
      unresolved = unresolved + 1
    end

    if thread.isOutdated then
      outdated = outdated + 1
    end
  end

  return {
    total_threads = total_threads,
    total_comments = total_comments,
    unresolved_threads = unresolved,
    outdated_threads = outdated,
  }
end

return M
