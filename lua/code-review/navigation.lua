local notify = require("code-review.notify")
local path = require("code-review.path")
local state = require("code-review.state")

local M = {}

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

function M.source_buf(buf)
  local s = state.get()
  if not s.root or not valid_buf(buf) then
    return false
  end
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= "" and vim.bo[buf].buftype == "" and path.relative(s.root, name) ~= nil
end

function M.source_win(win)
  return valid_win(win) and M.source_buf(vim.api.nvim_win_get_buf(win))
end

function M.modified_visible_source_buffers()
  local seen = {}
  local modified = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if not seen[buf] and M.source_buf(buf) then
      seen[buf] = true
      if vim.bo[buf].modified then
        modified[#modified + 1] = buf
      end
    end
  end
  return modified
end

function M.find_source_window()
  local current = vim.api.nvim_get_current_win()
  if M.source_win(current) then
    return current
  end

  local previous = vim.fn.win_getid(vim.fn.winnr("#"))
  if M.source_win(previous) then
    return previous
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if M.source_win(win) then
      return win
    end
  end
  return nil
end

function M.go_to(relative_path, line)
  local s = state.get()
  if not s.root then
    return false
  end
  local target = vim.fs.joinpath(s.root, relative_path)
  local win = M.find_source_window()
  if win then
    vim.api.nvim_set_current_win(win)
  end
  vim.cmd.edit(target)
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  return true
end

function M.require_source_buffer(message)
  if M.source_buf(vim.api.nvim_get_current_buf()) then
    return true
  end
  notify.warn(message or "Open a file buffer inside the active Review root first.")
  return false
end

return M
