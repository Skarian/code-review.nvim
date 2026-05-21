describe("preview lifecycle", function()
  local function make_complete_review()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "x" }, project .. "/x.lua")
    config.setup({ storage = { dir = project .. "/store" } })
    pcall(vim.cmd, "only")
    vim.cmd.edit(project .. "/x.lua")
    local source_buf = vim.api.nvim_get_current_buf()
    local source_win = vim.api.nvim_get_current_win()
    code_review.start()
    actions.create_review("Preview")
    vim.fn.setpos("'<", { 0, 1, 1, 0 })
    vim.fn.setpos("'>", { 0, 1, 1, 0 })
    actions.add_reference()
    vim.api.nvim_buf_set_lines(state.get().composer.body_buf, 0, -1, false, { "body" })
    require("code-review.composer").submit()
    return code_review, actions, state, source_win, source_buf, project
  end

  local function open_plugin_buffer()
    vim.cmd.enew()
    vim.bo.buftype = "nofile"
    vim.bo.bufhidden = "wipe"
    vim.api.nvim_buf_set_name(0, "Plugin Buffer " .. vim.fn.tempname())
  end

  local function has_normal_map(buf, lhs)
    local normalized = vim.api.nvim_replace_termcodes(lhs, true, true, true)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if map.lhs == lhs or map.lhs == normalized then
        return true
      end
    end
    return false
  end

  local function active_sidebar_visible(state)
    local sidebar = state.get().sidebar
    return sidebar
      and vim.api.nvim_win_is_valid(sidebar.win)
      and vim.bo[vim.api.nvim_win_get_buf(sidebar.win)].filetype == "code-review-sidebar"
      and vim.api.nvim_win_is_valid(sidebar.footer_win)
      and vim.bo[vim.api.nvim_win_get_buf(sidebar.footer_win)].filetype == "code-review-sidebar-footer"
  end

  local function win_for_buf(buf)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(win) == buf then
        return win
      end
    end
    return nil
  end

  local function layout_widths(state, source_buf)
    local widths = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if buf == source_buf then
        widths.source = vim.api.nvim_win_get_width(win)
      elseif state.get().sidebar and buf == state.get().sidebar.buf then
        widths.sidebar = vim.api.nvim_win_get_width(win)
      elseif state.get().sidebar and buf == state.get().sidebar.footer_buf then
        widths.footer = vim.api.nvim_win_get_width(win)
      end
    end
    return widths
  end

  local function set_neo_tree_window(win)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(win, buf)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].filetype = "neo-tree"
    vim.b[buf].neo_tree_source = "filesystem"
    return buf
  end

  local function stub_auxiliary_exit(code_review)
    local calls = 0
    local previous = code_review._exit_auxiliary_layout
    code_review._exit_auxiliary_layout = function()
      calls = calls + 1
    end
    return function()
      return calls
    end, function()
      code_review._exit_auxiliary_layout = previous
    end
  end

  it("classifies preview as content without making it a source or auxiliary window", function()
    local code_review, actions, state, _, source_buf = make_complete_review()
    local navigation = require("code-review.navigation")

    assert.is_true(navigation.content_buf(source_buf))
    assert.is_true(navigation.source_buf(source_buf))
    actions.preview()
    local preview_buf = state.get().preview.buf
    local preview_win = win_for_buf(preview_buf)

    assert.is_true(navigation.content_buf(preview_buf))
    assert.is_true(navigation.content_window(preview_win))
    assert.is_false(navigation.source_buf(preview_buf))
    assert.is_false(navigation.aux_window(preview_win))
    assert.equals(1, #navigation.tab_content_windows(0))
    code_review.quit()
  end)

  it("keeps outside-root and unnamed normal buffers as content but not source", function()
    local code_review, _, _, source_win = make_complete_review()
    local navigation = require("code-review.navigation")
    local outside = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "outside" }, outside)

    vim.cmd.vsplit(outside)
    local outside_win = vim.api.nvim_get_current_win()
    local outside_buf = vim.api.nvim_get_current_buf()
    assert.is_true(navigation.content_window(outside_win))
    assert.is_false(navigation.source_buf(outside_buf))

    vim.api.nvim_set_current_win(source_win)
    vim.cmd.enew()
    local unnamed_win = vim.api.nvim_get_current_win()
    local unnamed_buf = vim.api.nvim_get_current_buf()
    assert.is_true(navigation.content_window(unnamed_win))
    assert.is_false(navigation.source_buf(unnamed_buf))
    code_review.quit()
  end)

  it("treats sidebar, footer, and neo-tree as auxiliary rather than content", function()
    local code_review, _, state = make_complete_review()
    local navigation = require("code-review.navigation")
    local sidebar = state.get().sidebar

    assert.is_true(navigation.aux_window(sidebar.win))
    assert.is_true(navigation.aux_window(sidebar.footer_win))
    assert.is_false(navigation.content_window(sidebar.win))
    assert.is_false(navigation.content_window(sidebar.footer_win))

    vim.cmd.vsplit()
    set_neo_tree_window(vim.api.nvim_get_current_win())
    assert.is_true(navigation.aux_window(vim.api.nvim_get_current_win()))
    assert.is_false(navigation.content_window(vim.api.nvim_get_current_win()))
    code_review.quit()
  end)

  it("refreshes preview buffers and closes preview on quit", function()
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
    actions.create_review("Preview")
    vim.fn.setpos("'<", { 0, 1, 1, 0 })
    vim.fn.setpos("'>", { 0, 1, 1, 0 })
    actions.add_reference()
    vim.api.nvim_buf_set_lines(state.get().composer.body_buf, 0, -1, false, { "body" })
    require("code-review.composer").submit()
    local review = model.find_review(state.get().store, state.get().active_review_id)
    actions.preview()
    local preview_buf = state.get().preview.buf
    assert.truthy(vim.api.nvim_buf_is_valid(preview_buf))
    assert.equals("nofile", vim.bo[preview_buf].buftype)
    assert.is_true(vim.bo[preview_buf].buflisted)
    assert.equals("wipe", vim.bo[preview_buf].bufhidden)
    assert.equals("code-review-preview", vim.bo[preview_buf].filetype)
    assert.is_false(vim.bo[preview_buf].swapfile)
    assert.is_true(vim.bo[preview_buf].modifiable)
    assert.is_false(vim.bo[preview_buf].readonly)
    assert.is_false(has_normal_map(preview_buf, "q"))
    assert.is_false(has_normal_map(preview_buf, "<leader>q"))
    assert.is_false(has_normal_map(preview_buf, "<leader>c"))
    vim.api.nvim_buf_set_lines(preview_buf, 0, 0, false, { "scratch edit" })
    assert.is_false(vim.bo[preview_buf].modified)
    actions.preview()
    assert.equals("preview", state.mode())
    assert.equals(preview_buf, state.get().preview.buf)
    code_review.quit()
    assert.is_false(vim.api.nvim_buf_is_valid(preview_buf))
  end)

  it("keeps Review Mode active while preview is the only content window", function()
    local code_review, actions, state = make_complete_review()
    local exit_calls = 0
    local previous = code_review._exit_auxiliary_layout
    code_review._exit_auxiliary_layout = function()
      exit_calls = exit_calls + 1
    end

    actions.preview()
    vim.wait(50, function()
      return false
    end)

    assert.is_true(state.is_active())
    assert.equals("preview", state.mode())
    assert.equals(1, #require("code-review.navigation").tab_content_windows(0))
    assert.equals(0, exit_calls)
    code_review._exit_auxiliary_layout = previous
    code_review.quit()
  end)

  it("restores the source and sidebar after raw preview buffer delete", function()
    local code_review, actions, state, _, source_buf = make_complete_review()
    local exit_calls, restore_exit = stub_auxiliary_exit(code_review)
    actions.preview()

    vim.cmd.bdelete()
    vim.wait(300, function()
      return state.mode() == "comment_list" and vim.api.nvim_get_current_buf() == source_buf and active_sidebar_visible(state)
    end)

    assert.is_true(state.is_active())
    assert.equals("comment_list", state.mode())
    assert.equals(source_buf, vim.api.nvim_get_current_buf())
    assert.is_true(active_sidebar_visible(state))
    assert.truthy(win_for_buf(source_buf))
    assert.equals(0, exit_calls())
    restore_exit()
    code_review.quit()
  end)

  it("restores the origin source after raw preview delete while other content remains", function()
    local code_review, actions, state, source_win, source_buf = make_complete_review()
    local outside = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "outside" }, outside)
    vim.cmd.vsplit(outside)
    local outside_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(source_win)
    actions.preview()

    vim.cmd.bdelete()
    vim.wait(300, function()
      return state.mode() == "comment_list" and win_for_buf(source_buf) ~= nil and active_sidebar_visible(state)
    end)

    assert.is_true(state.is_active())
    assert.truthy(win_for_buf(source_buf))
    assert.is_true(vim.api.nvim_win_is_valid(outside_win))
    assert.is_true(active_sidebar_visible(state))
    code_review.quit()
  end)

  it("restores the source and sidebar after raw preview window quit", function()
    local code_review, actions, state, _, source_buf = make_complete_review()
    local exit_calls, restore_exit = stub_auxiliary_exit(code_review)
    actions.preview()

    vim.cmd("confirm q")
    vim.wait(300, function()
      return state.mode() == "comment_list" and vim.api.nvim_get_current_buf() == source_buf and active_sidebar_visible(state)
    end)

    assert.is_true(state.is_active())
    assert.equals("comment_list", state.mode())
    assert.equals(source_buf, vim.api.nvim_get_current_buf())
    assert.is_true(active_sidebar_visible(state))
    assert.truthy(win_for_buf(source_buf))
    assert.equals(0, exit_calls())
    restore_exit()
    code_review.quit()
  end)

  it("preserves user-adjusted sidebar width after raw preview close fallback", function()
    local columns = vim.o.columns
    vim.o.columns = 180
    local code_review, actions, state, _, source_buf = make_complete_review()
    local exit_calls, restore_exit = stub_auxiliary_exit(code_review)
    local sidebar = state.get().sidebar
    vim.api.nvim_set_current_win(sidebar.win)
    vim.api.nvim_win_set_width(sidebar.win, 55)
    vim.api.nvim_win_set_width(sidebar.footer_win, 55)
    require("code-review.sidebar").capture_width_from_sidebar()
    local adjusted_width = sidebar.desired_width

    vim.api.nvim_set_current_win(win_for_buf(source_buf))
    actions.preview()
    vim.cmd("confirm q")
    vim.wait(300, function()
      local widths = layout_widths(state, source_buf)
      return widths.sidebar == adjusted_width and widths.footer == adjusted_width
    end)
    local widths = layout_widths(state, source_buf)

    assert.equals(55, adjusted_width)
    assert.equals(adjusted_width, widths.sidebar)
    assert.equals(adjusted_width, widths.footer)
    assert.equals(adjusted_width, state.get().sidebar.desired_width)
    assert.equals(0, exit_calls())
    restore_exit()
    code_review.quit()
    vim.o.columns = columns
  end)

  it("uses a source window for preview when focus is in neo-tree", function()
    local code_review, actions, state, source_win, source_buf = make_complete_review()
    vim.cmd.vsplit()
    local neo_win = vim.api.nvim_get_current_win()
    local neo_buf = set_neo_tree_window(neo_win)

    actions.preview()
    local preview_buf = state.get().preview.buf

    assert.equals(preview_buf, vim.api.nvim_win_get_buf(source_win))
    assert.equals(neo_buf, vim.api.nvim_win_get_buf(neo_win))
    assert.equals(nil, win_for_buf(source_buf))
    code_review.quit()
  end)

  it("uses clean non-source content for preview from neo-tree when no source window remains", function()
    local code_review, actions, state, source_win = make_complete_review()
    local outside = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "outside" }, outside)
    vim.cmd.vsplit(outside)
    local outside_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(source_win)
    vim.cmd.close()
    vim.api.nvim_set_current_win(outside_win)
    vim.cmd.vsplit()
    local neo_win = vim.api.nvim_get_current_win()
    local neo_buf = set_neo_tree_window(neo_win)

    actions.preview()
    local preview_buf = state.get().preview.buf

    assert.equals(preview_buf, vim.api.nvim_win_get_buf(outside_win))
    assert.equals(neo_buf, vim.api.nvim_win_get_buf(neo_win))
    code_review.quit()
  end)

  it("does not preview into auxiliary panes when only modified generic content remains", function()
    local code_review, actions, state, source_win = make_complete_review()
    local outside = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "outside" }, outside)
    vim.cmd.vsplit(outside)
    local outside_win = vim.api.nvim_get_current_win()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "modified" })
    vim.bo.modified = true
    vim.api.nvim_set_current_win(source_win)
    vim.cmd.close()
    vim.api.nvim_set_current_win(outside_win)
    vim.cmd.vsplit()
    local neo_win = vim.api.nvim_get_current_win()
    local neo_buf = set_neo_tree_window(neo_win)

    actions.preview()

    assert.equals(nil, state.get().preview)
    assert.equals("comment_list", state.mode())
    assert.equals(neo_buf, vim.api.nvim_win_get_buf(neo_win))
    vim.api.nvim_set_current_win(outside_win)
    vim.bo.modified = false
    code_review.quit()
  end)

  it("rolls back the survivor window if a preview window quit does not complete", function()
    local code_review, actions, state = make_complete_review()
    actions.preview()
    local preview = state.get().preview
    local session_id = state.get().session_id
    local before = #vim.api.nvim_tabpage_list_wins(0)

    assert.is_true(require("code-review.preview").prepare_window_quit())
    require("code-review.preview").rollback_quit_attempt(preview, session_id, preview.quit_attempt_id)

    assert.is_true(vim.api.nvim_buf_is_valid(preview.buf))
    assert.is_false(state.get().preview_restoring)
    assert.equals(before, #vim.api.nvim_tabpage_list_wins(0))
    code_review.quit()
  end)

  it("blocks preview from modified code buffers", function()
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
    actions.create_review("Preview")
    vim.fn.setpos("'<", { 0, 1, 1, 0 })
    vim.fn.setpos("'>", { 0, 1, 1, 0 })
    actions.add_reference()
    vim.api.nvim_buf_set_lines(state.get().composer.body_buf, 0, -1, false, { "body" })
    require("code-review.composer").submit()
    local review = model.find_review(state.get().store, state.get().active_review_id)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved" })
    actions.preview()
    assert.equals(nil, state.get().preview)
    vim.bo.modified = false
    code_review.quit()
  end)

  it("allows review picker from preview buffers", function()
    local code_review, actions, state = make_complete_review()
    actions.preview()
    local picker = require("code-review.review_picker")
    local old_pick = picker.adapter.pick_review
    local picked = false
    picker.adapter.pick_review = function(_, callbacks)
      picked = true
      callbacks.cancel()
    end

    actions.dispatch("open_picker")

    picker.adapter.pick_review = old_pick
    assert.is_true(picked)
    code_review.quit()
  end)

  it("previews from plugin buffers when visible Review files are clean", function()
    local code_review, actions, state, source_win = make_complete_review()
    vim.api.nvim_set_current_win(source_win)
    vim.cmd.vsplit()
    open_plugin_buffer()

    actions.preview()

    assert.equals("preview", state.mode())
    assert.truthy(state.get().preview)
    code_review.quit()
  end)

  it("blocks preview from plugin buffers when visible Review files are modified", function()
    local code_review, actions, state, source_win = make_complete_review()
    vim.api.nvim_win_call(source_win, function()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "modified" })
      vim.bo.modified = true
      assert.is_true(vim.bo.modified)
    end)
    vim.api.nvim_set_current_win(source_win)
    vim.cmd.vsplit()
    open_plugin_buffer()
    local old_notify = vim.notify
    local messages = {}
    vim.notify = function(message)
      messages[#messages + 1] = message
    end

    actions.preview()

    vim.notify = old_notify
    assert.equals("Write modified Review files before previewing", messages[1])
    assert.equals(nil, state.get().preview)
    vim.api.nvim_win_call(source_win, function()
      vim.bo.modified = false
    end)
    code_review.quit()
  end)
end)
