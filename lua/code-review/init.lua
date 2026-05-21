local config = require("code-review.config")
local highlights = require("code-review.highlights")
local navigation = require("code-review.navigation")
local notify = require("code-review.notify")
local root = require("code-review.root")
local state = require("code-review.state")
local storage = require("code-review.storage")

local M = {}

local commands_registered = false
local sidebar_refresh_ms = 60000
local lifecycle_exit_scheduled = false

local function stop_sidebar_timer(current)
  if current.sidebar_timer and not current.sidebar_timer:is_closing() then
    current.sidebar_timer:stop()
    current.sidebar_timer:close()
  end
  current.sidebar_timer = nil
end

local function refresh_for_buffer(bufnr)
  if not state.is_active() then
    return
  end
  local current = state.get()
  local review = require("code-review.model").find_review(current.store, current.active_review_id)
  if review then
    local _, changed = require("code-review.stale").refresh_review(current.root, review, bufnr)
    if changed then
      storage.mark_dirty(current.storage)
    end
  end
  require("code-review.highlights").refresh(bufnr)
  require("code-review.sidebar").render()
end

local function debounce_stale_refresh(bufnr)
  local current = state.get()
  if current.stale_timer and not current.stale_timer:is_closing() then
    current.stale_timer:stop()
  else
    current.stale_timer = (vim.uv or vim.loop).new_timer()
  end
  current.stale_timer:start(config.get().stale.debounce_ms or 200, 0, function()
    vim.schedule(function()
      refresh_for_buffer(bufnr)
    end)
  end)
end

local function start_sidebar_timer()
  local current = state.get()
  stop_sidebar_timer(current)
  current.sidebar_timer = (vim.uv or vim.loop).new_timer()
  current.sidebar_timer:start(sidebar_refresh_ms, sidebar_refresh_ms, function()
    vim.schedule(function()
      if state.is_active() then
        require("code-review.sidebar").render()
      end
    end)
  end)
end

local function refresh_content_window_snapshot()
  if not state.is_active() then
    return
  end
  local s = state.get()
  s.content_windows = navigation.snapshot_content_windows()
end

local function only_auxiliary_windows_remain(tab)
  local wins = vim.api.nvim_tabpage_list_wins(tab or 0)
  local normal_count = 0
  for _, win in ipairs(wins) do
    if not navigation.normal_window(win) then
      goto continue
    end
    normal_count = normal_count + 1
    if navigation.content_window(win) then
      return false
    end
    if not navigation.aux_window(win) then
      return false
    end
    ::continue::
  end
  return normal_count > 0
end

local function other_tabs_have_content_window()
  local current_tab = vim.api.nvim_get_current_tabpage()
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if tab ~= current_tab and #navigation.tab_content_windows(tab) > 0 then
      return true
    end
  end
  return false
end

function M._exit_auxiliary_layout()
  local s = state.get()
  if s.auxiliary_exit_requested then
    return
  end
  s.auxiliary_exit_requested = true
  vim.schedule(function()
    vim.cmd("confirm qall")
  end)
end

local function schedule_auxiliary_only_check()
  local s = state.get()
  if lifecycle_exit_scheduled or s.tearing_down then
    return
  end
  local session_id = s.session_id
  lifecycle_exit_scheduled = true
  vim.schedule(function()
    lifecycle_exit_scheduled = false
    if not state.is_active() or state.get().session_id ~= session_id then
      return
    end
    if state.get().preview or state.get().preview_restoring then
      return
    end
    if #navigation.tab_content_windows(0) > 0 or not only_auxiliary_windows_remain(0) then
      return
    end
    local other_tabs_had_content = other_tabs_have_content_window()
    if other_tabs_had_content then
      state.get().tearing_down = true
      M.quit()
      if #vim.api.nvim_list_tabpages() > 1 then
        pcall(vim.cmd, "tabclose")
      end
      return
    end
    M._exit_auxiliary_layout()
  end)
end

local function create_augroup()
  local s = state.get()
  if s.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, s.augroup)
  end
  s.augroup = vim.api.nvim_create_augroup("code_review_nvim", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = s.augroup,
    callback = function()
      local current = state.get()
      if current.active then
        pcall(require("code-review.voice").stop)
        storage.flush(current.storage)
      end
    end,
  })
  vim.api.nvim_create_autocmd("QuitPre", {
    group = s.augroup,
    callback = function()
      local current = state.get()
      local buf = vim.api.nvim_get_current_buf()
      if current.active and current.preview and current.preview.buf == buf then
        require("code-review.preview").prepare_window_quit()
        return
      end
      if current.active and (current.preview or current.preview_restoring) then
        return
      end
      if current.active and current.sidebar and (current.sidebar.buf == buf or current.sidebar.footer_buf == buf) then
        if #navigation.tab_content_windows(0) == 0 and only_auxiliary_windows_remain(0) then
          M._exit_auxiliary_layout()
        else
          M.quit()
        end
      elseif current.active and #navigation.tab_content_windows(0) == 0 and only_auxiliary_windows_remain(0) then
        M._exit_auxiliary_layout()
      end
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = s.augroup,
    callback = function(args)
      require("code-review.sidebar").update_filter_for_buffer(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = s.augroup,
    callback = function(args)
      local current = state.get()
      if not current.active or current.tearing_down or current.recreating_sidebar then
        return
      end
      local closing = tonumber(args.match)
      if current.preview and closing and current.preview.win == closing then
        require("code-review.preview").handle_window_closed(current.preview)
      end
      if
        closing
        and current.sidebar
        and (closing == current.sidebar.win or closing == current.sidebar.footer_win)
        and #navigation.tab_content_windows(0) > 0
      then
        vim.schedule(function()
          if state.is_active() then
            state.get().recreating_sidebar = true
            require("code-review.sidebar").close()
            require("code-review.sidebar").render()
            state.get().recreating_sidebar = false
          end
        end)
        return
      end
      local was_content = closing and current.content_windows and current.content_windows[closing]
      refresh_content_window_snapshot()
      if was_content then
        schedule_auxiliary_only_check()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter", "BufEnter" }, {
    group = s.augroup,
    callback = function()
      refresh_content_window_snapshot()
      require("code-review.sidebar").capture_width_from_sidebar()
      if #navigation.tab_content_windows(0) > 0 then
        local session_id = state.get().session_id
        vim.schedule(function()
          if state.is_active() and state.get().session_id == session_id and #navigation.tab_content_windows(0) > 0 then
            require("code-review.sidebar").render()
          end
        end)
      end
      schedule_auxiliary_only_check()
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = s.augroup,
    callback = function()
      require("code-review.sidebar").capture_width_from_sidebar()
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost", "BufDelete", "BufUnload", "DirChanged", "VimResized", "WinResized" }, {
    group = s.augroup,
    callback = function(args)
      if args.event == "BufDelete" or args.event == "BufUnload" then
        if state.get().recreating_sidebar then
          return
        end
        refresh_content_window_snapshot()
        schedule_auxiliary_only_check()
        if state.is_active() and #navigation.tab_content_windows(0) > 0 then
          local session_id = state.get().session_id
          vim.schedule(function()
            if state.is_active() and state.get().session_id == session_id and #navigation.tab_content_windows(0) > 0 then
              require("code-review.sidebar").render()
            end
          end)
        end
        return
      elseif args.event == "VimResized" or args.event == "WinResized" then
        require("code-review.sidebar").handle_resize()
        require("code-review.sidebar").render()
      elseif args.event == "TextChanged" or args.event == "TextChangedI" then
        debounce_stale_refresh(args.buf)
      else
        refresh_for_buffer(args.buf)
      end
    end,
  })
end

function M._register_commands()
  if commands_registered then
    return
  end
  commands_registered = true
  vim.api.nvim_create_user_command("CodeReview", function()
    M.toggle()
  end, {})
  vim.api.nvim_create_user_command("CodeReviewHealth", function()
    require("code-review.health").show()
  end, {})
  vim.api.nvim_create_user_command("CodeReviewClearData", function()
    M.clear_data()
  end, {})
end

function M.setup(opts)
  config.setup(opts)
  highlights.setup()
  M._register_commands()
  require("code-review.keymaps").setup_defaults()
  return config.get()
end

function M.is_active()
  return state.is_active()
end

function M.status()
  return state.status()
end

function M.start()
  if state.is_active() then
    return
  end
  local source_win = navigation.find_start_file_window()
  if not source_win then
    notify.warn("Open a file buffer before starting Code Review.")
    return
  end
  local project_root = root.detect(vim.api.nvim_win_get_buf(source_win))
  source_win = navigation.find_source_window_for_root(project_root) or source_win
  local handle = storage.load(project_root)
  if handle.blocked then
    return
  end
  state.activate(project_root, handle.root_hash, handle.store, handle)
  lifecycle_exit_scheduled = false
  if vim.api.nvim_win_is_valid(source_win) then
    vim.api.nvim_set_current_win(source_win)
  end
  require("code-review.sidebar").render()
  create_augroup()
  refresh_content_window_snapshot()
  start_sidebar_timer()
  require("code-review.highlights").refresh()
  if handle.store.last_active_review_id then
    state.set_mode("comment_list")
  else
    state.set_mode("review_picker")
  end
end

function M.quit()
  if not state.is_active() then
    return
  end
  local s = state.get()
  if s.preview and s.preview.buf and vim.api.nvim_buf_is_valid(s.preview.buf) and vim.bo[s.preview.buf].modified then
    notify.warn("Write or discard the modified Code Review preview before quitting.")
    return false
  end
  lifecycle_exit_scheduled = false
  s.tearing_down = true
  pcall(require("code-review.voice").stop)
  storage.flush(s.storage)
  if s.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, s.augroup)
    s.augroup = nil
  end
  require("code-review.sidebar").close()
  if require("code-review.preview").close() == false then
    s.tearing_down = false
    return false
  end
  if s.composer then
    require("code-review.composer").close()
  end
  require("code-review.highlights").clear_all()
  if s.stale_timer and not s.stale_timer:is_closing() then
    s.stale_timer:stop()
    s.stale_timer:close()
  end
  stop_sidebar_timer(s)
  state.deactivate()
  return true
end

function M.toggle()
  if state.is_active() then
    M.quit()
  else
    M.start()
    if state.is_active() and state.mode() == "review_picker" then
      require("code-review.review_picker").open()
    end
  end
end

function M.clear_data()
  local project_root = state.is_active() and state.get().root or root.detect(0)
  local function do_clear()
    if state.is_active() then
      M.quit()
    end
    local ok, err = storage.clear_current(project_root)
    if ok then
      notify.info("Code Review data cleared.")
    else
      notify.error("Could not clear Code Review data: " .. tostring(err))
    end
  end
  vim.ui.select({ "Delete", "Cancel" }, { prompt = "Delete Code Review data for this project?" }, function(choice)
    if choice == "Delete" then
      do_clear()
    end
  end)
end

return M
