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
    vim.cmd.edit(project .. "/x.lua")
    local source_win = vim.api.nvim_get_current_win()
    code_review.start()
    actions.create_review("Preview")
    vim.fn.setpos("'<", { 0, 1, 1, 0 })
    vim.fn.setpos("'>", { 0, 1, 1, 0 })
    actions.add_reference()
    vim.api.nvim_buf_set_lines(state.get().composer.body_buf, 0, -1, false, { "body" })
    require("code-review.composer").submit()
    return code_review, actions, state, source_win
  end

  local function open_plugin_buffer()
    vim.cmd.enew()
    vim.bo.buftype = "nofile"
    vim.bo.bufhidden = "wipe"
    vim.api.nvim_buf_set_name(0, "Plugin Buffer " .. vim.fn.tempname())
  end

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
    actions.preview()
    assert.equals("preview", state.mode())
    code_review.quit()
    assert.is_false(vim.api.nvim_buf_is_valid(preview_buf))
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
    local code_review, actions, state = make_complete_review()
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
