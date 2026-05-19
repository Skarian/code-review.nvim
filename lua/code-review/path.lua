local M = {}

local uv = vim.uv or vim.loop

local function normalize_slashes(path)
  return (path or ""):gsub("\\", "/")
end

function M.normalize(path)
  return normalize_slashes(vim.fs and vim.fs.normalize and vim.fs.normalize(path) or path)
end

function M.realpath(path)
  if not path or path == "" then
    return nil
  end
  return uv.fs_realpath(path) or M.normalize(path)
end

function M.is_absolute(path)
  if type(path) ~= "string" then
    return false
  end
  return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil
end

function M.relative(root, target)
  root = normalize_slashes(M.realpath(root) or root)
  target = normalize_slashes(M.realpath(target) or target)
  if vim.fn.has("win32") == 1 then
    root = root:lower()
    target = target:lower()
  end
  local prefix = root
  if prefix:sub(-1) ~= "/" then
    prefix = prefix .. "/"
  end
  if target == root then
    return "."
  end
  if target:sub(1, #prefix) ~= prefix then
    return nil
  end
  return target:sub(#prefix + 1)
end

function M.inside(root, target)
  return M.relative(root, target) ~= nil
end

function M.join(...)
  local parts = { ... }
  local out = table.concat(parts, "/")
  out = out:gsub("/+", "/")
  return out
end

return M
