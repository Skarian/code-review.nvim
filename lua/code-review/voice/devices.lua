local notify = require("code-review.notify")
local plugin = require("code-review.plugin")
local process = require("code-review.voice.process")
local state = require("code-review.state")
local temp = require("code-review.voice.temp")

local M = {}

local session_device = nil
local device_cache = nil

local uv = vim.uv or vim.loop

local function now_ms()
  if uv and uv.hrtime then
    return math.floor(uv.hrtime() / 1000000)
  end
  return os.time() * 1000
end

local function state_dir()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "code-review.nvim")
end

local function preference_path()
  return vim.fs.joinpath(state_dir(), "voice-device.json")
end

local function mkdir(path)
  return pcall(vim.fn.mkdir, path, "p")
end

local function decode_json(text)
  local ok, decoded = pcall(vim.json.decode, text)
  if ok and type(decoded) == "table" then
    return decoded
  end
  return nil
end

local function encode_json(value)
  local ok, encoded = pcall(vim.json.encode, value)
  if ok then
    return encoded
  end
  return nil
end

local function read_file(path)
  local uv = vim.uv or vim.loop
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  local text = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  return text
end

function M.load()
  local decoded = decode_json(read_file(preference_path()) or "")
  if not decoded or decoded.schema_version ~= 1 or type(decoded.device) ~= "table" then
    return nil
  end
  return decoded.device
end

function M.save(device)
  if type(device) ~= "table" or type(device.id) ~= "string" then
    return false
  end
  mkdir(state_dir())
  local payload = {
    schema_version = 1,
    device = {
      id = device.id,
      provider = device.provider,
      kind = device.kind,
      name = device.name,
      last_index = device.index,
      selected_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    },
  }
  local encoded = encode_json(payload)
  if not encoded then
    return false
  end
  local ok = vim.fn.writefile({ encoded }, preference_path()) == 0
  if ok then
    session_device = payload.device
  end
  return ok
end

local function current_preference()
  return session_device or M.load()
end

local function cache_key(cfg, helper_path)
  return tostring(cfg and cfg.node_cmd or "") .. "\n" .. tostring(helper_path or "")
end

local function cache_ttl_ms(cfg)
  return tonumber(cfg and cfg.device_cache_ttl_ms) or 60000
end

local function selection_id(selection)
  if type(selection) == "table" and type(selection.id) == "string" and selection.id ~= "" then
    return selection.id
  end
end

local function trusted_opaque_id(id)
  if type(id) ~= "string" then
    return false
  end
  return id == "ffmpeg-avfoundation:audio:default"
    or id:match("^ffmpeg%-avfoundation:audio:%d+$") ~= nil
    or id:match("^ffmpeg%-dshow:audio:.+") ~= nil
end

local function update_cache(cfg, helper_path, result)
  if type(result) ~= "table" or result.ok == false then
    return
  end
  device_cache = {
    key = cache_key(cfg, helper_path),
    updated_at = now_ms(),
    devices = vim.deepcopy(result.devices or {}),
    default_selection = vim.deepcopy(result.defaultSelection),
    recommended_selection = vim.deepcopy(result.recommendedSelection),
  }
end

local function fresh_cache(cfg, helper_path)
  if not device_cache or device_cache.key ~= cache_key(cfg, helper_path) then
    return nil
  end
  if now_ms() - (device_cache.updated_at or 0) > cache_ttl_ms(cfg) then
    return nil
  end
  return device_cache
end

local function cached_recommended_id(cfg, helper_path)
  local cached = fresh_cache(cfg, helper_path)
  local id = cached and selection_id(cached.recommended_selection) or nil
  if id and trusted_opaque_id(id) then
    return id
  end
  return nil
end

local function sort_devices(devices)
  table.sort(devices, function(a, b)
    local order = { likely_physical = 1, unknown = 2, likely_virtual = 3 }
    local a_default = a.id and a.id:find(":default$", 1, false) ~= nil
    local b_default = b.id and b.id:find(":default$", 1, false) ~= nil
    local av = a_default and 4 or (order[a.virtuality or "unknown"] or 2)
    local bv = b_default and 4 or (order[b.virtuality or "unknown"] or 2)
    if av ~= bv then
      return av < bv
    end
    return tostring(a.name or "") < tostring(b.name or "")
  end)
end

local function format_device(device)
  local label = device.name or device.id or "Unknown microphone"
  if device.virtuality == "likely_virtual" then
    label = label .. " (virtual)"
  elseif device.virtuality == "likely_physical" then
    label = label .. " (mic)"
  end
  return label
end

local function find_preference(devices, preference)
  if not preference then
    return nil
  end
  for _, device in ipairs(devices or {}) do
    if device.id == preference.id then
      return device
    end
  end
  for _, device in ipairs(devices or {}) do
    if device.provider == preference.provider and device.name == preference.name then
      return device
    end
  end
  for _, device in ipairs(devices or {}) do
    if preference.last_index ~= nil and device.provider == preference.provider and device.index == preference.last_index then
      return device
    end
  end
  return nil
end

local function clear_pending_voice()
  local s = state.get()
  local voice = s.voice
  if voice then
    if voice.recording and voice.recording.kill then
      pcall(voice.recording.kill)
    end
    if voice.transcribing and voice.transcribing.kill then
      pcall(voice.transcribing.kill)
    end
    if voice.audio_path then
      temp.delete(voice.audio_path)
    end
    s.voice = nil
  end
  if state.is_active() and s.mode == "voice_error_pending" then
    state.set_mode(s.composer and "composer" or "comment_list")
    pcall(require("code-review.composer").refresh)
    pcall(require("code-review.sidebar").render)
  end
end

function M.resolve_for_record(cfg, helper_path)
  local preference = current_preference()
  if not preference then
    return cached_recommended_id(cfg, helper_path)
  end
  if trusted_opaque_id(preference.id) then
    return preference.id
  end
  local listed = process.devices_sync({
    node_cmd = cfg.node_cmd,
    helper_path = helper_path,
  })
  if not listed or listed.ok == false then
    return preference.id
  end
  update_cache(cfg, helper_path, listed)
  local matched = find_preference(listed.devices or {}, preference)
  if matched then
    session_device = {
      id = matched.id,
      provider = matched.provider,
      kind = matched.kind,
      name = matched.name,
      last_index = matched.index,
      selected_at = preference.selected_at,
    }
    return matched.id
  end
  notify.warn("Selected microphone is unavailable; using another available microphone.")
  return nil
end

function M.prewarm(cfg, helper_path, opts)
  opts = opts or {}
  if not cfg or not cfg.enabled then
    return false
  end
  if not helper_path or vim.fn.filereadable(helper_path) == 0 then
    return false
  end
  if not opts.force and fresh_cache(cfg, helper_path) then
    return true
  end
  local _, err = process.devices({
    node_cmd = cfg.node_cmd,
    helper_path = helper_path,
    on_exit = function(_, result)
      if result and result.ok ~= false then
        update_cache(cfg, helper_path, result)
      end
    end,
  })
  return err == nil
end

function M.invalidate()
  device_cache = nil
end

function M.pick()
  local mode = state.mode()
  if mode == "recording_starting" or mode == "recording" or mode == "transcribing" then
    notify.warn("Finish voice recording before switching microphones.")
    return
  end
  local cfg = require("code-review.config").get().voice
  if not cfg.enabled then
    notify.warn("Voice disabled.")
    return
  end
  local helper = cfg.helper_path or plugin.voice_helper()
  if vim.fn.filereadable(helper) == 0 then
    notify.warn("Voice helper missing: run :Lazy build code-review.nvim")
    return
  end
  local _, err = process.devices({
    node_cmd = cfg.node_cmd,
    helper_path = helper,
    on_exit = function(_, result, stderr_text)
      if not result or result.ok == false then
        notify.warn((result and (result.message or result.code)) or stderr_text or "Could not list microphones.")
        return
      end
      update_cache(cfg, helper, result)
      local devices = vim.deepcopy(result.devices or {})
      if #devices == 0 then
        notify.warn("No microphone input devices found.")
        return
      end
      sort_devices(devices)
      vim.ui.select(devices, {
        prompt = "Code Review Microphone",
        format_item = format_device,
      }, function(choice)
        if not choice then
          return
        end
        if M.save(choice) then
          clear_pending_voice()
          pcall(require("code-review.voice").restart_prearm)
          notify.info("Code Review microphone: " .. tostring(choice.name or choice.id))
        else
          notify.warn("Could not save Code Review microphone preference.")
        end
      end)
    end,
  })
  if err then
    notify.warn(err)
  end
end

function M._reset_for_tests()
  session_device = nil
  device_cache = nil
end

function M._path_for_tests()
  return preference_path()
end

function M._find_preference_for_tests(devices, preference)
  return find_preference(devices, preference)
end

function M._cache_for_tests()
  return device_cache
end

function M._trusted_opaque_id_for_tests(id)
  return trusted_opaque_id(id)
end

return M
