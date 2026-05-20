local model = require("code-review.model")
local navigation = require("code-review.navigation")
local notify = require("code-review.notify")
local path = require("code-review.path")
local preview = require("code-review.preview")
local state = require("code-review.state")
local storage = require("code-review.storage")

local M = {}

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
  if mode == "composer" then
    notify.warn("Submit or cancel the comment composer first.")
    return true
  end
  if mode == "recording" or mode == "transcribing" or mode == "voice_error_pending" then
    notify.warn("Finish voice transcription first.")
    return true
  end
  return false
end

local function require_active()
  if not state.is_active() then
    notify.warn("Start Review Mode with <leader>rR first.")
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
    state.set_mode(s.active_review_id and "comment_list" or "review_picker")
    persist()
    if not s.active_review_id then
      require("code-review.review_picker").open()
    end
  end)
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

local function capture_reference()
  if not require_active() then
    return nil
  end
  local s = state.get()
  if blocked_by_editor_or_voice() then
    return nil
  end
  if not active_review() then
    notify.warn("Create or select a Review first.")
    return nil
  end
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].buftype ~= "" or vim.api.nvim_buf_get_name(bufnr) == "" then
    notify.warn("Save the buffer before adding a File Reference.")
    return nil
  end
  if vim.bo[bufnr].modified then
    notify.warn("Write the buffer before adding a File Reference.")
    return nil
  end
  local rel = path.relative(s.root, vim.api.nvim_buf_get_name(bufnr))
  if not rel then
    notify.warn("File is outside the active Review root.")
    return nil
  end
  local start_line, end_line = visual_range()
  if start_line < 1 or end_line < start_line then
    notify.warn("Select lines before adding a File Reference.")
    return nil
  end
  local snapshot = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  return model.new_file_reference({
    relative_path = rel,
    start_line = start_line,
    end_line = end_line,
    selected_lines_snapshot = snapshot,
  })
end

function M.add_reference()
  local ref = capture_reference()
  if not ref then
    return
  end
  require("code-review.composer").open_new(ref)
end

function M.append_reference()
  local ref = capture_reference()
  if not ref then
    return
  end
  require("code-review.comment_picker").open({ append_reference = ref })
end

function M.new_comment()
  notify.warn("Select at least one line in Visual mode to create a Comment.")
end

function M.append_reference_hint()
  notify.warn("Select at least one line in Visual mode to append a File Reference.")
end

function M.edit_comment()
  if not require_active() then
    return
  end
  if blocked_by_editor_or_voice() then
    return
  end
  require("code-review.comment_picker").open()
end

local function comments_under_cursor()
  local s = state.get()
  local review = active_review()
  if not review then
    return nil, "Create or select a Review first."
  end
  if not navigation.require_source_buffer("Open a file buffer inside the active Review root first.") then
    return nil
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local rel = path.relative(s.root, vim.api.nvim_buf_get_name(bufnr))
  if not rel then
    return nil, "File is outside the active Review root."
  end
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local matches = {}
  for _, comment in ipairs(review.comments or {}) do
    for _, ref in ipairs(comment.file_references or {}) do
      if ref.relative_path == rel and cursor_line >= ref.start_line and cursor_line <= ref.end_line then
        matches[#matches + 1] = comment
        break
      end
    end
  end
  return matches
end

function M.edit_comment_under_cursor()
  if not require_active() then
    return
  end
  if blocked_by_editor_or_voice() then
    return
  end
  local matches, err = comments_under_cursor()
  if not matches then
    notify.warn(err)
    return
  end
  if #matches == 0 then
    notify.warn("No Comment on the current line.")
  elseif #matches == 1 then
    require("code-review.composer").open_edit(matches[1])
  else
    require("code-review.comment_picker").open({ comments = matches })
  end
end

function M.open_picker()
  if not state.is_active() then
    require("code-review").start()
  end
  if state.mode() ~= "comment_list" and state.mode() ~= "review_picker" and state.mode() ~= "preview" then
    notify.warn("Close current Review UI before switching Reviews.")
    return
  end
  if state.is_active() and blocked_by_editor_or_voice() then
    return
  end
  require("code-review.review_picker").open()
end

M.review_picker = M.open_picker

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
  if #navigation.modified_visible_source_buffers() > 0 then
    notify.warn("Write modified Review files before previewing")
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

function M.quit()
  require("code-review").quit()
end

function M.dispatch(action)
  if M[action] then
    return M[action]()
  end
  notify.warn("Unknown Code Review action: " .. tostring(action))
end

return M
