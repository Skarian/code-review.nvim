local config = require("code-review.config")
local model = require("code-review.model")
local notify = require("code-review.notify")
local plugin = require("code-review.plugin")
local state = require("code-review.state")
local storage = require("code-review.storage")
local ui = require("code-review.ui")

local M = {}

local function active_review()
  local s = state.get()
  return model.find_review(s.store, s.active_review_id)
end

local function split_body(body)
  if body == nil or body == "" then
    return { "" }
  end
  return vim.split(body, "\n", { plain = true })
end

local function voice_available()
  local cfg = config.get().voice
  if not cfg.enabled then
    return false
  end
  local helper = cfg.helper_path or plugin.voice_helper()
  return vim.fn.filereadable(helper) == 1
end

local function voice_status_line()
  local s = state.get()
  if s.mode == "recording" then
    return "Voice: recording - <Space> stops"
  end
  if s.mode == "transcribing" then
    return "Voice: transcribing..."
  end
  if s.mode == "voice_error_pending" then
    return "Voice: failed - <Space> retries"
  end
  if not voice_available() then
    return "Voice: unavailable"
  end
  return "Voice: <Space> record"
end

local function header_lines(references)
  local lines = { "File References:" }
  for index, ref in ipairs(references or {}) do
    lines[#lines + 1] = string.format("  %d. %s:%d-%d", index, ref.relative_path, ref.start_line, ref.end_line)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Keys: <CR> submit | q/<Esc> cancel | d delete ref | ? help"
  lines[#lines + 1] = voice_status_line()
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Comment:"
  return lines
end

local function body_lines(composer)
  if not composer or not vim.api.nvim_buf_is_valid(composer.buf) then
    return {}
  end
  return vim.api.nvim_buf_get_lines(composer.buf, composer.body_start, -1, false)
end

local function set_lines(composer, body)
  local header = header_lines(composer.references)
  composer.body_start = #header
  vim.bo[composer.buf].modifiable = true
  vim.api.nvim_buf_set_lines(composer.buf, 0, -1, false, vim.list_extend(header, body or { "" }))
  vim.bo[composer.buf].modifiable = true
end

local function refresh_draft_highlights()
  require("code-review.highlights").refresh_all()
end

local function close_window(composer)
  if composer.handle and type(composer.handle.close) == "function" then
    pcall(composer.handle.close, composer.handle)
  elseif composer.win and vim.api.nvim_win_is_valid(composer.win) then
    pcall(vim.api.nvim_win_close, composer.win, true)
  end
end

local function clear_composer(delete_buf)
  local s = state.get()
  local composer = s.composer
  if not composer then
    return
  end
  if s.voice then
    pcall(require("code-review.voice").stop)
  end
  close_window(composer)
  if delete_buf and composer.buf and vim.api.nvim_buf_is_valid(composer.buf) then
    pcall(vim.api.nvim_buf_delete, composer.buf, { force = true })
  end
  s.composer = nil
  if s.active then
    state.set_mode("comment_list")
  end
  refresh_draft_highlights()
  require("code-review.sidebar").render()
end

local function restore_header(composer)
  if not composer or composer.restoring or not vim.api.nvim_buf_is_valid(composer.buf) then
    return
  end
  local expected = header_lines(composer.references)
  local actual = vim.api.nvim_buf_get_lines(composer.buf, 0, #expected, false)
  if vim.deep_equal(expected, actual) then
    return
  end
  composer.restoring = true
  local body = vim.api.nvim_buf_get_lines(composer.buf, composer.body_start, -1, false)
  set_lines(composer, body)
  composer.restoring = false
end

local function submit_body()
  local composer = state.get().composer
  if not composer then
    return nil
  end
  restore_header(composer)
  return table.concat(body_lines(composer), "\n")
end

local function persist()
  local s = state.get()
  storage.mark_dirty(s.storage)
  require("code-review.sidebar").render()
  require("code-review.highlights").refresh_all()
end

local function apply_keymaps(buf)
  vim.keymap.set("n", "<CR>", function()
    require("code-review.composer").submit()
  end, { buffer = buf, nowait = true, desc = "Submit Code Review comment" })
  vim.keymap.set("n", "q", function()
    require("code-review.composer").cancel()
  end, { buffer = buf, nowait = true, desc = "Cancel Code Review comment" })
  vim.keymap.set("n", "<Esc>", function()
    require("code-review.composer").cancel()
  end, { buffer = buf, nowait = true, desc = "Cancel Code Review comment" })
  vim.keymap.set("n", "d", function()
    require("code-review.composer").delete_reference_under_cursor()
  end, { buffer = buf, nowait = true, desc = "Delete draft File Reference" })
  vim.keymap.set("n", "<Space>", function()
    require("code-review.voice").toggle()
  end, { buffer = buf, nowait = true, desc = "Toggle Code Review voice" })
  vim.keymap.set("n", "?", function()
    require("code-review.composer").show_help()
  end, { buffer = buf, nowait = true, desc = "Show Code Review composer help" })
end

local function open(opts)
  local s = state.get()
  if s.composer then
    notify.warn("Submit or cancel the comment composer first.")
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, "Code Review Comment")
  local composer = {
    buf = buf,
    references = vim.deepcopy(opts.references or {}),
    target_comment_id = opts.target_comment_id,
  }
  s.composer = composer
  set_lines(composer, split_body(opts.body or ""))
  composer.win, composer.handle = ui.open_composer(buf)
  apply_keymaps(buf)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = function()
      restore_header(state.get().composer)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      if state.get().composer and state.get().composer.buf == buf then
        clear_composer(false)
      end
    end,
  })
  state.set_mode("composer")
  refresh_draft_highlights()
  vim.cmd("stopinsert")
end

function M.open_new(reference)
  open({ references = { reference } })
end

function M.open_edit(comment)
  open({
    target_comment_id = comment.id,
    references = comment.file_references,
    body = comment.body,
  })
end

function M.submit()
  local s = state.get()
  local composer = s.composer
  if not composer then
    return
  end
  if #composer.references == 0 then
    notify.warn("Add at least one File Reference before submitting.")
    return
  end
  local body = submit_body()
  if vim.trim(body or "") == "" then
    notify.warn("Write a comment before submitting.")
    return
  end
  local review = active_review()
  if not review then
    notify.warn("Create or select a Review first.")
    return
  end
  local comment = composer.target_comment_id and model.find_comment(review, composer.target_comment_id) or nil
  if not comment then
    comment = model.new_comment()
    table.insert(review.comments, comment)
  end
  comment.body = body
  comment.file_references = vim.deepcopy(composer.references)
  s.current_comment_id = comment.id
  s.current_reference_index = math.min(1, #comment.file_references)
  model.touch_comment(review, comment)
  clear_composer(true)
  persist()
end

function M.cancel()
  clear_composer(true)
end

function M.close()
  clear_composer(true)
end

function M.refresh()
  restore_header(state.get().composer)
end

function M.show_help()
  return ui.open_composer_help({
    "Composer keys",
    "",
    "<CR> submits the comment from Normal mode.",
    "q or <Esc> cancels the composer without saving the draft.",
    "d deletes the draft File Reference under the cursor.",
    "<Space> starts recording, stops recording, or retries voice transcription.",
    "",
    "Voice states",
    "",
    "recording: press <Space> to stop recording.",
    "transcribing: wait for text to be inserted at the cursor.",
    "failed: press <Space> to retry, or quit/cancel to discard the draft.",
  })
end

function M.delete_reference_under_cursor()
  local composer = state.get().composer
  if not composer then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local index = row - 1
  if index < 1 or index > #composer.references then
    notify.warn("Move to a draft File Reference row before deleting.")
    return
  end
  vim.ui.select({ "Delete", "Cancel" }, { prompt = "Delete draft File Reference?" }, function(choice)
    if choice ~= "Delete" then
      return
    end
    local body = body_lines(composer)
    table.remove(composer.references, index)
    set_lines(composer, body)
    refresh_draft_highlights()
  end)
end

function M.insert_text(text)
  local composer = state.get().composer
  if not composer or not vim.api.nvim_buf_is_valid(composer.buf) then
    return false
  end
  text = vim.trim(text or "")
  if text == "" then
    return true
  end
  local win = composer.win and vim.api.nvim_win_is_valid(composer.win) and composer.win or nil
  local row, col
  if win then
    local cursor = vim.api.nvim_win_get_cursor(win)
    row = cursor[1] - 1
    col = cursor[2]
  else
    row = vim.api.nvim_buf_line_count(composer.buf) - 1
    col = #vim.api.nvim_buf_get_lines(composer.buf, row, row + 1, false)[1]
  end
  if row < composer.body_start then
    row = composer.body_start
    col = 0
  end
  local lines = vim.split(text, "\n", { plain = true })
  vim.api.nvim_buf_set_text(composer.buf, row, col, row, col, lines)
  return true
end

return M
