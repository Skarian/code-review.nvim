local id = require("code-review.id")
local time = require("code-review.time")

local M = {}

local function stamp(now)
  return now or time.now()
end

function M.new_store(root, root_hash)
  return {
    schema_version = 1,
    project_root = root,
    project_root_hash = root_hash,
    last_active_review_id = nil,
    reviews = {},
  }
end

function M.new_review(name, now)
  assert(type(name) == "string" and vim.trim(name) ~= "", "review name required")
  now = stamp(now)
  return {
    id = id.new("review"),
    name = vim.trim(name),
    created_at = now,
    updated_at = now,
    comments = {},
  }
end

function M.new_comment(now)
  now = stamp(now)
  return {
    id = id.new("comment"),
    body = "",
    created_at = now,
    updated_at = now,
    file_references = {},
  }
end

function M.new_file_reference(opts, now)
  now = stamp(now)
  return {
    id = id.new("ref"),
    relative_path = opts.relative_path,
    start_line = opts.start_line,
    end_line = opts.end_line,
    selected_lines_snapshot = opts.selected_lines_snapshot or {},
    stale_state = opts.stale_state or "fresh",
    stale_reason = opts.stale_reason,
    created_at = now,
    updated_at = now,
  }
end

function M.comment_complete(comment)
  return comment
    and type(comment.body) == "string"
    and vim.trim(comment.body) ~= ""
    and type(comment.file_references) == "table"
    and #comment.file_references > 0
end

function M.find_review(store, review_id)
  if not store then
    return nil
  end
  for _, review in ipairs(store.reviews or {}) do
    if review.id == review_id then
      return review
    end
  end
end

function M.find_comment(review, comment_id)
  if not review then
    return nil
  end
  for _, comment in ipairs(review.comments or {}) do
    if comment.id == comment_id then
      return comment
    end
  end
end

function M.sort_reviews(reviews)
  table.sort(reviews, function(a, b)
    return tostring(a.updated_at) > tostring(b.updated_at)
  end)
  return reviews
end

function M.comments_newest(review)
  local comments = vim.deepcopy(review and review.comments or {})
  table.sort(comments, function(a, b)
    return tostring(a.updated_at) > tostring(b.updated_at)
  end)
  return comments
end

function M.comments_oldest(review)
  local comments = vim.deepcopy(review and review.comments or {})
  table.sort(comments, function(a, b)
    return tostring(a.created_at) < tostring(b.created_at)
  end)
  return comments
end

function M.touch_review(review, now)
  review.updated_at = stamp(now)
end

function M.touch_comment(review, comment, now)
  comment.updated_at = stamp(now)
  M.touch_review(review, now)
end

return M
