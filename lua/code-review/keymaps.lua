local config = require("code-review.config")
local state = require("code-review.state")

local M = {}

local defaults = {}
local plugs_done = false

local actions = {
  open_picker = { mode = "n", plug = "<Plug>(code-review-open-picker)", desc = "Review picker" },
  new_comment = { mode = "n", plug = "<Plug>(code-review-new-comment)", desc = "New comment" },
  add_reference = { mode = "x", plug = "<Plug>(code-review-add-reference)", desc = "Add file reference" },
  edit_comment = { mode = "n", plug = "<Plug>(code-review-edit-comment)", desc = "Edit comment" },
  toggle_voice = { mode = "n", plug = "<Plug>(code-review-toggle-voice)", desc = "Toggle voice" },
  next = { mode = "n", plug = "<Plug>(code-review-next)", desc = "Next" },
  previous = { mode = "n", plug = "<Plug>(code-review-previous)", desc = "Previous" },
  open_current = { mode = "n", plug = "<Plug>(code-review-open-current)", desc = "Open current" },
  delete_reference = { mode = "n", plug = "<Plug>(code-review-delete-reference)", desc = "Delete file reference" },
  delete_comment = { mode = "n", plug = "<Plug>(code-review-delete-comment)", desc = "Delete comment" },
  close_comment = { mode = "n", plug = "<Plug>(code-review-close-comment)", desc = "Close comment" },
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
