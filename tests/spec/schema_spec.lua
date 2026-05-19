describe("schema", function()
  it("validates a fresh store", function()
    local model = require("code-review.model")
    local schema = require("code-review.schema")
    local store = model.new_store("/tmp/project", "abc")
    local result = schema.validate(store, "abc")
    assert.is_true(result.ok)
    assert.equals(store, result.store)
  end)

  it("rejects future schema without corrupting", function()
    local schema = require("code-review.schema")
    local result = schema.validate({ schema_version = 99, project_root_hash = "abc" }, "abc")
    assert.is_false(result.ok)
    assert.equals("unsupported_schema", result.kind)
  end)

  it("treats missing root hash as corrupt before root mismatch", function()
    local schema = require("code-review.schema")
    local result = schema.validate({ schema_version = 1, project_root = "/tmp/project", reviews = {} }, "abc")
    assert.is_false(result.ok)
    assert.equals("corrupt", result.kind)
  end)

  it("normalizes stale references without reasons to unknown", function()
    local model = require("code-review.model")
    local schema = require("code-review.schema")
    local store = model.new_store("/tmp/project", "abc")
    local review = model.new_review("Schema")
    local comment = model.new_comment()
    comment.body = "body"
    table.insert(comment.file_references, model.new_file_reference({
      relative_path = "a.lua",
      start_line = 1,
      end_line = 1,
      selected_lines_snapshot = { "x" },
      stale_state = "stale",
      stale_reason = nil,
    }))
    table.insert(review.comments, comment)
    table.insert(store.reviews, review)
    local result = schema.validate(store, "abc")
    assert.is_true(result.ok)
    assert.equals("unknown", comment.file_references[1].stale_reason)
  end)
end)
