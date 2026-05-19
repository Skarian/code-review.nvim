local M = {}

local function snacks()
  local ok, mod = pcall(require, "snacks")
  if not ok then
    error("code-review.nvim requires folke/snacks.nvim at runtime", 2)
  end
  if type(mod.win) ~= "function" then
    error("code-review.nvim requires Snacks.win", 2)
  end
  return mod
end

function M.open_composer(buf)
  local win = snacks().win({
    buf = buf,
    title = " Code Review Comment ",
    border = "rounded",
    width = math.min(88, math.max(56, math.floor(vim.o.columns * 0.62))),
    height = math.min(22, math.max(10, math.floor(vim.o.lines * 0.45))),
    wo = {
      number = false,
      relativenumber = false,
      signcolumn = "no",
      wrap = true,
    },
  })
  if type(win) == "table" then
    return win.win or win.winid or win[1], win
  end
  return win, nil
end

return M
