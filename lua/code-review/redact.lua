local M = {}

local patterns = {
  "Bearer%s+[%w%._%-]+",
  "sk%-%w+",
  "eyJ[%w%._%-]+",
}

function M.text(value)
  local out = tostring(value or "")
  for _, pattern in ipairs(patterns) do
    out = out:gsub(pattern, "[REDACTED]")
  end
  out = out:gsub("(/[^%s:]+/)[^/%s]+%.wav", "[REDACTED_AUDIO_PATH]")
  return out
end

return M
