-- Viewed state management
local M = {}

-- Session state storage
local state_cache = {}

-- Generate cache key for a PR
local function get_pr_key(owner, repo, pr_number)
  return string.format("%s/%s#%d", owner, repo, pr_number)
end

-- Initialize state for a PR from API data
function M.initialize(owner, repo, pr_number, files_data)
  local pr_key = get_pr_key(owner, repo, pr_number)

  -- Create state structure
  state_cache[pr_key] = {
    files = {},
    pr_id = files_data.pr_metadata.id,
    owner = owner,
    repo = repo,
    pr_number = pr_number,
    comments = nil, -- Lazy-loaded by comments.lua
  }

  -- Initialize file states from API data
  for _, file in ipairs(files_data.files) do
    state_cache[pr_key].files[file.path] = {
      viewed = file.viewerViewedState == "VIEWED",
      pending = false,
    }
  end

  vim.notify(
    string.format("Initialized state for %d files", #files_data.files),
    vim.log.levels.DEBUG
  )
end

-- Get current viewed state for a file
function M.is_viewed(owner, repo, pr_number, file_path)
  local pr_key = get_pr_key(owner, repo, pr_number)
  local pr_state = state_cache[pr_key]

  if not pr_state or not pr_state.files[file_path] then
    return false
  end

  return pr_state.files[file_path].viewed
end

-- Get all files in a PR with their states
function M.get_files(owner, repo, pr_number)
  local pr_key = get_pr_key(owner, repo, pr_number)
  local pr_state = state_cache[pr_key]

  if not pr_state then
    return {}
  end

  local files = {}
  for path, state in pairs(pr_state.files) do
    table.insert(files, {
      path = path,
      viewed = state.viewed,
      pending = state.pending,
    })
  end

  -- Sort by path for consistent ordering
  table.sort(files, function(a, b)
    return a.path < b.path
  end)

  return files
end

-- Get unviewed files only
function M.get_unviewed_files(owner, repo, pr_number)
  local all_files = M.get_files(owner, repo, pr_number)
  local unviewed = {}

  for _, file in ipairs(all_files) do
    if not file.viewed then
      table.insert(unviewed, file)
    end
  end

  return unviewed
end

-- Optimistically update local state (before API confirms)
function M.set_viewed_optimistic(owner, repo, pr_number, file_path, viewed)
  local pr_key = get_pr_key(owner, repo, pr_number)
  local pr_state = state_cache[pr_key]

  if not pr_state then
    vim.notify("No state found for PR", vim.log.levels.ERROR)
    return false
  end

  if not pr_state.files[file_path] then
    vim.notify("File not found in PR state", vim.log.levels.ERROR)
    return false
  end

  -- Store previous state for rollback
  local previous_state = pr_state.files[file_path].viewed

  -- Optimistically update
  pr_state.files[file_path].viewed = viewed
  pr_state.files[file_path].pending = true

  vim.notify(
    string.format("Marked %s as %s", file_path, viewed and "viewed" or "unviewed"),
    vim.log.levels.INFO
  )

  return true, previous_state
end

-- Confirm state change after API success
function M.confirm_viewed(owner, repo, pr_number, file_path)
  local pr_key = get_pr_key(owner, repo, pr_number)
  local pr_state = state_cache[pr_key]

  if pr_state and pr_state.files[file_path] then
    pr_state.files[file_path].pending = false
  end
end

-- Rollback state change after API failure
function M.rollback_viewed(owner, repo, pr_number, file_path, previous_state)
  local pr_key = get_pr_key(owner, repo, pr_number)
  local pr_state = state_cache[pr_key]

  if pr_state and pr_state.files[file_path] then
    pr_state.files[file_path].viewed = previous_state
    pr_state.files[file_path].pending = false

    vim.notify(
      string.format("Failed to update %s, rolled back", file_path),
      vim.log.levels.WARN
    )
  end
end

-- Get PR metadata (for API calls)
function M.get_pr_metadata(owner, repo, pr_number)
  local pr_key = get_pr_key(owner, repo, pr_number)
  local pr_state = state_cache[pr_key]

  if not pr_state then
    return nil
  end

  return {
    pr_id = pr_state.pr_id,
    owner = pr_state.owner,
    repo = pr_state.repo,
    pr_number = pr_state.pr_number,
  }
end

-- Clear state for a PR
function M.clear(owner, repo, pr_number)
  local pr_key = get_pr_key(owner, repo, pr_number)
  state_cache[pr_key] = nil
end

-- Get statistics for a PR
function M.get_stats(owner, repo, pr_number)
  local files = M.get_files(owner, repo, pr_number)
  local viewed_count = 0
  local pending_count = 0

  for _, file in ipairs(files) do
    if file.viewed then
      viewed_count = viewed_count + 1
    end
    if file.pending then
      pending_count = pending_count + 1
    end
  end

  return {
    total = #files,
    viewed = viewed_count,
    unviewed = #files - viewed_count,
    pending = pending_count,
  }
end

return M
