local config = require("code-review.config")
local notify = require("code-review.notify")
local process = require("code-review.voice.process")
local plugin = require("code-review.plugin")
local state = require("code-review.state")
local temp = require("code-review.voice.temp")

local M = {}

local uv = vim.uv or vim.loop
local next_voice_id = 0
local watchdog_grace_ms = 2000
local record_stop_timeout_ms = 5000

local function refresh_composer()
  pcall(require("code-review.composer").refresh)
end

local function render_sidebar()
  pcall(require("code-review.sidebar").render)
end

local function close_timer(timer)
  if timer then
    pcall(timer.stop, timer)
    pcall(timer.close, timer)
  end
end

local function clear_watchdog(voice)
  if voice then
    close_timer(voice.watchdog)
    voice.watchdog = nil
  end
end

local function next_id()
  next_voice_id = next_voice_id + 1
  return next_voice_id
end

local function active_composer_mode()
  return state.get().composer and "composer" or "comment_list"
end

local function current_voice(id)
  local s = state.get()
  local voice = s.voice
  if not state.is_active() or not voice then
    return nil, nil
  end
  if id and voice.id ~= id then
    return nil, nil
  end
  if s.session_id ~= voice.session_id or s.active_review_id ~= voice.review_id then
    return nil, nil
  end
  if not s.composer or s.composer.buf ~= voice.composer_buf then
    return nil, nil
  end
  return s, voice
end

local function current_transcribe(id, transcribe_id)
  local s, voice = current_voice(id)
  if not voice or voice.transcribe_id ~= transcribe_id then
    return nil, nil
  end
  return s, voice
end

local function set_active_mode(mode)
  if state.is_active() then
    state.set_mode(mode)
    refresh_composer()
    render_sidebar()
  end
end

local function kill_handle(handle)
  if handle and handle.kill then
    pcall(handle.kill)
  end
end

local function delete_audio(path)
  if path then
    temp.delete(path)
  end
end

local function clear_voice(voice, opts)
  opts = opts or {}
  local s = state.get()
  if s.voice == voice then
    clear_watchdog(voice)
    if opts.kill_recording then
      kill_handle(voice.recording)
    end
    if opts.kill_transcribing then
      kill_handle(voice.transcribing)
    end
    if opts.delete_audio ~= false then
      delete_audio(voice.audio_path)
    end
    s.voice = nil
  else
    if opts.delete_audio ~= false then
      delete_audio(voice and voice.audio_path)
    end
  end
  if opts.mode and state.is_active() then
    state.set_mode(opts.mode)
  end
  refresh_composer()
  render_sidebar()
end

local function start_watchdog(voice, timeout_ms, callback)
  clear_watchdog(voice)
  local timer = uv.new_timer()
  voice.watchdog = timer
  local id = voice.id
  timer:start((timeout_ms or 0) + watchdog_grace_ms, 0, function()
    vim.schedule(function()
      local s, current = current_voice(id)
      if not current or current.watchdog ~= timer then
        close_timer(timer)
        return
      end
      current.watchdog = nil
      close_timer(timer)
      callback(s, current)
    end)
  end)
end

function M.available()
  local cfg = config.get().voice
  if not cfg.enabled then
    return false, "Voice disabled."
  end
  local helper = cfg.helper_path or plugin.voice_helper()
  if vim.fn.filereadable(helper) == 0 then
    return false, "Voice helper missing: run :Lazy build code-review.nvim"
  end
  return true, helper
end

local function start_recording()
  local ok, message = M.available()
  if not ok then
    notify.warn(message)
    return
  end
  local s = state.get()
  local composer = s.composer
  if not composer then
    notify.warn("Open the Comment Editor before using voice.")
    return
  end
  local review = require("code-review.model").find_review(s.store, s.active_review_id)
  if not review then
    notify.warn("Create or select a Review first.")
    return
  end
  local cfg = config.get().voice
  local voice = {
    id = next_id(),
    phase = "recording",
    audio_path = temp.wav_path(),
    session_id = s.session_id,
    review_id = review.id,
    composer_buf = composer.buf,
    attempts = 0,
  }
  s.voice = voice
  local id = voice.id
  local recording, err = process.record({
    node_cmd = cfg.node_cmd,
    helper_path = message,
    out = voice.audio_path,
    max_ms = cfg.max_recording_ms,
    min_duration_ms = cfg.min_duration_ms,
    on_event = function(event)
      local _, current = current_voice(id)
      if not current or current.phase ~= "recording" then
        return
      end
      if event.event == "recording_started" then
        state.set_mode("recording")
        refresh_composer()
        render_sidebar()
      end
    end,
    on_exit = function(_, result, stderr_text)
      M._record_done(id, result, stderr_text)
    end,
  })
  if not recording then
    clear_voice(voice, { mode = active_composer_mode() })
    notify.error(err)
    return
  end
  voice.recording = recording
  state.set_mode("recording")
  refresh_composer()
  render_sidebar()
  start_watchdog(voice, cfg.max_recording_ms, function(_, current)
    kill_handle(current.recording)
    clear_voice(current, { mode = active_composer_mode(), delete_audio = true })
    notify.warn("Voice recording timed out.")
  end)
end

function M.toggle()
  local s = state.get()
  if s.mode == "recording" and s.voice and s.voice.recording then
    local voice = s.voice
    voice.phase = "stopping"
    clear_watchdog(voice)
    local ok, wrote = false, false
    if voice.recording.stop then
      ok, wrote = pcall(voice.recording.stop)
    end
    if not ok or wrote == false then
      kill_handle(voice.recording)
      clear_voice(voice, { mode = active_composer_mode(), delete_audio = true })
      notify.warn("Voice recording could not be stopped.")
      return
    end
    if state.get().voice ~= voice or voice.phase ~= "stopping" then
      return
    end
    state.set_mode("transcribing")
    refresh_composer()
    render_sidebar()
    local cfg = config.get().voice
    start_watchdog(voice, record_stop_timeout_ms, function(_, current)
      kill_handle(current.recording)
      clear_voice(current, { mode = active_composer_mode(), delete_audio = true })
      notify.warn("Voice recording did not finish stopping.")
    end)
    return
  end
  if s.mode == "transcribing" and s.voice then
    notify.warn("Voice transcription is already running.")
    return
  end
  if s.mode == "voice_error_pending" and s.voice then
    local ok, message = M.available()
    if not ok then
      notify.warn(message)
      return
    end
    M._transcribe()
    return
  end
  start_recording()
end

function M.stop()
  local s = state.get()
  local voice = s.voice
  if not voice then
    return
  end
  if voice.recording and voice.recording.discard then
    pcall(voice.recording.discard)
    kill_handle(voice.recording)
  end
  if voice.transcribing then
    kill_handle(voice.transcribing)
  end
  clear_voice(voice, { delete_audio = true })
end

function M.discard()
  local s = state.get()
  local voice = s.voice
  if voice and voice.recording then
    kill_handle(voice.recording)
  end
  if voice and voice.transcribing then
    kill_handle(voice.transcribing)
  end
  if voice then
    clear_voice(voice, { mode = active_composer_mode(), delete_audio = true })
  elseif state.is_active() then
    set_active_mode(active_composer_mode())
  end
  notify.warn("Voice transcription discarded.")
end

function M._record_done(id_or_result, result_or_stderr, maybe_stderr)
  local id, result, stderr_text
  if type(id_or_result) == "number" then
    id = id_or_result
    result = result_or_stderr
    stderr_text = maybe_stderr
  else
    result = id_or_result
    stderr_text = result_or_stderr
  end
  local _, voice = current_voice(id)
  if not voice then
    return
  end
  clear_watchdog(voice)
  if not result or result.ok ~= true or result.event == "discarded" or result.event == "recording_too_short" then
    local message
    if result and result.event == "recording_too_short" then
      message = result.message or "Recording was too short."
    elseif result and result.code then
      message = result.message or result.code
    elseif stderr_text and stderr_text ~= "" then
      message = stderr_text
    end
    clear_voice(voice, { mode = active_composer_mode(), delete_audio = true })
    if message then
      notify.warn(message)
    end
    return
  end
  M._transcribe()
end

function M._transcribe()
  local s = state.get()
  local voice = s.voice
  local cfg = config.get().voice
  if not voice then
    return
  end
  voice.phase = "transcribing"
  voice.attempts = (voice.attempts or 0) + 1
  voice.transcribe_id = (voice.transcribe_id or 0) + 1
  local id = voice.id
  local transcribe_id = voice.transcribe_id
  state.set_mode("transcribing")
  refresh_composer()
  render_sidebar()
  local transcribing, err = process.transcribe({
    node_cmd = cfg.node_cmd,
    helper_path = cfg.helper_path or plugin.voice_helper(),
    input = voice.audio_path,
    timeout_ms = cfg.transcription_timeout_ms,
    max_audio_bytes = cfg.max_audio_bytes,
    on_exit = function(_, result, stderr_text)
      M._transcribe_done(id, transcribe_id, result, stderr_text)
    end,
  })
  if not transcribing then
    clear_voice(voice, { mode = active_composer_mode(), delete_audio = true })
    notify.warn(err or "Voice transcription failed.")
    return
  end
  voice.transcribing = transcribing
  start_watchdog(voice, cfg.transcription_timeout_ms, function(_, current)
    local max_attempts = cfg.max_transcription_attempts or 3
    kill_handle(current.transcribing)
    current.transcribing = nil
    current.transcribe_id = (current.transcribe_id or 0) + 1
    if (current.attempts or 0) < max_attempts then
      current.phase = "error_pending"
      state.set_mode("voice_error_pending")
      refresh_composer()
      render_sidebar()
      notify.warn("Voice transcription timed out. Press voice again to retry.")
    else
      clear_voice(current, { mode = active_composer_mode(), delete_audio = true })
      notify.warn("Voice transcription timed out.")
    end
  end)
end

function M._transcribe_done(id_or_result, transcribe_or_stderr, result_or_nil, stderr_or_nil)
  local id, transcribe_id, result, stderr_text
  if type(id_or_result) == "number" then
    id = id_or_result
    transcribe_id = transcribe_or_stderr
    result = result_or_nil
    stderr_text = stderr_or_nil
  else
    result = id_or_result
    stderr_text = transcribe_or_stderr
  end
  local _, voice = current_transcribe(id, transcribe_id)
  if not voice then
    return
  end
  clear_watchdog(voice)
  local cfg = config.get().voice
  if result and result.ok then
    local ok, inserted = pcall(require("code-review.composer").insert_text, result.text or "")
    clear_voice(voice, { mode = "composer", delete_audio = true })
    if not ok or inserted == false then
      notify.warn("Voice transcription could not be inserted.")
    end
    return
  end
  local max_attempts = cfg.max_transcription_attempts or 3
  if voice.attempts < max_attempts and result and result.retryable then
    voice.phase = "error_pending"
    state.set_mode("voice_error_pending")
    refresh_composer()
    notify.warn((result.message or result.code or "Voice transcription failed") .. " Press voice again to retry.")
  else
    clear_voice(voice, { mode = active_composer_mode(), delete_audio = true })
    notify.warn((result and (result.message or result.code)) or stderr_text or "Voice transcription failed.")
  end
  render_sidebar()
end

function M._set_watchdog_grace_for_tests(ms, stop_ms)
  watchdog_grace_ms = ms
  record_stop_timeout_ms = stop_ms or 5000
end

return M
