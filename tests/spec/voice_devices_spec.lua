describe("voice device selection", function()
  local function reset_devices()
    local devices = require("code-review.voice.devices")
    devices._reset_for_tests()
    pcall(vim.fn.delete, devices._path_for_tests())
    return devices
  end

  local function device(id, name, index, virtuality)
    return {
      id = id,
      provider = "ffmpeg-avfoundation",
      kind = "audioinput",
      index = index,
      name = name,
      virtuality = virtuality or "likely_physical",
      confidence = "medium",
      reasons = {},
    }
  end

  local function start_composer(opts)
    opts = opts or {}
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local state = require("code-review.state")
    local process = require("code-review.voice.process")
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
    actions.create_review("Voice Devices")
    vim.fn.setpos("'<", { 0, 1, 1, 0 })
    vim.fn.setpos("'>", { 0, 1, 1, 0 })
    if opts.before_reference then
      opts.before_reference(process, helper)
    end
    actions.add_reference()
    return code_review, state, process, helper
  end

  it("persists microphone preference outside Review storage", function()
    local devices = reset_devices()
    assert.is_true(devices.save(device("ffmpeg-avfoundation:audio:1", "DJI Mic", 1)))
    local loaded = devices.load()
    assert.equals("ffmpeg-avfoundation:audio:1", loaded.id)
    assert.equals("DJI Mic", loaded.name)
    assert.truthy(devices._path_for_tests():find("code%-review%.nvim/voice%-device%.json"))
    pcall(vim.fn.delete, devices._path_for_tests())
  end)

  it("shows all microphone devices and saves the selected one", function()
    local devices = reset_devices()
    local config = require("code-review.config")
    local process = require("code-review.voice.process")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project, "p")
    local helper = project .. "/helper.js"
    vim.fn.writefile({ "" }, helper)
    config.setup({ voice = { helper_path = helper } })
    local old_devices = process.devices
    local old_select = vim.ui.select
    local selected_prompt
    local selected_count
    process.devices = function(opts)
      opts.on_exit(0, {
        ok = true,
        devices = {
          device("ffmpeg-avfoundation:audio:default", "System Default", nil, "unknown"),
          device("ffmpeg-avfoundation:audio:0", "ZoomAudioDevice", 0, "likely_virtual"),
          device("ffmpeg-avfoundation:audio:1", "DJI Mic", 1, "likely_physical"),
        },
      }, "")
      return { kill = function() end }
    end
    vim.ui.select = function(items, opts, cb)
      selected_prompt = opts.prompt
      selected_count = #items
      assert.equals("ffmpeg-avfoundation:audio:1", items[1].id)
      assert.equals("ffmpeg-avfoundation:audio:0", items[2].id)
      assert.equals("ffmpeg-avfoundation:audio:default", items[3].id)
      cb(items[1])
    end

    require("code-review.voice").pick_microphone()
    local loaded = devices.load()
    assert.equals("Code Review Microphone", selected_prompt)
    assert.equals(3, selected_count)
    assert.equals("ffmpeg-avfoundation:audio:1", loaded.id)

    process.devices = old_devices
    vim.ui.select = old_select
    pcall(vim.fn.delete, devices._path_for_tests())
  end)

  it("passes trusted persisted microphone directly to recording", function()
    local devices = reset_devices()
    devices.save(device("ffmpeg-avfoundation:audio:1", "DJI Mic", 1))
    local code_review, state, process = start_composer()
    local old_devices_sync = process.devices_sync
    local old_record = process.record
    local old_transcribe = process.transcribe
    local seen_device
    process.devices_sync = function()
      error("trusted opaque microphone should not list devices on the hot path")
    end
    process.record = function(opts)
      seen_device = opts.audio_device
      vim.schedule(function()
        opts.on_event({ ok = true, event = "recording_started" })
        opts.on_exit(0, { ok = true, event = "recording_stopped", durationMillis = 1000, audioBytes = 3 }, "")
      end)
      return { stop = function() end, discard = function() end, kill = function() end }
    end
    process.transcribe = function(opts)
      vim.schedule(function()
        opts.on_exit(0, { ok = true, text = "spoken" }, "")
      end)
      return { kill = function() end }
    end

    require("code-review.voice").toggle()
    vim.wait(1000, function()
      return state.get().voice == nil
    end)
    assert.equals("ffmpeg-avfoundation:audio:1", seen_device)

    process.devices_sync = old_devices_sync
    process.record = old_record
    process.transcribe = old_transcribe
    require("code-review.composer").cancel()
    code_review.quit()
    pcall(vim.fn.delete, devices._path_for_tests())
  end)

  it("passes stale trusted opaque microphone through so helper can fail visibly", function()
    local devices = reset_devices()
    devices.save(device("ffmpeg-avfoundation:audio:99", "Missing Mic", 99))
    local code_review, _, process = start_composer()
    local old_devices_sync = process.devices_sync
    local old_record = process.record
    local seen_device
    process.devices_sync = function()
      error("trusted opaque microphone should not list devices on the hot path")
    end
    process.record = function(opts)
      seen_device = opts.audio_device
      return { stop = function() end, discard = function() end, kill = function() end }
    end

    require("code-review.voice").toggle()
    assert.equals("ffmpeg-avfoundation:audio:99", seen_device)

    process.devices_sync = old_devices_sync
    process.record = old_record
    require("code-review.voice").discard()
    require("code-review.composer").cancel()
    code_review.quit()
    pcall(vim.fn.delete, devices._path_for_tests())
  end)

  it("falls through to helper selection when a legacy persisted microphone is stale", function()
    local devices = reset_devices()
    devices.save(device("legacy-missing-mic", "Missing Mic", 99))
    local code_review, _, process = start_composer()
    local old_devices_sync = process.devices_sync
    local old_record = process.record
    local old_notify = vim.notify
    local seen_device = "unset"
    local warning
    process.devices_sync = function()
      return { ok = true, devices = { device("ffmpeg-avfoundation:audio:1", "DJI Mic", 1) } }, ""
    end
    process.record = function(opts)
      seen_device = opts.audio_device
      return { stop = function() end, discard = function() end, kill = function() end }
    end
    vim.notify = function(message)
      warning = message
    end

    require("code-review.voice").toggle()
    assert.equals(nil, seen_device)
    assert.truthy(warning:find("another available microphone", 1, true))
    assert.falsy(warning:find("system default", 1, true))

    process.devices_sync = old_devices_sync
    process.record = old_record
    vim.notify = old_notify
    require("code-review.voice").discard()
    require("code-review.composer").cancel()
    code_review.quit()
    pcall(vim.fn.delete, devices._path_for_tests())
  end)

  it("prewarms microphones on composer open and uses cached recommendation without a saved mic", function()
    local devices = reset_devices()
    local process = require("code-review.voice.process")
    local old_devices = process.devices
    local calls = 0
    local code_review, state, _, helper = start_composer({
      before_reference = function(proc)
        proc.devices = function(opts)
          calls = calls + 1
          opts.on_exit(0, {
            ok = true,
            devices = {
              device("ffmpeg-avfoundation:audio:0", "ZoomAudioDevice", 0, "likely_virtual"),
              device("ffmpeg-avfoundation:audio:1", "DJI Mic", 1, "likely_physical"),
            },
            recommendedSelection = { id = "ffmpeg-avfoundation:audio:1", reason = "first likely physical device" },
          }, "")
          return { kill = function() end }
        end
      end,
    })

    vim.wait(1000, function()
      return devices._cache_for_tests() ~= nil
    end)
    assert.is_true(calls >= 1)
    assert.equals("ffmpeg-avfoundation:audio:1", devices.resolve_for_record(require("code-review.config").get().voice, helper))

    process.devices = old_devices
    require("code-review.composer").cancel()
    assert.equals("comment_list", state.mode())
    code_review.quit()
    pcall(vim.fn.delete, devices._path_for_tests())
  end)

  it("prearms microphone on composer open without entering voice mode", function()
    local devices = reset_devices()
    local old_prearm
    local captured
    local handle = { started = false, discarded = false, killed = false }
    local code_review, state, process = start_composer({
      before_reference = function(proc)
        old_prearm = proc.prearm
        proc.prearm = function(opts)
          captured = opts
          return {
            start = function()
              handle.started = true
              return true
            end,
            discard = function()
              handle.discarded = true
            end,
            kill = function()
              handle.killed = true
            end,
          }
        end
      end,
    })

    vim.wait(1000, function()
      return state.get().voice_prearm ~= nil
    end)
    assert.equals("composer", state.mode())
    assert.equals(nil, state.get().voice)
    assert.truthy(state.get().voice_prearm)
    assert.equals(250, captured.pre_roll_ms)
    assert.is_false(handle.started)

    require("code-review.composer").cancel()
    assert.is_true(handle.discarded)
    assert.is_true(handle.killed)
    process.prearm = old_prearm
    code_review.quit()
    pcall(vim.fn.delete, devices._path_for_tests())
  end)

  it("starts quickly from a ready prearm", function()
    local devices = reset_devices()
    local old_prearm
    local captured
    local starts = 0
    local code_review, state, process = start_composer({
      before_reference = function(proc)
        old_prearm = proc.prearm
        proc.prearm = function(opts)
          captured = opts
          return {
            start = function()
              starts = starts + 1
              return true
            end,
            stop = function()
              return true
            end,
            discard = function() end,
            kill = function() end,
          }
        end
      end,
    })
    vim.wait(1000, function()
      return state.get().voice_prearm ~= nil
    end)
    captured.on_event({ ok = true, event = "recording_ready" })

    require("code-review.voice").toggle()
    assert.equals("recording_starting", state.mode())
    assert.equals(1, starts)
    captured.on_event({ ok = true, event = "recording_started" })
    assert.equals("recording", state.mode())

    require("code-review.voice").discard()
    process.prearm = old_prearm
    require("code-review.composer").cancel()
    code_review.quit()
    pcall(vim.fn.delete, devices._path_for_tests())
  end)

  it("waits in starting mode when voice is pressed while prearm is warming", function()
    local devices = reset_devices()
    local old_prearm
    local captured
    local starts = 0
    local code_review, state, process = start_composer({
      before_reference = function(proc)
        old_prearm = proc.prearm
        proc.prearm = function(opts)
          captured = opts
          return {
            start = function()
              starts = starts + 1
              return true
            end,
            discard = function() end,
            kill = function() end,
          }
        end
      end,
    })
    vim.wait(1000, function()
      return state.get().voice_prearm ~= nil
    end)

    require("code-review.voice").toggle()
    assert.equals("recording_starting", state.mode())
    assert.equals(0, starts)
    captured.on_event({ ok = true, event = "recording_ready" })
    assert.equals(1, starts)
    captured.on_event({ ok = true, event = "recording_started" })
    assert.equals("recording", state.mode())

    require("code-review.voice").discard()
    process.prearm = old_prearm
    require("code-review.composer").cancel()
    code_review.quit()
    pcall(vim.fn.delete, devices._path_for_tests())
  end)

  it("microphone picker restarts the idle prearm after selection", function()
    local devices = reset_devices()
    local old_prearm
    local old_devices
    local old_select = vim.ui.select
    local prearms = {}
    local code_review, _, process = start_composer({
      before_reference = function(proc)
        old_prearm = proc.prearm
        old_devices = proc.devices
        proc.prearm = function()
          local handle = { discarded = false, killed = false }
          function handle.discard()
            handle.discarded = true
          end
          function handle.kill()
            handle.killed = true
          end
          table.insert(prearms, handle)
          return handle
        end
        proc.devices = function(opts)
          opts.on_exit(0, { ok = true, devices = { device("ffmpeg-avfoundation:audio:1", "DJI Mic", 1) } }, "")
          return { kill = function() end }
        end
      end,
    })
    vim.wait(1000, function()
      return #prearms == 1
    end)
    vim.ui.select = function(items, _, cb)
      cb(items[1])
    end

    require("code-review.voice").pick_microphone()
    vim.wait(1000, function()
      return #prearms >= 2
    end)
    assert.equals(2, #prearms)
    assert.is_true(prearms[1].discarded)
    assert.is_true(prearms[1].killed)
    assert.is_false(prearms[2].discarded)

    process.prearm = old_prearm
    process.devices = old_devices
    vim.ui.select = old_select
    require("code-review.composer").cancel()
    code_review.quit()
    pcall(vim.fn.delete, devices._path_for_tests())
  end)

  it("saved trusted microphone skips device listing even when a cache exists", function()
    local devices = reset_devices()
    devices.save(device("ffmpeg-avfoundation:audio:2", "MacBook Pro Microphone", 2))
    local cfg = { enabled = true, node_cmd = "node", device_cache_ttl_ms = 60000 }
    local helper = vim.fn.tempname()
    vim.fn.writefile({ "" }, helper)
    local process = require("code-review.voice.process")
    local old_devices = process.devices
    local old_devices_sync = process.devices_sync
    process.devices = function(opts)
      opts.on_exit(0, {
        ok = true,
        devices = { device("ffmpeg-avfoundation:audio:1", "DJI Mic", 1) },
        recommendedSelection = { id = "ffmpeg-avfoundation:audio:1", reason = "first likely physical device" },
      }, "")
      return { kill = function() end }
    end
    assert.is_true(devices.prewarm(cfg, helper, { force = true }))
    assert.truthy(devices._cache_for_tests())
    process.devices_sync = function()
      error("trusted opaque microphone should not use devices_sync")
    end
    assert.equals("ffmpeg-avfoundation:audio:2", devices.resolve_for_record(cfg, helper))

    process.devices = old_devices
    process.devices_sync = old_devices_sync
    pcall(vim.fn.delete, helper)
    pcall(vim.fn.delete, devices._path_for_tests())
  end)

  it("blocks microphone picker while voice is starting", function()
    local devices = reset_devices()
    local code_review, state, process = start_composer()
    local old_record = process.record
    local old_devices = process.devices
    local listed = false
    process.record = function()
      return { stop = function() end, discard = function() end, kill = function() end }
    end
    process.devices = function()
      listed = true
      return { kill = function() end }
    end

    require("code-review.voice").toggle()
    assert.equals("recording_starting", state.mode())
    require("code-review.voice").pick_microphone()
    assert.is_false(listed)

    process.record = old_record
    process.devices = old_devices
    require("code-review.voice").discard()
    require("code-review.composer").cancel()
    code_review.quit()
    pcall(vim.fn.delete, devices._path_for_tests())
  end)

  it("refreshes microphone cache after stale opaque startup failure", function()
    local devices = reset_devices()
    devices.save(device("ffmpeg-avfoundation:audio:99", "Missing Mic", 99))
    local process = require("code-review.voice.process")
    local old_devices = process.devices
    local old_prearm = process.prearm
    local refreshes = 0
    local code_review, state, _, _ = start_composer({
      before_reference = function(proc)
        proc.devices = function(opts)
          refreshes = refreshes + 1
          opts.on_exit(0, {
            ok = true,
            devices = { device("ffmpeg-avfoundation:audio:1", "DJI Mic", 1) },
            recommendedSelection = { id = "ffmpeg-avfoundation:audio:1", reason = "first likely physical device" },
          }, "")
          return { kill = function() end }
        end
        proc.prearm = function(opts)
          vim.schedule(function()
            opts.on_exit(1, { ok = false, code = "audio_device_unavailable", message = "missing" }, "")
          end)
          return { discard = function() end, kill = function() end }
        end
      end,
    })
    vim.wait(1000, function()
      return refreshes > 0
    end)
    vim.wait(1000, function()
      return state.mode() == "composer" and state.get().voice == nil and state.get().voice_prearm == nil
    end)
    assert.equals("composer", state.mode())
    assert.is_true(refreshes > 0)

    process.devices = old_devices
    process.prearm = old_prearm
    require("code-review.composer").cancel()
    code_review.quit()
    pcall(vim.fn.delete, devices._path_for_tests())
  end)

  it("switching microphone in voice error pending clears failed audio and preserves draft", function()
    local devices = reset_devices()
    local code_review, state, process = start_composer()
    local old_devices = process.devices
    local old_select = vim.ui.select
    local audio_path = vim.fn.tempname() .. ".wav"
    vim.fn.writefile({ "wav" }, audio_path)
    vim.api.nvim_buf_set_lines(state.get().composer.body_buf, 0, -1, false, { "draft text" })
    state.get().voice = {
      id = 42,
      phase = "error_pending",
      audio_path = audio_path,
      session_id = state.get().session_id,
      review_id = state.get().active_review_id,
      composer_buf = state.get().composer.buf,
      attempts = 1,
    }
    state.set_mode("voice_error_pending")
    process.devices = function(opts)
      opts.on_exit(0, { ok = true, devices = { device("ffmpeg-avfoundation:audio:1", "DJI Mic", 1) } }, "")
      return { kill = function() end }
    end
    vim.ui.select = function(items, _, cb)
      cb(items[1])
    end

    require("code-review.voice").pick_microphone()
    assert.equals("composer", state.mode())
    assert.equals(nil, state.get().voice)
    assert.equals(0, vim.fn.filereadable(audio_path))
    assert.equals("draft text", table.concat(vim.api.nvim_buf_get_lines(state.get().composer.body_buf, 0, -1, false), "\n"))

    process.devices = old_devices
    vim.ui.select = old_select
    require("code-review.composer").cancel()
    code_review.quit()
    pcall(vim.fn.delete, devices._path_for_tests())
  end)
end)
