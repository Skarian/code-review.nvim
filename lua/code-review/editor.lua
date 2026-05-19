local model = require("code-review.model")
local notify = require("code-review.notify")
local state = require("code-review.state")

local M = {}

local function is_editor_buf(buf)
  local editor = state.get().editor
  return editor and editor.buf == buf
end

local function set_clean(buf)
  vim.bo[buf].modified = false
  state.set_mode("body_editor_clean")
end

local function prompt_discard()
  return vim.fn.confirm("Discard comment edits?", "&Discard\n&Cancel", 2) == 1
end

function M.open()
  local s = state.get()
  if s.mode ~= "comment_open" then
    notify.warn("Open a comment before editing its body.")
    return
  end
  local review = model.find_review(s.store, s.active_review_id)
  local comment = model.find_comment(review, s.current_comment_id)
  if not comment then
    notify.warn("No current comment.")
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_name(buf, "Code Review Comment")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(comment.body or "", "\n", { plain = true }))
  vim.api.nvim_set_current_buf(buf)
  s.editor = { buf = buf, comment_id = comment.id }
  state.set_mode("body_editor_clean")
  vim.api.nvim_create_autocmd("CmdlineLeave", {
    buffer = buf,
    callback = function()
      if is_editor_buf(buf) then
        local line = vim.fn.getcmdline():lower():gsub("^%s*", ""):gsub("%s*$", "")
        if line == "q!" or line == "quit!" then
          state.get().editor.force_quit = true
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = function()
      if state.get().editor and state.get().editor.buf == buf then
        state.set_mode("body_editor_dirty")
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local current = state.get()
      local current_review = model.find_review(current.store, current.active_review_id)
      local current_comment = model.find_comment(current_review, comment.id)
      if current_comment then
        current_comment.body = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        model.touch_comment(current_review, current_comment)
        require("code-review.storage").mark_dirty(current.storage)
        require("code-review.sidebar").render()
      end
      set_clean(buf)
    end,
  })
  vim.api.nvim_create_autocmd("QuitPre", {
    buffer = buf,
    callback = function()
      local current = state.get()
      if not current.editor or current.editor.buf ~= buf then
        return
      end
      if current.editor.force_quit then
        current.editor.force_quit = nil
        vim.bo[buf].modified = false
        return
      end
      if vim.bo[buf].modified and not prompt_discard() then
        error("Code Review comment close cancelled", 0)
      end
      vim.bo[buf].modified = false
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      local current = state.get()
      if current.editor and current.editor.buf == buf then
        current.editor = nil
        if current.active then
          state.set_mode("comment_open")
        end
      end
    end,
  })
end

function M.save()
  local current = state.get()
  if not current.editor or not vim.api.nvim_buf_is_valid(current.editor.buf) then
    return false
  end
  vim.api.nvim_buf_call(current.editor.buf, function()
    vim.cmd("write")
  end)
  return true
end

function M.close(force)
  local current = state.get()
  local editor = current.editor
  if not editor or not vim.api.nvim_buf_is_valid(editor.buf) then
    return
  end
  if vim.bo[editor.buf].modified and not force then
    vim.ui.select({ "Discard", "Cancel" }, { prompt = "Discard comment edits?" }, function(choice)
      if choice == "Discard" then
        M.close(true)
      end
    end)
    return
  end
  pcall(vim.api.nvim_buf_delete, editor.buf, { force = true })
end

return M
