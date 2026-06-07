local config = require("code-review.config")
local model = require("code-review.model")
local navigation = require("code-review.navigation")
local notify = require("code-review.notify")
local plugin = require("code-review.plugin")
local state = require("code-review.state")
local storage = require("code-review.storage")
local ui = require("code-review.ui")

local M = {}
-- Frames copied from xieyonn/spinner.nvim's dotsCircle and dots14 patterns.
local recording_frames = {
  "⢎ ",
  "⠎⠁",
  "⠊⠑",
  "⠈⠱",
  " ⡱",
  "⢀⡰",
  "⢄⡠",
  "⢆⡀",
}
local transcribing_frames = {
  "⠉⠉",
  "⠈⠙",
  "⠀⠹",
  "⠀⢸",
  "⠀⣰",
  "⢀⣠",
  "⣀⣀",
  "⣄⡀",
  "⣆⠀",
  "⡇⠀",
  "⠏⠀",
  "⠋⠁",
}
local spinner_interval_ms = 80

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

local function edit_body_lines(body)
  local lines = split_body(body)
  local last = lines[#lines] or ""
  if last:match("%S$") then
    lines[#lines] = last .. "  "
  end
  return lines
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

local function word_like(char)
  return char ~= "" and char:match("[%w_]") ~= nil
end

local function punctuation_like(char)
  return char ~= "" and char:match("[%.%!%?,;:]") ~= nil
end

local function first_nonspace(text)
  return (text or ""):match("^%s*(.)") or ""
end

local function add_insert_boundary_spaces(lines, line, col)
  if #lines == 0 then
    return lines
  end
  local before = col > 0 and line:sub(col, col) or ""
  local after = line:sub(col + 1, col + 1)
  local first = first_nonspace(lines[1])
  if before:match("%S") and lines[1]:match("^%S") then
    local separator = " "
    if punctuation_like(first) then
      separator = ""
    end
    lines[1] = separator .. lines[1]
  end
  if word_like(after) and lines[#lines]:match("%S$") then
    lines[#lines] = lines[#lines] .. " "
  end
  return lines
end

local function voice_available()
  local cfg = config.get().voice
  if not cfg.enabled then
    return false
  end
  local helper = cfg.helper_path or plugin.voice_helper()
  return vim.fn.filereadable(helper) == 1
end

local function voice_status_label()
  local s = state.get()
  if s.mode == "recording_starting" then
    return "Starting"
  end
  if s.mode == "recording" then
    return "Recording"
  end
  if s.mode == "transcribing" then
    return "Transcribing"
  end
  if s.mode == "voice_error_pending" then
    return "Failed"
  end
  if not voice_available() then
    return "Unavailable"
  end
  return "Ready"
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

local function voice_active()
  local mode = state.mode()
  return mode == "recording_starting" or mode == "recording" or mode == "transcribing"
end

local function active_voice_frames()
  local mode = state.mode()
  if mode == "recording_starting" or mode == "recording" then
    return recording_frames
  end
  if mode == "transcribing" then
    return transcribing_frames
  end
end

local function voice_prefix(composer)
  local frames = active_voice_frames()
  if frames then
    return frames[((composer.spinner_frame or 1) - 1) % #frames + 1]
  end
  if state.mode() == "voice_error_pending" then
    return "× "
  end
  if not voice_available() then
    return "! "
  end
  return "○ "
end

local function center_lines(lines, width)
  local centered = {}
  for _, line in ipairs(lines) do
    local padding = math.max(0, math.floor((width - vim.fn.strdisplaywidth(line)) / 2))
    centered[#centered + 1] = string.rep(" ", padding) .. line
  end
  return centered
end

local function voice_lines(composer)
  local label = voice_status_label()
  local line = voice_prefix(composer) .. " " .. label
  if valid_win(composer.voice_win) then
    line = center_lines({ line }, vim.api.nvim_win_get_width(composer.voice_win))[1]
  end
  return { line }
end

local function legend_lines(composer)
  local width = valid_win(composer.legend_win) and vim.api.nvim_win_get_width(composer.legend_win) or 92
  local height = valid_win(composer.legend_win) and vim.api.nvim_win_get_height(composer.legend_win) or 3
  local voice_error = state.mode() == "voice_error_pending"
  if height <= 1 then
    if voice_error and width >= 42 then
      return { "<leader><Space> retry | <leader>x discard" }
    end
    if width >= 32 then
      return { "Enter submit | q cancel | ? help" }
    end
    return { "Enter | q | ?" }
  end
  if width >= 58 then
    if voice_error then
      return {
        "Enter submit | <leader><Space> retry | <leader>x discard",
        "q cancel | Tab switch panels | ? help",
      }
    end
    return {
      "Enter submit | <leader><Space> voice | <leader>d delete",
      "q cancel | Tab switch panels | ? help",
    }
  end
  if width < 37 then
    if height <= 2 then
      if voice_error then
        if width >= 20 then
          return {
            "Enter submit | retry",
            "discard | q | ?",
          }
        end
        return {
          "Enter | retry",
          "discard | q",
        }
      end
      if width >= 20 then
        return {
          "Enter submit | voice",
          "delete | q | ?",
        }
      end
      return {
        "Enter | voice",
        "delete | q | ?",
      }
    end
    if voice_error then
      return {
        "Enter submit",
        "retry | discard",
        "q cancel | ? help",
      }
    end
    return {
      "Enter submit",
      "voice | delete",
      "q cancel | ? help",
    }
  end
  if height <= 2 then
    if voice_error then
      return {
        "Enter submit | <leader><Space> retry",
        "<leader>x discard | q cancel | ? help",
      }
    end
    return {
      "Enter submit | <leader><Space> voice",
      "<leader>d delete | q cancel | ? help",
    }
  end
  if voice_error then
    return {
      "Enter submit | <leader><Space> retry",
      "<leader>x discard | q cancel",
      "Tab switch panels | ? help",
    }
  end
  return {
    "Enter submit | <leader><Space> voice",
    "<leader>d delete | q cancel",
    "Tab switch panels | ? help",
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

local function stop_spinner(composer)
  if composer and composer.spinner_timer then
    pcall(composer.spinner_timer.stop, composer.spinner_timer)
    pcall(composer.spinner_timer.close, composer.spinner_timer)
    composer.spinner_timer = nil
  end
end

local function render_voice(composer)
  set_readonly_lines(composer.voice_buf, voice_lines(composer))
end

local function sync_spinner(composer)
  if not composer then
    return
  end
  if not voice_active() then
    stop_spinner(composer)
    composer.spinner_frame = 1
    render_voice(composer)
    return
  end
  composer.spinner_frame = composer.spinner_frame or 1
  if composer.spinner_timer then
    render_voice(composer)
    return
  end
  local session_id = state.get().session_id
  local timer = vim.loop.new_timer()
  composer.spinner_timer = timer
  timer:start(0, spinner_interval_ms, function()
    vim.schedule(function()
      local current = state.get().composer
      if current ~= composer or state.get().session_id ~= session_id or not valid_buf(composer.voice_buf) then
        stop_spinner(composer)
        return
      end
      if not voice_active() then
        stop_spinner(composer)
        composer.spinner_frame = 1
        render_voice(composer)
        return
      end
      local frames = active_voice_frames()
      composer.spinner_frame = ((composer.spinner_frame or 1) % #frames) + 1
      render_voice(composer)
    end)
  end)
  render_voice(composer)
end

function M.refresh()
  local composer = state.get().composer
  if not composer then
    return
  end
  set_readonly_lines(composer.refs_buf, reference_lines(composer))
  do
    local width = valid_win(composer.legend_win) and vim.api.nvim_win_get_width(composer.legend_win) or 92
    set_readonly_lines(composer.legend_buf, center_lines(legend_lines(composer), width))
  end
  sync_spinner(composer)
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
  stop_spinner(composer)
  if composer.handle and type(composer.handle.close) == "function" then
    pcall(composer.handle.close, composer.handle)
    return
  end
  for _, win in ipairs({ composer.refs_win, composer.body_win, composer.voice_win, composer.legend_win }) do
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
  pcall(require("code-review.voice").stop_prearm)
  if composer.resize_autocmd then
    pcall(vim.api.nvim_del_autocmd, composer.resize_autocmd)
    composer.resize_autocmd = nil
  end
  close_windows(composer)
  if delete_buf then
    for _, buf in ipairs({ composer.refs_buf, composer.body_buf, composer.voice_buf, composer.legend_buf }) do
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

local function confirm_delete_comment_or_draft()
  local composer = state.get().composer
  if not composer then
    return
  end
  local review = active_review()
  local target_comment_id = composer.target_comment_id
  local prompt = target_comment_id and "Delete Comment?" or "Delete Draft?"
  vim.ui.select({ "Delete", "Cancel" }, { prompt = prompt }, function(choice)
    if choice ~= "Delete" then
      return
    end
    if not target_comment_id then
      clear_composer(true)
      return
    end
    if not review then
      notify.warn("Create or select a Review first.")
      return
    end
    for index, comment in ipairs(review.comments or {}) do
      if comment.id == target_comment_id then
        table.remove(review.comments, index)
        model.touch_review(review)
        clear_composer(true)
        persist()
        return
      end
    end
    notify.warn("Comment no longer exists.")
  end)
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
  navigation.go_to(ref.relative_path, ref.start_line)
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

local function register_buffer_which_key(buf, delete_desc)
  local ok, which_key = pcall(require, "which-key")
  if not ok then
    return
  end
  if which_key.add then
    pcall(which_key.add, {
      { "<leader>d", desc = delete_desc, mode = "n", buffer = buf },
      { "<leader><Space>", desc = "Toggle Code Review voice", mode = "n", buffer = buf },
      { "<leader>x", desc = "Discard Code Review voice transcription", mode = "n", buffer = buf },
    })
  elseif which_key.register then
    pcall(which_key.register, {
      ["<leader>d"] = delete_desc,
      ["<leader><Space>"] = "Toggle Code Review voice",
      ["<leader>x"] = "Discard Code Review voice transcription",
    }, { mode = "n", buffer = buf })
  end
end

local function apply_common_keymaps(buf)
  vim.keymap.set("n", "<leader><Space>", function()
    require("code-review.voice").toggle()
  end, { buffer = buf, nowait = true, desc = "Toggle Code Review voice" })
  vim.keymap.set("n", "<leader>x", function()
    if state.mode() == "voice_error_pending" and state.get().voice then
      require("code-review.voice").discard()
    else
      notify.warn("No voice transcription to discard.")
    end
  end, { buffer = buf, nowait = true, desc = "Discard Code Review voice transcription" })
  vim.keymap.set("n", "q", function()
    require("code-review.composer").cancel()
  end, { buffer = buf, nowait = true, desc = "Cancel Code Review comment" })
  vim.keymap.set("n", "<leader>q", function()
    require("code-review.composer").cancel()
  end, { buffer = buf, nowait = true, desc = "Cancel Code Review comment" })
  vim.keymap.set("n", "<Esc>", function()
    require("code-review.composer").cancel()
  end, { buffer = buf, nowait = true, desc = "Cancel Code Review comment" })
  vim.keymap.set("n", "?", function()
    require("code-review.composer").show_help()
  end, { buffer = buf, nowait = true, desc = "Show Code Review Comment Editor help" })
  vim.keymap.set("n", "<Tab>", function()
    cycle_focus(false)
  end, { buffer = buf, nowait = true, desc = "Next Code Review Comment Editor section" })
  vim.keymap.set("n", "<S-Tab>", function()
    cycle_focus(true)
  end, { buffer = buf, nowait = true, desc = "Previous Code Review Comment Editor section" })
end

local function apply_body_keymaps(buf)
  apply_common_keymaps(buf)
  vim.keymap.set("n", "<leader>d", function()
    require("code-review.composer").delete_comment_or_draft()
  end, { buffer = buf, nowait = true, desc = "Delete Code Review comment or draft" })
  register_buffer_which_key(buf, "Delete Code Review comment or draft")
  vim.keymap.set("n", "<CR>", function()
    require("code-review.composer").submit()
  end, { buffer = buf, nowait = true, desc = "Submit Code Review comment" })
end

local function apply_refs_keymaps(buf)
  apply_common_keymaps(buf)
  vim.keymap.set("n", "<CR>", reference_action, { buffer = buf, nowait = true, desc = "Open File Reference actions" })
  vim.keymap.set("n", "<leader>d", function()
    confirm_delete_reference(current_ref_index(state.get().composer))
  end, { buffer = buf, nowait = true, desc = "Delete draft File Reference" })
  register_buffer_which_key(buf, "Delete draft File Reference")
end

local function open(opts)
  local s = state.get()
  if s.composer then
    notify.warn("Submit or cancel the Comment Editor first.")
    return
  end
  local source_win = vim.api.nvim_get_current_win()
  local body_lines_for_open = opts.body_lines or split_body(opts.body or "")
  local handle = ui.open_composer_stack(body_lines_for_open)
  local composer = {
    buf = handle.body_buf,
    win = handle.body_win,
    body_buf = handle.body_buf,
    body_win = handle.body_win,
    refs_buf = handle.refs_buf,
    refs_win = handle.refs_win,
    voice_buf = handle.voice_buf,
    voice_win = handle.voice_win,
    legend_buf = handle.legend_buf,
    legend_win = handle.legend_win,
    handle = handle,
    source_win = source_win,
    active_section = "body",
    references = vim.deepcopy(opts.references or {}),
    target_comment_id = opts.target_comment_id,
    spinner_frame = 1,
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
  composer.resize_autocmd = vim.api.nvim_create_autocmd("VimResized", {
    callback = function()
      local current = state.get().composer
      if current and current.body_buf == composer.body_buf then
        ui.layout_composer_stack(composer.handle)
        M.refresh()
      end
    end,
  })
  state.set_mode("composer")
  M.refresh()
  vim.schedule(function()
    local current = state.get().composer
    if current and current.body_buf == composer.body_buf then
      local ok_voice, voice = pcall(require, "code-review.voice")
      if ok_voice then
        pcall(voice.prewarm_devices)
        pcall(voice.start_prearm)
      end
    end
  end)
  refresh_draft_highlights()
  focus_section("body")
  if opts.start_insert == false then
    local last_line = body_lines_for_open[#body_lines_for_open] or ""
    vim.api.nvim_win_set_cursor(composer.body_win, { #body_lines_for_open, math.max(#last_line - 1, 0) })
    vim.cmd("stopinsert")
  else
    vim.cmd("startinsert")
  end
end

function M.open_new(reference)
  open({ references = { reference } })
end

function M.open_edit(comment)
  open({
    target_comment_id = comment.id,
    references = comment.file_references,
    body_lines = edit_body_lines(comment.body),
    start_insert = false,
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
  require("code-review.sidebar").suppress_next_source_filter()
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

function M.delete_comment_or_draft()
  confirm_delete_comment_or_draft()
end

function M.show_help()
  return ui.open_composer_help({
    "Overview",
    "  Write a review comment with its source context attached",
    "  File References stay visible above the text while you write",
    "  Edit the comment text below; use Tab and Shift-Tab to switch panes",
    "  Submit when the comment has text and at least one File Reference",
    "  Voice Dictation is built in for drafting longer comments without leaving the editor",
    "",
    "Comment text",
    "  Key          Action",
    "  Enter        Submit the comment",
    "  <leader>d   Delete the whole comment or draft",
    "  <leader><Space> Start, cancel startup, stop, or retry voice recording",
    "  <leader>rm  Choose microphone",
    "  <leader>x   Discard a failed voice transcription",
    "  q or Esc     Cancel from Normal mode",
    "  ?            Show help",
    "",
    "File References",
    "  Key          Action",
    "  Enter        Open actions for the focused reference",
    "               Delete removes it; Go to jumps the source window to that line",
    "  <leader>d   Delete the focused reference",
    "",
    "Submitting and cancelling",
    "  Submit requires comment text and at least one File Reference",
    "",
    "Voice Dictation",
    "  Ready         Voice is ready",
    "  Starting      Voice helper is opening the microphone",
    "  Recording     Voice is recording",
    "  Transcribing  Voice is being transcribed",
    "  Failed        Voice dictation failed; retry with <leader><Space> or discard with <leader>x",
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
  local line = vim.api.nvim_buf_get_lines(composer.body_buf, row, row + 1, false)[1] or ""
  local lines = add_insert_boundary_spaces(vim.split(text, "\n", { plain = true }), line, col)
  vim.api.nvim_buf_set_text(composer.body_buf, row, col, row, col, lines)
  if valid_win(composer.body_win) then
    local cursor_row = row + #lines
    local cursor_col = #lines[#lines]
    if #lines == 1 then
      cursor_col = col + cursor_col
    end
    pcall(vim.api.nvim_win_set_cursor, composer.body_win, { cursor_row, cursor_col })
  end
  M.refresh()
  return true
end

return M
