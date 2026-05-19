local M = {}

function M.wav_path()
  local dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "code-review.nvim", "voice")
  vim.fn.mkdir(dir, "p")
  return vim.fs.joinpath(dir, vim.fn.fnamemodify(vim.fn.tempname(), ":t") .. ".wav")
end

function M.delete(path)
  if path and path ~= "" then
    pcall(vim.fn.delete, path)
  end
end

return M
