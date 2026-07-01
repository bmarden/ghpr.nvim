-- GitHub GraphQL API wrapper with async execution and caching
local M = {}

-- Weak-referenced cache for automatic GC
local cache = setmetatable({}, { __mode = "v" })

-- Cache key format
local function cache_key(owner, repo, pr)
	return string.format("%s/%s#%d", owner, repo, pr)
end

-- Check if cached data is still valid
local function is_cache_valid(cached_data)
	if not cached_data then
		return false
	end

	local config = require("ghpr.config")
	local ttl = config.options.cache_ttl
	local age = os.time() - cached_data.timestamp

	return age < ttl
end

-- Notify user with configured level
local function notify(message, level)
	local config = require("ghpr.config")
	if config.options.notifications.enabled then
		vim.notify(message, level or config.options.notifications.level)
	end
end

-- GraphQL query for PR files with viewed state
local VIEWED_FILES_QUERY = [[
query($owner: String!, $name: String!, $pr: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $pr) {
      id
      baseRefName
      headRefName
      files(first: 100, after: $cursor) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          path
          viewerViewedState
          additions
          deletions
        }
      }
    }
  }
}
]]

-- Execute gh CLI GraphQL query asynchronously
local function execute_graphql(query, variables, callback)
	local config = require("ghpr.config")
	local gh_path = config.options.gh_cli_path

	-- Build the command arguments
	local args = { "api", "graphql", "-f", "query=" .. query }

	-- Add variables
	for key, value in pairs(variables) do
		local flag = "-F"
		if type(value) == "string" then
			flag = "-f"
		end
		table.insert(args, flag)
		table.insert(args, string.format("%s=%s", key, tostring(value)))
	end

	-- Execute asynchronously
	vim.system({ gh_path, unpack(args) }, { text = true }, function(result)
		vim.schedule(function()
			if result.code ~= 0 then
				local error_msg = result.stderr or "Unknown error"
				notify("GitHub API error: " .. error_msg, vim.log.levels.ERROR)
				callback(nil, error_msg)
				return
			end

			local ok, data = pcall(vim.json.decode, result.stdout)
			if not ok then
				notify("Failed to parse GitHub API response", vim.log.levels.ERROR)
				callback(nil, "JSON parse error")
				return
			end

			if data.errors then
				local error_msg = vim.inspect(data.errors)
				notify("GitHub GraphQL error: " .. error_msg, vim.log.levels.ERROR)
				callback(nil, error_msg)
				return
			end

			callback(data.data)
		end)
	end)
end

-- Fetch PR files with pagination support
local function fetch_all_files(owner, repo, pr_number, callback)
	local all_files = {}
	local pr_metadata = nil

	local function fetch_page(cursor)
		local variables = {
			owner = owner,
			name = repo,
			pr = pr_number,
			cursor = cursor,
		}

		execute_graphql(VIEWED_FILES_QUERY, variables, function(data, err)
			if err then
				callback(nil, err)
				return
			end

			if not data or not data.repository or not data.repository.pullRequest then
				callback(nil, "PR not found")
				return
			end

			local pr = data.repository.pullRequest

			-- Store PR metadata on first page
			if not pr_metadata then
				pr_metadata = {
					id = pr.id,
					base_ref = pr.baseRefName,
					head_ref = pr.headRefName,
				}
			end

			-- Collect files from this page
			if pr.files and pr.files.nodes then
				for _, file in ipairs(pr.files.nodes) do
					table.insert(all_files, file)
				end
			end

			-- Check if there are more pages
			if pr.files.pageInfo.hasNextPage then
				fetch_page(pr.files.pageInfo.endCursor)
			else
				-- All pages fetched
				callback({
					pr_metadata = pr_metadata,
					files = all_files,
				})
			end
		end)
	end

	-- Start fetching from first page
	fetch_page(nil)
end

-- Get PR files with viewed state (cached)
function M.get_pr_files(owner, repo, pr_number, callback)
	local key = cache_key(owner, repo, pr_number)
	local cached = cache[key]

	if is_cache_valid(cached) then
		notify("Using cached PR data", vim.log.levels.DEBUG)
		vim.schedule(function()
			callback(cached.data)
		end)
		return
	end

	notify("Fetching PR files from GitHub...", vim.log.levels.INFO)

	fetch_all_files(owner, repo, pr_number, function(data, err)
		if err then
			callback(nil, err)
			return
		end

		-- Cache the result
		cache[key] = {
			data = data,
			timestamp = os.time(),
		}

		callback(data)
	end)
end

-- Invalidate cache for a specific PR
function M.invalidate_cache(owner, repo, pr_number)
	local key = cache_key(owner, repo, pr_number)
	cache[key] = nil
end

-- Clear all cache
function M.clear_cache()
	for k in pairs(cache) do
		cache[k] = nil
	end
end

-- Mark a file as viewed/unviewed on GitHub
function M.mark_file_viewed(owner, repo, pr_number, file_path, viewed, callback)
	-- First, get PR ID from cache or state
	local state = require("ghpr.review.state")
	local pr_metadata = state.get_pr_metadata(owner, repo, pr_number)

	if not pr_metadata or not pr_metadata.pr_id then
		notify("PR metadata not available", vim.log.levels.ERROR)
		callback("PR metadata not available")
		return
	end

	-- GitHub uses different mutations for marking viewed vs unviewed
	local mutation
	if viewed then
		mutation = [[
  mutation($pullRequestId: ID!, $path: String!) {
    markFileAsViewed(input: {pullRequestId: $pullRequestId, path: $path}) {
      pullRequest {
        id
      }
    }
  }
  ]]
	else
		mutation = [[
  mutation($pullRequestId: ID!, $path: String!) {
    unmarkFileAsViewed(input: {pullRequestId: $pullRequestId, path: $path}) {
      pullRequest {
        id
      }
    }
  }
  ]]
	end

	local variables = {
		pullRequestId = pr_metadata.pr_id,
		path = file_path,
	}

	-- Execute the mutation
	execute_graphql(mutation, variables, function(_, err)
		if err then
			local action = viewed and "viewed" or "unviewed"
			notify("Failed to mark file as " .. action .. ": " .. err, vim.log.levels.ERROR)
			callback(err)
			return
		end

		-- Invalidate cache so next fetch gets fresh data
		M.invalidate_cache(owner, repo, pr_number)
		callback(nil)
	end)
end

-- GraphQL query for PR review threads
local REVIEW_THREADS_QUERY = [[
query($owner: String!, $name: String!, $pr: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $pr) {
      id
      reviewThreads(first: 100, after: $cursor) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          id
          path
          line
          isResolved
          isOutdated
          diffSide
          comments(first: 50) {
            nodes {
              id
              body
              createdAt
              author {
                login
              }
              viewerDidAuthor
            }
          }
        }
      }
    }
  }
}
]]

-- Fetch PR review threads with pagination
function M.fetch_review_threads(owner, repo, pr_number, callback)
	local all_threads = {}

	local function fetch_page(cursor)
		local variables = {
			owner = owner,
			name = repo,
			pr = pr_number,
			cursor = cursor,
		}

		execute_graphql(REVIEW_THREADS_QUERY, variables, function(data, err)
			if err then
				callback(nil, err)
				return
			end

			if not data or not data.repository or not data.repository.pullRequest then
				callback(nil, "PR not found")
				return
			end

			local pr = data.repository.pullRequest

			-- Collect threads from this page
			if pr.reviewThreads and pr.reviewThreads.nodes then
				for _, thread in ipairs(pr.reviewThreads.nodes) do
					-- Flatten the comments.nodes structure to just comments array
					if thread.comments and thread.comments.nodes then
						thread.comments = thread.comments.nodes
					else
						thread.comments = {}
					end
					table.insert(all_threads, thread)
				end
			end

			-- Check if there are more pages
			if pr.reviewThreads.pageInfo.hasNextPage then
				fetch_page(pr.reviewThreads.pageInfo.endCursor)
			else
				-- All pages fetched
				callback(all_threads)
			end
		end)
	end

	-- Start fetching from first page
	fetch_page(nil)
end

---@class AddReviewThreadOpts
---@field pr_id string GraphQL ID of the pull request
---@field path string File path for the comment
---@field line number Line number for the comment
---@field side string "LEFT" or "RIGHT" for the diff side
---@field body string Comment body text
---@field start_line? number Optional starting line for multi-line comments (GitHub API v2)

-- Add a new review thread
--- @param opts AddReviewThreadOpts
--- @param callback fun(thread: table?, err: string?) Callback function to receive the new thread or error message
function M.add_review_thread(opts, callback)
	local mutation = [[
mutation($pullRequestId: ID!, $path: String!, $line: Int!, $side: DiffSide!, $body: String!, $startLine: Int, $startSide: DiffSide) {
  addPullRequestReviewThread(input: {
    pullRequestId: $pullRequestId,
    path: $path,
    line: $line,
    side: $side,
    body: $body,
    startLine: $startLine,
    startSide: $startSide
  }) {
    thread {
      id
      path
      line
      isResolved
      isOutdated
      diffSide
      comments(first: 50) {
        nodes {
          id
          body
          createdAt
          author {
            login
          }
          viewerDidAuthor
        }
      }
    }
  }
}
]]

	local variables = {
		pullRequestId = opts.pr_id,
		path = opts.path,
		line = opts.line,
		side = opts.side,
		body = opts.body,
		startLine = opts.start_line,
		startSide = opts.start_line and opts.side, -- GitHub API v2 requires startDiffSide if startLine is provided
	}

	execute_graphql(mutation, variables, function(data, err)
		if err then
			notify("Failed to add comment: " .. err, vim.log.levels.ERROR)
			callback(nil, err)
			return
		end

		local thread = data and data.addPullRequestReviewThread and data.addPullRequestReviewThread.thread
		if thread and type(thread) == "table" then
			-- Flatten comments.nodes to match fetch_review_threads format
			if thread.comments and thread.comments.nodes then
				thread.comments = thread.comments.nodes
			elseif not thread.comments or type(thread.comments) ~= "table" then
				thread.comments = {}
			end
			callback(thread)
			return
		end

		-- Thread came back null (known GitHub API issue). Re-fetch threads to find it.
		local pr = vim.g.ghpr_active_pr
		if not pr then
			callback(nil, "Comment may have been created but could not verify")
			return
		end

		M.fetch_review_threads(pr.owner, pr.repo, pr.number, function(threads, fetch_err)
			if fetch_err then
				callback(nil, "Comment may have been created but failed to re-fetch threads: " .. fetch_err)
				return
			end

			-- Find the most recent thread matching our path/line/side
			for i = #threads, 1, -1 do
				local t = threads[i]
				if t.path == opts.path and t.line == opts.line and t.diffSide == opts.side then
					callback(t)
					return
				end
			end

			callback(nil, "Comment may have been created but could not find the new thread")
		end)
	end)
end

-- Add reply to existing review thread
function M.add_thread_reply(thread_id, body, callback)
	local mutation = [[
mutation($pullRequestReviewThreadId: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {
    pullRequestReviewThreadId: $pullRequestReviewThreadId,
    body: $body
  }) {
    comment {
      id
      body
      createdAt
      author {
        login
      }
      viewerDidAuthor
    }
  }
}
]]

	local variables = {
		pullRequestReviewThreadId = thread_id,
		body = body,
	}

	execute_graphql(mutation, variables, function(data, err)
		if err then
			notify("Failed to add reply: " .. err, vim.log.levels.ERROR)
			callback(nil, err)
			return
		end

		if data and data.addPullRequestReviewThreadReply then
			callback(data.addPullRequestReviewThreadReply.comment)
		else
			callback(nil, "Invalid response")
		end
	end)
end

-- Update an existing comment
function M.update_comment(comment_id, body, callback)
	local mutation = [[
mutation($pullRequestReviewCommentId: ID!, $body: String!) {
  updatePullRequestReviewComment(input: {
    pullRequestReviewCommentId: $pullRequestReviewCommentId,
    body: $body
  }) {
    pullRequestReviewComment {
      id
      body
      createdAt
      author {
        login
      }
      viewerDidAuthor
    }
  }
}
]]

	local variables = {
		pullRequestReviewCommentId = comment_id,
		body = body,
	}

	execute_graphql(mutation, variables, function(data, err)
		if err then
			notify("Failed to update comment: " .. err, vim.log.levels.ERROR)
			callback(nil, err)
			return
		end

		if data and data.updatePullRequestReviewComment then
			callback(data.updatePullRequestReviewComment.pullRequestReviewComment)
		else
			callback(nil, "Invalid response")
		end
	end)
end

-- Delete a comment
function M.delete_comment(comment_id, callback)
	local mutation = [[
mutation($id: ID!) {
  deletePullRequestReviewComment(input: {
    id: $id
  }) {
    pullRequestReviewComment {
      id
    }
  }
}
]]

	local variables = {
		id = comment_id,
	}

	execute_graphql(mutation, variables, function(data, err)
		if err then
			notify("Failed to delete comment: " .. err, vim.log.levels.ERROR)
			callback(nil, err)
			return
		end

		callback(data)
	end)
end

return M
