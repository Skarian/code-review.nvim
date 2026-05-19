describe("model", function()
  it("creates reviews and comments", function()
    local model = require("code-review.model")
    local review = model.new_review("  Test  ", "2026-05-18T00:00:00Z")
    assert.equals("Test", review.name)
    local comment = model.new_comment("2026-05-18T00:00:01Z")
    assert.is_false(model.comment_complete(comment))
    comment.body = "Looks wrong"
    table.insert(comment.file_references, model.new_file_reference({
      relative_path = "lua/example.lua",
      start_line = 1,
      end_line = 2,
      selected_lines_snapshot = { "a", "b" },
    }, "2026-05-18T00:00:02Z"))
    assert.is_true(model.comment_complete(comment))
  end)
end)
