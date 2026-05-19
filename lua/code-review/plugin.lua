local M = {}

function M.root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

function M.voice_helper()
  return vim.fs.joinpath(M.root(), "voice", "dist", "index.js")
end

return M
