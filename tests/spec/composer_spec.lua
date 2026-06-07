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

  local function refs_text(composer)
    return table.concat(vim.api.nvim_buf_get_lines(composer.refs_buf, 0, -1, false), "\n")
  end

  local function voice_text(composer)
    return table.concat(vim.api.nvim_buf_get_lines(composer.voice_buf, 0, -1, false), "\n")
  end

  local function legend_text(composer)
    return table.concat(vim.api.nvim_buf_get_lines(composer.legend_buf, 0, -1, false), "\n")
  end

  local recording_frames = {
    "⢎ ",
    "⠎⠁",
    "⠊⠑",
    "⠈⠱",
    " ⡱",
    "⢀⡰",
    "⢄⡠",
    "⢆⡀",
  }

  local transcribing_frames = {
    "⠉⠉",
    "⠈⠙",
    "⠀⠹",
    "⠀⢸",
    "⠀⣰",
    "⢀⣠",
    "⣀⣀",
    "⣄⡀",
    "⣆⠀",
    "⡇⠀",
    "⠏⠀",
    "⠋⠁",
  }

  local function voice_status_lines(composer)
    local lines = vim.api.nvim_buf_get_lines(composer.voice_buf, 0, -1, false)
    local status = {}
    for index, line in ipairs(lines) do
      if line:match("%S") then
        status[#status + 1] = { index = index, line = line }
      end
    end
    assert.equals(1, #status)
    return lines, status[1]
  end

  local function assert_voice_centered(composer, rendered, expected)
    local width = vim.api.nvim_win_get_width(composer.voice_win)
    local start_col = rendered.line:find(expected, 1, true)
    assert.truthy(start_col)
    local left_padding = start_col - 1
    local right_padding = width - left_padding - vim.fn.strdisplaywidth(expected)
    assert.is_true(math.abs(left_padding - right_padding) <= 1)
    assert.equals(1, rendered.index)
    assert.is_true(vim.fn.strdisplaywidth(rendered.line) <= width)
  end

  local function assert_voice_line(composer, expected)
    local lines, rendered = voice_status_lines(composer)
    assert.is_true(#lines <= vim.api.nvim_win_get_height(composer.voice_win))
    assert_voice_centered(composer, rendered, expected)
  end

  local function assert_voice_frame_line(composer, frames, label)
    local lines, rendered = voice_status_lines(composer)
    assert.is_true(#lines <= vim.api.nvim_win_get_height(composer.voice_win))
    for _, frame in ipairs(frames) do
      assert.equals(2, vim.fn.strdisplaywidth(frame))
      local expected = frame .. " " .. label
      if rendered.line:find(expected, 1, true) then
        assert_voice_centered(composer, rendered, expected)
        return
      end
    end
    error("voice line did not use expected " .. label .. " frame: " .. rendered.line)
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

  local function assert_display_pane(composer, pane)
    local buf = composer[pane .. "_buf"]
    local win = composer[pane .. "_win"]
    assert.is_true(vim.api.nvim_buf_is_valid(buf))
    assert.is_true(vim.api.nvim_win_is_valid(win))
    assert.is_false(vim.api.nvim_win_get_config(win).focusable)
    assert.is_false(vim.bo[buf].modifiable)
    assert.same({}, vim.api.nvim_buf_get_keymap(buf, "n"))
  end

  local function assert_ordered_layout(composer)
    local order = { "refs_win", "body_win", "voice_win", "legend_win" }
    local previous_bottom = -1
    for _, key in ipairs(order) do
      local win = composer[key]
      assert.is_true(vim.api.nvim_win_is_valid(win))
      local cfg = vim.api.nvim_win_get_config(win)
      local border_extra = key == "legend_win" and 0 or 2
      assert.equals("editor", cfg.relative)
      assert.is_true(cfg.width > 0)
      assert.is_true(cfg.height > 0)
      assert.is_true(cfg.row >= 0)
      assert.is_true(cfg.col >= 0)
      assert.is_true(cfg.row + cfg.height + border_extra <= vim.o.lines)
      assert.is_true(cfg.col + cfg.width + border_extra <= vim.o.columns)
      if key == "legend_win" then
        local body_cfg = vim.api.nvim_win_get_config(composer.body_win)
        assert.equals(body_cfg.col, cfg.col)
        assert.equals(body_cfg.width + 2, cfg.width)
      end
      assert.is_true(cfg.row > previous_bottom)
      previous_bottom = cfg.row + cfg.height + border_extra - 1
    end
  end

  local function assert_voice_title(composer)
    assert.truthy(vim.inspect(vim.api.nvim_win_get_config(composer.voice_win).title):find("Voice", 1, true))
  end

  local function assert_legend_fits(composer)
    local width = vim.api.nvim_win_get_width(composer.legend_win)
    for _, line in ipairs(vim.api.nvim_buf_get_lines(composer.legend_buf, 0, -1, false)) do
      assert.is_true(vim.fn.strdisplaywidth(line) <= width)
    end
  end

  local function assert_voice_fits(composer)
    local width = vim.api.nvim_win_get_width(composer.voice_win)
    for _, line in ipairs(vim.api.nvim_buf_get_lines(composer.voice_buf, 0, -1, false)) do
      assert.is_true(vim.fn.strdisplaywidth(line) <= width)
    end
  end

  local function assert_legend_centered(composer)
    local width = vim.api.nvim_win_get_width(composer.legend_win)
    for _, line in ipairs(vim.api.nvim_buf_get_lines(composer.legend_buf, 0, -1, false)) do
      local text = vim.trim(line)
      local expected_padding = math.floor((width - vim.fn.strdisplaywidth(text)) / 2)
      local actual_padding = #(line:match("^ *") or "")
      assert.is_true(math.abs(actual_padding - expected_padding) <= 1)
    end
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

  it("allows deleting the last draft File Reference and blocks zero-reference submit", function()
    local code_review, actions, state, model = start_project()
    select_lines(actions, 1, 1)
    local composer_module = require("code-review.composer")
    local old_select = vim.ui.select
    local old_notify = vim.notify
    local messages = {}
    vim.ui.select = function(_, _, cb)
      cb("Delete")
    end
    vim.notify = function(message)
      messages[#messages + 1] = message
    end

    composer_module.delete_reference_under_cursor()
    local composer = state.get().composer
    assert.equals("No draft File References", vim.trim(refs_text(composer)))
    vim.api.nvim_buf_set_lines(composer.body_buf, 0, -1, false, { "body" })
    composer_module.submit()

    vim.ui.select = old_select
    vim.notify = old_notify
    local review = model.find_review(state.get().store, state.get().active_review_id)
    assert.equals(0, #review.comments)
    assert.equals("composer", state.mode())
    assert.equals("Add at least one File Reference before submitting.", messages[#messages])
    composer_module.cancel()
    code_review.quit()
  end)

  it("opens a stacked composer focused on a body-only comment buffer", function()
    local code_review, actions, state = start_project()
    require("code-review.config").setup({ voice = { enabled = false } })
    select_lines(actions, 1, 1)
    local composer = state.get().composer
    assert.equals(composer.body_buf, vim.api.nvim_get_current_buf())
    assert.equals(composer.body_win, vim.api.nvim_get_current_win())
    assert.equals(composer.body_buf, composer.buf)
    assert.equals(composer.body_win, composer.win)
    assert.equals(nil, composer.status_buf)
    assert.equals(nil, composer.status_win)
    assert.equals("", composer_text(composer))
    assert.truthy(legend_text(composer):find("Tab switch panels", 1, true))
    assert.truthy(legend_text(composer):find("<leader><Space> voice", 1, true))
    assert.truthy(legend_text(composer):find("<leader>d delete", 1, true))
    assert_voice_line(composer, "!  Unavailable")
    assert.truthy(refs_text(composer):find("x.lua:1-1", 1, true))
    assert_display_pane(composer, "voice")
    assert_display_pane(composer, "legend")
    assert_ordered_layout(composer)
    assert_voice_title(composer)
    vim.api.nvim_buf_set_lines(composer.body_buf, 0, -1, false, { "body" })
    require("code-review.composer").submit()
    local review = require("code-review.model").find_review(state.get().store, state.get().active_review_id)
    assert.equals("body", review.comments[1].body)
    code_review.quit()
  end)

  it("shows and maps voice discard while retryable voice errors are pending", function()
    local code_review, actions, state = start_project()
    select_lines(actions, 1, 1)
    local composer_module = require("code-review.composer")
    local composer = state.get().composer
    local audio_path = vim.fn.tempname() .. ".wav"
    vim.fn.writefile({ "wav" }, audio_path)
    state.get().voice = {
      id = 1001,
      phase = "error_pending",
      audio_path = audio_path,
      session_id = state.get().session_id,
      review_id = state.get().active_review_id,
      composer_buf = composer.buf,
      attempts = 1,
    }
    state.set_mode("voice_error_pending")
    composer_module.refresh()

    assert.is_true(has_normal_map(composer.body_buf, "<leader>x"))
    assert.is_true(has_normal_map(composer.refs_buf, "<leader>x"))
    assert.truthy(legend_text(composer):find("<leader><Space> retry", 1, true))
    assert.truthy(legend_text(composer):find("<leader>x discard", 1, true))
    local _, _, help_buf = composer_module.show_help()
    local help = table.concat(vim.api.nvim_buf_get_lines(help_buf, 0, -1, false), "\n")
    assert.truthy(help:find("<leader>x", 1, true))
    pcall(vim.api.nvim_buf_delete, help_buf, { force = true })

    vim.api.nvim_set_current_win(composer.body_win)
    vim.cmd("normal \\x")

    assert.equals("composer", state.mode())
    assert.equals(nil, state.get().voice)
    assert.equals(0, vim.fn.filereadable(audio_path))
    composer_module.cancel()
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
    assert.is_true(has_normal_map(composer.body_buf, "q"))
    assert.is_true(has_normal_map(composer.refs_buf, "q"))
    assert.is_true(has_normal_map(composer.body_buf, "<Esc>"))
    assert.is_true(has_normal_map(composer.refs_buf, "<Esc>"))
    assert.is_true(has_normal_map(composer.body_buf, "<Leader>q"))
    assert.is_true(has_normal_map(composer.refs_buf, "<Leader>q"))
    assert.is_true(has_normal_map(composer.body_buf, "?"))
    assert.is_true(has_normal_map(composer.refs_buf, "?"))
    assert.is_true(has_normal_map(composer.body_buf, "<Tab>"))
    assert.is_true(has_normal_map(composer.refs_buf, "<Tab>"))
    assert.is_true(has_normal_map(composer.body_buf, "<S-Tab>"))
    assert.is_true(has_normal_map(composer.refs_buf, "<S-Tab>"))
    assert.is_false(has_normal_map(composer.body_buf, "<Space>"))
    assert.is_false(has_normal_map(composer.refs_buf, "<Space>"))
    assert.is_false(has_normal_map(composer.body_buf, "d"))
    assert.is_false(has_normal_map(composer.refs_buf, "d"))
    assert.same({}, vim.api.nvim_buf_get_keymap(composer.voice_buf, "n"))
    assert.same({}, vim.api.nvim_buf_get_keymap(composer.legend_buf, "n"))
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

  it("maps common quit keys on every composer pane to cancel the whole composer", function()
    for _, lhs in ipairs({ "q", "<Leader>q", "<Esc>" }) do
      for _, pane in ipairs({ "body_buf", "refs_buf" }) do
        local code_review, actions, state = start_project()
        select_lines(actions, 1, 1)
        local composer = state.get().composer
        get_normal_map(composer[pane], lhs).callback()
        assert.equals("comment_list", state.mode())
        assert.equals(nil, state.get().composer)
        assert.is_false(vim.api.nvim_buf_is_valid(composer.body_buf))
        assert.is_false(vim.api.nvim_buf_is_valid(composer.refs_buf))
        assert.is_false(vim.api.nvim_buf_is_valid(composer.voice_buf))
        assert.is_false(vim.api.nvim_buf_is_valid(composer.legend_buf))
        code_review.quit()
      end
    end
  end)

  it("keeps global leader quit from closing only the focused reference pane", function()
    local old_map = vim.fn.maparg("<leader>q", "n", false, true)
    if old_map and old_map.lhs then
      pcall(vim.keymap.del, "n", "<leader>q")
    end
    vim.keymap.set("n", "<leader>q", "<cmd>close<cr>", { desc = "User close mapping" })

    local code_review, actions, state = start_project()
    select_lines(actions, 1, 1)
    local composer = state.get().composer
    require("code-review.composer").focus_references()
    vim.cmd("stopinsert")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<leader>q", true, false, true), "xt", false)
    vim.cmd("redraw")

    pcall(vim.keymap.del, "n", "<leader>q")
    if old_map and old_map.lhs then
      vim.fn.mapset("n", false, old_map)
    end

    assert.equals("comment_list", state.mode())
    assert.equals(nil, state.get().composer)
    assert.is_false(vim.api.nvim_win_is_valid(composer.refs_win))
    assert.is_false(vim.api.nvim_win_is_valid(composer.body_win))
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
    assert.truthy(text:find("Delete removes it; Go to jumps the source window to that line", 1, true))
    assert.truthy(text:find("<leader>d   Delete the focused reference", 1, true))
    assert.truthy(text:find("<leader>d   Delete the whole comment or draft", 1, true))
    assert.truthy(text:find("<leader><Space> Start, cancel startup, stop, or retry voice recording", 1, true))
    assert.truthy(text:find("Submit requires comment text and at least one File Reference", 1, true))
    assert.truthy(text:find("Starting      Voice helper is opening the microphone", 1, true))
    assert.truthy(text:find("Transcribing  Voice is being transcribed", 1, true))
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

  it("cycles focus between references and body while skipping display panes", function()
    local code_review, actions, state = start_project()
    select_lines(actions, 1, 1)
    local composer = state.get().composer
    assert.equals(composer.body_win, vim.api.nvim_get_current_win())
    assert.is_false(vim.api.nvim_win_get_config(composer.voice_win).focusable)
    assert.is_false(vim.api.nvim_win_get_config(composer.legend_win).focusable)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "x", false)
    assert.equals(composer.refs_win, vim.api.nvim_get_current_win())
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "x", false)
    assert.equals(composer.body_win, vim.api.nvim_get_current_win())
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<S-Tab>", true, false, true), "x", false)
    assert.equals(composer.refs_win, vim.api.nvim_get_current_win())
    assert.is_false(composer.voice_win == vim.api.nvim_get_current_win())
    assert.is_false(composer.legend_win == vim.api.nvim_get_current_win())
    require("code-review.composer").cancel()
    code_review.quit()
  end)

  it("keeps composer panes ordered and in bounds at constrained sizes", function()
    local old_columns = vim.o.columns
    local old_lines = vim.o.lines
    local code_review
    local ok, err = pcall(function()
      vim.o.columns = 80
      vim.o.lines = 24
      local actions, state
      code_review, actions, state = start_project()
      select_lines(actions, 1, 1)
      local composer = state.get().composer
      assert_ordered_layout(composer)
      for _, size in ipairs({
        { columns = 50, lines = 12 },
        { columns = 80, lines = 18 },
        { columns = 80, lines = 20 },
        { columns = 80, lines = 21 },
        { columns = 24, lines = 18 },
        { columns = 24, lines = 24 },
        { columns = 36, lines = 18 },
        { columns = 36, lines = 24 },
        { columns = 50, lines = 18 },
        { columns = 50, lines = 20 },
        { columns = 50, lines = 21 },
      }) do
        vim.o.columns = size.columns
        vim.o.lines = size.lines
        vim.cmd("doautocmd VimResized")
        assert_ordered_layout(composer)
        assert.truthy(legend_text(composer):find("Enter submit", 1, true))
        assert.truthy(voice_text(composer):find("Ready", 1, true) or voice_text(composer):find("Unavailable", 1, true))
            assert.is_true(#vim.api.nvim_buf_get_lines(composer.legend_buf, 0, -1, false) <= vim.api.nvim_win_get_height(composer.legend_win))
        assert.is_true(#vim.api.nvim_buf_get_lines(composer.voice_buf, 0, -1, false) <= vim.api.nvim_win_get_height(composer.voice_win))
        assert_legend_fits(composer)
        assert_voice_fits(composer)
        assert_legend_centered(composer)
        assert_voice_title(composer)
      end
      vim.o.columns = 140
      vim.o.lines = 12
      vim.cmd("doautocmd VimResized")
      assert_ordered_layout(composer)
      assert.is_true(#vim.api.nvim_buf_get_lines(composer.legend_buf, 0, -1, false) <= vim.api.nvim_win_get_height(composer.legend_win))
      assert_legend_fits(composer)
      assert_voice_fits(composer)
      assert_legend_centered(composer)
      assert_voice_title(composer)
      vim.o.columns = 120
      vim.o.lines = 40
      vim.cmd("doautocmd VimResized")
      assert_ordered_layout(composer)
      assert.is_true(#vim.api.nvim_buf_get_lines(composer.legend_buf, 0, -1, false) <= vim.api.nvim_win_get_height(composer.legend_win))
      assert_legend_fits(composer)
      assert_voice_fits(composer)
      assert_legend_centered(composer)
      assert_voice_title(composer)
      require("code-review.composer").cancel()
      code_review.quit()
    end)
    vim.o.columns = old_columns
    vim.o.lines = old_lines
    if not ok then
      if code_review then
        pcall(code_review.quit)
      end
      error(err)
    end
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

  it("deletes the last File Reference when leader delete is requested", function()
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
    assert.equals("No draft File References", vim.trim(refs_text(composer)))
    require("code-review.composer").cancel()
    code_review.quit()
  end)

  it("closes the composer on Review Mode quit", function()
    local code_review, actions, state = start_project()
    select_lines(actions, 1, 1)
    local buf = state.get().composer.buf
    local refs_buf = state.get().composer.refs_buf
    local voice_buf = state.get().composer.voice_buf
    local legend_buf = state.get().composer.legend_buf
    code_review.quit()
    assert.is_false(code_review.is_active())
    assert.equals(nil, state.get().composer)
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
    assert.is_false(vim.api.nvim_buf_is_valid(refs_buf))
    assert.is_false(vim.api.nvim_buf_is_valid(voice_buf))
    assert.is_false(vim.api.nvim_buf_is_valid(legend_buf))
  end)

  it("adds voice transcript spaces only at the insertion boundary", function()
    local code_review, actions, state, model = start_project()
    select_lines(actions, 1, 1)
    local composer = state.get().composer
    local composer_module = require("code-review.composer")

    local function insert_on_line(line, col, text)
      vim.api.nvim_buf_set_lines(composer.body_buf, 0, -1, false, { line })
      vim.api.nvim_win_set_cursor(composer.body_win, { 1, col })
      assert.is_true(composer_module.insert_text(text))
      return table.concat(vim.api.nvim_buf_get_lines(composer.body_buf, 0, -1, false), "\n")
    end

    assert.equals("start voice end", insert_on_line("startend", 5, "voice"))
    assert.equals("start voice end", insert_on_line("start end", 6, "voice "))
    assert.equals("start voice end", insert_on_line("start end", 5, "voice"))
    assert.equals("voice start", insert_on_line("start", 0, "voice"))
    assert.equals("start voice", insert_on_line("start", 5, "voice"))
    assert.equals("start voice, end", insert_on_line("start, end", 5, "voice"))
    assert.equals("hello, world", insert_on_line("hello world", 5, ","))
    assert.equals("wood??", insert_on_line("wood?", 4, "?"))
    assert.equals("today This is Ruby", insert_on_line("today", 5, "This is Ruby"))
    assert.equals("alpha one\ntwo omega", insert_on_line("alphaomega", 5, "one\ntwo"))

    composer_module.cancel()

    local review = model.find_review(state.get().store, state.get().active_review_id)
    local comment = model.new_comment("2026-05-18T00:00:01Z")
    comment.body = "second"
    table.insert(comment.file_references, model.new_file_reference({
      relative_path = "x.lua",
      start_line = 1,
      end_line = 1,
      selected_lines_snapshot = { "one" },
    }))
    table.insert(review.comments, comment)
    composer_module.open_edit(comment)
    composer = state.get().composer
    assert.equals("second  ", composer_text(composer))
    assert.is_true(composer_module.insert_text("voice"))
    assert.equals("second voice ", composer_text(composer))
    assert.equals("second", comment.body)

    composer_module.cancel()
    code_review.quit()
  end)

  it("keeps repeated voice transcripts separated in one composer session", function()
    local code_review, actions, state = start_project()
    select_lines(actions, 1, 1)
    local composer = state.get().composer
    local composer_module = require("code-review.composer")
    vim.api.nvim_buf_set_lines(composer.body_buf, 0, -1, false, { "" })
    vim.api.nvim_win_set_cursor(composer.body_win, { 1, 0 })

    assert.is_true(composer_module.insert_text("Hello, how are you doing today?"))
    assert.is_true(composer_module.insert_text("This is Ruby reporting in for duty."))
    assert.is_true(composer_module.insert_text("How much wood could a woodchuck chuck if a woodchuck could chuck wood?"))

    assert.equals(
      "Hello, how are you doing today? This is Ruby reporting in for duty. How much wood could a woodchuck chuck if a woodchuck could chuck wood?",
      composer_text(composer)
    )
    assert.same({ 1, #composer_text(composer) }, vim.api.nvim_win_get_cursor(composer.body_win))

    composer_module.cancel()
    code_review.quit()
  end)

  it("preserves question marks across repeated voice inserts", function()
    local code_review, actions, state = start_project()
    select_lines(actions, 1, 1)
    local composer = state.get().composer
    local composer_module = require("code-review.composer")
    vim.api.nvim_buf_set_lines(composer.body_buf, 0, -1, false, { "" })
    vim.api.nvim_win_set_cursor(composer.body_win, { 1, 0 })

    local question = "Can you add a section here about the project details?"
    assert.is_true(composer_module.insert_text(question))
    assert.equals(question, composer_text(composer))
    assert.same({ 1, #question }, vim.api.nvim_win_get_cursor(composer.body_win))
    assert.is_true(composer_module.insert_text(question))

    assert.equals(question .. " " .. question, composer_text(composer))
    assert.same({ 1, #(question .. " " .. question) }, vim.api.nvim_win_get_cursor(composer.body_win))

    composer_module.cancel()
    code_review.quit()
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
    assert.equals("start voice end", line)
    assert.same({ 1, 12 }, vim.api.nvim_win_get_cursor(composer.body_win))
    assert.equals(nil, composer.spinner_timer)
    local current_win = vim.api.nvim_get_current_win()
    local cursor = vim.api.nvim_win_get_cursor(composer.body_win)
    vim.wait(200)
    assert.equals("composer", state.mode())
    assert.equals(current_win, vim.api.nvim_get_current_win())
    assert.same(cursor, vim.api.nvim_win_get_cursor(composer.body_win))
    assert.is_true(vim.api.nvim_buf_is_valid(composer.voice_buf))
    process.record = old_record
    process.transcribe = old_transcribe
    require("code-review.composer").cancel()
    code_review.quit()
  end)

  it("updates the display-only voice panel during recording, transcribing, retry, and discard", function()
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
    assert.equals("recording_starting", state.mode())
    assert_voice_frame_line(composer, recording_frames, "Starting")
    assert.truthy(composer.spinner_timer)
    local first_timer = composer.spinner_timer
    record_opts.on_event({ ok = true, event = "recording_started" })
    assert.equals("recording", state.mode())
    assert_voice_frame_line(composer, recording_frames, "Recording")
    require("code-review.voice").toggle()
    assert.truthy(transcribe_opts)
    assert_voice_frame_line(composer, transcribing_frames, "Transcribing")
    assert.equals(first_timer, composer.spinner_timer)
    transcribe_opts.on_exit(1, { ok = false, code = "network_error", message = "temporary", retryable = true }, "")
    assert.equals("voice_error_pending", state.mode())
    assert_voice_line(composer, "×  Failed")
    assert.equals(nil, composer.spinner_timer)
    require("code-review.voice").discard()
    assert.equals("composer", state.mode())
    assert_voice_line(composer, "○  Ready")
    process.record = old_record
    process.transcribe = old_transcribe
    require("code-review.composer").cancel()
    code_review.quit()
  end)

  it("stops spinner ticks when the composer closes during recording", function()
    local code_review, actions, state = start_project()
    local config = require("code-review.config")
    local process = require("code-review.voice.process")
    local project = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":h")
    local helper = project .. "/helper.js"
    vim.fn.writefile({ "" }, helper)
    config.setup({ storage = { dir = project .. "/store" }, voice = { helper_path = helper } })
    select_lines(actions, 1, 1)
    local composer = state.get().composer
    local voice_buf = composer.voice_buf
    local old_record = process.record
    process.record = function(opts)
      return { stop = function() end, discard = function() end, kill = function() end }
    end
    require("code-review.voice").toggle()
    assert.truthy(composer.spinner_timer)
    require("code-review.composer").cancel()
    assert.equals(nil, composer.spinner_timer)
    assert.is_false(vim.api.nvim_buf_is_valid(voice_buf))
    vim.wait(200)
    assert.equals("comment_list", state.mode())
    process.record = old_record
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
