describe("health and clear data", function()
  it("reports health checks without opening microphone", function()
    require("code-review.config").setup({ voice = { helper_path = "/missing/code-review-helper.js" } })
    local health = require("code-review.health")
    local checks = health.checks()
    assert.truthy(checks[1])
    local has_helper = false
    for _, check in ipairs(checks) do
      if check.name == "voice_helper" then
        has_helper = true
        assert.equals("warn", check.status)
        assert.equals("Voice helper missing: run :Lazy build code-review.nvim", check.message)
      end
    end
    assert.is_true(has_helper)
  end)

  it("includes voice helper health JSON when helper is available", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local helper = dir .. "/helper.mjs"
    vim.fn.writefile({
      "console.log(JSON.stringify({ checks: [",
      "  { name: 'credentials', status: 'warn', message: 'Codex auth not found' },",
      "  { name: 'audio_provider', status: 'warn', message: 'Health does not open the microphone.' }",
      "] }))",
    }, helper)
    require("code-review.config").setup({ voice = { helper_path = helper } })
    local checks = require("code-review.health").checks()
    local found_credentials = false
    local found_audio = false
    for _, check in ipairs(checks) do
      if check.name == "voice_credentials" then
        found_credentials = true
        assert.equals("warn", check.status)
      elseif check.name == "voice_audio_provider" then
        found_audio = true
        assert.equals("warn", check.status)
      end
    end
    assert.is_true(found_credentials)
    assert.is_true(found_audio)
  end)

  it("passes no-network flag to helper health when disabled", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local helper = dir .. "/helper.mjs"
    local args_file = dir .. "/args.txt"
    vim.fn.writefile({
      "import { writeFileSync } from 'node:fs';",
      "writeFileSync(" .. vim.inspect(args_file) .. ", process.argv.slice(2).join(' '));",
      "console.log(JSON.stringify({ checks: [] }))",
    }, helper)
    require("code-review.config").setup({ voice = { helper_path = helper }, health = { network = false } })
    require("code-review.health").checks()
    local args = table.concat(vim.fn.readfile(args_file), "\n")
    assert.truthy(args:find("--no-network", 1, true))
  end)

  it("probes storage for the active Review root", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local project = vim.fn.tempname()
    local other = vim.fn.tempname()
    local store = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.mkdir(other .. "/.git", "p")
    vim.fn.writefile({ "x" }, project .. "/x.lua")
    vim.fn.writefile({ "y" }, other .. "/y.lua")
    config.setup({ storage = { dir = store }, voice = { helper_path = "/missing/code-review-helper.js" } })
    vim.cmd.edit(project .. "/x.lua")
    code_review.start()
    vim.cmd.edit(other .. "/y.lua")
    local checks = require("code-review.health").checks()
    local storage_message
    for _, check in ipairs(checks) do
      if check.name == "storage" then
        storage_message = check.message
      end
    end
    local expected_hash = require("code-review.root").hash(require("code-review.state").get().root)
    assert.truthy(storage_message:find(expected_hash, 1, true))
    code_review.quit()
  end)

  it("clear data removes only the current store after confirmation", function()
    local code_review = require("code-review")
    local config = require("code-review.config")
    local storage = require("code-review.storage")
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local project = vim.fn.tempname()
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.writefile({ "x" }, project .. "/x.lua")
    vim.cmd.edit(project .. "/x.lua")
    config.setup({ storage = { dir = dir } })
    local root = require("code-review.root").detect(0)
    local handle = storage.load(root)
    storage.mark_dirty(handle)
    storage.flush(handle)
    assert.equals(1, vim.fn.filereadable(handle.path))
    local old_select = vim.ui.select
    vim.ui.select = function(_, _, cb)
      cb("Delete")
    end
    code_review.clear_data()
    vim.ui.select = old_select
    assert.equals(0, vim.fn.filereadable(handle.path))
  end)
end)
