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

  it("rejects regex-shaped but impossible UTC timestamps", function()
    assert.is_false(time.is_iso_utc("2026-02-29T00:00:00Z"))
    assert.is_false(time.is_iso_utc("2026-04-31T00:00:00Z"))
    assert.is_false(time.is_iso_utc("2026-01-01T24:00:00Z"))
    assert.is_false(time.is_iso_utc("2026-01-01T00:60:00Z"))
    assert.is_false(time.is_iso_utc("2026-01-01T00:00:60Z"))
    assert.is_true(time.is_iso_utc("2024-02-29T23:59:59Z"))
  end)
end)
