local model = require("code-review.model")
local navigation = require("code-review.navigation")
local notify = require("code-review.notify")
local stale = require("code-review.stale")

local M = {}

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function previous_mode(preview)
  local mode = preview and preview.previous_mode or "comment_list"
  return mode == "preview" and "comment_list" or mode
end

local function set_preview_lines(buf, text)
  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = modifiable
end

local function preview_window(buf)
  if not valid_buf(buf) then
    return nil
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
  return nil
end

local function origin_buffer(preview)
  if valid_buf(preview.origin_buf) then
    return preview.origin_buf
  end
  if preview.origin_name and preview.origin_name ~= "" then
    local buf = vim.fn.bufadd(preview.origin_name)
    if buf and buf > 0 then
      pcall(vim.fn.bufload, buf)
      if valid_buf(buf) then
        preview.origin_buf = buf
        return buf
      end
    end
  end
  return nil
end

local function capture_origin(target_win, previous)
  local origin_buf = vim.api.nvim_win_get_buf(target_win)
  return {
    origin_buf = origin_buf,
    origin_name = vim.api.nvim_buf_get_name(origin_buf),
    origin_win = target_win,
    previous_mode = previous,
    view = navigation.normal_window(target_win) and vim.api.nvim_win_call(target_win, vim.fn.winsaveview) or nil,
  }
end

local function restore_view(preview, win)
  if valid_win(win) and preview.view then
    pcall(vim.api.nvim_win_call, win, function()
      vim.fn.winrestview(preview.view)
    end)
  end
end

local function restore_after_raw_close(preview)
  local state = require("code-review.state")
  local s = state.get()
  if not s.active or s.tearing_down then
    s.preview_restoring = false
    return
  end
  local ok, err = pcall(function()
    s.preview = nil
    state.set_mode(previous_mode(preview))
    local buf = origin_buffer(preview)
    local restored_win = nil
    if buf then
      if valid_win(preview.origin_win) then
        restored_win = preview.origin_win
        vim.api.nvim_win_set_buf(restored_win, buf)
      elseif valid_win(preview.survivor_win) then
        restored_win = preview.survivor_win
        vim.api.nvim_win_set_buf(restored_win, buf)
      elseif #navigation.tab_content_windows(0) == 0 then
        restored_win = require("code-review.sidebar").replace_with_content_buffer(buf)
      end
    end
    if valid_win(restored_win) then
      vim.api.nvim_set_current_win(restored_win)
      restore_view(preview, restored_win)
    end
    require("code-review.sidebar").render()
  end)
  s.preview_restoring = false
  if not ok then
    error(err, 0)
  end
end

function M.rollback_quit_attempt(preview, session_id, attempt_id)
  local state = require("code-review.state")
  local s = state.get()
  preview = preview or s.preview
  if
    not state.is_active()
    or not preview
    or s.session_id ~= session_id
    or s.preview ~= preview
    or preview.quit_attempt_id ~= attempt_id
    or not valid_buf(preview.buf)
  then
    return
  end
  local survivor = preview.survivor_win
  local origin = origin_buffer(preview)
  if valid_win(survivor) and origin and vim.api.nvim_win_get_buf(survivor) == origin then
    pcall(vim.api.nvim_win_close, survivor, true)
  end
  preview.survivor_win = nil
  preview.quit_attempt_id = nil
  preview.quit_origin_win = nil
  s.preview_restoring = false
end

local function schedule_quit_rollback(preview, session_id, attempt_id)
  vim.defer_fn(function()
    M.rollback_quit_attempt(preview, session_id, attempt_id)
  end, 0)
end

function M.prepare_window_quit()
  local state = require("code-review.state")
  local s = state.get()
  local preview = s.preview
  if not (s.active and preview and valid_buf(preview.buf)) then
    return false
  end
  local current_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_get_current_buf() ~= preview.buf then
    return false
  end
  local content_count = 0
  for _, win in ipairs(navigation.tab_content_windows(0)) do
    if vim.api.nvim_win_get_buf(win) ~= preview.buf then
      return false
    end
    content_count = content_count + 1
  end
  if content_count ~= 1 then
    return false
  end
  local buf = origin_buffer(preview)
  if not buf then
    return false
  end
  local session_id = s.session_id
  local attempt_id = (preview.quit_attempt_id or 0) + 1
  s.preview_restoring = true
  preview.quit_attempt_id = attempt_id
  preview.quit_origin_win = current_win
  vim.cmd("aboveleft split")
  local survivor = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(survivor, buf)
  preview.survivor_win = survivor
  restore_view(preview, survivor)
  vim.api.nvim_set_current_win(current_win)
  schedule_quit_rollback(preview, session_id, attempt_id)
  return true
end

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

function M.open(text, previous)
  local state = require("code-review.state")
  local s = state.get()
  if s.preview and valid_buf(s.preview.buf) then
    set_preview_lines(s.preview.buf, text)
    local win = preview_window(s.preview.buf)
    if win then
      vim.api.nvim_set_current_win(win)
    else
      local target = navigation.find_preview_target_window(s.root)
      if not (target and valid_win(target) and navigation.content_window(target)) then
        notify.warn("Open a content window before previewing.")
        return nil
      end
      for key, value in pairs(capture_origin(target, previous)) do
        s.preview[key] = value
      end
      vim.api.nvim_set_current_win(target)
      vim.api.nvim_win_set_buf(target, s.preview.buf)
    end
    return s.preview.buf
  end
  local target_win = navigation.find_preview_target_window(s.root)
  if not (target_win and valid_win(target_win) and navigation.content_window(target_win)) then
    notify.warn("Open a content window before previewing.")
    return nil
  end
  local origin = capture_origin(target_win, previous)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].buflisted = true
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "code-review-preview"
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, "Code Review Preview")
  set_preview_lines(buf, text)
  s.preview = vim.tbl_extend("force", origin, {
    buf = buf,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      local state = require("code-review.state")
      local s = state.get()
      if s.preview and s.preview.buf == buf then
        local preview = s.preview
        if s.active and not preview.closing then
          s.preview_restoring = true
          vim.schedule(function()
            restore_after_raw_close(preview)
          end)
          return
        end
        local mode = previous_mode(preview)
        s.preview = nil
        if s.active then
          state.set_mode(mode)
        end
      end
    end,
  })
  if valid_win(target_win) and target_win ~= vim.api.nvim_get_current_win() then
    vim.api.nvim_set_current_win(target_win)
  end
  vim.api.nvim_win_set_buf(target_win, buf)
  return buf
end

function M.close()
  local state = require("code-review.state")
  local s = state.get()
  if s.preview and s.preview.buf and vim.api.nvim_buf_is_valid(s.preview.buf) then
    s.preview.closing = true
    pcall(vim.api.nvim_buf_delete, s.preview.buf, { force = true })
  end
  s.preview = nil
end

return M
