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
    assert_mapped("<leader>rc", "n")
    assert_mapped("<leader>ro", "n")
    assert_mapped("<leader>rm", "n")
    assert_mapped("<leader>rR", "n")
    assert_mapped("<leader>ra", "n")
    assert_mapped("<leader>ra", "x")
    assert_mapped("<leader>rt", "n")
    assert.equals("", vim.fn.maparg("<leader>rq", "n"))
  end)

  it("toggles Review Mode through the default child action", function()
    local code_review = require("code-review")
    local actions = require("code-review.actions")
    local review_picker = require("code-review.review_picker")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "x" }, project .. "/x.lua")
    code_review.setup({ storage = { dir = project .. "/store" }, keymaps = { prefix = "<leader>r" } })
    vim.cmd.edit(project .. "/x.lua")

    local old_open = review_picker.open
    review_picker.open = function() end
    actions.dispatch("toggle")
    assert.is_true(code_review.is_active())

    actions.dispatch("toggle")
    review_picker.open = old_open
    assert.is_false(code_review.is_active())
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

  it("deletes all reviews from the review picker after confirmation", function()
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
    actions.create_review("Two")
    local store = state.get().store
    local old_select = vim.ui.select
    local old_input = vim.ui.input
    vim.ui.select = function(items, opts, cb)
      if opts.prompt == "Code Review" then
        for _, item in ipairs(items) do
          if item.id == "__delete_all" then
            cb(item)
            return
          end
        end
      else
        cb("Delete All")
      end
    end
    local prompted_for_name = false
    vim.ui.input = function(_, cb)
      prompted_for_name = true
      cb(nil)
    end

    require("code-review.review_picker").open()

    vim.ui.select = old_select
    vim.ui.input = old_input
    assert.equals(0, #store.reviews)
    assert.equals(nil, store.last_active_review_id)
    assert.is_true(prompted_for_name)
    assert.is_false(code_review.is_active())
  end)

  it("keeps all reviews when deleting all is cancelled", function()
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
    actions.create_review("Two")
    local active = state.get().active_review_id
    local old_select = vim.ui.select
    vim.ui.select = function(_, _, cb)
      cb("Cancel")
    end

    actions.delete_all_reviews()

    vim.ui.select = old_select
    assert.equals(2, #state.get().store.reviews)
    assert.equals(active, state.get().active_review_id)
    assert.equals("comment_list", state.mode())
    code_review.quit()
  end)

  it("restores the previous mode when delete all is cancelled from the review picker", function()
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
    local old_select = vim.ui.select
    vim.ui.select = function(items, opts, cb)
      if opts.prompt == "Code Review" then
        for _, item in ipairs(items) do
          if item.id == "__delete_all" then
            cb(item)
            return
          end
        end
      else
        cb("Cancel")
      end
    end

    require("code-review.review_picker").open()

    vim.ui.select = old_select
    assert.equals(1, #state.get().store.reviews)
    assert.equals("comment_list", state.mode())
    code_review.quit()
  end)

  it("restores the previous mode when delete current is cancelled from the review picker", function()
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
    local old_select = vim.ui.select
    vim.ui.select = function(items, opts, cb)
      if opts.prompt == "Code Review" then
        for _, item in ipairs(items) do
          if item.id == "__delete" then
            cb(item)
            return
          end
        end
      else
        cb("Cancel")
      end
    end

    require("code-review.review_picker").open()

    vim.ui.select = old_select
    assert.equals(1, #state.get().store.reviews)
    assert.equals("comment_list", state.mode())
    code_review.quit()
  end)

  it("ignores stale delete-all confirmations after Review Mode exits", function()
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
    local store = state.get().store
    local deferred
    local old_select = vim.ui.select
    vim.ui.select = function(_, _, cb)
      deferred = cb
    end

    actions.delete_all_reviews()
    code_review.quit()
    deferred("Delete All")

    vim.ui.select = old_select
    assert.equals(1, #store.reviews)
    assert.is_false(code_review.is_active())
  end)

  it("ignores stale delete-all cancellation after Review Mode restarts", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local state = require("code-review.state")
    local project_a = vim.fn.tempname()
    local project_b = vim.fn.tempname()
    vim.fn.mkdir(project_a .. "/.git", "p")
    vim.fn.mkdir(project_b .. "/.git", "p")
    vim.fn.writefile({ "x" }, project_a .. "/x.lua")
    vim.fn.writefile({ "x" }, project_b .. "/x.lua")
    config.setup({ storage = { dir = vim.fn.tempname() .. "/store" } })
    vim.cmd.edit(project_a .. "/x.lua")
    code_review.start()
    actions.create_review("One")
    state.set_mode("preview")
    local deferred
    local old_select = vim.ui.select
    vim.ui.select = function(items, opts, cb)
      if opts.prompt == "Code Review" then
        for _, item in ipairs(items) do
          if item.id == "__delete_all" then
            cb(item)
            return
          end
        end
      else
        deferred = cb
      end
    end

    require("code-review.review_picker").open()
    vim.ui.select = old_select
    code_review.quit()
    vim.cmd.edit(project_b .. "/x.lua")
    code_review.start()
    actions.create_review("Two")
    local session_id = state.get().session_id
    deferred("Cancel")

    assert.is_true(code_review.is_active())
    assert.equals(session_id, state.get().session_id)
    assert.equals("comment_list", state.mode())
    assert.equals(1, #state.get().store.reviews)
    code_review.quit()
  end)

  it("ignores superseded picker delete-all confirmations", function()
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
    actions.create_review("Two")
    local deferred
    local old_select = vim.ui.select
    local old_input = vim.ui.input
    vim.ui.select = function(items, opts, cb)
      if opts.prompt == "Code Review" then
        for _, item in ipairs(items) do
          if item.id == "__delete_all" then
            cb(item)
            return
          end
        end
      else
        deferred = cb
      end
    end
    vim.ui.input = function(_, cb)
      cb(nil)
    end

    require("code-review.review_picker").open()
    vim.ui.select = function() end
    require("code-review.review_picker").open()
    deferred("Delete All")

    vim.ui.select = old_select
    vim.ui.input = old_input
    assert.is_true(code_review.is_active())
    assert.equals(2, #state.get().store.reviews)
    assert.equals("review_picker", state.mode())
    code_review.quit()
  end)

  it("ignores superseded picker delete-all cancellations", function()
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
    actions.create_review("Two")
    local deferred
    local old_select = vim.ui.select
    vim.ui.select = function(items, opts, cb)
      if opts.prompt == "Code Review" then
        for _, item in ipairs(items) do
          if item.id == "__delete_all" then
            cb(item)
            return
          end
        end
      else
        deferred = cb
      end
    end

    require("code-review.review_picker").open()
    vim.ui.select = function() end
    require("code-review.review_picker").open()
    state.set_mode("comment_list")
    deferred("Cancel")

    vim.ui.select = old_select
    assert.equals("comment_list", state.mode())
    assert.equals(2, #state.get().store.reviews)
    code_review.quit()
  end)

  it("ignores stale review picker cancellation after the mode changes", function()
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
    state.set_mode("preview")
    local deferred
    local old_select = vim.ui.select
    vim.ui.select = function(_, _, cb)
      deferred = cb
    end

    require("code-review.review_picker").open()
    vim.ui.select = old_select
    state.set_mode("comment_list")
    deferred(nil)

    assert.equals("comment_list", state.mode())
    assert.is_true(code_review.is_active())
    code_review.quit()
  end)

  it("ignores stale review picker selections after the mode changes", function()
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
    local original = state.get().active_review_id
    actions.create_review("Two")
    actions.select_review(original)
    state.set_mode("preview")
    local deferred
    local picker_items
    local old_select = vim.ui.select
    vim.ui.select = function(items, _, cb)
      picker_items = items
      deferred = cb
    end

    require("code-review.review_picker").open()
    vim.ui.select = old_select
    state.set_mode("comment_list")
    for _, item in ipairs(picker_items) do
      if item.id and item.id ~= "__new" and item.id ~= "__delete" and item.id ~= "__delete_all" and item.id ~= original then
        deferred(item)
        break
      end
    end

    assert.equals(original, state.get().active_review_id)
    assert.equals("comment_list", state.mode())
    code_review.quit()
  end)

  it("ignores stale delete-review confirmations after Review Mode exits", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "x" }, project .. "/x.lua")
    config.setup({ storage = { dir = project .. "/store" } })
    vim.cmd.edit(project .. "/x.lua")
    code_review.start()
    actions.create_review("One")
    local store = require("code-review.state").get().store
    local deferred
    local old_select = vim.ui.select
    vim.ui.select = function(_, _, cb)
      deferred = cb
    end

    actions.delete_review()
    vim.ui.select = old_select
    code_review.quit()
    local ok = pcall(function()
      deferred("Delete")
    end)

    assert.is_true(ok)
    assert.equals(1, #store.reviews)
    assert.is_false(code_review.is_active())
  end)

  it("ignores stale delete-review confirmations after active review changes", function()
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
    actions.create_review("Two")
    local stale_review = state.get().active_review_id
    local deferred
    local old_select = vim.ui.select
    vim.ui.select = function(_, _, cb)
      deferred = cb
    end

    actions.delete_review()
    vim.ui.select = old_select
    for _, review in ipairs(state.get().store.reviews) do
      if review.id ~= stale_review then
        actions.select_review(review.id)
        break
      end
    end
    deferred("Delete")

    assert.truthy(require("code-review.model").find_review(state.get().store, stale_review))
    assert.equals(2, #state.get().store.reviews)
    code_review.quit()
  end)

  it("ignores superseded picker delete-current confirmations", function()
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
    actions.create_review("Two")
    local active = state.get().active_review_id
    local deferred
    local old_select = vim.ui.select
    vim.ui.select = function(items, opts, cb)
      if opts.prompt == "Code Review" then
        for _, item in ipairs(items) do
          if item.id == "__delete" then
            cb(item)
            return
          end
        end
      else
        deferred = cb
      end
    end

    require("code-review.review_picker").open()
    vim.ui.select = function() end
    require("code-review.review_picker").open()
    deferred("Delete")

    vim.ui.select = old_select
    assert.truthy(require("code-review.model").find_review(state.get().store, active))
    assert.equals(2, #state.get().store.reviews)
    assert.equals("review_picker", state.mode())
    code_review.quit()
  end)

  it("ignores superseded picker delete-current cancellations", function()
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
    local deferred
    local old_select = vim.ui.select
    vim.ui.select = function(items, opts, cb)
      if opts.prompt == "Code Review" then
        for _, item in ipairs(items) do
          if item.id == "__delete" then
            cb(item)
            return
          end
        end
      else
        deferred = cb
      end
    end

    require("code-review.review_picker").open()
    vim.ui.select = function() end
    require("code-review.review_picker").open()
    state.set_mode("comment_list")
    deferred("Cancel")

    vim.ui.select = old_select
    assert.equals("comment_list", state.mode())
    assert.equals(1, #state.get().store.reviews)
    code_review.quit()
  end)

  it("ignores stale review-name input after Review Mode restarts", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local state = require("code-review.state")
    local project_a = vim.fn.tempname()
    local project_b = vim.fn.tempname()
    vim.fn.mkdir(project_a .. "/.git", "p")
    vim.fn.mkdir(project_b .. "/.git", "p")
    vim.fn.writefile({ "x" }, project_a .. "/x.lua")
    vim.fn.writefile({ "x" }, project_b .. "/x.lua")
    config.setup({ storage = { dir = vim.fn.tempname() .. "/store" } })
    vim.cmd.edit(project_a .. "/x.lua")
    code_review.start()
    actions.create_review("One")
    local deferred_input
    local old_select = vim.ui.select
    local old_input = vim.ui.input
    vim.ui.select = function(items, opts, cb)
      if opts.prompt == "Code Review" then
        for _, item in ipairs(items) do
          if item.id == "__new" then
            cb(item)
            return
          end
        end
      end
    end
    vim.ui.input = function(_, cb)
      deferred_input = cb
    end

    require("code-review.review_picker").open()
    vim.ui.select = old_select
    vim.ui.input = old_input
    code_review.quit()
    vim.cmd.edit(project_b .. "/x.lua")
    code_review.start()
    actions.create_review("Two")
    deferred_input("Stale")

    assert.equals(1, #state.get().store.reviews)
    assert.equals("Two", state.get().store.reviews[1].name)
    code_review.quit()
  end)

  it("blocks delete all while preview is open", function()
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
    actions.create_review("One")
    local review = model.find_review(state.get().store, state.get().active_review_id)
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
    local preview_buf = state.get().preview.buf
    local old_notify = vim.notify
    local messages = {}
    vim.notify = function(message)
      messages[#messages + 1] = message
    end

    actions.delete_all_reviews()

    vim.notify = old_notify
    assert.equals("Close the preview before deleting all Reviews.", messages[1])
    assert.equals(1, #state.get().store.reviews)
    assert.equals("preview", state.mode())
    assert.equals(preview_buf, state.get().preview.buf)
    code_review.quit()
  end)

  it("returns to preview when delete all is blocked from the review picker", function()
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
    actions.create_review("One")
    local review = model.find_review(state.get().store, state.get().active_review_id)
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
    local old_select = vim.ui.select
    local old_notify = vim.notify
    local messages = {}
    vim.ui.select = function(items, opts, cb)
      if opts.prompt == "Code Review" then
        for _, item in ipairs(items) do
          if item.id == "__delete_all" then
            cb(item)
            return
          end
        end
      end
    end
    vim.notify = function(message)
      messages[#messages + 1] = message
    end

    require("code-review.review_picker").open()

    vim.ui.select = old_select
    vim.notify = old_notify
    assert.equals("Close the preview before deleting all Reviews.", messages[1])
    assert.equals("preview", state.mode())
    assert.equals(1, #state.get().store.reviews)
    code_review.quit()
  end)

  it("blocks delete current while preview is open", function()
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
    actions.create_review("One")
    actions.create_review("Two")
    local active = state.get().active_review_id
    local review = model.find_review(state.get().store, active)
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
    local preview_buf = state.get().preview.buf
    local old_notify = vim.notify
    local messages = {}
    vim.notify = function(message)
      messages[#messages + 1] = message
    end

    actions.delete_review()

    vim.notify = old_notify
    assert.equals("Close the preview before deleting Reviews.", messages[1])
    assert.equals(active, state.get().active_review_id)
    assert.equals(2, #state.get().store.reviews)
    assert.equals("preview", state.mode())
    assert.equals(preview_buf, state.get().preview.buf)
    code_review.quit()
  end)

  it("returns to preview when delete current is blocked from the review picker", function()
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
    actions.create_review("One")
    actions.create_review("Two")
    local active = state.get().active_review_id
    local review = model.find_review(state.get().store, active)
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
    local preview_buf = state.get().preview.buf
    local old_select = vim.ui.select
    local old_notify = vim.notify
    local messages = {}
    vim.ui.select = function(items, opts, cb)
      if opts.prompt == "Code Review" then
        for _, item in ipairs(items) do
          if item.id == "__delete" then
            cb(item)
            return
          end
        end
      end
    end
    vim.notify = function(message)
      messages[#messages + 1] = message
    end

    require("code-review.review_picker").open()

    vim.ui.select = old_select
    vim.notify = old_notify
    assert.equals("Close the preview before deleting Reviews.", messages[1])
    assert.equals(active, state.get().active_review_id)
    assert.equals(2, #state.get().store.reviews)
    assert.equals("preview", state.mode())
    assert.equals(preview_buf, state.get().preview.buf)
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
