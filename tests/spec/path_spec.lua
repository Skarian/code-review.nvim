describe("path helpers", function()
  local path = require("code-review.path")

  it("normalizes Windows drive-letter paths with slash and case differences", function()
    path._set_windows_for_tests(true)
    local rel = path.relative([[C:\Repo]], [[c:\Repo\src\file.lua]])
    path._set_windows_for_tests(nil)

    assert.equals("src/file.lua", rel)
  end)

  it("does not treat same-prefix Windows paths as inside the root", function()
    path._set_windows_for_tests(true)
    local rel = path.relative([[C:\Repo]], [[C:\Repository\file.lua]])
    path._set_windows_for_tests(nil)

    assert.equals(nil, rel)
  end)
end)
