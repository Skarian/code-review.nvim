local id = require("code-review.id")
local time = require("code-review.time")
local path = require("code-review.path")

local M = {}

local stale_states = { fresh = true, stale = true }
local stale_reasons = {
  missing_file = true,
  range_out_of_bounds = true,
  content_mismatch = true,
  unknown = true,
}

local function corrupt(message)
  return { ok = false, kind = "corrupt", message = message }
end

local function ids_unique(items)
  local seen = {}
  for _, item in ipairs(items or {}) do
    if seen[item.id] then
      return false
    end
    seen[item.id] = true
  end
  return true
end

function M.validate(store, expected_root_hash)
  if type(store) ~= "table" then
    return corrupt("store is not an object")
  end
  if type(store.schema_version) ~= "number" then
    return corrupt("missing schema_version")
  end
  if store.schema_version > 1 then
    return { ok = false, kind = "unsupported_schema", message = "unsupported schema_version" }
  end
  if store.schema_version ~= 1 then
    return corrupt("invalid schema_version")
  end
  if type(store.project_root) ~= "string" or type(store.project_root_hash) ~= "string" or type(store.reviews) ~= "table" then
    return corrupt("missing required store fields")
  end
  if expected_root_hash and store.project_root_hash ~= expected_root_hash then
    return { ok = false, kind = "root_mismatch", message = "project root hash mismatch" }
  end
  if not ids_unique(store.reviews) then
    return corrupt("duplicate review id")
  end

  local review_ids = {}
  for _, review in ipairs(store.reviews) do
    if not id.valid(review.id, "review") then
      return corrupt("invalid review id")
    end
    review_ids[review.id] = true
    if type(review.name) ~= "string" or not time.is_iso_utc(review.created_at) or not time.is_iso_utc(review.updated_at) then
      return corrupt("invalid review fields")
    end
    if type(review.comments) ~= "table" then
      return corrupt("invalid comments")
    end
    if not ids_unique(review.comments) then
      return corrupt("duplicate comment id")
    end
    for _, comment in ipairs(review.comments) do
      if not id.valid(comment.id, "comment") or type(comment.body) ~= "string" or not time.is_iso_utc(comment.created_at) or not time.is_iso_utc(comment.updated_at) then
        return corrupt("invalid comment fields")
      end
      if type(comment.file_references) ~= "table" then
        return corrupt("invalid file_references")
      end
      if not ids_unique(comment.file_references) then
        return corrupt("duplicate file reference id")
      end
      for _, ref in ipairs(comment.file_references) do
        if not id.valid(ref.id, "ref") or type(ref.relative_path) ~= "string" or path.is_absolute(ref.relative_path) then
          return corrupt("invalid file reference path")
        end
        if type(ref.start_line) ~= "number" or type(ref.end_line) ~= "number" or ref.start_line < 1 or ref.end_line < ref.start_line or ref.start_line % 1 ~= 0 or ref.end_line % 1 ~= 0 then
          return corrupt("invalid file reference range")
        end
        if type(ref.selected_lines_snapshot) ~= "table" or not time.is_iso_utc(ref.created_at) or not time.is_iso_utc(ref.updated_at) then
          return corrupt("invalid file reference fields")
        end
        for _, line in ipairs(ref.selected_lines_snapshot) do
          if type(line) ~= "string" then
            return corrupt("invalid selected line snapshot")
          end
        end
        if not stale_states[ref.stale_state] then
          ref.stale_state = "stale"
          ref.stale_reason = "unknown"
        elseif ref.stale_state == "stale" and not stale_reasons[ref.stale_reason] then
          ref.stale_state = "stale"
          ref.stale_reason = "unknown"
        elseif ref.stale_state == "fresh" then
          ref.stale_reason = nil
        end
      end
    end
  end

  if store.last_active_review_id and not review_ids[store.last_active_review_id] then
    store.last_active_review_id = nil
  end
  return { ok = true, store = store }
end

return M
