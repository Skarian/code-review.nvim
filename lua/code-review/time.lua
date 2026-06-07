local M = {}

function M.now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function parse_iso_utc(value)
  if type(value) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, s = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
  if not y then
    return nil
  end
  return tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)
end

local function leap_year(year)
  return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

local function days_in_month(year, month)
  if month == 2 then
    return leap_year(year) and 29 or 28
  end
  local days = { 31, nil, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  return days[month]
end

function M.is_iso_utc(value)
  local year, month, day, hour, min, sec = parse_iso_utc(value)
  if not year then
    return false
  end
  if year < 1 or month < 1 or month > 12 then
    return false
  end
  local month_days = days_in_month(year, month)
  if not month_days or day < 1 or day > month_days then
    return false
  end
  return hour >= 0 and hour <= 23 and min >= 0 and min <= 59 and sec >= 0 and sec <= 59
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
  local y, mo, d, h, mi, s = parse_iso_utc(value)
  local epoch = utc_epoch(y, mo, d, h, mi, s)
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
