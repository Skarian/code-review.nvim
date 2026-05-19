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
end)
