local config = require("code-review.config")
local state = require("code-review.state")

local M = {}

local defaults = {}
local plugs_done = false

local actions = {
  review_picker = { mode = "n", plug = "<Plug>(code-review-review-picker)", desc = "Review picker" },
  add_reference = { mode = "x", plug = "<Plug>(code-review-add-reference)", desc = "New comment from selection" },
  append_reference = { mode = "x", plug = "<Plug>(code-review-append-reference)", desc = "Append selection to comment" },
  edit_comment = { mode = "n", plug = "<Plug>(code-review-edit-comment)", desc = "Edit comments" },
  edit_comment_under_cursor = { mode = "n", plug = "<Plug>(code-review-edit-comment-under-cursor)", desc = "Edit comment under cursor" },
  preview = { mode = "n", plug = "<Plug>(code-review-preview)", desc = "Preview" },
  quit = { mode = "n", plug = "<Plug>(code-review-quit)", desc = "Quit Review Mode" },
}

local function dispatch(action)
  return function()
    require("code-review.actions").dispatch(action)
  end
end

function M.setup_plugs()
  if plugs_done then
    return
  end
  plugs_done = true
  for name, spec in pairs(actions) do
    vim.keymap.set(spec.mode, spec.plug, dispatch(name), { desc = "Code Review: " .. spec.desc })
  end
end

function M.setup_defaults()
  local cfg = config.get().keymaps
  M.setup_plugs()
  for _, mapping in ipairs(defaults) do
    pcall(vim.keymap.del, mapping.mode, mapping.lhs)
  end
  defaults = {}
  if not cfg.enabled then
    return
  end
  for name, spec in pairs(actions) do
    local suffix = cfg[name]
    if suffix ~= false and suffix ~= nil then
      local lhs = cfg.prefix .. suffix
      vim.keymap.set(spec.mode, lhs, spec.plug, { remap = true, desc = "Code Review: " .. spec.desc })
      defaults[#defaults + 1] = { mode = spec.mode, lhs = lhs }
    end
  end
  if cfg.add_reference ~= false and cfg.add_reference ~= nil then
    local lhs = cfg.prefix .. cfg.add_reference
    vim.keymap.set("n", lhs, function()
      require("code-review.actions").new_comment()
    end, { desc = "Code Review: New comment from selection" })
    defaults[#defaults + 1] = { mode = "n", lhs = lhs }
  end
  if cfg.append_reference ~= false and cfg.append_reference ~= nil then
    local lhs = cfg.prefix .. cfg.append_reference
    vim.keymap.set("n", lhs, function()
      require("code-review.actions").append_reference_hint()
    end, { desc = "Code Review: Append selection to comment" })
    defaults[#defaults + 1] = { mode = "n", lhs = lhs }
  end
  local ok, which_key = pcall(require, "which-key")
  if ok and which_key.add then
    pcall(which_key.add, { { config.get().keymaps.prefix, group = "Code Review" } })
  elseif ok and which_key.register then
    pcall(which_key.register, { [config.get().keymaps.prefix] = { name = "Code Review" } })
  end
end

function M.attach()
end

function M.attach_all()
  M.setup_defaults()
end

function M.detach(bufnr)
  local s = state.get()
  if not s.mappings or not s.mappings[bufnr] then
    return
  end
  for _, mapping in ipairs(s.mappings[bufnr]) do
    pcall(vim.keymap.del, mapping.mode, mapping.lhs, { buffer = bufnr })
  end
  s.mappings[bufnr] = nil
end

function M.detach_all()
end

return M
