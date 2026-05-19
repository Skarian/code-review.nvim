local M = {}

function M.notify(message, level, opts)
  opts = opts or {}
  level = level or vim.log.levels.INFO
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks and snacks.notify then
    snacks.notify(message, vim.tbl_extend("force", { level = level }, opts))
    return
  end
  vim.notify(message, level, opts)
end

function M.info(message)
  M.notify(message, vim.log.levels.INFO)
end

function M.warn(message)
  M.notify(message, vim.log.levels.WARN)
end

function M.error(message)
  M.notify(message, vim.log.levels.ERROR)
end

return M
