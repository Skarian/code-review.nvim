local config = require("code-review.config")
local model = require("code-review.model")
local notify = require("code-review.notify")
local process = require("code-review.voice.process")
local plugin = require("code-review.plugin")
local state = require("code-review.state")
local storage = require("code-review.storage")
local temp = require("code-review.voice.temp")

local M = {}

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

function M.toggle()
  local ok, message = M.available()
  if not ok then
    notify.warn(message)
    return
  end
  local s = state.get()
  if s.mode == "recording" and s.voice and s.voice.recording then
    s.voice.recording.stop()
    state.set_mode("transcribing")
    require("code-review.sidebar").render()
    return
  end
  if s.mode == "voice_error_pending" and s.voice then
    M._transcribe()
    return
  end
  local review = model.find_review(s.store, s.active_review_id)
  local comment = model.find_comment(review, s.current_comment_id)
  if not comment then
    notify.warn("No current Comment.")
    return
  end
  local cfg = config.get().voice
  local audio_path = temp.wav_path()
  local session_id = s.session_id
  local review_id = review.id
  local comment_id = comment.id
  s.voice = {
    audio_path = audio_path,
    session_id = session_id,
    review_id = review_id,
    comment_id = comment_id,
    attempts = 0,
  }
  local recording, err = process.record({
    node_cmd = cfg.node_cmd,
    helper_path = message,
    out = audio_path,
    max_ms = cfg.max_recording_ms,
    min_duration_ms = cfg.min_duration_ms,
    on_event = function(event)
      if event.event == "recording_started" then
        state.set_mode("recording")
        require("code-review.sidebar").render()
      end
    end,
    on_exit = function(_, result, stderr_text)
      M._record_done(result, stderr_text)
    end,
  })
  if not recording then
    temp.delete(audio_path)
    s.voice = nil
    notify.error(err)
    return
  end
  s.voice.recording = recording
  state.set_mode("recording")
  require("code-review.sidebar").render()
end

function M.stop()
  local s = state.get()
  if s.voice and s.voice.recording then
    local recording = s.voice.recording
    local audio_path = s.voice.audio_path
    recording.discard()
    vim.defer_fn(function()
      pcall(recording.kill)
      if audio_path then
        temp.delete(audio_path)
      end
    end, 250)
  elseif s.voice and s.voice.transcribing then
    s.voice.transcribing.kill()
    if s.voice.audio_path then
      temp.delete(s.voice.audio_path)
    end
  end
  s.voice = nil
end

function M.discard()
  local s = state.get()
  if s.voice and s.voice.transcribing then
    s.voice.transcribing.kill()
  end
  if s.voice and s.voice.audio_path then
    temp.delete(s.voice.audio_path)
  end
  s.voice = nil
  if state.is_active() then
    state.set_mode("comment_list")
    require("code-review.sidebar").render()
  end
  notify.warn("Voice transcription discarded.")
end

function M._record_done(result, stderr_text)
  local s = state.get()
  if not s.voice then
    return
  end
  if not result or result.ok ~= true or result.event == "discarded" or result.event == "recording_too_short" then
    temp.delete(s.voice.audio_path)
    s.voice = nil
    if state.is_active() then
      state.set_mode("comment_list")
      require("code-review.sidebar").render()
    end
    if result and result.event == "recording_too_short" then
      notify.warn(result.message or "Recording was too short.")
    elseif result and result.code then
      notify.warn(result.message or result.code)
    elseif stderr_text and stderr_text ~= "" then
      notify.warn(stderr_text)
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
  voice.attempts = (voice.attempts or 0) + 1
  state.set_mode("transcribing")
  voice.transcribing = process.transcribe({
    node_cmd = cfg.node_cmd,
    helper_path = cfg.helper_path or plugin.voice_helper(),
    input = voice.audio_path,
    timeout_ms = cfg.transcription_timeout_ms,
    max_audio_bytes = cfg.max_audio_bytes,
    on_exit = function(_, result, stderr_text)
      M._transcribe_done(result, stderr_text)
    end,
  })
end

function M._transcribe_done(result, stderr_text)
  local s = state.get()
  local voice = s.voice
  local cfg = config.get().voice
  if not voice then
    return
  end
  if s.session_id ~= voice.session_id or s.active_review_id ~= voice.review_id or s.current_comment_id ~= voice.comment_id then
    temp.delete(voice.audio_path)
    s.voice = nil
    notify.warn("Voice result discarded because Review state changed.")
    return
  end
  local review = model.find_review(s.store, voice.review_id)
  local comment = model.find_comment(review, voice.comment_id)
  if not comment then
    temp.delete(voice.audio_path)
    s.voice = nil
    notify.warn("Voice result discarded because Review state changed.")
    return
  end
  if result and result.ok and comment then
    local text = vim.trim(result.text or "")
    if text ~= "" then
      comment.body = vim.trim((comment.body or "") .. "\n" .. text)
      model.touch_comment(review, comment)
      storage.mark_dirty(s.storage)
    end
    temp.delete(voice.audio_path)
    s.voice = nil
    state.set_mode("comment_list")
    require("code-review.sidebar").render()
    return
  end
  local max_attempts = cfg.max_transcription_attempts or 3
  if voice.attempts < max_attempts and result and result.retryable then
    state.set_mode("voice_error_pending")
    notify.warn((result.message or result.code or "Voice transcription failed") .. " Press voice again to retry.")
  else
    temp.delete(voice.audio_path)
    s.voice = nil
    state.set_mode("comment_list")
    notify.warn((result and (result.message or result.code)) or stderr_text or "Voice transcription failed.")
  end
  require("code-review.sidebar").render()
end

return M
