local M = {}

function M.now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

function M.is_iso_utc(value)
  return type(value) == "string" and value:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") ~= nil
end

function M.relative(value)
  if not M.is_iso_utc(value) then
    return "unknown"
  end
  local y, mo, d, h, mi, s = value:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)Z$")
  local epoch = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
    isdst = false,
  })
  local diff = math.max(0, os.time() - epoch)
  if diff < 60 then
    return "just now"
  elseif diff < 3600 then
    return string.format("%dm ago", math.floor(diff / 60))
  elseif diff < 86400 then
    return string.format("%dh ago", math.floor(diff / 3600))
  else
    return string.format("%dd ago", math.floor(diff / 86400))
  end
end

function M.backup_stamp()
  return os.date("!%Y%m%dT%H%M%SZ")
end

return M
