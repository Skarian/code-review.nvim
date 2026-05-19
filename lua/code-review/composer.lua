local config = require("code-review.config")
local model = require("code-review.model")
local notify = require("code-review.notify")
local plugin = require("code-review.plugin")
local state = require("code-review.state")
local storage = require("code-review.storage")
local ui = require("code-review.ui")

local M = {}

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

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

local function body_lines(composer)
  if not composer or not valid_buf(composer.body_buf) then
    return {}
  end
  return vim.api.nvim_buf_get_lines(composer.body_buf, 0, -1, false)
end

local function body_text(composer)
  return table.concat(body_lines(composer), "\n")
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
    return "Recording: press Space to stop"
  end
  if s.mode == "transcribing" then
    return "Transcribing audio..."
  end
  if s.mode == "voice_error_pending" then
    return "Voice failed: press Space to retry"
  end
  if not voice_available() then
    return "Voice: unavailable"
  end
  return "Voice ready: press Space to record"
end

local function refresh_draft_highlights()
  require("code-review.highlights").refresh_all()
end

local function set_readonly_lines(buf, lines)
  if not valid_buf(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function current_ref_index(composer)
  if not composer or not valid_win(composer.refs_win) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(composer.refs_win)[1]
  if row < 1 or row > #(composer.references or {}) then
    return nil
  end
  return row
end

local function status_lines(composer)
  return {
    "Enter submit | q cancel | Space voice | Tab switch panels | ? help",
    voice_status_line(),
  }
end

local function reference_lines(composer)
  local lines = {}
  for index, ref in ipairs(composer.references or {}) do
    lines[#lines + 1] = string.format("%d. %s:%d-%d", index, ref.relative_path, ref.start_line, ref.end_line)
  end
  if #lines == 0 then
    lines[1] = "No draft File References"
  end
  return lines
end

function M.refresh()
  local composer = state.get().composer
  if not composer then
    return
  end
  set_readonly_lines(composer.status_buf, status_lines(composer))
  set_readonly_lines(composer.refs_buf, reference_lines(composer))
end

local function focus_section(section)
  local composer = state.get().composer
  if not composer then
    return
  end
  local win = section == "refs" and composer.refs_win or composer.body_win
  if valid_win(win) then
    composer.active_section = section
    vim.api.nvim_set_current_win(win)
  end
end

local function cycle_focus(reverse)
  local composer = state.get().composer
  if not composer then
    return
  end
  local current = vim.api.nvim_get_current_win()
  if current == composer.refs_win then
    focus_section("body")
  elseif current == composer.body_win then
    focus_section("refs")
  else
    focus_section(reverse and "refs" or "body")
  end
end

local function close_windows(composer)
  if composer.handle and type(composer.handle.close) == "function" then
    pcall(composer.handle.close, composer.handle)
    return
  end
  for _, win in ipairs({ composer.status_win, composer.refs_win, composer.body_win }) do
    if valid_win(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
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
  close_windows(composer)
  if delete_buf then
    for _, buf in ipairs({ composer.status_buf, composer.refs_buf, composer.body_buf }) do
      if valid_buf(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end
  s.composer = nil
  if s.active then
    state.set_mode("comment_list")
  end
  refresh_draft_highlights()
  require("code-review.sidebar").render()
end

local function persist()
  local s = state.get()
  storage.mark_dirty(s.storage)
  require("code-review.sidebar").render()
  require("code-review.highlights").refresh_all()
end

local function confirm_delete_reference(index)
  local composer = state.get().composer
  if not composer or not index or not composer.references[index] then
    notify.warn("Move to a draft File Reference row before deleting.")
    return
  end
  vim.ui.select({ "Delete", "Cancel" }, { prompt = "Delete draft File Reference?" }, function(choice)
    if choice ~= "Delete" then
      return
    end
    table.remove(composer.references, index)
    M.refresh()
    refresh_draft_highlights()
    if valid_win(composer.refs_win) and #composer.references > 0 then
      vim.api.nvim_win_set_cursor(composer.refs_win, { math.min(index, #composer.references), 0 })
    end
  end)
end

local function go_to_reference(index)
  local composer = state.get().composer
  local ref = composer and composer.references[index]
  local root = state.get().root
  if not ref or not root then
    notify.warn("Move to a draft File Reference row first.")
    return
  end
  local source_win = valid_win(composer.source_win) and composer.source_win or nil
  if not source_win then
    notify.warn("Source window is no longer available.")
    return
  end
  vim.api.nvim_win_call(source_win, function()
    vim.cmd.edit(vim.fs.joinpath(root, ref.relative_path))
    vim.api.nvim_win_set_cursor(0, { ref.start_line, 0 })
  end)
end

local function reference_action()
  local composer = state.get().composer
  local index = current_ref_index(composer)
  if not index then
    notify.warn("Move to a draft File Reference row first.")
    return
  end
  vim.ui.select({ "Delete", "Go to" }, { prompt = "File Reference action" }, function(choice)
    if choice == "Delete" then
      confirm_delete_reference(index)
    elseif choice == "Go to" then
      go_to_reference(index)
    end
  end)
end

local function apply_common_keymaps(buf)
  vim.keymap.set("n", "<Space>", function()
    require("code-review.voice").toggle()
  end, { buffer = buf, nowait = true, desc = "Toggle Code Review voice" })
  vim.keymap.set("n", "?", function()
    require("code-review.composer").show_help()
  end, { buffer = buf, nowait = true, desc = "Show Code Review composer help" })
  vim.keymap.set("n", "<Tab>", function()
    cycle_focus(false)
  end, { buffer = buf, nowait = true, desc = "Next Code Review composer section" })
  vim.keymap.set("n", "<S-Tab>", function()
    cycle_focus(true)
  end, { buffer = buf, nowait = true, desc = "Previous Code Review composer section" })
end

local function apply_body_keymaps(buf)
  apply_common_keymaps(buf)
  vim.keymap.set("n", "<CR>", function()
    require("code-review.composer").submit()
  end, { buffer = buf, nowait = true, desc = "Submit Code Review comment" })
  vim.keymap.set("n", "q", function()
    require("code-review.composer").cancel()
  end, { buffer = buf, nowait = true, desc = "Cancel Code Review comment" })
  vim.keymap.set("n", "<Esc>", function()
    require("code-review.composer").cancel()
  end, { buffer = buf, nowait = true, desc = "Cancel Code Review comment" })
end

local function apply_refs_keymaps(buf)
  apply_common_keymaps(buf)
  vim.keymap.set("n", "<CR>", reference_action, { buffer = buf, nowait = true, desc = "Open File Reference actions" })
  vim.keymap.set("n", "d", function()
    confirm_delete_reference(current_ref_index(state.get().composer))
  end, { buffer = buf, nowait = true, desc = "Delete draft File Reference" })
  vim.keymap.set("n", "q", function()
    require("code-review.composer").cancel()
  end, { buffer = buf, nowait = true, desc = "Cancel Code Review comment" })
  vim.keymap.set("n", "<Esc>", function()
    require("code-review.composer").cancel()
  end, { buffer = buf, nowait = true, desc = "Cancel Code Review comment" })
end

local function open(opts)
  local s = state.get()
  if s.composer then
    notify.warn("Submit or cancel the comment composer first.")
    return
  end
  local source_win = vim.api.nvim_get_current_win()
  local handle = ui.open_composer_stack(split_body(opts.body or ""))
  local composer = {
    buf = handle.body_buf,
    win = handle.body_win,
    body_buf = handle.body_buf,
    body_win = handle.body_win,
    refs_buf = handle.refs_buf,
    refs_win = handle.refs_win,
    status_buf = handle.status_buf,
    status_win = handle.status_win,
    handle = handle,
    source_win = source_win,
    active_section = "body",
    references = vim.deepcopy(opts.references or {}),
    target_comment_id = opts.target_comment_id,
  }
  s.composer = composer
  apply_body_keymaps(composer.body_buf)
  apply_refs_keymaps(composer.refs_buf)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = composer.body_buf,
    callback = function()
      if state.get().composer and state.get().composer.body_buf == composer.body_buf then
        clear_composer(false)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = composer.body_buf,
    callback = function()
      local current = state.get().composer
      if current and current.body_buf == composer.body_buf then
        M.refresh()
      end
    end,
  })
  state.set_mode("composer")
  M.refresh()
  refresh_draft_highlights()
  focus_section("body")
  vim.cmd("startinsert")
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
    M.refresh()
    return
  end
  local body = body_text(composer)
  if vim.trim(body or "") == "" then
    notify.warn("Write a comment before submitting.")
    M.refresh()
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

function M.focus_references()
  focus_section("refs")
end

function M.focus_body()
  focus_section("body")
end

function M.reference_action()
  reference_action()
end

function M.show_help()
  return ui.open_composer_help({
    "Composer keys",
    "",
    "Tab and Shift-Tab move between references and comment text.",
    "Enter submits from the comment box.",
    "Enter on a reference opens Delete / Go to actions.",
    "d on a reference confirms and deletes that reference.",
    "q or <Esc> cancels the composer from Normal mode.",
    "Space starts recording, stops recording, or retries voice transcription.",
    "",
    "Voice states",
    "",
    "recording: press Space to stop recording.",
    "transcribing: wait for text to be inserted at the comment cursor.",
    "failed: press Space to retry, or cancel to discard the draft.",
  })
end

function M.delete_reference_under_cursor()
  confirm_delete_reference(current_ref_index(state.get().composer))
end

function M.insert_text(text)
  local composer = state.get().composer
  if not composer or not valid_buf(composer.body_buf) then
    return false
  end
  text = vim.trim(text or "")
  if text == "" then
    return true
  end
  local row, col
  if valid_win(composer.body_win) then
    local cursor = vim.api.nvim_win_get_cursor(composer.body_win)
    row = cursor[1] - 1
    col = cursor[2]
  else
    row = vim.api.nvim_buf_line_count(composer.body_buf) - 1
    col = #vim.api.nvim_buf_get_lines(composer.body_buf, row, row + 1, false)[1]
  end
  vim.api.nvim_buf_set_text(composer.body_buf, row, col, row, col, vim.split(text, "\n", { plain = true }))
  M.refresh()
  return true
end

return M
