describe("comment composer", function()
  local function start_project(lines)
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile(lines or { "one", "two", "three" }, project .. "/x.lua")
    config.setup({ storage = { dir = project .. "/store" } })
    vim.cmd.edit(project .. "/x.lua")
    code_review.start()
    actions.create_review("Composer")
    return code_review, actions, require("code-review.state"), require("code-review.model")
  end

  local function select_lines(actions, first, last)
    vim.fn.setpos("'<", { 0, first, 1, 0 })
    vim.fn.setpos("'>", { 0, last, 1, 0 })
    actions.add_reference()
  end

  local function composer_text(composer)
    return table.concat(vim.api.nvim_buf_get_lines(composer.buf, 0, -1, false), "\n")
  end

  local function status_text(composer)
    return table.concat(vim.api.nvim_buf_get_lines(composer.status_buf, 0, -1, false), "\n")
  end

  local function refs_text(composer)
    return table.concat(vim.api.nvim_buf_get_lines(composer.refs_buf, 0, -1, false), "\n")
  end

  local function get_normal_map(buf, lhs)
    local normalized = vim.api.nvim_replace_termcodes(lhs, true, true, true)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if map.lhs == lhs or map.lhs == normalized then
        return map
      end
    end
  end

  local function has_normal_map(buf, lhs)
    return get_normal_map(buf, lhs) ~= nil
  end

  it("accepts Snacks.win when it is a callable table", function()
    local previous = package.loaded.snacks
    local called = false
    package.loaded.snacks = {
      win = setmetatable({}, {
        __call = function(_, opts)
          called = true
          local win = vim.api.nvim_open_win(opts.buf, true, {
            relative = "editor",
            row = 1,
            col = 1,
            width = 20,
            height = 4,
            style = "minimal",
          })
          return { win = win, close = function(self) vim.api.nvim_win_close(self.win, true) end }
        end,
      }),
      picker = { pick = function() end },
    }
    local buf = vim.api.nvim_create_buf(false, true)
    local win, handle = require("code-review.ui").open_composer(buf)
    assert.is_true(called)
    assert.truthy(win)
    handle:close()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    package.loaded.snacks = previous
  end)

  it("cancels new composer drafts without creating a comment", function()
    local code_review, actions, state, model = start_project()
    select_lines(actions, 1, 2)
    assert.equals("composer", state.mode())
    assert.truthy(state.get().composer)
    require("code-review.composer").cancel()
    local review = model.find_review(state.get().store, state.get().active_review_id)
    assert.equals(0, #review.comments)
    assert.equals("comment_list", state.mode())
    code_review.quit()
  end)

  it("refuses empty submit and keeps the composer open", function()
    local code_review, actions, state, model = start_project()
    select_lines(actions, 1, 1)
    require("code-review.composer").submit()
    local review = model.find_review(state.get().store, state.get().active_review_id)
    assert.equals(0, #review.comments)
    assert.equals("composer", state.mode())
    assert.truthy(state.get().composer)
    require("code-review.composer").cancel()
    code_review.quit()
  end)

  it("opens a stacked composer focused on a body-only comment buffer", function()
    local code_review, actions, state = start_project()
    require("code-review.config").setup({ voice = { enabled = false } })
    select_lines(actions, 1, 1)
    local composer = state.get().composer
    assert.equals(composer.body_buf, vim.api.nvim_get_current_buf())
    assert.equals(composer.body_win, vim.api.nvim_get_current_win())
    assert.equals("", composer_text(composer))
    assert.truthy(status_text(composer):find("Tab switch panels", 1, true))
    assert.truthy(status_text(composer):find("<leader><Space> voice", 1, true))
    assert.truthy(status_text(composer):find("<leader>d delete", 1, true))
    assert.truthy(status_text(composer):find("Voice: unavailable", 1, true))
    assert.truthy(refs_text(composer):find("x.lua:1-1", 1, true))
    vim.api.nvim_buf_set_lines(composer.body_buf, 0, -1, false, { "body" })
    require("code-review.composer").submit()
    local review = require("code-review.model").find_review(state.get().store, state.get().active_review_id)
    assert.equals("body", review.comments[1].body)
    code_review.quit()
  end)

  it("submits a complete comment from the selected reference and body", function()
    local code_review, actions, state, model = start_project()
    select_lines(actions, 2, 3)
    vim.api.nvim_buf_set_lines(state.get().composer.body_buf, 0, -1, false, { "body", "more" })
    require("code-review.composer").submit()
    local review = model.find_review(state.get().store, state.get().active_review_id)
    local comment = review.comments[1]
    assert.equals("body\nmore", comment.body)
    assert.equals(1, #comment.file_references)
    assert.equals(2, comment.file_references[1].start_line)
    assert.equals(3, comment.file_references[1].end_line)
    assert.equals("comment_list", state.mode())
    assert.equals(nil, state.get().composer)
    code_review.quit()
  end)

  it("shows all sidebar comments after a successful submit until source filtering resumes", function()
    local code_review, actions, state, model = start_project({ "one", "two", "three", "four" })
    local sidebar = require("code-review.sidebar")
    local source_buf = vim.api.nvim_get_current_buf()
    local source_win = vim.api.nvim_get_current_win()
    local review = model.find_review(state.get().store, state.get().active_review_id)
    local existing = model.new_comment("2026-05-18T00:00:01Z")
    existing.body = "existing"
    table.insert(existing.file_references, model.new_file_reference({
      relative_path = "x.lua",
      start_line = 2,
      end_line = 2,
      selected_lines_snapshot = { "two" },
    }))
    local other = model.new_comment("2026-05-18T00:00:02Z")
    other.body = "other"
    table.insert(other.file_references, model.new_file_reference({
      relative_path = "x.lua",
      start_line = 4,
      end_line = 4,
      selected_lines_snapshot = { "four" },
    }))
    review.comments = { existing, other }
    vim.api.nvim_win_set_cursor(source_win, { 2, 0 })
    sidebar.update_filter_for_buffer(source_buf)
    assert.truthy(state.get().sidebar.filter)

    select_lines(actions, 2, 2)
    vim.api.nvim_buf_set_lines(state.get().composer.body_buf, 0, -1, false, { "new" })
    require("code-review.composer").submit()

    local lines = table.concat(vim.api.nvim_buf_get_lines(state.get().sidebar.buf, 0, -1, false), "\n")
    assert.equals(nil, state.get().sidebar.filter)
    assert.truthy(lines:find("new", 1, true))
    assert.truthy(lines:find("existing", 1, true))
    assert.truthy(lines:find("other", 1, true))

    sidebar.update_filter_for_buffer(source_buf)
    lines = table.concat(vim.api.nvim_buf_get_lines(state.get().sidebar.buf, 0, -1, false), "\n")
    assert.equals(nil, state.get().sidebar.filter)
    assert.truthy(lines:find("new", 1, true))
    assert.truthy(lines:find("existing", 1, true))
    assert.truthy(lines:find("other", 1, true))

    sidebar.update_filter_for_buffer(source_buf)
    lines = table.concat(vim.api.nvim_buf_get_lines(state.get().sidebar.buf, 0, -1, false), "\n")
    assert.truthy(state.get().sidebar.filter)
    assert.truthy(lines:find("new", 1, true))
    assert.truthy(lines:find("existing", 1, true))
    assert.falsy(lines:find("other", 1, true))
    code_review.quit()
  end)

  it("opens existing comments in normal mode at the end of the body", function()
    local code_review, _actions, state, model = start_project()
    local review = model.find_review(state.get().store, state.get().active_review_id)
    local comment = model.new_comment("2026-05-18T00:00:01Z")
    comment.body = "first\nsecond"
    table.insert(comment.file_references, model.new_file_reference({
      relative_path = "x.lua",
      start_line = 1,
      end_line = 1,
      selected_lines_snapshot = { "one" },
    }))
    table.insert(review.comments, comment)

    require("code-review.composer").open_edit(comment)

    local composer = state.get().composer
    assert.equals("first\nsecond  ", composer_text(composer))
    assert.equals("first\nsecond", comment.body)
    assert.equals(composer.body_win, vim.api.nvim_get_current_win())
    assert.same({ 2, 7 }, vim.api.nvim_win_get_cursor(composer.body_win))
    assert.equals("n", vim.api.nvim_get_mode().mode)
    require("code-review.composer").cancel()
    code_review.quit()
  end)

  it("deletes an existing comment from the composer after confirmation", function()
    local code_review, _actions, state, model = start_project()
    local review = model.find_review(state.get().store, state.get().active_review_id)
    local comment = model.new_comment("2026-05-18T00:00:01Z")
    comment.body = "body"
    table.insert(comment.file_references, model.new_file_reference({
      relative_path = "x.lua",
      start_line = 1,
      end_line = 1,
      selected_lines_snapshot = { "one" },
    }))
    table.insert(review.comments, comment)
    require("code-review.composer").open_edit(comment)

    local old_select = vim.ui.select
    vim.ui.select = function(items, opts, cb)
      assert.same({ "Delete", "Cancel" }, items)
      assert.equals("Delete Comment?", opts.prompt)
      cb("Delete")
    end
    require("code-review.composer").delete_comment_or_draft()
    vim.ui.select = old_select

    assert.equals(0, #review.comments)
    assert.equals("comment_list", state.mode())
    assert.equals(nil, state.get().composer)
    code_review.quit()
  end)

  it("keeps an existing comment open when composer delete is cancelled", function()
    local code_review, _actions, state, model = start_project()
    local review = model.find_review(state.get().store, state.get().active_review_id)
    local comment = model.new_comment("2026-05-18T00:00:01Z")
    comment.body = "body"
    table.insert(comment.file_references, model.new_file_reference({
      relative_path = "x.lua",
      start_line = 1,
      end_line = 1,
      selected_lines_snapshot = { "one" },
    }))
    table.insert(review.comments, comment)
    require("code-review.composer").open_edit(comment)

    local old_select = vim.ui.select
    vim.ui.select = function(_, opts, cb)
      assert.equals("Delete Comment?", opts.prompt)
      cb("Cancel")
    end
    require("code-review.composer").delete_comment_or_draft()
    vim.ui.select = old_select

    assert.equals(1, #review.comments)
    assert.equals("composer", state.mode())
    assert.truthy(state.get().composer)
    require("code-review.composer").cancel()
    code_review.quit()
  end)

  it("deletes a new draft from the composer after confirmation", function()
    local code_review, actions, state, model = start_project()
    select_lines(actions, 1, 1)
    local review = model.find_review(state.get().store, state.get().active_review_id)

    local old_select = vim.ui.select
    vim.ui.select = function(items, opts, cb)
      assert.same({ "Delete", "Cancel" }, items)
      assert.equals("Delete Draft?", opts.prompt)
      cb("Delete")
    end
    require("code-review.composer").delete_comment_or_draft()
    vim.ui.select = old_select

    assert.equals(0, #review.comments)
    assert.equals("comment_list", state.mode())
    assert.equals(nil, state.get().composer)
    code_review.quit()
  end)

  it("maps context-sensitive composer keys without overriding plain delete or space", function()
    local code_review, actions, state = start_project()
    select_lines(actions, 1, 1)
    local composer = state.get().composer
    assert.is_true(has_normal_map(composer.body_buf, "<Leader>d"))
    assert.is_true(has_normal_map(composer.refs_buf, "<Leader>d"))
    assert.is_true(has_normal_map(composer.body_buf, "<Leader><Space>"))
    assert.is_true(has_normal_map(composer.refs_buf, "<Leader><Space>"))
    assert.is_false(has_normal_map(composer.body_buf, "<Space>"))
    assert.is_false(has_normal_map(composer.refs_buf, "<Space>"))
    assert.is_false(has_normal_map(composer.body_buf, "d"))
    assert.is_false(has_normal_map(composer.refs_buf, "d"))
    require("code-review.composer").cancel()
    code_review.quit()
  end)

  it("maps leader delete in the comment body to delete the whole draft", function()
    local code_review, actions, state, model = start_project()
    select_lines(actions, 1, 1)
    local composer = state.get().composer
    local review = model.find_review(state.get().store, state.get().active_review_id)
    local old_select = vim.ui.select
    vim.ui.select = function(items, opts, cb)
      assert.same({ "Delete", "Cancel" }, items)
      assert.equals("Delete Draft?", opts.prompt)
      cb("Delete")
    end
    get_normal_map(composer.body_buf, "<Leader>d").callback()
    vim.ui.select = old_select
    assert.equals(0, #review.comments)
    assert.equals("comment_list", state.mode())
    assert.equals(nil, state.get().composer)
    code_review.quit()
  end)

  it("registers composer-local which-key labels for context-sensitive actions", function()
    local previous = package.loaded["which-key"]
    local calls = {}
    package.loaded["which-key"] = {
      add = function(spec)
        calls[#calls + 1] = spec
      end,
    }

    local code_review, actions, state = start_project()
    select_lines(actions, 1, 1)
    local composer = state.get().composer

    local by_buffer = {}
    for _, call in ipairs(calls) do
      for _, item in ipairs(call) do
        by_buffer[item.buffer] = by_buffer[item.buffer] or {}
        by_buffer[item.buffer][item[1]] = item.desc
      end
    end
    assert.equals("Delete Code Review comment or draft", by_buffer[composer.body_buf]["<leader>d"])
    assert.equals("Delete draft File Reference", by_buffer[composer.refs_buf]["<leader>d"])
    assert.equals("Toggle Code Review voice", by_buffer[composer.body_buf]["<leader><Space>"])
    assert.equals("Toggle Code Review voice", by_buffer[composer.refs_buf]["<leader><Space>"])

    require("code-review.composer").cancel()
    code_review.quit()
    package.loaded["which-key"] = previous
  end)

  it("opens compact composer help and maps q and escape to close it", function()
    local code_review, actions, state = start_project()
    select_lines(actions, 1, 1)
    local win, _, buf = require("code-review.composer").show_help()
    assert.truthy(win)
    assert.is_true(vim.api.nvim_buf_is_valid(buf))
    assert.equals("Code Review Comment Editor Help", vim.api.nvim_buf_get_name(buf):match("[^/]+$"))
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.truthy(text:find("Overview", 1, true))
    assert.truthy(text:find("Write a review comment with its source context attached", 1, true))
    assert.truthy(text:find("File References stay visible above the text while you write", 1, true))
    assert.truthy(text:find("Edit the comment text below; use Tab and Shift-Tab to switch panes", 1, true))
    assert.truthy(text:find("Voice Dictation is built in for drafting longer comments without leaving the editor", 1, true))
    assert.truthy(text:find("Comment text", 1, true))
    assert.truthy(text:find("File References", 1, true))
    assert.truthy(text:find("Submitting and cancelling", 1, true))
    assert.truthy(text:find("Voice Dictation", 1, true))
    assert.truthy(text:find("Open actions for the focused reference", 1, true))
    assert.truthy(text:find("Delete removes it; Go to closes the editor and jumps to the source line", 1, true))
    assert.truthy(text:find("<leader>d   Delete the focused reference", 1, true))
    assert.truthy(text:find("<leader>d   Delete the whole comment or draft", 1, true))
    assert.truthy(text:find("<leader><Space> Start, stop, or retry voice recording", 1, true))
    assert.truthy(text:find("Submit requires comment text and at least one File Reference", 1, true))
    assert.truthy(text:find("Transcribing  Wait for text to be inserted at the comment cursor", 1, true))
    local maps = vim.api.nvim_buf_get_keymap(buf, "n")
    local seen_q, seen_esc = false, false
    for _, map in ipairs(maps) do
      if map.lhs == "q" then
        seen_q = true
      elseif map.lhs == "<Esc>" then
        seen_esc = true
      end
    end
    assert.is_true(seen_q)
    assert.is_true(seen_esc)
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    assert.equals("composer", state.mode())
    require("code-review.composer").cancel()
    assert.equals("comment_list", state.mode())
    code_review.quit()
  end)

  it("cycles focus between references and body while skipping status", function()
    local code_review, actions, state = start_project()
    select_lines(actions, 1, 1)
    local composer = state.get().composer
    assert.equals(composer.body_win, vim.api.nvim_get_current_win())
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "x", false)
    assert.equals(composer.refs_win, vim.api.nvim_get_current_win())
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "x", false)
    assert.equals(composer.body_win, vim.api.nvim_get_current_win())
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<S-Tab>", true, false, true), "x", false)
    assert.equals(composer.refs_win, vim.api.nvim_get_current_win())
    assert.is_false(composer.status_win == vim.api.nvim_get_current_win())
    require("code-review.composer").cancel()
    code_review.quit()
  end)

  it("opens reference actions from enter and can go to the selected reference", function()
    local code_review, actions, state = start_project({ "one", "two", "three" })
    select_lines(actions, 2, 2)
    local composer = state.get().composer
    require("code-review.composer").focus_references()
    vim.api.nvim_win_set_cursor(composer.refs_win, { 1, 0 })
    local old_select = vim.ui.select
    vim.ui.select = function(items, _, cb)
      assert.same({ "Delete", "Go to" }, items)
      cb("Go to")
    end
    require("code-review.composer").reference_action()
    vim.ui.select = old_select
    assert.equals(2, vim.api.nvim_win_get_cursor(composer.source_win)[1])
    assert.equals("composer", state.mode())
    assert.truthy(state.get().composer)
    require("code-review.composer").cancel()
    code_review.quit()
  end)

  it("maps leader delete in references to delete the focused File Reference", function()
    local code_review, actions, state = start_project()
    select_lines(actions, 1, 1)
    local composer = state.get().composer
    require("code-review.composer").focus_references()
    vim.api.nvim_win_set_cursor(composer.refs_win, { 1, 0 })
    local old_select = vim.ui.select
    vim.ui.select = function(_, _, cb)
      cb("Delete")
    end
    get_normal_map(composer.refs_buf, "<Leader>d").callback()
    vim.ui.select = old_select
    assert.equals(0, #composer.references)
    require("code-review.composer").submit()
    assert.equals("composer", state.mode())
    require("code-review.composer").cancel()
    code_review.quit()
  end)

  it("closes the composer on Review Mode quit", function()
    local code_review, actions, state = start_project()
    select_lines(actions, 1, 1)
    local buf = state.get().composer.buf
    local status_buf = state.get().composer.status_buf
    local refs_buf = state.get().composer.refs_buf
    code_review.quit()
    assert.is_false(code_review.is_active())
    assert.equals(nil, state.get().composer)
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
    assert.is_false(vim.api.nvim_buf_is_valid(status_buf))
    assert.is_false(vim.api.nvim_buf_is_valid(refs_buf))
  end)

  it("inserts voice transcripts at the composer cursor", function()
    local code_review, actions, state = start_project()
    local config = require("code-review.config")
    local process = require("code-review.voice.process")
    local project = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":h")
    local helper = project .. "/helper.js"
    vim.fn.writefile({ "" }, helper)
    config.setup({ storage = { dir = project .. "/store" }, voice = { helper_path = helper } })
    select_lines(actions, 1, 1)
    local composer = state.get().composer
    vim.api.nvim_buf_set_lines(composer.body_buf, 0, -1, false, { "start end" })
    vim.api.nvim_win_set_cursor(composer.body_win, { 1, 6 })
    local old_record = process.record
    local old_transcribe = process.transcribe
    process.record = function(opts)
      vim.fn.writefile({ "wav" }, opts.out)
      vim.schedule(function()
        opts.on_exit(0, { ok = true, event = "recording_stopped", durationMillis = 1000, audioBytes = 3 }, "")
      end)
      return { stop = function() end, discard = function() end, kill = function() end }
    end
    process.transcribe = function(opts)
      vim.schedule(function()
        opts.on_exit(0, { ok = true, text = "voice " }, "")
      end)
      return { kill = function() end }
    end
    require("code-review.voice").toggle()
    vim.wait(1000, function()
      return state.mode() == "composer" and state.get().voice == nil
    end)
    local line = vim.api.nvim_buf_get_lines(composer.body_buf, 0, 1, false)[1]
    assert.equals("start voiceend", line)
    process.record = old_record
    process.transcribe = old_transcribe
    require("code-review.composer").cancel()
    code_review.quit()
  end)

  it("updates composer voice status during recording, transcribing, retry, and discard", function()
    local code_review, actions, state = start_project()
    local config = require("code-review.config")
    local process = require("code-review.voice.process")
    local project = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":h")
    local helper = project .. "/helper.js"
    vim.fn.writefile({ "" }, helper)
    config.setup({ storage = { dir = project .. "/store" }, voice = { helper_path = helper, transcription_timeout_ms = 55 } })
    select_lines(actions, 1, 1)
    local composer = state.get().composer
    local old_record = process.record
    local old_transcribe = process.transcribe
    local record_opts
    local transcribe_opts
    process.record = function(opts)
      record_opts = opts
      vim.fn.writefile({ "wav" }, opts.out)
      return {
        stop = function()
          opts.on_exit(0, { ok = true, event = "recording_stopped", durationMillis = 1000, audioBytes = 3 }, "")
        end,
        discard = function() end,
        kill = function() end,
      }
    end
    process.transcribe = function(opts)
      transcribe_opts = opts
      return { kill = function() end }
    end
    require("code-review.voice").toggle()
    assert.truthy(record_opts)
    assert.truthy(status_text(composer):find("Recording: press <leader><Space> to stop", 1, true))
    require("code-review.voice").toggle()
    assert.truthy(transcribe_opts)
    assert.truthy(status_text(composer):find("Transcribing audio...", 1, true))
    transcribe_opts.on_exit(1, { ok = false, code = "network_error", message = "temporary", retryable = true }, "")
    assert.equals("voice_error_pending", state.mode())
    assert.truthy(status_text(composer):find("Voice failed: press <leader><Space> to retry", 1, true))
    require("code-review.voice").discard()
    assert.equals("composer", state.mode())
    assert.truthy(status_text(composer):find("Voice ready: press <leader><Space> to record", 1, true))
    process.record = old_record
    process.transcribe = old_transcribe
    require("code-review.composer").cancel()
    code_review.quit()
  end)

  it("keeps retryable voice errors inside the composer", function()
    local code_review, actions, state = start_project()
    local config = require("code-review.config")
    local process = require("code-review.voice.process")
    local project = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":h")
    local helper = project .. "/helper.js"
    vim.fn.writefile({ "" }, helper)
    config.setup({ storage = { dir = project .. "/store" }, voice = { helper_path = helper, transcription_timeout_ms = 55 } })
    select_lines(actions, 1, 1)
    vim.api.nvim_buf_set_lines(state.get().composer.body_buf, 0, -1, false, { "draft" })
    local old_record = process.record
    local old_transcribe = process.transcribe
    local seen_timeout
    process.record = function(opts)
      vim.fn.writefile({ "wav" }, opts.out)
      vim.schedule(function()
        opts.on_exit(0, { ok = true, event = "recording_stopped", durationMillis = 1000, audioBytes = 3 }, "")
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
    require("code-review.voice").toggle()
    vim.wait(1000, function()
      return state.mode() == "voice_error_pending"
    end)
    assert.equals(55, seen_timeout)
    assert.truthy(state.get().composer)
    assert.truthy(state.get().voice and state.get().voice.audio_path)
    require("code-review.voice").discard()
    assert.equals("composer", state.mode())
    process.record = old_record
    process.transcribe = old_transcribe
    require("code-review.composer").cancel()
    code_review.quit()
  end)
end)
