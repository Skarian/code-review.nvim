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

local function preview_visible(buf)
  return preview_window(buf) ~= nil
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

local function preview_filename(buf)
  return valid_buf(buf) and vim.api.nvim_buf_get_name(buf) or ""
end

local function detect_filetype(buf, name)
  if not (vim.filetype and vim.filetype.match) then
    return ""
  end
  local ok, filetype = pcall(vim.filetype.match, { buf = buf, filename = name })
  if ok and filetype then
    return filetype
  end
  return ""
end

local function clear_preview_autocmds(preview)
  if not (preview and preview.autocmds) then
    return
  end
  for _, id in ipairs(preview.autocmds) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  preview.autocmds = nil
end

local function detach_saved_preview(preview)
  local state = require("code-review.state")
  local s = state.get()
  if not (s.active and s.preview == preview and valid_buf(preview.buf)) then
    return false
  end
  local name = preview_filename(preview.buf)
  if name == "" then
    return false
  end

  preview.detached = true
  preview.promoting = false
  clear_preview_autocmds(preview)
  s.preview = nil
  s.preview_restoring = false
  if state.mode() == "preview" then
    state.set_mode(previous_mode(preview))
  end
  pcall(vim.api.nvim_buf_del_var, preview.buf, "code_review_preview")
  pcall(vim.api.nvim_buf_set_var, preview.buf, "code_review_detached_preview", true)
  pcall(function()
    if vim.bo[preview.buf].filetype == "code-review-preview" then
      vim.bo[preview.buf].filetype = detect_filetype(preview.buf, name)
    end
    if vim.bo[preview.buf].bufhidden == "unload" then
      vim.bo[preview.buf].bufhidden = ""
    end
  end)
  require("code-review.sidebar").render()
  require("code-review.highlights").refresh(preview.buf)
  return true
end

local function rollback_preview_promotion(preview, session_id)
  vim.schedule(function()
    local state = require("code-review.state")
    local s = state.get()
    if s.active and s.session_id == session_id and s.preview == preview and not preview.detached then
      preview.promoting = false
    end
  end)
end

local function restore_after_preview_closed(preview)
  local state = require("code-review.state")
  local s = state.get()
  if s.preview ~= preview then
    return
  end
  if not s.active or s.tearing_down then
    s.preview_restoring = false
    return
  end
  local ok, err = pcall(function()
    s.preview = nil
    clear_preview_autocmds(preview)
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

local function schedule_preview_lifecycle_check(preview)
  vim.schedule(function()
    local state = require("code-review.state")
    local s = state.get()
    if not s.active or s.tearing_down or s.preview ~= preview or preview.closing or preview.promoting or preview.detached then
      return
    end
    if valid_buf(preview.buf) and preview_visible(preview.buf) then
      return
    end
    s.preview_restoring = true
    restore_after_preview_closed(preview)
  end)
end

function M.handle_window_closed(preview)
  schedule_preview_lifecycle_check(preview)
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
  if not preview_visible(preview.buf) then
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
      s.preview.win = win
      vim.api.nvim_set_current_win(win)
    else
      local target = navigation.find_preview_target_window(s.root)
      if not (target and valid_win(target) and navigation.content_window(target)) then
        notify.warn("Open another content window before previewing.")
        return nil
      end
      for key, value in pairs(capture_origin(target, previous)) do
        s.preview[key] = value
      end
      vim.api.nvim_set_current_win(target)
      vim.api.nvim_win_set_buf(target, s.preview.buf)
      s.preview.win = target
    end
    return s.preview.buf
  end
  local target_win = navigation.find_preview_target_window(s.root)
  if not (target_win and valid_win(target_win) and navigation.content_window(target_win)) then
    notify.warn("Open another content window before previewing.")
    return nil
  end
  local origin = capture_origin(target_win, previous)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.bo[buf].buftype = ""
  vim.bo[buf].buflisted = true
  vim.bo[buf].bufhidden = "unload"
  vim.bo[buf].filetype = "code-review-preview"
  vim.bo[buf].swapfile = false
  vim.b[buf].code_review_preview = true
  set_preview_lines(buf, text)
  s.preview = vim.tbl_extend("force", origin, {
    buf = buf,
  })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufDelete", "BufWipeout" }, {
    buffer = buf,
    callback = function()
      local state = require("code-review.state")
      local s = state.get()
      if s.preview and s.preview.buf == buf then
        local preview = s.preview
        if preview.promoting or preview.detached then
          return
        end
        if s.active then
          if preview.closing then
            local mode = previous_mode(preview)
            s.preview = nil
            clear_preview_autocmds(preview)
            state.set_mode(mode)
          else
            schedule_preview_lifecycle_check(preview)
          end
        end
      end
    end,
  })
  local preview_autocmds = {}
  preview_autocmds[#preview_autocmds + 1] = vim.api.nvim_create_autocmd("BufWritePre", {
    callback = function(args)
      local state = require("code-review.state")
      local s = state.get()
      if s.preview and s.preview.buf == buf and not s.preview.detached and args.buf == buf then
        s.preview.promoting = true
        rollback_preview_promotion(s.preview, s.session_id)
      end
    end,
  })
  preview_autocmds[#preview_autocmds + 1] = vim.api.nvim_create_autocmd("BufWritePost", {
    callback = function(args)
      local state = require("code-review.state")
      local s = state.get()
      if s.preview and s.preview.buf == buf and not s.preview.detached and args.buf == buf then
        detach_saved_preview(s.preview)
      end
    end,
  })
  s.preview.autocmds = preview_autocmds
  vim.api.nvim_create_autocmd("BufWinLeave", {
    buffer = buf,
    callback = function()
      local state = require("code-review.state")
      local s = state.get()
      if s.preview and s.preview.buf == buf and not s.preview.promoting and not s.preview.detached then
        schedule_preview_lifecycle_check(s.preview)
      end
    end,
  })
  if valid_win(target_win) and target_win ~= vim.api.nvim_get_current_win() then
    vim.api.nvim_set_current_win(target_win)
  end
  vim.api.nvim_win_set_buf(target_win, buf)
  s.preview.win = target_win
  return buf
end

function M.close()
  local state = require("code-review.state")
  local s = state.get()
  local preview = s.preview
  if preview and preview.buf and vim.api.nvim_buf_is_valid(preview.buf) then
    if vim.bo[preview.buf].modified then
      notify.warn("Write or discard the modified Code Review preview before quitting.")
      return false
    end
    clear_preview_autocmds(preview)
    preview.closing = true
    pcall(vim.api.nvim_buf_delete, preview.buf, { force = true })
  elseif preview then
    clear_preview_autocmds(preview)
  end
  s.preview = nil
  return true
end

return M
