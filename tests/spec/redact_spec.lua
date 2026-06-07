describe("redaction", function()
  it("redacts credentials and audio paths from text", function()
    local redact = require("code-review.redact")
    local text = redact.text("Bearer secret.token eyJabc.def.sig /tmp/code-review/recording.wav C:\\Temp\\recording.wav")

    assert.falsy(text:find("secret.token", 1, true))
    assert.falsy(text:find("eyJabc.def.sig", 1, true))
    assert.falsy(text:find("/tmp/code-review/recording.wav", 1, true))
    assert.falsy(text:find("C:\\Temp\\recording.wav", 1, true))
    assert.truthy(text:find("[REDACTED_AUDIO_PATH]", 1, true))
  end)

  it("redacts Comment bodies and selected snapshots from structured Review data", function()
    local redact = require("code-review.redact")
    local review = {
      name = "Review",
      comments = {
        {
          body = "secret comment body",
          file_references = {
            {
              relative_path = "x.lua",
              selected_lines_snapshot = { "secret source line" },
            },
          },
        },
      },
    }

    local redacted = redact.review_data(review)

    assert.equals("secret comment body", review.comments[1].body)
    assert.equals("[REDACTED_COMMENT_BODY]", redacted.comments[1].body)
    assert.same({ "[REDACTED_SELECTED_LINES]" }, redacted.comments[1].file_references[1].selected_lines_snapshot)
    assert.equals("x.lua", redacted.comments[1].file_references[1].relative_path)
  end)
end)
