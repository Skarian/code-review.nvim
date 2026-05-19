describe("staleness and preview", function()
  it("detects content mismatch and blocks preview", function()
    local model = require("code-review.model")
    local stale = require("code-review.stale")
    local preview = require("code-review.preview")

    local project = vim.fn.tempname()
    vim.fn.mkdir(project, "p")
    vim.fn.writefile({ "one", "two" }, project .. "/a.lua")
    local review = model.new_review("Stale", "2026-05-18T00:00:00Z")
    local comment = model.new_comment("2026-05-18T00:00:01Z")
    comment.body = "body"
    table.insert(comment.file_references, model.new_file_reference({
      relative_path = "a.lua",
      start_line = 1,
      end_line = 2,
      selected_lines_snapshot = { "one", "TWO" },
    }, "2026-05-18T00:00:02Z"))
    table.insert(review.comments, comment)

    assert.equals(1, stale.refresh_review(project, review))
    assert.equals("stale", comment.file_references[1].stale_state)
    assert.equals("content_mismatch", comment.file_references[1].stale_reason)
    assert.equals(1, preview.validate(project, review).stale_references)
  end)

  it("uses disk contents instead of modified buffer contents", function()
    local model = require("code-review.model")
    local stale = require("code-review.stale")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project, "p")
    vim.fn.writefile({ "saved" }, project .. "/a.lua")
    vim.cmd.edit(project .. "/a.lua")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved" })
    local review = model.new_review("Modified", "2026-05-18T00:00:00Z")
    local comment = model.new_comment("2026-05-18T00:00:01Z")
    comment.body = "body"
    table.insert(comment.file_references, model.new_file_reference({
      relative_path = "a.lua",
      start_line = 1,
      end_line = 1,
      selected_lines_snapshot = { "saved" },
    }, "2026-05-18T00:00:02Z"))
    table.insert(review.comments, comment)
    assert.equals(0, stale.refresh_review(project, review, 0))
    assert.equals("fresh", comment.file_references[1].stale_state)
    vim.cmd("edit!")
  end)

  it("does not crash highlighting out-of-bounds stale references", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local model = require("code-review.model")
    local highlights = require("code-review.highlights")
    local state = require("code-review.state")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "one" }, project .. "/a.lua")
    config.setup({ storage = { dir = project .. "/store" } })
    vim.cmd.edit(project .. "/a.lua")
    code_review.start()
    actions.create_review("Bounds")
    local review = model.find_review(state.get().store, state.get().active_review_id)
    local comment = model.new_comment("2026-05-18T00:00:00Z")
    comment.body = "body"
    table.insert(comment.file_references, model.new_file_reference({
      relative_path = "a.lua",
      start_line = 1,
      end_line = 99,
      selected_lines_snapshot = { "one" },
      stale_state = "stale",
      stale_reason = "range_out_of_bounds",
    }, "2026-05-18T00:00:01Z"))
    table.insert(review.comments, comment)
    assert.truthy(pcall(highlights.refresh, 0))
    code_review.quit()
  end)

  it("persists stale state found by editor lifecycle refresh", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local actions = require("code-review.actions")
    local model = require("code-review.model")
    local state = require("code-review.state")
    local storage = require("code-review.storage")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "one", "two" }, project .. "/a.lua")
    config.setup({ storage = { dir = project .. "/store" } })
    vim.cmd.edit(project .. "/a.lua")
    code_review.start()
    actions.create_review("Persist stale")
    vim.fn.setpos("'<", { 0, 1, 1, 0 })
    vim.fn.setpos("'>", { 0, 1, 1, 0 })
    actions.add_reference()
    local review = model.find_review(state.get().store, state.get().active_review_id)
    local comment = model.find_comment(review, state.get().current_comment_id)
    comment.body = "body"
    model.touch_comment(review, comment)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "changed" })
    vim.cmd.write()
    assert.equals("stale", comment.file_references[1].stale_state)
    local path = storage.path_for(state.get().root)
    code_review.quit()
    local decoded = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    assert.equals("stale", decoded.reviews[1].comments[1].file_references[1].stale_state)
  end)

  it("renders oldest comments first with file references before body", function()
    local model = require("code-review.model")
    local preview = require("code-review.preview")
    local review = model.new_review("Order", "2026-05-18T00:00:00Z")
    local first = model.new_comment("2026-05-18T00:00:01Z")
    first.body = "first body"
    table.insert(first.file_references, model.new_file_reference({
      relative_path = "a.lua",
      start_line = 1,
      end_line = 1,
      selected_lines_snapshot = { "a" },
    }, "2026-05-18T00:00:01Z"))
    local second = model.new_comment("2026-05-18T00:00:02Z")
    second.body = "second body"
    table.insert(second.file_references, model.new_file_reference({
      relative_path = "b.lua",
      start_line = 2,
      end_line = 3,
      selected_lines_snapshot = { "b", "c" },
    }, "2026-05-18T00:00:02Z"))
    review.comments = { second, first }
    local rendered = preview.render_review(review)
    assert.truthy(rendered:find("a.lua:1-1\nfirst body", 1, true))
    assert.truthy(rendered:find("first body\n\nb.lua:2-3", 1, true))
  end)
end)
