local config = require("code-review.config")
local highlights = require("code-review.highlights")
local notify = require("code-review.notify")
local root = require("code-review.root")
local state = require("code-review.state")
local storage = require("code-review.storage")

local M = {}

local commands_registered = false

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
      if current.active and current.sidebar and current.sidebar.buf == vim.api.nvim_get_current_buf() then
        M.quit()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufEnter", "TextChanged", "TextChangedI", "BufWritePost", "BufDelete", "BufUnload", "DirChanged", "VimResized", "WinResized" }, {
    group = s.augroup,
    callback = function(args)
      if args.event == "VimResized" or args.event == "WinResized" then
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
  local project_root = root.detect(0)
  local handle = storage.load(project_root)
  if handle.blocked then
    return
  end
  state.activate(project_root, handle.root_hash, handle.store, handle)
  require("code-review.sidebar").render()
  create_augroup()
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
  pcall(require("code-review.voice").stop)
  storage.flush(s.storage)
  if s.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, s.augroup)
    s.augroup = nil
  end
  require("code-review.sidebar").close()
  require("code-review.preview").close()
  if s.composer then
    require("code-review.composer").close()
  end
  require("code-review.highlights").clear_all()
  if s.stale_timer and not s.stale_timer:is_closing() then
    s.stale_timer:stop()
    s.stale_timer:close()
  end
  state.deactivate()
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
