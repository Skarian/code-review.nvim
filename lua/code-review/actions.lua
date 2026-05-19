local model = require("code-review.model")
local notify = require("code-review.notify")
local path = require("code-review.path")
local preview = require("code-review.preview")
local state = require("code-review.state")
local storage = require("code-review.storage")

local M = {}

local function current_buffer_allows_action(action)
  if action == "quit" then
    return true
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local s = state.get()
  if s.sidebar and s.sidebar.buf == bufnr then
    notify.warn("Code Review actions run from code buffers.")
    return false
  end
  if s.preview and s.preview.buf == bufnr then
    notify.warn("Code Review actions run from code buffers.")
    return false
  end
  if s.editor and s.editor.buf == bufnr then
    notify.warn("Submit or cancel the comment composer first.")
    return false
  end
  local bt = vim.bo[bufnr].buftype
  if bt ~= "" then
    notify.warn("Code Review actions run from normal file buffers.")
    return false
  end
  return true
end

local function active_review()
  local s = state.get()
  return model.find_review(s.store, s.active_review_id)
end

local function persist()
  local s = state.get()
  storage.mark_dirty(s.storage)
  require("code-review.sidebar").render()
  require("code-review.highlights").refresh()
end

local function blocked_by_editor_or_voice()
  local mode = state.mode()
  if mode == "body_editor_clean" or mode == "body_editor_dirty" or mode == "composer" then
    notify.warn("Submit or cancel the comment composer first.")
    return true
  end
  if mode == "recording" or mode == "transcribing" or mode == "voice_error_pending" then
    notify.warn("Finish voice transcription first.")
    return true
  end
  return false
end

local function voice_error_pending()
  return state.mode() == "voice_error_pending"
end

local function require_active()
  if not state.is_active() then
    notify.warn("Start Review Mode with <leader>rr first.")
    return false
  end
  return true
end

function M.create_review(name)
  if not require_active() then
    return
  end
  if blocked_by_editor_or_voice() then
    return
  end
  local s = state.get()
  local review = model.new_review(name)
  table.insert(s.store.reviews, review)
  model.sort_reviews(s.store.reviews)
  s.active_review_id = review.id
  s.store.last_active_review_id = review.id
  state.set_mode("comment_list")
  persist()
end

function M.select_review(review_id)
  if not require_active() then
    return
  end
  if blocked_by_editor_or_voice() then
    return
  end
  local s = state.get()
  s.active_review_id = review_id
  s.store.last_active_review_id = review_id
  s.current_comment_id = nil
  s.current_reference_index = 1
  state.set_mode("comment_list")
  persist()
end

function M.delete_review()
  if not require_active() then
    return
  end
  if blocked_by_editor_or_voice() then
    return
  end
  local s = state.get()
  local review = active_review()
  if not review then
    notify.warn("No active Review.")
    return
  end
  vim.ui.select({ "Delete", "Cancel" }, { prompt = "Delete Review " .. review.name .. "?" }, function(choice)
    if choice ~= "Delete" then
      return
    end
    for idx, item in ipairs(s.store.reviews) do
      if item.id == review.id then
        table.remove(s.store.reviews, idx)
        break
      end
    end
    model.sort_reviews(s.store.reviews)
    local next_review = s.store.reviews[1]
    s.active_review_id = next_review and next_review.id or nil
    s.store.last_active_review_id = s.active_review_id
    s.current_comment_id = nil
    s.current_reference_index = 1
    state.set_mode(s.active_review_id and "comment_list" or "review_picker")
    persist()
    if not s.active_review_id then
      require("code-review.review_picker").open()
    end
  end)
end

local function ensure_comment()
  local s = state.get()
  local review = active_review()
  if not review then
    notify.warn("Create or select a Review first.")
    return nil
  end
  if s.current_comment_id then
    return model.find_comment(review, s.current_comment_id), review
  end
  local comment = model.new_comment()
  table.insert(review.comments, comment)
  model.touch_review(review)
  s.current_comment_id = comment.id
  s.current_reference_index = 1
  state.set_mode("comment_list")
  return comment, review
end

local function visual_range()
  local mode = vim.api.nvim_get_mode().mode
  if mode == "v" or mode == "V" or mode == "\022" then
    local a = vim.fn.line("v")
    local b = vim.fn.line(".")
    if a > b then
      a, b = b, a
    end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    return a, b
  end
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local a = start_pos[2]
  local b = end_pos[2]
  if a > b then
    a, b = b, a
  end
  return a, b
end

function M.add_reference()
  if not require_active() then
    return
  end
  local s = state.get()
  if blocked_by_editor_or_voice() then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].buftype ~= "" or vim.api.nvim_buf_get_name(bufnr) == "" then
    notify.warn("Save the buffer before adding a File Reference.")
    return
  end
  if vim.bo[bufnr].modified then
    notify.warn("Write the buffer before adding a File Reference.")
    return
  end
  local rel = path.relative(s.root, vim.api.nvim_buf_get_name(bufnr))
  if not rel then
    notify.warn("File is outside the active Review root.")
    return
  end
  local start_line, end_line = visual_range()
  if start_line < 1 or end_line < start_line then
    notify.warn("Select lines before adding a File Reference.")
    return
  end
  local snapshot = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  local comment, review = ensure_comment()
  if not comment then
    return
  end
  local ref = model.new_file_reference({
    relative_path = rel,
    start_line = start_line,
    end_line = end_line,
    selected_lines_snapshot = snapshot,
  })
  table.insert(comment.file_references, ref)
  s.current_comment_id = comment.id
  s.current_reference_index = #comment.file_references
  state.set_mode("comment_list")
  model.touch_comment(review, comment)
  persist()
end

function M.new_comment()
  if not require_active() then
    return
  end
  if blocked_by_editor_or_voice() then
    return
  end
  local s = state.get()
  local review = active_review()
  if not review then
    notify.warn("Create or select a Review first.")
    return
  end
  local comment = model.new_comment()
  table.insert(review.comments, comment)
  s.current_comment_id = comment.id
  s.current_reference_index = 1
  state.set_mode("comment_list")
  model.touch_review(review)
  persist()
end

function M.edit_comment()
  if require_active() then
    require("code-review.editor").open()
  end
end

function M.open_picker()
  if not state.is_active() then
    require("code-review").start()
  end
  if not current_buffer_allows_action("open_picker") then
    return
  end
  if state.mode() ~= "comment_list" and state.mode() ~= "review_picker" then
    notify.warn("Close current Review UI before switching Reviews.")
    return
  end
  if state.is_active() and blocked_by_editor_or_voice() then
    return
  end
  require("code-review.review_picker").open()
end

function M.toggle_voice()
  if require_active() then
    require("code-review.voice").toggle()
  end
end

function M.preview()
  if not require_active() then
    return
  end
  if blocked_by_editor_or_voice() then
    return
  end
  local s = state.get()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].buftype ~= "" or vim.api.nvim_buf_get_name(bufnr) == "" or not path.relative(s.root, vim.api.nvim_buf_get_name(bufnr)) then
    notify.warn("Preview from a saved code buffer inside the active Review root.")
    return
  end
  if vim.bo[bufnr].modified then
    notify.warn("Write the buffer before previewing the active Review.")
    return
  end
  local review = active_review()
  if not review then
    notify.warn("Create or select a Review first.")
    return
  end
  local validation = preview.validate(s.root, review)
  if validation.stale_references > 0 then
    notify.warn(string.format("%d stale references detected, please update or delete them", validation.stale_references))
    persist()
    return
  end
  if validation.incomplete_comments > 0 then
    notify.warn(string.format("%d incomplete comments detected, please complete or delete them", validation.incomplete_comments))
    return
  end
  if validation.complete_comments == 0 then
    notify.warn("No complete comments to preview")
    return
  end
  local text = preview.render_review(review)
  local function open_preview()
    s.preview = { buf = preview.open(text), previous_mode = s.mode }
    state.set_mode("preview")
  end
  if s.preview and s.preview.buf and vim.api.nvim_buf_is_valid(s.preview.buf) then
    if vim.bo[s.preview.buf].modified then
      vim.ui.select({ "Replace", "Cancel" }, { prompt = "Replace modified preview?" }, function(choice)
        if choice == "Replace" then
          pcall(vim.api.nvim_buf_delete, s.preview.buf, { force = true })
          open_preview()
        end
      end)
      return
    end
    pcall(vim.api.nvim_buf_delete, s.preview.buf, { force = true })
  end
  open_preview()
end

function M.next()
  if not require_active() then
    return
  end
  if blocked_by_editor_or_voice() then
    return
  end
  local s = state.get()
  local review = active_review()
  if not review then
    return
  end
  local comments = model.comments_newest(review)
  for idx, comment in ipairs(comments) do
    if comment.id == s.current_comment_id then
      s.current_comment_id = (comments[idx + 1] or comments[1] or {}).id
      break
    end
  end
  if not s.current_comment_id and comments[1] then
    s.current_comment_id = comments[1].id
  end
  s.current_reference_index = 1
  require("code-review.sidebar").render()
  require("code-review.highlights").refresh()
end

function M.previous()
  if not require_active() then
    return
  end
  if blocked_by_editor_or_voice() then
    return
  end
  local s = state.get()
  local review = active_review()
  if not review then
    return
  end
  local comments = model.comments_newest(review)
  for idx, comment in ipairs(comments) do
    if comment.id == s.current_comment_id then
      s.current_comment_id = (comments[idx - 1] or comments[#comments] or {}).id
      break
    end
  end
  if not s.current_comment_id and comments[1] then
    s.current_comment_id = comments[1].id
  end
  s.current_reference_index = 1
  require("code-review.sidebar").render()
  require("code-review.highlights").refresh()
end

function M.open_current()
  if not require_active() then
    return
  end
  if blocked_by_editor_or_voice() then
    return
  end
  local s = state.get()
  local review = active_review()
  local comment = model.find_comment(review, s.current_comment_id)
  if not comment then
    notify.warn("No current Comment.")
    return
  end
  local ref = comment.file_references[s.current_reference_index]
  if ref then
    vim.cmd.edit(vim.fs.joinpath(s.root, ref.relative_path))
    vim.api.nvim_win_set_cursor(0, { ref.start_line, 0 })
  end
end

function M.close_comment()
  if require_active() then
    if voice_error_pending() then
      require("code-review.voice").discard()
    end
    if blocked_by_editor_or_voice() then
      return
    end
    state.get().current_comment_id = nil
    state.get().current_reference_index = 1
    state.set_mode("comment_list")
    require("code-review.sidebar").render()
  end
end

function M.delete_reference()
  if not require_active() then
    return
  end
  if blocked_by_editor_or_voice() then
    return
  end
  local s = state.get()
  local review = active_review()
  local comment = model.find_comment(review, s.current_comment_id)
  if not comment or not comment.file_references[s.current_reference_index] then
    notify.warn("No current File Reference.")
    return
  end
  vim.ui.select({ "Delete", "Cancel" }, { prompt = "Delete current File Reference?" }, function(choice)
    if choice ~= "Delete" then
      return
    end
    table.remove(comment.file_references, s.current_reference_index)
    s.current_reference_index = math.max(1, math.min(s.current_reference_index, #comment.file_references))
    model.touch_comment(review, comment)
    persist()
  end)
end

function M.delete_comment()
  if not require_active() then
    return
  end
  if blocked_by_editor_or_voice() then
    return
  end
  local s = state.get()
  local review = active_review()
  if not review or not s.current_comment_id then
    notify.warn("No current Comment.")
    return
  end
  vim.ui.select({ "Delete", "Cancel" }, { prompt = "Delete current Comment?" }, function(choice)
    if choice ~= "Delete" then
      return
    end
    for idx, comment in ipairs(review.comments) do
      if comment.id == s.current_comment_id then
        table.remove(review.comments, idx)
        break
      end
    end
    local comments = model.comments_newest(review)
    s.current_comment_id = comments[1] and comments[1].id or nil
    s.current_reference_index = 1
    state.set_mode("comment_list")
    model.touch_review(review)
    persist()
  end)
end

function M.quit()
  require("code-review").quit()
end

function M.dispatch(action)
  if not current_buffer_allows_action(action) then
    return
  end
  if M[action] then
    return M[action]()
  end
  notify.warn("Unknown Code Review action: " .. tostring(action))
end

return M
