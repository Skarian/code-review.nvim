describe("lifecycle and keymaps", function()
  local function assert_mapped(lhs, mode)
    assert.is_false(vim.fn.maparg(lhs, mode) == "")
  end

  it("installs child mappings without mapping the parent prefix", function()
    local code_review = require("code-review")
    code_review.setup({ keymaps = { prefix = "<leader>r" } })
    assert.equals("", vim.fn.maparg("<leader>r", "n"))
    assert_mapped("<leader>rr", "n")
    assert_mapped("<leader>rr", "x")
    assert_mapped("<leader>re", "n")
    assert_mapped("<leader>ro", "n")
    assert_mapped("<leader>rR", "n")
    assert_mapped("<leader>ra", "n")
    assert_mapped("<leader>ra", "x")
  end)

  it("guards visual reference mappings in normal mode", function()
    local code_review = require("code-review")
    code_review.setup({ keymaps = { prefix = "<leader>r" } })
    vim.cmd.enew()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "abc" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    vim.cmd("normal \\ra")
    assert.equals("abc", vim.api.nvim_get_current_line())
    vim.cmd("normal \\rr")
    assert.equals("abc", vim.api.nvim_get_current_line())
    vim.bo.modified = false
    vim.cmd.bwipeout()
  end)

  it("keeps visual reference actions restricted to source buffers", function()
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
    actions.create_review("Visual")
    vim.cmd.enew()
    vim.bo.buftype = "nofile"
    vim.bo.bufhidden = "wipe"
    vim.api.nvim_buf_set_name(0, "Plugin Buffer " .. vim.fn.tempname())
    vim.fn.setpos("'<", { 0, 1, 1, 0 })
    vim.fn.setpos("'>", { 0, 1, 1, 0 })
    local old_notify = vim.notify
    local messages = {}
    vim.notify = function(message)
      messages[#messages + 1] = message
    end

    actions.add_reference()

    vim.notify = old_notify
    assert.equals("Save the buffer before adding a File Reference.", messages[1])
    assert.falsy(state.get().composer)
    code_review.quit()
  end)

  it("starts, creates a review, adds a reference, and previews", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local state = require("code-review.state")

    local original_cwd = vim.fn.getcwd()
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.mkdir(project .. "/lua", "p")
    vim.fn.writefile({ "local a = 1", "local b = 2", "return a + b" }, project .. "/lua/example.lua")
    vim.cmd("lcd " .. vim.fn.fnameescape(project))
    config.setup({ storage = { dir = project .. "/store" } })

    vim.cmd.edit(project .. "/lua/example.lua")
    code_review.start()
    assert.is_true(code_review.is_active())
    actions.create_review("Smoke")
    assert.truthy(state.get().active_review_id)

    vim.fn.setpos("'<", { 0, 1, 1, 0 })
    vim.fn.setpos("'>", { 0, 2, 1, 0 })
    actions.add_reference()
    vim.api.nvim_buf_set_lines(state.get().composer.body_buf, 0, -1, false, { "Please check this." })
    require("code-review.composer").submit()
    local review = require("code-review.model").find_review(state.get().store, state.get().active_review_id)
    local comment = review.comments[1]
    assert.equals(1, #comment.file_references)
    actions.preview()
    assert.equals("preview", state.mode())
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.truthy(text:find("Review: Smoke", 1, true))
    assert.truthy(text:find("lua/example.lua:1-2", 1, true))

    code_review.quit()
    vim.cmd("lcd " .. vim.fn.fnameescape(original_cwd))
  end)

  it("captures the active visual selection from the add-reference mapping", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local state = require("code-review.state")
    local model = require("code-review.model")

    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "one", "two", "three", "four", "five" }, project .. "/x.lua")
    config.setup({ storage = { dir = project .. "/store" }, keymaps = { prefix = "<leader>r" } })

    vim.cmd.edit(project .. "/x.lua")
    code_review.start()
    actions.create_review("Visual")

    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    vim.cmd("normal Vj\\ra")

    local ref = state.get().composer.references[1]
    assert.equals(4, ref.start_line)
    assert.equals(5, ref.end_line)
    assert.same({ "four", "five" }, ref.selected_lines_snapshot)
    assert.equals("n", vim.api.nvim_get_mode().mode)
    assert.equals(0, #model.find_review(state.get().store, state.get().active_review_id).comments)
    require("code-review.composer").cancel()

    code_review.quit()
  end)

  it("switches reviews without carrying transient comment selection", function()
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
    actions.create_review("One")
    local model = require("code-review.model")
    local review = model.find_review(state.get().store, state.get().active_review_id)
    local comment = model.new_comment()
    comment.body = "selected"
    table.insert(comment.file_references, model.new_file_reference({
      relative_path = "x.lua",
      start_line = 1,
      end_line = 1,
      selected_lines_snapshot = { "x" },
    }))
    table.insert(review.comments, comment)
    actions.create_review("Two")
    assert.equals("comment_list", state.mode())
    assert.equals(2, #state.get().store.reviews)
    assert.equals("Two", require("code-review.model").find_review(state.get().store, state.get().active_review_id).name)
    code_review.quit()
  end)

  it("deletes the active review and selects the next newest review", function()
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
    actions.create_review("One")
    local one = state.get().active_review_id
    actions.create_review("Two")
    local old_select = vim.ui.select
    vim.ui.select = function(_, _, cb)
      cb("Delete")
    end
    actions.delete_review()
    vim.ui.select = old_select
    assert.equals(1, #state.get().store.reviews)
    assert.equals(one, state.get().active_review_id)
    code_review.quit()
  end)

  it("exits Review Mode when cancelling initial review name input", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "x" }, project .. "/x.lua")
    config.setup({ storage = { dir = project .. "/store" } })
    vim.cmd.edit(project .. "/x.lua")
    local old_input = vim.ui.input
    vim.ui.input = function(_, cb)
      cb(nil)
    end
    code_review.start()
    require("code-review.review_picker").open()
    vim.ui.input = old_input
    assert.is_false(code_review.is_active())
  end)

  it("starts and stops the sidebar refresh timer with Review Mode", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "x" }, project .. "/x.lua")
    config.setup({ storage = { dir = project .. "/store" } })
    vim.cmd.edit(project .. "/x.lua")

    code_review.start()

    local timer = state.get().sidebar_timer
    assert.truthy(timer)
    assert.is_false(timer:is_closing())

    code_review.quit()

    assert.falsy(state.get().sidebar_timer)
    assert.is_true(timer:is_closing())
  end)

  it("restores the previous active-review mode when cancelling review picker", function()
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
    actions.create_review("One")
    local review = require("code-review.model").find_review(state.get().store, state.get().active_review_id)
    local model = require("code-review.model")
    local comment = model.new_comment()
    comment.body = "ready"
    table.insert(comment.file_references, model.new_file_reference({
      relative_path = "x.lua",
      start_line = 1,
      end_line = 1,
      selected_lines_snapshot = { "x" },
    }))
    table.insert(review.comments, comment)
    actions.preview()
    assert.equals("preview", state.mode())
    local old_select = vim.ui.select
    vim.ui.select = function(_, _, cb)
      cb(nil)
    end
    require("code-review.review_picker").open()
    vim.ui.select = old_select
    assert.equals("preview", state.mode())
    code_review.quit()
  end)
end)
