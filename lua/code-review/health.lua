local config = require("code-review.config")
local plugin = require("code-review.plugin")
local state = require("code-review.state")
local storage = require("code-review.storage")

local M = {}

local function helper_path()
  return config.get().voice.helper_path or plugin.voice_helper()
end

local function add(checks, name, status, message)
  local normalized = status
  if type(status) == "boolean" then
    normalized = status and "ok" or "warn"
  end
  checks[#checks + 1] = { name = name, status = normalized, ok = normalized == "ok", message = message }
end

local function storage_writable()
  local root = state.get().root or require("code-review.root").detect(0) or vim.fn.getcwd()
  local path = storage.path_for(root)
  local dir = vim.fs.dirname(path)
  vim.fn.mkdir(dir, "p")
  local probe = vim.fs.joinpath(dir, ".code-review-health-" .. tostring((vim.uv or vim.loop).hrtime()))
  local fd, err = (vim.uv or vim.loop).fs_open(probe, "w", 384)
  if not fd then
    return false, tostring(err)
  end
  (vim.uv or vim.loop).fs_close(fd)
  pcall((vim.uv or vim.loop).fs_unlink, probe)
  return true, path
end

local function helper_health(checks)
  local cfg = config.get()
  local helper = helper_path()
  if vim.fn.executable(cfg.voice.node_cmd) ~= 1 or vim.fn.filereadable(helper) ~= 1 then
    return
  end
  local args = { cfg.voice.node_cmd, helper, "health" }
  if not cfg.health.network then
    args[#args + 1] = "--no-network"
  end
  local result = vim.system(args, { text = true }):wait(5000)
  if result.code ~= 0 then
    add(checks, "voice_helper_health", "warn", "Voice helper health failed")
    return
  end
  local ok, decoded = pcall(vim.json.decode, result.stdout or "")
  if not ok or type(decoded) ~= "table" then
    add(checks, "voice_helper_health", "warn", "Voice helper health returned invalid JSON")
    return
  end
  for _, check in ipairs(decoded.checks or {}) do
    if type(check) == "table" and check.code ~= "not_checked" and check.code ~= "disabled" then
      add(checks, "voice_" .. tostring(check.name), tostring(check.status or "warn"), tostring(check.message or check.code or check.name))
    end
  end
end

function M.checks()
  local checks = {}
  local nvim_ok = vim.fn.has("nvim-0.11") == 1
  add(checks, "neovim", nvim_ok and "ok" or "warn", nvim_ok and "Neovim >= 0.11" or "Neovim 0.11 or newer required")
  add(checks, "snacks", pcall(require, "snacks") and "ok" or "warn", "folke/snacks.nvim")
  local writable, storage_message = storage_writable()
  add(checks, "storage", writable and "ok" or "warn", storage_message)
  add(checks, "node", vim.fn.executable(config.get().voice.node_cmd) == 1 and "ok" or "warn", config.get().voice.node_cmd)
  add(checks, "npm", vim.fn.executable("npm") == 1 and "ok" or "warn", "npm")
  local helper_exists = vim.fn.filereadable(helper_path()) == 1
  add(checks, "voice_helper", helper_exists and "ok" or "warn", helper_exists and helper_path() or "Voice helper missing: run :Lazy build code-review.nvim")
  helper_health(checks)
  return checks
end

function M.run()
  local health = vim.health or require("health")
  if health.start then
    health.start("code-review.nvim")
  end
  for _, check in ipairs(M.checks()) do
    if check.status == "ok" then
      health.ok(check.message)
    elseif check.status == "error" and health.error then
      health.error(check.message)
    else
      health.warn(check.message)
    end
  end
end

M.check = M.run

function M.show()
  local lines = { "code-review.nvim health", "" }
  for _, check in ipairs(M.checks()) do
    lines[#lines + 1] = string.format("%s %s - %s", string.upper(check.status or "warn"), check.name, check.message)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_name(buf, "Code Review Health")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
end

return M
