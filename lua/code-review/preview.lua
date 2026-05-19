local model = require("code-review.model")
local stale = require("code-review.stale")

local M = {}

function M.validate(root, review)
  local result = {
    incomplete_comments = 0,
    stale_references = 0,
    complete_comments = 0,
  }
  stale.refresh_review(root, review, vim.api.nvim_get_current_buf())
  for _, comment in ipairs(review and review.comments or {}) do
    if model.comment_complete(comment) then
      result.complete_comments = result.complete_comments + 1
    else
      result.incomplete_comments = result.incomplete_comments + 1
    end
    for _, ref in ipairs(comment.file_references or {}) do
      if ref.stale_state == "stale" then
        result.stale_references = result.stale_references + 1
      end
    end
  end
  return result
end

function M.render_review(review)
  local lines = { "Review: " .. review.name, "" }
  for _, comment in ipairs(model.comments_oldest(review)) do
    for _, ref in ipairs(comment.file_references or {}) do
      lines[#lines + 1] = string.format("%s:%d-%d", ref.relative_path, ref.start_line, ref.end_line)
    end
    if vim.trim(comment.body or "") ~= "" then
      for _, body_line in ipairs(vim.split(comment.body or "", "\n", { plain = true })) do
        lines[#lines + 1] = body_line
      end
    end
    lines[#lines + 1] = ""
  end
  return table.concat(lines, "\n")
end

function M.open(text)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, "Code Review Preview")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      local state = require("code-review.state")
      local s = state.get()
      if s.preview and s.preview.buf == buf then
        local previous = s.preview.previous_mode or "comment_list"
        s.preview = nil
        if s.active then
          state.set_mode(previous == "preview" and "comment_list" or previous)
        end
      end
    end,
  })
  return buf
end

function M.close()
  local state = require("code-review.state")
  local s = state.get()
  if s.preview and s.preview.buf and vim.api.nvim_buf_is_valid(s.preview.buf) then
    pcall(vim.api.nvim_buf_delete, s.preview.buf, { force = true })
  end
  s.preview = nil
end

return M
