local M = {}

M.defaults = {
  sidebar = {
    width = 42,
    position = "right",
  },
  keymaps = {
    enabled = true,
    prefix = "<leader>r",
    review_picker = "R",
    add_reference = "a",
    append_reference = "r",
    edit_comment = "c",
    edit_comment_under_cursor = "o",
    microphone = "m",
    preview = "p",
    toggle = "t",
  },
  storage = {
    dir = nil,
    debounce_ms = 250,
  },
  stale = {
    debounce_ms = 200,
  },
  voice = {
    enabled = true,
    node_cmd = "node",
    helper_path = nil,
    max_recording_ms = 60000,
    max_audio_bytes = 16 * 1024 * 1024,
    device_cache_ttl_ms = 60000,
    pre_roll_ms = 250,
    min_duration_ms = 900,
    max_transcription_attempts = 3,
    transcription_timeout_ms = 120000,
  },
  health = {
    network = true,
  },
}

local current = vim.deepcopy(M.defaults)

local function merge(dst, src)
  if type(src) ~= "table" then
    return dst
  end
  for key, value in pairs(src) do
    if type(value) == "table" and type(dst[key]) == "table" then
      merge(dst[key], value)
    else
      dst[key] = value
    end
  end
  return dst
end

function M.setup(opts)
  current = merge(vim.deepcopy(M.defaults), opts or {})
  return current
end

function M.get()
  return current
end

function M.reset()
  current = vim.deepcopy(M.defaults)
end

return M
