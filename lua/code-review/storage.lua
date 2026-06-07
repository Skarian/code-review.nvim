local config = require("code-review.config")
local model = require("code-review.model")
local notify = require("code-review.notify")
local root_mod = require("code-review.root")
local schema = require("code-review.schema")
local time = require("code-review.time")

local M = {}

local uv = vim.uv or vim.loop

local function mkdir(path)
  local ok, err = pcall(vim.fn.mkdir, path, "p")
  if not ok then
    return false, err
  end
  if vim.fn.isdirectory(path) == 0 then
    return false, "not a directory"
  end
  return true
end

local function storage_dir()
  local override = config.get().storage.dir
  if override and override ~= "" then
    return override
  end
  return vim.fs.joinpath(vim.fn.stdpath("data"), "code-review.nvim", "reviews")
end

function M.path_for(root)
  local hash = root_mod.hash(root)
  return vim.fs.joinpath(storage_dir(), hash .. ".json"), hash
end

local function decode_json(text)
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok then
    return nil, decoded
  end
  return decoded
end

local function stop_timer(handle)
  if handle and handle.timer and not handle.timer:is_closing() then
    handle.timer:stop()
    handle.timer:close()
  end
  if handle then
    handle.timer = nil
  end
end

function M.load(root)
  local store_path, hash = M.path_for(root)
  mkdir(vim.fs.dirname(store_path))
  local fd = uv.fs_open(store_path, "r", 438)
  if not fd then
    return {
      path = store_path,
      root_hash = hash,
      store = model.new_store(root, hash),
      dirty = false,
    }
  end
  local stat = uv.fs_fstat(fd)
  local text = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  local decoded = decode_json(text or "")
  if not decoded then
    local backup = store_path:gsub("%.json$", "") .. ".corrupt-" .. time.backup_stamp() .. ".json"
    uv.fs_rename(store_path, backup)
    notify.warn("Code Review store was corrupt; moved backup to " .. backup)
    return {
      path = store_path,
      root_hash = hash,
      store = model.new_store(root, hash),
      dirty = false,
    }
  end
  local result = schema.validate(decoded, hash)
  if result.ok then
    return {
      path = store_path,
      root_hash = hash,
      store = result.store,
      dirty = false,
    }
  end
  if result.kind == "corrupt" then
    local backup = store_path:gsub("%.json$", "") .. ".corrupt-" .. time.backup_stamp() .. ".json"
    uv.fs_rename(store_path, backup)
    notify.warn("Code Review store was corrupt; moved backup to " .. backup)
    return {
      path = store_path,
      root_hash = hash,
      store = model.new_store(root, hash),
      dirty = false,
    }
  end
  notify.error("Code Review store cannot be loaded: " .. result.message)
  return {
    path = store_path,
    root_hash = hash,
    store = model.new_store(root, hash),
    dirty = false,
    blocked = true,
  }
end

function M.mark_dirty(handle)
  if handle then
    handle.dirty = true
    if handle.timer and not handle.timer:is_closing() then
      handle.timer:stop()
    else
      handle.timer = uv.new_timer()
    end
    handle.timer:start(config.get().storage.debounce_ms or 250, 0, function()
      vim.schedule(function()
        if handle.timer and not handle.timer:is_closing() then
          handle.timer:close()
          handle.timer = nil
        end
        M.flush(handle)
      end)
    end)
  end
end

function M.save(handle)
  if not handle or handle.blocked then
    return false
  end
  stop_timer(handle)
  local dir_ok, dir_err = mkdir(vim.fs.dirname(handle.path))
  if not dir_ok then
    notify.error("Could not create Code Review storage directory: " .. tostring(dir_err))
    return false
  end
  local tmp = handle.path .. ".tmp." .. tostring(uv.hrtime())
  local text = vim.json.encode(handle.store)
  local fd, err = uv.fs_open(tmp, "w", 438)
  if not fd then
    notify.error("Could not write Code Review store: " .. tostring(err))
    return false
  end
  local written, write_err = uv.fs_write(fd, text, 0)
  uv.fs_close(fd)
  if not written or written < #text then
    pcall(uv.fs_unlink, tmp)
    notify.error("Could not write complete Code Review store: " .. tostring(write_err or "short write"))
    return false
  end
  local ok, rename_err = uv.fs_rename(tmp, handle.path)
  if not ok then
    notify.error("Could not save Code Review store: " .. tostring(rename_err))
    return false
  end
  handle.dirty = false
  return true
end

function M.flush(handle)
  if handle and handle.dirty then
    return M.save(handle)
  end
  return true
end

function M.clear_current(root)
  local store_path = M.path_for(root)
  if uv.fs_stat(store_path) then
    return uv.fs_unlink(store_path)
  end
  return true
end

return M
