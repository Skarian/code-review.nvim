local model = require("code-review.model")
local path = require("code-review.path")
local state = require("code-review.state")

local M = {}

local ns = vim.api.nvim_create_namespace("code-review.nvim")

function M.setup()
  vim.api.nvim_set_hl(0, "CodeReviewReference", { bg = "#2d3f2d", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewDraftReference", { bg = "#263f5f", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewStaleReference", { bg = "#4a1f1f", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewStatus", { fg = "#ffd75f", bold = true, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewSidebarHeader", { fg = "#8ec07c", bold = true, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewSidebarIncomplete", { fg = "#fabd2f", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewSidebarStale", { fg = "#fb4934", default = true })
end

function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local s = state.get()
  if not s.active then
    return
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return
  end
  local rel = path.relative(s.root, name)
  if not rel then
    return
  end
  local review = model.find_review(s.store, s.active_review_id)
  if not review then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, comment in ipairs(review.comments or {}) do
    for i, ref in ipairs(comment.file_references or {}) do
      if ref.relative_path == rel then
        local hl = ref.stale_state == "stale" and "CodeReviewStaleReference" or "CodeReviewReference"
        local start_line = math.max(0, math.min(line_count - 1, ref.start_line - 1))
        local end_line = math.max(0, math.min(line_count - 1, ref.end_line - 1))
        if line_count > 0 then
          for line = start_line, end_line do
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line, 0, {
              line_hl_group = hl,
              hl_eol = true,
            })
          end
        end
      end
    end
  end
  local composer = s.composer
  if composer then
    for _, ref in ipairs(composer.references or {}) do
      if ref.relative_path == rel then
        local start_line = math.max(0, math.min(line_count - 1, ref.start_line - 1))
        local end_line = math.max(0, math.min(line_count - 1, ref.end_line - 1))
        if line_count > 0 then
          for line = start_line, end_line do
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line, 0, {
              line_hl_group = "CodeReviewDraftReference",
              hl_eol = true,
            })
          end
        end
      end
    end
  end
end

function M.refresh_all()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      M.refresh(buf)
    end
  end
end

function M.clear_all()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
    end
  end
end

return M
