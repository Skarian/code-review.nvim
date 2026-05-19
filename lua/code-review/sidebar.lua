local config = require("code-review.config")
local model = require("code-review.model")
local state = require("code-review.state")
local time = require("code-review.time")

local M = {}
local ns = vim.api.nvim_create_namespace("code-review.nvim.sidebar")
local pad = "  "
local legend_height = 4

local function truncate_to_width(text, width)
  text = text or ""
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  if width <= 3 then
    return string.sub("...", 1, width)
  end

  local out = ""
  for _, char in ipairs(vim.fn.split(text, "\\zs")) do
    if vim.fn.strdisplaywidth(out .. char .. "...") > width then
      break
    end
    out = out .. char
  end
  return out .. "..."
end

local function padded(line, width)
  if line == "" then
    return ""
  end
  if not width then
    return pad .. line
  end
  return pad .. truncate_to_width(line, width - vim.fn.strdisplaywidth(pad))
end

local function center_line(text, width)
  text = truncate_to_width(text, width)
  local available = math.max(0, width - vim.fn.strdisplaywidth(text))
  return string.rep(" ", math.floor(available / 2)) .. text
end

local function line_count_without_legend(height)
  return height > legend_height and height - legend_height or height
end

local function legend_lines(width)
  local rule_width = math.max(12, width - 4)
  return {
    center_line(string.rep("-", rule_width), width),
    center_line("Keys: ra new   rr append", width),
    center_line("re edit   rR reviews", width),
    center_line("rp preview rq quit", width),
  }
end

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function with_winenter_ignored(fn)
  local previous = vim.o.eventignore
  if previous ~= "all" and not vim.tbl_contains(vim.split(previous, ",", { plain = true }), "WinEnter") then
    vim.o.eventignore = previous == "" and "WinEnter" or (previous .. ",WinEnter")
  end
  local ok, result = pcall(fn)
  vim.o.eventignore = previous
  if not ok then
    error(result, 2)
  end
  return result
end

local function open_sidebar_window(buf)
  local position = config.get().sidebar.position
  return vim.api.nvim_open_win(buf, false, {
    win = -1,
    vertical = true,
    split = position == "left" and "left" or "right",
    width = config.get().sidebar.width,
    noautocmd = true,
  })
end

local function ensure()
  local s = state.get()
  if valid_win(s.sidebar and s.sidebar.win) and valid_buf(s.sidebar.buf) then
    return s.sidebar.buf, s.sidebar.win
  end
  local current = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  local win = with_winenter_ignored(function()
    return open_sidebar_window(buf)
  end)
  vim.api.nvim_win_set_width(win, config.get().sidebar.width)
  vim.wo[win].winfixwidth = true
  pcall(function()
    vim.wo[win].eventignorewin = "WinEnter"
  end)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "code-review-sidebar"
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].readonly = true
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "Code Review")
  s.sidebar = { buf = buf, win = win }
  if valid_win(current) and vim.api.nvim_get_current_win() ~= current then
    with_winenter_ignored(function()
      vim.api.nvim_set_current_win(current)
    end)
  end
  return buf, win
end

local function wrap_preview_line(line, width)
  local out = {}
  local current = ""
  for word in line:gmatch("%S+") do
    if current == "" then
      current = word
    elseif vim.fn.strdisplaywidth(current .. " " .. word) <= width then
      current = current .. " " .. word
    else
      out[#out + 1] = truncate_to_width(current, width)
      current = word
    end
  end
  if current ~= "" then
    out[#out + 1] = truncate_to_width(current, width)
  end
  return out
end

local function preview_body(body, width)
  local lines = vim.split(body or "", "\n", { plain = true })
  local out = {}
  local body_pad = "  "
  local available = width - vim.fn.strdisplaywidth(pad) - vim.fn.strdisplaywidth(body_pad)
  if available <= 0 then
    return out
  end
  for _, line in ipairs(lines) do
    if line ~= "" then
      for _, wrapped in ipairs(wrap_preview_line(line, available)) do
        out[#out + 1] = body_pad .. wrapped
        if #out == 4 then
          return out
        end
      end
    end
  end
  return out
end

function M.render()
  local s = state.get()
  if not s.active then
    return
  end
  local buf = ensure()
  local win = s.sidebar and s.sidebar.win
  local width = valid_win(win) and vim.api.nvim_win_get_width(win) or config.get().sidebar.width
  local height = valid_win(win) and vim.api.nvim_win_get_height(win) or 0
  local legend = legend_lines(width)
  local review = model.find_review(s.store, s.active_review_id)
  local lines = {
    center_line("Code Review", width),
    review and padded("Review: " .. review.name, width) or "",
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
    for _, comment in ipairs(comments) do
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
      content_lines[#content_lines + 1] = time.relative(comment.updated_at) .. (#flags > 0 and (" [" .. table.concat(flags, ", ") .. "]") or "")
      local comment_line = #content_lines - 1
      if incomplete then
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
      vim.list_extend(content_lines, preview_body(comment.body, width))
      content_lines[#content_lines + 1] = ""
    end
    local available = height > #legend and math.max(0, height - #legend - header_count) or #content_lines
    local start_line = 1
    local end_line = available > 0 and math.min(#content_lines, start_line + available - 1) or #content_lines
    for idx = start_line, end_line do
      lines[#lines + 1] = padded(content_lines[idx], width)
    end
    for _, hl in ipairs(content_highlights) do
      if hl.line >= start_line - 1 and hl.line <= end_line - 1 then
        highlights[#highlights + 1] = { line = header_count + hl.line - start_line + 1, group = hl.group }
      end
    end
  else
    local content_height = math.max(0, line_count_without_legend(height) - #lines)
    local top_padding = math.max(0, math.floor((content_height - 1) / 2))
    for _ = 1, top_padding do
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = center_line("No active review", width)
    highlights[#highlights + 1] = { line = #lines - 1, group = "CodeReviewSidebarHeader" }
  end
  if height > #legend and #lines > height - #legend then
    lines = vim.list_slice(lines, 1, height - #legend)
  end
  while height > #legend and #lines < height - #legend do
    lines[#lines + 1] = ""
  end
  for _, line in ipairs(legend) do
    lines[#lines + 1] = line
  end
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
