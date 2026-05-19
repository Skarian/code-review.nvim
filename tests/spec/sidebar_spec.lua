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
    assert_sidebar_count(1)

    local state = require("code-review.state")
    local review = model.find_review(state.get().store, state.get().active_review_id)
    review.comments[1].body = "ready"
    model.touch_comment(review, review.comments[1])
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
    local height = vim.api.nvim_win_get_height(sidebar.win)
    local lines = vim.api.nvim_buf_get_lines(sidebar.buf, 0, -1, false)
    assert.equals("      rp preview rq quit", lines[height])
    assert.truthy(vim.api.nvim_get_hl(0, { name = "CodeReviewSidebarHeader" }).bold)
    assert.truthy(vim.api.nvim_get_hl(0, { name = "CodeReviewSidebarCurrent" }))
    assert.truthy(vim.api.nvim_get_hl(0, { name = "CodeReviewSidebarIncomplete" }))
    assert.truthy(vim.api.nvim_get_hl(0, { name = "CodeReviewSidebarStale" }))
    code_review.quit()
  end)

  it("keeps the current comment visible when the sidebar is truncated", function()
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
    local current
    for i = 1, 30 do
      local comment = model.new_comment()
      comment.body = "comment-" .. i
      table.insert(review.comments, comment)
      current = comment
    end
    state.get().current_comment_id = current.id
    require("code-review.sidebar").render()
    local lines = table.concat(vim.api.nvim_buf_get_lines(state.get().sidebar.buf, 0, -1, false), "\n")
    assert.truthy(lines:find("> ", 1, true))
    assert.truthy(lines:find("comment%-30"))
    code_review.quit()
  end)
end)
