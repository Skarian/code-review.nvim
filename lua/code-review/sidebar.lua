local config = require("code-review.config")
local model = require("code-review.model")
local state = require("code-review.state")
local time = require("code-review.time")

local M = {}
local ns = vim.api.nvim_create_namespace("code-review.nvim.sidebar")

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function ensure()
  local s = state.get()
  if valid_win(s.sidebar and s.sidebar.win) and valid_buf(s.sidebar.buf) then
    return s.sidebar.buf, s.sidebar.win
  end
  local current = vim.api.nvim_get_current_win()
  local position = config.get().sidebar.position
  if position == "left" then
    vim.cmd("topleft vertical new")
  else
    vim.cmd("botright vertical new")
  end
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, config.get().sidebar.width)
  vim.wo[win].winfixwidth = true
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].readonly = true
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "Code Review")
  s.sidebar = { buf = buf, win = win }
  if valid_win(current) then
    vim.api.nvim_set_current_win(current)
  end
  return buf, win
end

local function truncate_body(body)
  local lines = vim.split(body or "", "\n", { plain = true })
  local out = {}
  for i = 1, math.min(4, #lines) do
    if lines[i] ~= "" then
      out[#out + 1] = "  " .. lines[i]
    end
  end
  if #lines > 4 then
    out[#out + 1] = "  ..."
  end
  return out
end

function M.render()
  local s = state.get()
  if not s.active then
    return
  end
  local buf = ensure()
  local review = model.find_review(s.store, s.active_review_id)
  local lines = {
    "Code Review",
    review and ("Review: " .. review.name) or "No active review",
    "",
  }
  local header_count = #lines
  local highlights = {
    { line = 0, group = "CodeReviewSidebarHeader" },
    { line = 1, group = "CodeReviewSidebarHeader" },
  }
  if review then
    local comments = model.comments_newest(review)
    local content_lines = {}
    local content_highlights = {}
    local current_content_line
    for _, comment in ipairs(comments) do
      local current = comment.id == s.current_comment_id and "> " or "  "
      local flags = {}
      local incomplete = not model.comment_complete(comment)
      local stale = false
      if incomplete then
        flags[#flags + 1] = "incomplete"
      end
      for _, ref in ipairs(comment.file_references or {}) do
        if ref.stale_state == "stale" then
          stale = true
          flags[#flags + 1] = "stale"
          break
        end
      end
      content_lines[#content_lines + 1] = current .. time.relative(comment.updated_at) .. (#flags > 0 and (" [" .. table.concat(flags, ", ") .. "]") or "")
      local comment_line = #content_lines - 1
      if comment.id == s.current_comment_id then
        current_content_line = comment_line
      end
      if comment.id == s.current_comment_id then
        content_highlights[#content_highlights + 1] = { line = comment_line, group = "CodeReviewSidebarCurrent" }
      elseif incomplete then
        content_highlights[#content_highlights + 1] = { line = comment_line, group = "CodeReviewSidebarIncomplete" }
      elseif stale then
        content_highlights[#content_highlights + 1] = { line = comment_line, group = "CodeReviewSidebarStale" }
      end
      for _, ref in ipairs(comment.file_references or {}) do
        content_lines[#content_lines + 1] = string.format("  %s:%d-%d%s", ref.relative_path, ref.start_line, ref.end_line, ref.stale_state == "stale" and " !" or "")
        if ref.stale_state == "stale" then
          content_highlights[#content_highlights + 1] = { line = #content_lines - 1, group = "CodeReviewSidebarStale" }
        end
      end
      vim.list_extend(content_lines, truncate_body(comment.body))
      content_lines[#content_lines + 1] = ""
    end
    local legend = {
      string.rep("-", 24),
      "Keys: rr picker  ra ref",
      "      rc edit    rs voice",
      "      rp preview rq quit",
    }
    local height = valid_win(s.sidebar and s.sidebar.win) and vim.api.nvim_win_get_height(s.sidebar.win) or 0
    local available = height > #legend and math.max(0, height - #legend - header_count) or #content_lines
    local start_line = 1
    if current_content_line and available > 0 and #content_lines > available then
      start_line = math.max(1, current_content_line - math.floor(available / 2) + 1)
      start_line = math.min(start_line, #content_lines - available + 1)
    end
    local end_line = available > 0 and math.min(#content_lines, start_line + available - 1) or #content_lines
    for idx = start_line, end_line do
      lines[#lines + 1] = content_lines[idx]
    end
    for _, hl in ipairs(content_highlights) do
      if hl.line >= start_line - 1 and hl.line <= end_line - 1 then
        highlights[#highlights + 1] = { line = header_count + hl.line - start_line + 1, group = hl.group }
      end
    end
  end
  local legend = {
    string.rep("-", 24),
    "Keys: rr picker  ra ref",
    "      rc edit    rs voice",
    "      rp preview rq quit",
  }
  local height = valid_win(s.sidebar and s.sidebar.win) and vim.api.nvim_win_get_height(s.sidebar.win) or 0
  if height > #legend and #lines > height - #legend then
    lines = vim.list_slice(lines, 1, height - #legend)
  end
  while height > #legend and #lines < height - #legend do
    lines[#lines + 1] = ""
  end
  vim.list_extend(lines, legend)
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, hl in ipairs(highlights) do
    if hl.line < #lines then
      pcall(vim.api.nvim_buf_add_highlight, buf, ns, hl.group, hl.line, 0, -1)
    end
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
end

function M.close()
  local s = state.get()
  if s.sidebar then
    if valid_win(s.sidebar.win) then
      pcall(vim.api.nvim_win_close, s.sidebar.win, true)
    elseif valid_buf(s.sidebar.buf) then
      pcall(vim.api.nvim_buf_delete, s.sidebar.buf, { force = true })
    end
  end
  s.sidebar = nil
end

return M
