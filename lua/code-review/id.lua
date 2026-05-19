local M = {}

local function hex(n)
  local out = {}
  for _ = 1, n do
    out[#out + 1] = string.format("%x", math.random(0, 15))
  end
  return table.concat(out)
end

function M.new(prefix)
  prefix = prefix or "id"
  return prefix .. "_" .. hex(8) .. "-" .. hex(4) .. "-" .. hex(4) .. "-" .. hex(4) .. "-" .. hex(12)
end

function M.valid(value, prefix)
  return type(value) == "string" and value:match("^" .. prefix .. "_[%x%-]+$") ~= nil
end

return M
