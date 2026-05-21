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

function M.normal_window(win)
  if not valid_win(win) then
    return false
  end
  local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
  if not ok or cfg.relative ~= "" then
    return false
  end
  return true
end

local function loaded_buf(buf)
  return valid_buf(buf) and vim.api.nvim_buf_is_loaded(buf)
end

local function normal_named_file_buf(buf)
  return valid_buf(buf) and vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= ""
end

local function preview_buf(buf)
  return valid_buf(buf) and vim.bo[buf].filetype == "code-review-preview"
end

function M.code_review_aux_window(win)
  if not M.normal_window(win) then
    return false
  end
  local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
  return ft == "code-review-sidebar" or ft == "code-review-sidebar-footer"
end

function M.neo_tree_window(win)
  if not M.normal_window(win) then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local ft = vim.bo[buf].filetype
  if ft:match("^neo%-tree") then
    return true
  end
  local ok, _ = pcall(vim.api.nvim_buf_get_var, buf, "neo_tree_source")
  return ok
end

function M.aux_window(win)
  if not M.normal_window(win) then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if preview_buf(buf) then
    return false
  end
  if M.code_review_aux_window(win) or M.neo_tree_window(win) then
    return true
  end
  return valid_buf(buf) and vim.bo[buf].buftype ~= ""
end

function M.content_buf(buf)
  if not loaded_buf(buf) then
    return false
  end
  if preview_buf(buf) then
    return true
  end
  return vim.bo[buf].buftype == ""
end

function M.content_window(win)
  if not M.normal_window(win) then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  return M.content_buf(buf) and not M.aux_window(win)
end

function M.start_file_window(win)
  return M.content_window(win) and normal_named_file_buf(vim.api.nvim_win_get_buf(win))
end

function M.source_buf(buf)
  local s = state.get()
  return M.source_buf_for_root(s.root, buf)
end

function M.source_buf_for_root(root, buf)
  if not root or not valid_buf(buf) then
    return false
  end
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= "" and vim.bo[buf].buftype == "" and path.relative(root, name) ~= nil
end

function M.source_win(win)
  return M.source_win_for_root(state.get().root, win)
end

function M.source_win_for_root(root, win)
  return valid_win(win) and M.source_buf_for_root(root, vim.api.nvim_win_get_buf(win))
end

function M.named_file_win(win)
  return M.start_file_window(win)
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

function M.find_source_window_for_root(root)
  local current = vim.api.nvim_get_current_win()
  if M.source_win_for_root(root, current) then
    return current
  end

  local previous = vim.fn.win_getid(vim.fn.winnr("#"))
  if M.source_win_for_root(root, previous) then
    return previous
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if M.source_win_for_root(root, win) then
      return win
    end
  end
  return nil
end

local function safe_preview_content_window(win)
  if not M.content_window(win) then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if preview_buf(buf) then
    return false
  end
  return not vim.bo[buf].modified
end

function M.find_preview_target_window(root)
  local current = vim.api.nvim_get_current_win()
  if M.source_win_for_root(root, current) then
    return current
  end

  local previous = vim.fn.win_getid(vim.fn.winnr("#"))
  if M.source_win_for_root(root, previous) then
    return previous
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if M.source_win_for_root(root, win) then
      return win
    end
  end

  if safe_preview_content_window(current) then
    return current
  end

  if safe_preview_content_window(previous) then
    return previous
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if safe_preview_content_window(win) then
      return win
    end
  end

  return nil
end

function M.find_named_file_window()
  return M.find_start_file_window()
end

function M.find_start_file_window()
  local current = vim.api.nvim_get_current_win()
  if M.start_file_window(current) then
    return current
  end

  local previous = vim.fn.win_getid(vim.fn.winnr("#"))
  if M.start_file_window(previous) then
    return previous
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if M.start_file_window(win) then
      return win
    end
  end
  return nil
end

function M.has_content_anchor_window()
  return #M.tab_content_windows(0) > 0
end

function M.tab_content_windows(tab)
  local wins = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab or 0)) do
    if M.content_window(win) then
      wins[#wins + 1] = win
    end
  end
  return wins
end

function M.tab_aux_windows(tab)
  local wins = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab or 0)) do
    if M.aux_window(win) then
      wins[#wins + 1] = win
    end
  end
  return wins
end

function M.any_tab_has_content_window()
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if #M.tab_content_windows(tab) > 0 then
      return true
    end
  end
  return false
end

function M.snapshot_content_windows()
  local windows = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if M.content_window(win) then
      windows[win] = true
    end
  end
  return windows
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
