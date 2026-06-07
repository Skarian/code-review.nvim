describe("storage", function()
  it("loads missing stores as empty schema v1", function()
    local config = require("code-review.config")
    local storage = require("code-review.storage")
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    config.setup({ storage = { dir = dir } })
    local handle = storage.load(vim.fn.getcwd())
    assert.equals(1, handle.store.schema_version)
    assert.equals({}, handle.store.reviews)
  end)

  it("saves and reloads stores atomically", function()
    local config = require("code-review.config")
    local storage = require("code-review.storage")
    local model = require("code-review.model")
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    config.setup({ storage = { dir = dir } })
    local handle = storage.load(vim.fn.getcwd())
    table.insert(handle.store.reviews, model.new_review("Persist", "2026-05-18T00:00:00Z"))
    storage.mark_dirty(handle)
    assert.is_true(storage.flush(handle))
    local reloaded = storage.load(vim.fn.getcwd())
    assert.equals("Persist", reloaded.store.reviews[1].name)
  end)

  it("backs up corrupt stores and creates a fresh store", function()
    local config = require("code-review.config")
    local storage = require("code-review.storage")
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    config.setup({ storage = { dir = dir } })
    local path = storage.path_for(vim.fn.getcwd())
    vim.fn.writefile({ "{" }, path)
    local handle = storage.load(vim.fn.getcwd())
    assert.equals(1, handle.store.schema_version)
    local backups = vim.fn.glob(dir .. "/*.corrupt-*.json", false, true)
    assert.equals(1, #backups)
  end)

  it("reports write failures without marking the store clean", function()
    local storage = require("code-review.storage")
    local model = require("code-review.model")
    local blocker = vim.fn.tempname()
    vim.fn.writefile({ "not a directory" }, blocker)
    local handle = {
      path = blocker .. "/store.json",
      store = model.new_store("/tmp/project", "abc"),
      dirty = true,
    }
    local old_notify = vim.notify
    local messages = {}
    vim.notify = function(message)
      messages[#messages + 1] = message
    end

    local ok = storage.save(handle)

    vim.notify = old_notify
    assert.is_false(ok)
    assert.is_true(handle.dirty)
    assert.truthy(messages[1]:find("Could not create Code Review storage directory", 1, true))
  end)
end)
