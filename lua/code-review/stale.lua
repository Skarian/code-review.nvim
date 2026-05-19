local path = require("code-review.path")

local M = {}

local function read_lines(root, relative_path, bufnr)
  local abs = path.join(root, relative_path)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and not vim.bo[bufnr].modified and path.realpath(vim.api.nvim_buf_get_name(bufnr)) == path.realpath(abs) then
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end
  local ok, lines = pcall(vim.fn.readfile, abs)
  if not ok then
    return nil, "unknown"
  end
  return lines
end

function M.check_reference(root, ref, bufnr)
  local lines, read_reason = read_lines(root, ref.relative_path, bufnr)
  if not lines then
    local stat = (vim.uv or vim.loop).fs_stat(path.join(root, ref.relative_path))
    return false, stat and read_reason or "missing_file"
  end
  if ref.end_line > #lines then
    return false, "range_out_of_bounds"
  end
  local current = {}
  for i = ref.start_line, ref.end_line do
    current[#current + 1] = lines[i]
  end
  if vim.deep_equal(current, ref.selected_lines_snapshot) then
    return true, nil
  end
  return false, "content_mismatch"
end

function M.refresh_review(root, review, bufnr)
  local stale_count = 0
  local changed = false
  for _, comment in ipairs(review and review.comments or {}) do
    for _, ref in ipairs(comment.file_references or {}) do
      local fresh, reason = M.check_reference(root, ref, bufnr)
      local before_state = ref.stale_state
      local before_reason = ref.stale_reason
      if fresh then
        ref.stale_state = "fresh"
        ref.stale_reason = nil
      else
        ref.stale_state = "stale"
        ref.stale_reason = reason or "unknown"
        stale_count = stale_count + 1
      end
      if before_state ~= ref.stale_state or before_reason ~= ref.stale_reason then
        changed = true
      end
    end
  end
  return stale_count, changed
end

return M
