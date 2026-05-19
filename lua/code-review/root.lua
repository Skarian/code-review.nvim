local path = require("code-review.path")

local M = {}

local uv = vim.uv or vim.loop

function M.detect(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  local source
  if name ~= "" and vim.bo[bufnr].buftype == "" then
    source = name
  else
    source = uv.cwd()
  end
  local root = vim.fs and vim.fs.root and vim.fs.root(source, { ".git" }) or nil
  if not root then
    local dir = source
    if vim.fn.filereadable(dir) == 1 then
      dir = vim.fs.dirname(dir)
    end
    while dir and dir ~= "" do
      if vim.fn.isdirectory(vim.fs.joinpath(dir, ".git")) == 1 then
        root = dir
        break
      end
      local parent = vim.fs.dirname(dir)
      if parent == dir then
        break
      end
      dir = parent
    end
  end
  return path.realpath(root or uv.cwd())
end

function M.hash(root)
  local normalized = path.normalize(root)
  if vim.fn.exists("*sha256") == 1 then
    return vim.fn.sha256(normalized)
  end
  local h = 5381
  for i = 1, #normalized do
    h = ((h * 33) + normalized:byte(i)) % 4294967296
  end
  return string.format("%08x", h)
end

return M
