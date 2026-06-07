describe("voice support", function()
  local function start_composer(opts)
    opts = opts or {}
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "x", "y" }, project .. "/x.lua")
    local helper = project .. "/helper.js"
    vim.fn.writefile({ "" }, helper)
    config.setup({
      storage = { dir = project .. "/store" },
      voice = vim.tbl_extend("force", { helper_path = helper }, opts.voice or {}),
    })
    vim.cmd.edit(project .. "/x.lua")
    code_review.start()
    actions.create_review("Voice")
    vim.fn.setpos("'<", { 0, 1, 1, 0 })
    vim.fn.setpos("'>", { 0, 1, 1, 0 })
    actions.add_reference()
    return code_review, state, require("code-review.voice.process")
  end

  it("passes configured voice limits to record and transcribe helpers", function()
    local code_review, state, process = start_composer({ voice = { min_duration_ms = 42, max_audio_bytes = 99 } })
    local old_record = process.record
    local old_transcribe = process.transcribe
    local seen_min
    local seen_max
    process.record = function(opts)
      seen_min = opts.min_duration_ms
      vim.fn.writefile({ "wav" }, opts.out)
      vim.schedule(function()
        opts.on_exit(0, { ok = true, event = "recording_stopped", durationMillis = 1000, audioBytes = 3 }, "")
      end)
      return { stop = function() end, discard = function() end, kill = function() end }
    end
    process.transcribe = function(opts)
      seen_max = opts.max_audio_bytes
      vim.schedule(function()
        opts.on_exit(0, { ok = true, text = "spoken" }, "")
      end)
      return { kill = function() end }
    end
    require("code-review.voice").toggle()
    vim.wait(1000, function()
      return state.get().voice == nil and state.mode() == "composer"
    end)
    assert.equals(42, seen_min)
    assert.equals(99, seen_max)
    process.record = old_record
    process.transcribe = old_transcribe
    require("code-review.composer").cancel()
    code_review.quit()
  end)

  it("discards async transcription when the composer is gone", function()
    local code_review, state = start_composer()
    state.get().voice = {
      audio_path = vim.fn.tempname() .. ".wav",
      session_id = state.get().session_id,
      review_id = state.get().active_review_id,
      composer_buf = state.get().composer.buf,
      attempts = 1,
    }
    vim.fn.writefile({ "wav" }, state.get().voice.audio_path)
    require("code-review.composer").cancel()
    require("code-review.voice")._transcribe_done({ ok = true, text = "late" }, "")
    assert.equals(nil, state.get().voice)
    code_review.quit()
  end)

  it("uses stdpath cache for voice temp files", function()
    local temp = require("code-review.voice.temp")
    local path = temp.wav_path()
    assert.truthy(path:find("code%-review%.nvim/voice") or path:find("code%-review%.nvim\\voice"))
  end)
  it("uses starting state, cancels startup, and blocks re-entry while transcribing", function()
    local voice = require("code-review.voice")
    local code_review, state, process = start_composer({ voice = { max_recording_ms = 200 } })
    local old_record = process.record
    local record_opts
    local first_record_opts
    local record_count = 0
    process.record = function(opts)
      record_count = record_count + 1
      record_opts = opts
      first_record_opts = first_record_opts or opts
      return { stop = function() return true end, discard = function() return true end, kill = function() end }
    end

    voice.toggle()
    assert.equals("recording_starting", state.mode())
    voice.toggle()
    assert.equals("composer", state.mode())
    assert.equals(nil, state.get().voice)
    first_record_opts.on_event({ ok = true, event = "recording_started" })
    assert.equals("composer", state.mode())
    voice.toggle()
    assert.equals("recording_starting", state.mode())
    record_opts.on_event({ ok = true, event = "recording_started" })
    assert.equals("recording", state.mode())
    voice.toggle()
    assert.equals("transcribing", state.mode())
    voice.toggle()
    assert.equals(2, record_count)
    assert.equals("transcribing", state.mode())

    process.record = old_record
    require("code-review.composer").cancel()
    code_review.quit()
  end)

  it("recovers when recording stop cannot be written", function()
    local voice = require("code-review.voice")
    local code_review, state, process = start_composer()
    local old_record = process.record
    local killed = false
    local record_opts
    process.record = function(opts)
      record_opts = opts
      return {
        stop = function() return false end,
        discard = function() return false end,
        kill = function() killed = true end,
      }
    end

    voice.toggle()
    record_opts.on_event({ ok = true, event = "recording_started" })
    assert.equals("recording", state.mode())
    voice.toggle()
    assert.equals("composer", state.mode())
    assert.equals(nil, state.get().voice)
    assert.is_true(killed)

    process.record = old_record
    require("code-review.composer").cancel()
    code_review.quit()
  end)

  it("kills active transcription when the composer stops voice", function()
    local voice = require("code-review.voice")
    local code_review, state, process = start_composer({ voice = { max_recording_ms = 1000, transcription_timeout_ms = 1000 } })
    local old_record = process.record
    local old_transcribe = process.transcribe
    local killed_record = false
    local killed_transcribe = false
    process.record = function(opts)
      opts.on_event({ ok = true, event = "recording_started" })
      return {
        stop = function()
          opts.on_exit(0, { ok = true, event = "recording_stopped", durationMillis = 1000, audioBytes = 3 }, "")
          return true
        end,
        discard = function() return true end,
        kill = function() killed_record = true end,
      }
    end
    process.transcribe = function()
      return { kill = function() killed_transcribe = true end }
    end

    voice.toggle()
    voice.toggle()
    assert.equals("transcribing", state.mode())
    require("code-review.composer").cancel()
    assert.is_true(killed_record)
    assert.is_true(killed_transcribe)
    assert.equals(nil, state.get().voice)

    process.record = old_record
    process.transcribe = old_transcribe
    code_review.quit()
  end)

  it("uses watchdogs for record and transcribe callbacks that never arrive", function()
    local voice = require("code-review.voice")
    voice._set_watchdog_grace_for_tests(5, 5)

    local code_review, state, process = start_composer({ voice = { max_recording_ms = 5 } })
    local old_record = process.record
    local killed_record = false
    process.record = function()
      return { stop = function() return true end, discard = function() return true end, kill = function() killed_record = true end }
    end
    voice.toggle()
    vim.wait(1000, function()
      return state.mode() == "composer" and state.get().voice == nil
    end)
    assert.equals("composer", state.mode())
    assert.equals(nil, state.get().voice)
    assert.is_true(killed_record)
    require("code-review.composer").cancel()
    code_review.quit()
    process.record = old_record

    code_review, state, process = start_composer({ voice = { max_recording_ms = 1000 } })
    old_record = process.record
    local killed_stopping_record = false
    process.record = function(opts)
      opts.on_event({ ok = true, event = "recording_started" })
      return { stop = function() return true end, discard = function() return true end, kill = function() killed_stopping_record = true end }
    end
    voice.toggle()
    voice.toggle()
    vim.wait(1000, function()
      return state.mode() == "composer" and state.get().voice == nil
    end)
    assert.equals("composer", state.mode())
    assert.equals(nil, state.get().voice)
    assert.is_true(killed_stopping_record)
    require("code-review.composer").cancel()
    code_review.quit()
    process.record = old_record

    code_review, state, process = start_composer({ voice = { max_recording_ms = 1000, transcription_timeout_ms = 5 } })
    old_record = process.record
    local old_transcribe = process.transcribe
    local killed_transcribe = false
    process.record = function(opts)
      opts.on_event({ ok = true, event = "recording_started" })
      return {
        stop = function()
          opts.on_exit(0, { ok = true, event = "recording_stopped", durationMillis = 1000, audioBytes = 3 }, "")
          return true
        end,
        discard = function() return true end,
        kill = function() end,
      }
    end
    process.transcribe = function()
      return { kill = function() killed_transcribe = true end }
    end
    voice.toggle()
    voice.toggle()
    vim.wait(1000, function()
      return state.mode() == "voice_error_pending"
    end)
    assert.equals("voice_error_pending", state.mode())
    assert.truthy(state.get().voice)
    assert.is_true(killed_transcribe)

    process.record = old_record
    process.transcribe = old_transcribe
    voice._set_watchdog_grace_for_tests(2000)
    require("code-review.voice").discard()
    require("code-review.composer").cancel()
    code_review.quit()
  end)

  it("cleans up when transcript insertion fails", function()
    local voice = require("code-review.voice")
    local composer_module = require("code-review.composer")
    local code_review, state = start_composer()
    local original_insert = composer_module.insert_text
    local audio_path = vim.fn.tempname() .. ".wav"
    vim.fn.writefile({ "wav" }, audio_path)
    state.get().voice = {
      id = 1001,
      phase = "transcribing",
      audio_path = audio_path,
      session_id = state.get().session_id,
      review_id = state.get().active_review_id,
      composer_buf = state.get().composer.buf,
      attempts = 1,
      transcribe_id = 1,
    }
    state.set_mode("transcribing")
    composer_module.insert_text = function()
      error("insert failed")
    end

    voice._transcribe_done(1001, 1, { ok = true, text = "spoken" }, "")
    composer_module.insert_text = original_insert

    assert.equals("composer", state.mode())
    assert.equals(nil, state.get().voice)
    assert.equals(0, vim.fn.filereadable(audio_path))

    require("code-review.composer").cancel()
    code_review.quit()
  end)

  it("ignores stale transcription callbacks from previous attempts", function()
    local voice = require("code-review.voice")
    local code_review, state, process = start_composer({ voice = { transcription_timeout_ms = 1000 } })
    local old_record = process.record
    local old_transcribe = process.transcribe
    local transcribe_opts = {}
    process.record = function(opts)
      opts.on_event({ ok = true, event = "recording_started" })
      return {
        stop = function()
          opts.on_exit(0, { ok = true, event = "recording_stopped", durationMillis = 1000, audioBytes = 3 }, "")
          return true
        end,
        discard = function() return true end,
        kill = function() end,
      }
    end
    process.transcribe = function(opts)
      transcribe_opts[#transcribe_opts + 1] = opts
      return { kill = function() end }
    end

    voice.toggle()
    voice.toggle()
    transcribe_opts[1].on_exit(1, { ok = false, code = "network_error", message = "temporary", retryable = true }, "")
    assert.equals("voice_error_pending", state.mode())
    voice.toggle()
    assert.equals(2, #transcribe_opts)
    transcribe_opts[1].on_exit(0, { ok = true, text = "old" }, "")
    assert.equals("transcribing", state.mode())
    assert.truthy(state.get().voice)
    transcribe_opts[2].on_exit(0, { ok = true, text = "new" }, "")
    assert.equals("composer", state.mode())
    assert.equals(nil, state.get().voice)
    assert.truthy(table.concat(vim.api.nvim_buf_get_lines(state.get().composer.body_buf, 0, -1, false), "\n"):find("new", 1, true))

    process.record = old_record
    process.transcribe = old_transcribe
    require("code-review.composer").cancel()
    code_review.quit()
  end)

end)
