local M = {}

function M.now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

function M.is_iso_utc(value)
  return type(value) == "string" and value:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") ~= nil
end

local function utc_epoch(year, month, day, hour, min, sec)
  year = month <= 2 and year - 1 or year
  local era = math.floor(year / 400)
  local yoe = year - era * 400
  local doy = math.floor((153 * (month + (month > 2 and -3 or 9)) + 2) / 5) + day - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  return days * 86400 + hour * 3600 + min * 60 + sec
end

function M.relative(value, now_epoch)
  if not M.is_iso_utc(value) then
    return "unknown"
  end
  local y, mo, d, h, mi, s = value:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)Z$")
  local epoch = utc_epoch(tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s))
  local diff = math.max(0, (now_epoch or os.time()) - epoch)
  if diff < 60 then
    return "0m ago"
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
