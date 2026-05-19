describe("time", function()
  local time = require("code-review.time")

  it("formats sub-minute comment ages as zero minutes", function()
    local value = "1970-01-01T00:00:00Z"

    assert.equals("0m ago", time.relative(value, 0))
    assert.equals("0m ago", time.relative(value, 59))
    assert.equals("1m ago", time.relative(value, 60))
  end)

  it("interprets Z timestamps as UTC instead of local time", function()
    assert.equals("3m ago", time.relative("1970-01-01T00:00:00Z", 180))
  end)
end)
