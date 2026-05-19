describe("comment picker", function()
  local function start_project()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local model = require("code-review.model")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "one", "two", "three", "four" }, project .. "/x.lua")
    config.setup({ storage = { dir = project .. "/store" } })
    vim.cmd.edit(project .. "/x.lua")
    code_review.start()
    actions.create_review("Picker")
    local review = model.find_review(state.get().store, state.get().active_review_id)
    return code_review, actions, model, state, review
  end

  local function add_comment(model, review, body, line, updated_at)
    local comment = model.new_comment("2026-05-18T00:00:00Z")
    comment.body = body
    comment.updated_at = updated_at
    table.insert(comment.file_references, model.new_file_reference({
      relative_path = "x.lua",
      start_line = line,
      end_line = line,
      selected_lines_snapshot = { tostring(line) },
    }))
    table.insert(review.comments, comment)
    return comment
  end

  it("opens edit composer from newest-first picker items with previews", function()
    local code_review, actions, model, state, review = start_project()
    local older = add_comment(model, review, "older body", 1, "2026-05-18T00:00:01Z")
    local newer = add_comment(model, review, "newer body", 2, "2026-05-18T00:00:02Z")
    local picker = require("code-review.comment_picker")
    local old_pick = picker.adapter.pick_comments
    picker.adapter.pick_comments = function(items, callbacks)
      assert.equals(newer.id, items[1].comment.id)
      assert.equals(older.id, items[2].comment.id)
      assert.truthy(items[1].preview:find("x.lua:2-2", 1, true))
      callbacks.select(items[1])
    end
    actions.edit_comment()
    picker.adapter.pick_comments = old_pick
    assert.equals("composer", state.mode())
    assert.equals(newer.id, state.get().composer.target_comment_id)
    vim.api.nvim_buf_set_lines(state.get().composer.body_buf, 0, -1, false, { "edited" })
    require("code-review.composer").submit()
    assert.equals("edited", newer.body)
    assert.equals(2, #review.comments)
    code_review.quit()
  end)

  it("appends a visual reference to the selected existing comment", function()
    local code_review, actions, model, state, review = start_project()
    local comment = add_comment(model, review, "body", 1, "2026-05-18T00:00:01Z")
    local picker = require("code-review.comment_picker")
    local old_pick = picker.adapter.pick_comments
    picker.adapter.pick_comments = function(items, callbacks)
      callbacks.select(items[1])
    end
    vim.fn.setpos("'<", { 0, 3, 1, 0 })
    vim.fn.setpos("'>", { 0, 4, 1, 0 })
    actions.append_reference()
    picker.adapter.pick_comments = old_pick
    assert.equals(1, #review.comments)
    assert.equals(2, #comment.file_references)
    assert.equals(3, comment.file_references[2].start_line)
    assert.equals(4, comment.file_references[2].end_line)
    code_review.quit()
  end)

  it("deletes and jumps to picker comments", function()
    local code_review, _actions, model, state, review = start_project()
    local first = add_comment(model, review, "first", 1, "2026-05-18T00:00:01Z")
    local second = add_comment(model, review, "second", 3, "2026-05-18T00:00:02Z")
    local picker = require("code-review.comment_picker")
    local old_pick = picker.adapter.pick_comments
    local old_select = vim.ui.select
    picker.adapter.pick_comments = function(items, callbacks)
      callbacks.jump(items[1])
      assert.equals(3, vim.api.nvim_win_get_cursor(0)[1])
      vim.ui.select = function(_, _, cb)
        cb("Delete")
      end
      callbacks.delete(items[1])
    end
    picker.open()
    picker.adapter.pick_comments = old_pick
    vim.ui.select = old_select
    assert.equals(1, #review.comments)
    assert.equals(first.id, review.comments[1].id)
    code_review.quit()
  end)
end)
