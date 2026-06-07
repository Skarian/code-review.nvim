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
  out = out:gsub("%a:[/\\][^%s]+%.wav", "[REDACTED_AUDIO_PATH]")
  out = out:gsub("(/[^%s:]+/)[^/%s]+%.wav", "[REDACTED_AUDIO_PATH]")
  return out
end

local function review_value(value, key)
  if key == "body" and type(value) == "string" then
    return "[REDACTED_COMMENT_BODY]"
  end
  if key == "selected_lines_snapshot" and type(value) == "table" then
    return { "[REDACTED_SELECTED_LINES]" }
  end
  if type(value) == "string" then
    return M.text(value)
  end
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for child_key, child_value in pairs(value) do
    out[child_key] = review_value(child_value, child_key)
  end
  return out
end

function M.review_data(value)
  return review_value(value)
end

return M
