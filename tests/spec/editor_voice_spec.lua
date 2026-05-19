describe("editor and voice", function()
  it("saves and closes the comment body editor", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local model = require("code-review.model")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "x" }, project .. "/x.lua")
    config.setup({ storage = { dir = project .. "/store" } })
    vim.cmd.edit(project .. "/x.lua")
    code_review.start()
    actions.create_review("Edit")
    actions.new_comment()
    require("code-review.editor").open()
    local editor = state.get().editor.buf
    vim.api.nvim_buf_set_lines(editor, 0, -1, false, { "body text" })
    require("code-review.editor").save()
    assert.equals("body_editor_clean", state.mode())
    require("code-review.editor").close(true)
    assert.equals("comment_list", state.mode())
    local review = model.find_review(state.get().store, state.get().active_review_id)
    local comment = model.find_comment(review, state.get().current_comment_id)
    assert.equals("body text", comment.body)
    code_review.quit()
  end)

  it("dirty comment body editor q! discards without prompting", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "x" }, project .. "/x.lua")
    config.setup({ storage = { dir = project .. "/store" } })
    vim.cmd.edit(project .. "/x.lua")
    code_review.start()
    actions.create_review("Edit")
    actions.new_comment()
    require("code-review.editor").open()
    local editor = state.get().editor.buf
    vim.api.nvim_buf_set_lines(editor, 0, -1, false, { "dirty" })
    vim.bo[editor].modified = true
    local prompted = false
    local old_confirm = vim.fn.confirm
    vim.fn.confirm = function()
      prompted = true
      return 1
    end
    state.get().editor.force_quit = true
    vim.cmd("q!")
    vim.fn.confirm = old_confirm
    assert.is_false(prompted)
    assert.equals("comment_list", state.mode())
    code_review.quit()
  end)

  it("dirty comment body editor q prompts discard or cancel", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "x" }, project .. "/x.lua")
    config.setup({ storage = { dir = project .. "/store" } })
    vim.cmd.edit(project .. "/x.lua")
    code_review.start()
    actions.create_review("Edit")
    actions.new_comment()
    require("code-review.editor").open()
    local editor = state.get().editor.buf
    vim.api.nvim_buf_set_lines(editor, 0, -1, false, { "dirty" })
    vim.bo[editor].modified = true
    local old_confirm = vim.fn.confirm
    vim.fn.confirm = function()
      return 2
    end
    local ok = pcall(vim.cmd, "q")
    assert.is_false(ok)
    assert.truthy(state.get().editor)
    vim.fn.confirm = function()
      return 1
    end
    vim.cmd("q")
    vim.fn.confirm = old_confirm
    assert.equals("comment_list", state.mode())
    code_review.quit()
  end)

  it("appends voice transcription and deletes temp audio with mocked process", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local model = require("code-review.model")
    local process = require("code-review.voice.process")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "x" }, project .. "/x.lua")
    local helper = project .. "/helper.js"
    vim.fn.writefile({ "" }, helper)
    config.setup({ storage = { dir = project .. "/store" }, voice = { helper_path = helper } })
    vim.cmd.edit(project .. "/x.lua")
    code_review.start()
    actions.create_review("Voice")
    actions.new_comment()
    local old_record = process.record
    local old_transcribe = process.transcribe
    process.record = function(opts)
      vim.fn.writefile({ "wav" }, opts.out)
      vim.schedule(function()
        opts.on_exit(0, { ok = true, event = "recording_stopped", path = opts.out, durationMillis = 1000, audioBytes = 3 }, "")
      end)
      return { stop = function() end, discard = function() end, kill = function() end }
    end
    process.transcribe = function(opts)
      vim.schedule(function()
        opts.on_exit(0, { ok = true, text = "spoken note" }, "")
      end)
      return { kill = function() end }
    end
    actions.toggle_voice()
    vim.wait(1000, function()
      return state.mode() == "comment_list" and state.get().voice == nil
    end)
    local review = model.find_review(state.get().store, state.get().active_review_id)
    local comment = model.find_comment(review, state.get().current_comment_id)
    assert.equals("spoken note", comment.body)
    process.record = old_record
    process.transcribe = old_transcribe
    code_review.quit()
  end)

  it("passes transcription timeout and lets close-comment discard a retryable voice error", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local process = require("code-review.voice.process")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "x" }, project .. "/x.lua")
    local helper = project .. "/helper.js"
    vim.fn.writefile({ "" }, helper)
    config.setup({
      storage = { dir = project .. "/store" },
      voice = { helper_path = helper, transcription_timeout_ms = 1234 },
    })
    vim.cmd.edit(project .. "/x.lua")
    code_review.start()
    actions.create_review("Voice retry")
    actions.new_comment()
    local old_record = process.record
    local old_transcribe = process.transcribe
    local seen_timeout
    process.record = function(opts)
      vim.fn.writefile({ "wav" }, opts.out)
      vim.schedule(function()
        opts.on_exit(0, { ok = true, event = "recording_stopped", path = opts.out, durationMillis = 1000, audioBytes = 3 }, "")
      end)
      return { stop = function() end, discard = function() end, kill = function() end }
    end
    process.transcribe = function(opts)
      seen_timeout = opts.timeout_ms
      vim.schedule(function()
        opts.on_exit(1, { ok = false, code = "network_error", message = "temporary", retryable = true }, "")
      end)
      return { kill = function() end }
    end
    actions.toggle_voice()
    vim.wait(1000, function()
      return state.mode() == "voice_error_pending"
    end)
    assert.equals(1234, seen_timeout)
    assert.truthy(state.get().voice and state.get().voice.audio_path)
    actions.close_comment()
    assert.equals("comment_list", state.mode())
    assert.equals(nil, state.get().voice)
    process.record = old_record
    process.transcribe = old_transcribe
    code_review.quit()
  end)

  it("passes configured voice limits to record and transcribe helpers", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local process = require("code-review.voice.process")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "x" }, project .. "/x.lua")
    local helper = project .. "/helper.js"
    vim.fn.writefile({ "" }, helper)
    config.setup({
      storage = { dir = project .. "/store" },
      voice = { helper_path = helper, min_duration_ms = 42, max_audio_bytes = 99 },
    })
    vim.cmd.edit(project .. "/x.lua")
    code_review.start()
    actions.create_review("Voice config")
    actions.new_comment()
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
    actions.toggle_voice()
    vim.wait(1000, function()
      return state.get().voice == nil
    end)
    assert.equals(42, seen_min)
    assert.equals(99, seen_max)
    process.record = old_record
    process.transcribe = old_transcribe
    code_review.quit()
  end)

  it("discards async transcription when current comment changes", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local model = require("code-review.model")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "x" }, project .. "/x.lua")
    local helper = project .. "/helper.js"
    vim.fn.writefile({ "" }, helper)
    config.setup({ storage = { dir = project .. "/store" }, voice = { helper_path = helper } })
    vim.cmd.edit(project .. "/x.lua")
    code_review.start()
    actions.create_review("Voice mismatch")
    actions.new_comment()
    local review = model.find_review(state.get().store, state.get().active_review_id)
    local first = state.get().current_comment_id
    state.get().voice = {
      audio_path = project .. "/voice.wav",
      session_id = state.get().session_id,
      review_id = review.id,
      comment_id = first,
      attempts = 1,
    }
    vim.fn.writefile({ "wav" }, state.get().voice.audio_path)
    local second = model.new_comment()
    table.insert(review.comments, second)
    state.get().current_comment_id = second.id
    require("code-review.voice")._transcribe_done({ ok = true, text = "late" }, "")
    assert.equals("", review.comments[1].body)
    assert.equals(nil, state.get().voice)
    code_review.quit()
  end)

  it("uses stdpath cache for voice temp files", function()
    local temp = require("code-review.voice.temp")
    local path = temp.wav_path()
    assert.truthy(path:find("code%-review%.nvim/voice") or path:find("code%-review%.nvim\\voice"))
  end)
end)
