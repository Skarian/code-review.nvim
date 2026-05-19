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

  it("centers the title and empty review message", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
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
    assert.is_true(is_centered(lines[1], "Code Review", width))

    local empty_line
    for index, line in ipairs(lines) do
      if line:find("No active review", 1, true) then
        empty_line = index
        assert.is_true(is_centered(line, "No active review", width))
        break
      end
    end
    assert.truthy(empty_line)
    assert.truthy(empty_line > 2)
    assert.truthy(empty_line < height - 4)

    code_review.quit()
  end)

  it("defines sidebar highlight groups and keeps legend at window bottom", function()
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
    local height = vim.api.nvim_win_get_height(sidebar.win)
    local lines = vim.api.nvim_buf_get_lines(sidebar.buf, 0, -1, false)
    assert.is_true(is_centered(lines[height], "rp preview rq quit", width))
    assert.truthy(lines[height - 1]:find("re edit", 1, true))
    assert.is_true(lines[height - 3]:find("%-%-") ~= nil)
    assert.truthy(vim.api.nvim_get_hl(0, { name = "CodeReviewSidebarHeader" }).bold)
    assert.truthy(vim.api.nvim_get_hl(0, { name = "CodeReviewSidebarIncomplete" }))
    assert.truthy(vim.api.nvim_get_hl(0, { name = "CodeReviewSidebarStale" }))
    assert.is_false(vim.wo[sidebar.win].number)
    assert.is_false(vim.wo[sidebar.win].relativenumber)
    assert.is_false(vim.wo[sidebar.win].wrap)
    assert.equals("no", vim.wo[sidebar.win].signcolumn)
    assert.equals("0", vim.wo[sidebar.win].foldcolumn)
    code_review.quit()
  end)

  it("renders newest sidebar comments first when truncated", function()
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
    local lines = table.concat(vim.api.nvim_buf_get_lines(state.get().sidebar.buf, 0, -1, false), "\n")
    assert.falsy(lines:find("  > ", 1, true))
    assert.truthy(lines:find("comment%-30"))
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
