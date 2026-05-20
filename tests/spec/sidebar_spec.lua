describe("sidebar", function()
  local function sidebar_window_count()
    local count = 0
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_get_name(buf):match("Code Review$") and vim.bo[buf].buftype == "nofile" then
        count = count + 1
      end
    end
    return count
  end

  local function assert_sidebar_count(expected)
    assert.equals(expected, sidebar_window_count())
  end

  local function code_review_ui_window_count()
    local count = 0
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      local ft = vim.bo[buf].filetype
      if ft == "code-review-sidebar" or ft == "code-review-sidebar-footer" then
        count = count + 1
      end
    end
    return count
  end

  local function set_neo_tree_window(win)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(win, buf)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].filetype = "neo-tree"
    vim.b[buf].neo_tree_source = "filesystem"
    return buf
  end

  local function wipe_normal_file_buffers_except(keep)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if
        buf ~= keep
        and vim.api.nvim_buf_is_valid(buf)
        and vim.bo[buf].buftype == ""
        and (vim.bo[buf].buflisted or vim.api.nvim_buf_get_name(buf) ~= "")
      then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
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

  local function is_centered(line, text, width)
    local start_col = line:find(text, 1, true)
    if not start_col then
      return false
    end
    local left = start_col - 1
    local right = width - left - vim.fn.strdisplaywidth(text)
    return math.abs(left - right) <= 1
  end

  local function assert_lines_fit(lines, width)
    for _, line in ipairs(lines) do
      assert.truthy(vim.fn.strdisplaywidth(line) <= width, line)
    end
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

  local function start_sidebar_project()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "x" }, project .. "/x.lua")
    config.setup({ storage = { dir = project .. "/store" }, sidebar = { width = 32 } })
    pcall(vim.cmd, "only")
    vim.cmd.edit(project .. "/x.lua")
    wipe_normal_file_buffers_except(vim.api.nvim_get_current_buf())
    return code_review, state
  end

  local function assert_direct_sidebar_close_recreates(command, target)
    local code_review, state = start_sidebar_project()
    code_review.start()
    local code_win = vim.api.nvim_get_current_win()
    local old_sidebar = state.get().sidebar
    vim.api.nvim_set_current_win(target == "footer" and old_sidebar.footer_win or old_sidebar.win)
    local ok, err = pcall(vim.cmd, command)
    assert.is_true(ok, tostring(err))
    local recreated = vim.wait(500, function()
      local sidebar = state.get().sidebar
      return sidebar
        and vim.api.nvim_win_is_valid(sidebar.win)
        and vim.api.nvim_win_is_valid(sidebar.footer_win)
        and sidebar.win ~= old_sidebar.win
    end)
    assert.is_true(recreated)
    assert.equals(code_win, vim.api.nvim_get_current_win())
    code_review.quit()
  end

  it("does not start Review Mode from a bare unnamed buffer", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    config.setup({ storage = { dir = project .. "/store" }, sidebar = { width = 32 } })
    pcall(vim.cmd, "only")
    vim.cmd.enew()
    wipe_normal_file_buffers_except(vim.api.nvim_get_current_buf())

    code_review.start()

    assert.is_false(state.is_active())
    assert.equals(0, code_review_ui_window_count())
  end)

  it("does not start Review Mode from neo-tree without a visible file window", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    config.setup({ storage = { dir = project .. "/store" }, sidebar = { width = 32 } })
    pcall(vim.cmd, "only")
    vim.cmd.enew()
    wipe_normal_file_buffers_except(vim.api.nvim_get_current_buf())
    set_neo_tree_window(vim.api.nvim_get_current_win())

    code_review.start()

    assert.is_false(state.is_active())
    assert.equals(0, code_review_ui_window_count())
  end)

  it("starts from a visible file window when focus is in neo-tree", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "x" }, project .. "/x.lua")
    config.setup({ storage = { dir = project .. "/store" }, sidebar = { width = 32 } })
    pcall(vim.cmd, "only")
    vim.cmd.edit(project .. "/x.lua")
    wipe_normal_file_buffers_except(vim.api.nvim_get_current_buf())
    local code_win = vim.api.nvim_get_current_win()
    vim.cmd.vsplit()
    set_neo_tree_window(vim.api.nvim_get_current_win())

    code_review.start()

    assert.is_true(state.is_active())
    assert.equals(require("code-review.path").realpath(project), state.get().root)
    assert.equals(code_win, vim.api.nvim_get_current_win())
    assert.equals(2, code_review_ui_window_count())
    code_review.quit()
  end)

  it("keeps Review Mode active and preserves configured width when neo-tree opens", function()
    local code_review, state = start_sidebar_project()
    code_review.start()
    local sidebar = state.get().sidebar
    assert.equals(32, sidebar.desired_width)

    vim.cmd.vsplit()
    set_neo_tree_window(vim.api.nvim_get_current_win())
    vim.api.nvim_win_set_width(sidebar.win, 20)
    vim.api.nvim_win_set_width(sidebar.footer_win, 20)
    require("code-review.sidebar").handle_resize()

    assert.is_true(state.is_active())
    assert.equals(32, sidebar.desired_width)
    assert.equals(32, vim.api.nvim_win_get_width(sidebar.win))
    assert.equals(32, vim.api.nvim_win_get_width(sidebar.footer_win))
    code_review.quit()
  end)

  it("preserves user-adjusted sidebar width across later layout pressure", function()
    local code_review, state = start_sidebar_project()
    code_review.start()
    local sidebar = state.get().sidebar
    vim.api.nvim_set_current_win(sidebar.win)
    vim.api.nvim_win_set_width(sidebar.win, 24)
    require("code-review.sidebar").capture_width_from_sidebar()

    vim.api.nvim_win_set_width(sidebar.win, 18)
    vim.api.nvim_win_set_width(sidebar.footer_win, 18)
    require("code-review.sidebar").handle_resize()

    assert.equals(24, sidebar.desired_width)
    assert.equals(24, vim.api.nvim_win_get_width(sidebar.win))
    assert.equals(24, vim.api.nvim_win_get_width(sidebar.footer_win))
    code_review.quit()
  end)

  it("schedules editor exit when the last work window is closed", function()
    local code_review, state = start_sidebar_project()
    local exit_calls, restore_exit = stub_auxiliary_exit(code_review)
    code_review.start()
    local code_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(code_win)

    vim.cmd.close()

    vim.wait(200, function()
      return exit_calls() == 1
    end)
    assert.is_true(state.is_active())
    assert.equals(2, code_review_ui_window_count())
    assert.equals(1, exit_calls())
    restore_exit()
    code_review.quit()
  end)

  it("keeps auxiliary panes in place while the editor exit is pending", function()
    local code_review, state = start_sidebar_project()
    local exit_calls, restore_exit = stub_auxiliary_exit(code_review)
    code_review.start()
    local code_win = vim.api.nvim_get_current_win()
    local sidebar = state.get().sidebar
    vim.api.nvim_set_current_win(code_win)

    vim.cmd.close()
    vim.wait(200, function()
      return exit_calls() == 1
    end)

    assert.is_true(state.is_active())
    assert.is_true(vim.api.nvim_win_is_valid(sidebar.win))
    assert.is_true(vim.api.nvim_win_is_valid(sidebar.footer_win))
    assert.equals(1, exit_calls())
    restore_exit()
    code_review.quit()
  end)

  it("schedules editor exit when the last work window becomes neo-tree", function()
    local code_review, state = start_sidebar_project()
    local exit_calls, restore_exit = stub_auxiliary_exit(code_review)
    code_review.start()
    local code_win = vim.api.nvim_get_current_win()

    set_neo_tree_window(code_win)

    vim.wait(200, function()
      return exit_calls() == 1
    end)
    assert.is_true(state.is_active())
    assert.equals(2, code_review_ui_window_count())
    assert.equals(1, exit_calls())
    restore_exit()
    code_review.quit()
  end)

  it("keeps Review Mode active when deleting a file leaves an unnamed work window", function()
    local code_review, state = start_sidebar_project()
    code_review.start()
    local code_win = vim.api.nvim_get_current_win()
    local code_buf = vim.api.nvim_win_get_buf(code_win)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if buf ~= code_buf and vim.bo[buf].buflisted then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end

    vim.cmd("bdelete " .. code_buf)
    vim.wait(100, function()
      return false
    end)

    assert.is_true(state.is_active())
    assert.equals("", vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(code_win)))
    assert.equals(2, code_review_ui_window_count())
    code_review.quit()
  end)

  it("keeps Review Mode active while an outside-root work window is visible", function()
    local code_review, state = start_sidebar_project()
    local code_win = vim.api.nvim_get_current_win()
    local outside = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "outside" }, outside)
    vim.cmd.vsplit(outside)
    local outside_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(code_win)
    code_review.start()

    vim.api.nvim_set_current_win(code_win)
    vim.cmd.close()
    vim.wait(100, function()
      return false
    end)

    assert.is_true(state.is_active())
    assert.equals(outside_win, vim.api.nvim_get_current_win())
    assert.equals(require("code-review.path").realpath(outside), vim.api.nvim_buf_get_name(0))
    assert.equals(2, code_review_ui_window_count())
    code_review.quit()
  end)

  it("keeps Review Mode active when closing one of two work windows", function()
    local code_review, state = start_sidebar_project()
    local exit_calls, restore_exit = stub_auxiliary_exit(code_review)
    local project = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":h")
    vim.fn.writefile({ "y" }, project .. "/y.lua")
    vim.cmd.vsplit(project .. "/y.lua")
    local second_win = vim.api.nvim_get_current_win()
    code_review.start()

    vim.api.nvim_set_current_win(second_win)
    vim.cmd.close()
    vim.wait(100, function()
      return false
    end)

    assert.is_true(state.is_active())
    assert.equals(2, code_review_ui_window_count())
    assert.equals(0, exit_calls())
    restore_exit()
    code_review.quit()
  end)

  it("closes only the auxiliary Review tab when another tab has work", function()
    local code_review, state = start_sidebar_project()
    local exit_calls, restore_exit = stub_auxiliary_exit(code_review)
    vim.cmd.tabnew()
    local other = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "other" }, other)
    vim.cmd.edit(other)
    local other_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd.tabprevious()
    code_review.start()
    local code_win = vim.api.nvim_get_current_win()

    vim.api.nvim_set_current_win(code_win)
    vim.cmd.close()
    local closed = vim.wait(500, function()
      return vim.api.nvim_get_current_tabpage() == other_tab and not state.is_active()
    end)

    assert.is_true(closed)
    assert.equals(1, #vim.api.nvim_list_tabpages())
    assert.equals(0, exit_calls())
    restore_exit()
  end)

  it("keeps at most one sidebar throughout the Review lifecycle", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local model = require("code-review.model")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "one", "two" }, project .. "/x.lua")
    config.setup({ storage = { dir = project .. "/store" }, sidebar = { width = 32 } })
    vim.cmd.edit(project .. "/x.lua")

    code_review.start()
    assert_sidebar_count(1)

    actions.create_review("Sidebar")
    assert_sidebar_count(1)

    vim.fn.setpos("'<", { 0, 1, 1, 0 })
    vim.fn.setpos("'>", { 0, 1, 1, 0 })
    actions.add_reference()
    local state = require("code-review.state")
    vim.api.nvim_buf_set_lines(state.get().composer.body_buf, 0, -1, false, { "ready" })
    require("code-review.composer").submit()
    assert_sidebar_count(1)

    local review = model.find_review(state.get().store, state.get().active_review_id)
    actions.preview()
    assert_sidebar_count(1)

    local old_select = vim.ui.select
    vim.ui.select = function(_, _, cb)
      cb(nil)
    end
    require("code-review.review_picker").open()
    vim.ui.select = old_select
    assert_sidebar_count(1)

    require("code-review.sidebar").render()
    assert_sidebar_count(1)

    code_review.quit()
    assert_sidebar_count(0)
  end)

  it("creates the sidebar without publishing a WinEnter target", function()
    local code_review, state = start_sidebar_project()
    local entered = {}
    local group = vim.api.nvim_create_augroup("code_review_sidebar_winenter_spec", { clear = true })
    vim.api.nvim_create_autocmd("WinEnter", {
      group = group,
      callback = function()
        entered[#entered + 1] = vim.api.nvim_get_current_win()
      end,
    })
    local current = vim.api.nvim_get_current_win()
    code_review.start()
    local sidebar = state.get().sidebar
    assert.equals(current, vim.api.nvim_get_current_win())
    assert.equals("code-review-sidebar", vim.bo[sidebar.buf].filetype)
    for _, win in ipairs(entered) do
      assert.is_false(win == sidebar.win)
    end
    code_review.quit()
    vim.api.nvim_del_augroup_by_id(group)
  end)

  it("suppresses sidebar WinEnter when eventignorewin is available", function()
    local code_review, state = start_sidebar_project()
    code_review.start()
    local sidebar = state.get().sidebar
    local has_eventignorewin = pcall(function()
      return vim.wo[sidebar.win].eventignorewin
    end)
    if not has_eventignorewin then
      code_review.quit()
      return
    end
    local entered = {}
    local group = vim.api.nvim_create_augroup("code_review_sidebar_manual_winenter_spec", { clear = true })
    vim.api.nvim_create_autocmd("WinEnter", {
      group = group,
      callback = function()
        entered[#entered + 1] = vim.api.nvim_get_current_win()
      end,
    })
    vim.api.nvim_set_current_win(sidebar.win)
    for _, win in ipairs(entered) do
      assert.is_false(win == sidebar.win)
    end
    vim.api.nvim_del_augroup_by_id(group)
    code_review.quit()
  end)

  it("recreates the sidebar after a direct window close", function()
    assert_direct_sidebar_close_recreates("close")
  end)

  it("recreates the sidebar after a direct buffer delete", function()
    assert_direct_sidebar_close_recreates("bdelete")
  end)

  it("recreates the sidebar after a direct footer window close", function()
    assert_direct_sidebar_close_recreates("close", "footer")
  end)

  it("recreates the sidebar after a direct footer buffer delete", function()
    assert_direct_sidebar_close_recreates("bdelete", "footer")
  end)

  it("exits Review Mode when quitting from the sidebar", function()
    local code_review, state = start_sidebar_project()
    code_review.start()
    local code_win = vim.api.nvim_get_current_win()
    local sidebar = state.get().sidebar
    vim.api.nvim_set_current_win(sidebar.win)
    local ok, err = pcall(vim.cmd, "confirm q")
    assert.is_true(ok, tostring(err))
    assert.is_false(state.is_active())
    assert.equals(nil, state.get().sidebar)
    assert.equals(1, #vim.api.nvim_list_wins())
    assert.equals(code_win, vim.api.nvim_get_current_win())
  end)

  it("maps the configured toggle key to quit from sidebar panes", function()
    local code_review, state = start_sidebar_project()
    code_review.start()
    local sidebar = state.get().sidebar

    assert.is_true(has_normal_map(sidebar.buf, "<leader>rt"))
    assert.is_true(has_normal_map(sidebar.footer_buf, "<leader>rt"))
    vim.api.nvim_set_current_win(sidebar.footer_win)
    vim.cmd("normal \\rt")

    assert.is_false(state.is_active())
    assert.equals(1, #vim.api.nvim_list_wins())
  end)

  it("shows centered header chrome and vertically centers empty messages", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "x" }, project .. "/x.lua")
    config.setup({ storage = { dir = project .. "/store" }, sidebar = { width = 32 } })
    vim.cmd.edit(project .. "/x.lua")
    code_review.start()

    local sidebar = state.get().sidebar
    local width = vim.api.nvim_win_get_width(sidebar.win)
    local height = vim.api.nvim_win_get_height(sidebar.win)
    local lines = vim.api.nvim_buf_get_lines(sidebar.buf, 0, -1, false)
    assert.truthy(vim.wo[sidebar.win].winbar:find("%%=", 1, false))
    assert.truthy(vim.wo[sidebar.win].winbar:find("CodeReviewSidebarTitle", 1, true))
    assert.truthy(vim.wo[sidebar.win].winbar:find("Code Review", 1, true))
    assert.falsy(vim.wo[sidebar.win].winbar:find("No active review", 1, true))

    local empty_line
    for index, line in ipairs(lines) do
      if line:find("No active review", 1, true) then
        empty_line = index
        assert.is_true(is_centered(line, "No active review", width - 1))
        break
      end
    end
    assert.truthy(empty_line)
    assert.equals(math.floor((height - 1) / 2) + 1, empty_line)

    actions.create_review("Test")
    require("code-review.sidebar").render()
    assert.truthy(vim.wo[sidebar.win].winbar:find("Code Review | Test", 1, true))
    assert.falsy(vim.wo[sidebar.win].winbar:find("Review: Test", 1, true))

    state.get().sidebar.filter = { ids = { "missing" }, count = 1 }
    require("code-review.sidebar").render()
    assert.truthy(vim.wo[sidebar.win].winbar:find("Code Review | Test", 1, true))
    assert.falsy(vim.wo[sidebar.win].winbar:find("Matching", 1, true))
    lines = vim.api.nvim_buf_get_lines(sidebar.buf, 0, -1, false)
    empty_line = nil
    for index, line in ipairs(lines) do
      if line:find("No Comments", 1, true) then
        empty_line = index
        assert.is_true(is_centered(line, "No Comments", width - 1))
        break
      end
    end
    assert.equals(math.floor((height - 1) / 2) + 1, empty_line)

    code_review.quit()
  end)

  it("defines sidebar highlight groups and keeps compact help legend fixed in the footer", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local model = require("code-review.model")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "x" }, project .. "/x.lua")
    config.setup({ storage = { dir = project .. "/store" }, sidebar = { width = 32 } })
    vim.cmd.edit(project .. "/x.lua")
    code_review.start()
    actions.create_review("Sidebar")
    local review = model.find_review(state.get().store, state.get().active_review_id)
    for _ = 1, 20 do
      table.insert(review.comments, model.new_comment())
    end
    require("code-review.sidebar").render()
    local sidebar = state.get().sidebar
    local width = vim.api.nvim_win_get_width(sidebar.win)
    local footer_lines = vim.api.nvim_buf_get_lines(sidebar.footer_buf, 0, -1, false)
    assert.equals(1, #footer_lines)
    assert.is_true(is_centered(footer_lines[1], "? help   q quit", width))
    assert.is_true(has_normal_map(sidebar.buf, "?"))
    assert.is_true(has_normal_map(sidebar.footer_buf, "?"))
    assert.is_true(has_normal_map(sidebar.buf, "q"))
    assert.is_true(has_normal_map(sidebar.footer_buf, "q"))
    assert.truthy(vim.api.nvim_get_hl(0, { name = "CodeReviewSidebarTitle" }).bg)
    assert.truthy(vim.api.nvim_get_hl(0, { name = "CodeReviewSidebarHeader" }).bold)
    assert.truthy(vim.api.nvim_get_hl(0, { name = "CodeReviewSidebarScope" }).italic)
    assert.truthy(vim.api.nvim_get_hl(0, { name = "CodeReviewSidebarIncomplete" }))
    assert.truthy(vim.api.nvim_get_hl(0, { name = "CodeReviewSidebarStale" }))
    assert.is_false(vim.wo[sidebar.win].number)
    assert.is_false(vim.wo[sidebar.win].relativenumber)
    assert.is_false(vim.wo[sidebar.win].wrap)
    assert.equals("no", vim.wo[sidebar.win].signcolumn)
    assert.equals("0", vim.wo[sidebar.win].foldcolumn)
    assert.equals(1, vim.api.nvim_win_get_height(sidebar.footer_win))
    code_review.quit()
  end)

  it("opens sidebar help with review mode and configured keymaps", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "x" }, project .. "/x.lua")
    config.setup({ storage = { dir = project .. "/store" }, keymaps = { prefix = "<leader>x" } })
    vim.cmd.edit(project .. "/x.lua")
    code_review.start()
    local sidebar = state.get().sidebar
    vim.api.nvim_set_current_win(sidebar.win)

    local win, _, buf = require("code-review.sidebar").show_help()
    assert.truthy(win)
    assert.is_true(vim.api.nvim_buf_is_valid(buf))
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.truthy(text:find("Overview", 1, true))
    assert.truthy(text:find("Normal mode", 1, true))
    assert.truthy(text:find("Visual mode", 1, true))
    assert.truthy(text:find("Sidebar buffer", 1, true))
    assert.truthy(text:find("<leader>xR", 1, true))
    assert.truthy(text:find("<leader>xc", 1, true))
    assert.truthy(text:find("<leader>xa", 1, true))
    assert.truthy(text:find("<leader>xt", 1, true))
    assert.truthy(text:find("Toggle Code Review", 1, true))
    assert.truthy(text:find("create, delete, or switch reviews", 1, true))
    assert.truthy(text:find("read%-only throwaway buffer"))
    assert.truthy(has_normal_map(buf, "q"))
    assert.truthy(has_normal_map(buf, "<Esc>"))
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    code_review.quit()
  end)

  it("renders all comments in a native scrollable sidebar buffer", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local model = require("code-review.model")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "x" }, project .. "/x.lua")
    config.setup({ storage = { dir = project .. "/store" }, sidebar = { width = 32 } })
    vim.cmd.edit(project .. "/x.lua")
    code_review.start()
    actions.create_review("Sidebar")
    local review = model.find_review(state.get().store, state.get().active_review_id)
    for i = 1, 30 do
      local comment = model.new_comment(string.format("2026-05-18T00:00:%02dZ", i))
      comment.body = "comment-" .. i
      table.insert(review.comments, comment)
    end
    require("code-review.sidebar").render()
    local sidebar = state.get().sidebar
    local lines = table.concat(vim.api.nvim_buf_get_lines(sidebar.buf, 0, -1, false), "\n")
    assert.truthy(vim.api.nvim_buf_line_count(sidebar.buf) > vim.api.nvim_win_get_height(sidebar.win))
    assert.falsy(lines:find("  > ", 1, true))
    assert.truthy(lines:find("30 Total Comments", 1, true))
    assert.truthy(lines:find("comment%-30"))
    assert.truthy(lines:find("comment%-1"))
    code_review.quit()
  end)

  it("aligns timestamps, references, and comment preview text", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local model = require("code-review.model")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "x" }, project .. "/x.lua")
    config.setup({ storage = { dir = project .. "/store" }, sidebar = { width = 32 } })
    vim.cmd.edit(project .. "/x.lua")
    code_review.start()
    actions.create_review("Sidebar")
    local review = model.find_review(state.get().store, state.get().active_review_id)
    local comment = model.new_comment("2026-05-18T00:00:01Z")
    comment.body = "comment body"
    table.insert(comment.file_references, model.new_file_reference({
      relative_path = "x.lua",
      start_line = 1,
      end_line = 1,
      selected_lines_snapshot = { "x" },
    }))
    table.insert(review.comments, comment)
    require("code-review.sidebar").render()

    local sidebar = state.get().sidebar
    local lines = vim.api.nvim_buf_get_lines(sidebar.buf, 0, -1, false)
    local width = vim.api.nvim_win_get_width(sidebar.win)
    assert.equals("", lines[1])
    assert.truthy(lines[2]:find("1 Total Comment", 1, true))
    assert.is_true(is_centered(lines[2], "1 Total Comment", width))
    assert.equals("", lines[3])
    local ns = vim.api.nvim_get_namespaces()["code-review.nvim.sidebar"]
    local scope_marks = vim.api.nvim_buf_get_extmarks(sidebar.buf, ns, { 1, 0 }, { 2, 0 }, { details = true })
    assert.equals("CodeReviewSidebarScope", scope_marks[1][4].hl_group)
    local timestamp, reference, body
    for _, line in ipairs(lines) do
      if line:find("ago", 1, true) then
        timestamp = line
      elseif line:find("x.lua:1%-1") then
        reference = line
      elseif line:find("comment body", 1, true) then
        body = line
      end
    end
    assert.truthy(timestamp)
    assert.truthy(reference)
    assert.truthy(body)
    assert.equals(timestamp:find("%S"), reference:find("%S"))
    assert.equals(timestamp:find("%S"), body:find("%S"))
    code_review.quit()
  end)

  it("preserves sidebar scroll view across rerenders", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local model = require("code-review.model")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "x" }, project .. "/x.lua")
    config.setup({ storage = { dir = project .. "/store" }, sidebar = { width = 32 } })
    vim.cmd.edit(project .. "/x.lua")
    code_review.start()
    actions.create_review("Sidebar")
    local review = model.find_review(state.get().store, state.get().active_review_id)
    for i = 1, 30 do
      local comment = model.new_comment(string.format("2026-05-18T00:00:%02dZ", i))
      comment.body = "comment-" .. i
      table.insert(review.comments, comment)
    end
    require("code-review.sidebar").render()
    local sidebar = state.get().sidebar
    local topline = vim.api.nvim_win_call(sidebar.win, function()
      vim.api.nvim_win_set_cursor(0, { 20, 0 })
      vim.cmd("normal! zt")
      return vim.fn.winsaveview().topline
    end)

    require("code-review.sidebar").render()

    local restored = vim.api.nvim_win_call(sidebar.win, function()
      return vim.fn.winsaveview().topline
    end)
    assert.equals(topline, restored)
    code_review.quit()
  end)

  it("filters the sidebar to comments matching the source cursor line", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local model = require("code-review.model")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "one", "two", "three", "four" }, project .. "/x.lua")
    config.setup({ storage = { dir = project .. "/store" }, sidebar = { width = 32 } })
    vim.cmd.edit(project .. "/x.lua")
    local code_win = vim.api.nvim_get_current_win()
    code_review.start()
    actions.create_review("Sidebar")
    local review = model.find_review(state.get().store, state.get().active_review_id)
    local older = model.new_comment("2026-05-18T00:00:01Z")
    older.body = "older"
    table.insert(older.file_references, model.new_file_reference({ relative_path = "x.lua", start_line = 2, end_line = 2, selected_lines_snapshot = { "two" } }))
    local newer = model.new_comment("2026-05-18T00:00:02Z")
    newer.body = "newer"
    table.insert(newer.file_references, model.new_file_reference({ relative_path = "x.lua", start_line = 2, end_line = 3, selected_lines_snapshot = { "two", "three" } }))
    local other = model.new_comment("2026-05-18T00:00:03Z")
    other.body = "other"
    table.insert(other.file_references, model.new_file_reference({ relative_path = "x.lua", start_line = 4, end_line = 4, selected_lines_snapshot = { "four" } }))
    review.comments = { older, newer, other }
    vim.api.nvim_set_current_win(code_win)
    vim.cmd("stopinsert")
    vim.api.nvim_win_set_cursor(code_win, { 2, 0 })

    require("code-review.sidebar").update_filter_for_buffer(vim.api.nvim_get_current_buf())

    local sidebar = state.get().sidebar
    local lines = table.concat(vim.api.nvim_buf_get_lines(sidebar.buf, 0, -1, false), "\n")
    assert.truthy(vim.wo[sidebar.win].winbar:find("Code Review | Sidebar", 1, true))
    assert.falsy(vim.wo[sidebar.win].winbar:find("Matching", 1, true))
    assert.truthy(lines:find("2 Comments on this line only", 1, true))
    assert.truthy(lines:find("newer", 1, true))
    assert.truthy(lines:find("older", 1, true))
    assert.falsy(lines:find("other", 1, true))

    vim.api.nvim_set_current_win(code_win)
    vim.api.nvim_win_set_cursor(code_win, { 4, 0 })
    require("code-review.sidebar").update_filter_for_buffer(vim.api.nvim_get_current_buf())
    lines = table.concat(vim.api.nvim_buf_get_lines(sidebar.buf, 0, -1, false), "\n")
    assert.truthy(lines:find("1 Comment on this line only", 1, true))
    assert.truthy(lines:find("other", 1, true))
    assert.falsy(lines:find("newer", 1, true))
    assert.falsy(lines:find("older", 1, true))

    vim.api.nvim_set_current_win(sidebar.win)
    require("code-review.sidebar").update_filter_for_buffer(sidebar.buf)
    lines = table.concat(vim.api.nvim_buf_get_lines(sidebar.buf, 0, -1, false), "\n")
    assert.falsy(vim.wo[sidebar.win].winbar:find("Matching", 1, true))
    assert.truthy(lines:find("3 Total Comments", 1, true))
    assert.truthy(lines:find("other", 1, true))

    vim.api.nvim_set_current_win(code_win)
    vim.api.nvim_win_set_cursor(code_win, { 1, 0 })
    require("code-review.sidebar").update_filter_for_buffer(vim.api.nvim_get_current_buf())
    lines = table.concat(vim.api.nvim_buf_get_lines(sidebar.buf, 0, -1, false), "\n")
    assert.falsy(vim.wo[sidebar.win].winbar:find("Matching", 1, true))
    assert.truthy(lines:find("3 Total Comments", 1, true))
    assert.truthy(lines:find("other", 1, true))
    code_review.quit()
  end)

  it("renders long sidebar content within the current window width", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local model = require("code-review.model")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    local long_path = "very/deep/path/with/a/long/file/name/that/exceeds/sidebar/width.lua"
    vim.fn.mkdir(project .. "/" .. vim.fn.fnamemodify(long_path, ":h"), "p")
    vim.fn.writefile({ "x" }, project .. "/" .. long_path)
    config.setup({ storage = { dir = project .. "/store" }, sidebar = { width = 24 } })
    vim.cmd.edit(project .. "/" .. long_path)
    code_review.start()
    actions.create_review("A review name that is much wider than the sidebar")
    local review = model.find_review(state.get().store, state.get().active_review_id)
    local comment = model.new_comment()
    comment.body = "This is a long comment preview that should wrap into physical sidebar rows without relying on native window wrapping."
    comment.file_references = {
      {
        relative_path = long_path,
        start_line = 1,
        end_line = 1,
        stale_state = "fresh",
      },
    }
    table.insert(review.comments, comment)
    require("code-review.sidebar").render()

    local sidebar = state.get().sidebar
    local width = vim.api.nvim_win_get_width(sidebar.win)
    local lines = vim.api.nvim_buf_get_lines(sidebar.buf, 0, -1, false)
    assert_lines_fit(lines, width)
    assert.truthy(table.concat(lines, "\n"):find("This is a long", 1, true))

    code_review.quit()
  end)
end)
