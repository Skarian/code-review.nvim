vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.shadafile = "NONE"
vim.opt.swapfile = false

local notifications = {}
vim.notify = function(message, level)
  notifications[#notifications + 1] = { message = tostring(message), level = level }
end

local function assert_contains(haystack, needle, message)
  assert(tostring(haystack):find(needle, 1, true), message or ("missing: " .. needle))
end

local function last_notification()
  local item = notifications[#notifications]
  return item and item.message or ""
end

local tmp = vim.fn.tempname()
local project = tmp .. "/project"
vim.fn.mkdir(project .. "/.git", "p")
vim.fn.mkdir(project .. "/lua", "p")
vim.fn.writefile({
  "local a = 1",
  "local b = 2",
  "return a + b",
}, project .. "/lua/example.lua")

local source = project .. "/lua/example.lua"
vim.cmd("lcd " .. vim.fn.fnameescape(project))
vim.cmd("edit " .. vim.fn.fnameescape(source))
local source_buf = vim.api.nvim_get_current_buf()

local code_review = require("code-review")
local actions = require("code-review.actions")
local model = require("code-review.model")
local state = require("code-review.state")
local storage = require("code-review.storage")

code_review.setup({
  storage = { dir = tmp .. "/store" },
  keymaps = { prefix = "<leader>r" },
})

assert(vim.api.nvim_get_commands({})["CodeReview"], "CodeReview command missing")
assert(vim.api.nvim_get_commands({})["CodeReviewHealth"], "CodeReviewHealth command missing")
assert(vim.api.nvim_get_commands({})["CodeReviewClearData"], "CodeReviewClearData command missing")
assert(vim.fn.maparg("<leader>r", "n") == "", "bare parent keymap must not be mapped")
assert(vim.fn.maparg("<leader>rr", "n") ~= "", "open picker keymap missing")
assert(vim.fn.maparg("<leader>ra", "x") ~= "", "add reference keymap missing")

code_review.start()
assert(code_review.is_active(), "Review Mode did not start")
actions.create_review("Smoke test")

vim.fn.setpos("'<", { 0, 1, 1, 0 })
vim.fn.setpos("'>", { 0, 2, 1, 0 })
actions.add_reference()

local s = state.get()
local review = model.find_review(s.store, s.active_review_id)
local comment = model.find_comment(review, s.current_comment_id)
assert(comment and #comment.file_references == 1, "visual File Reference was not added")

actions.preview()
assert(state.mode() ~= "preview", "preview should be blocked while Comment is incomplete")
assert_contains(last_notification(), "1 incomplete comments", "missing incomplete Comment notification")

comment.body = "Check this calculation."
model.touch_comment(review, comment)

actions.preview()
assert(state.mode() == "preview", "preview did not open")
local preview_text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
assert_contains(preview_text, "Review: Smoke test", "preview missing Review title")
assert_contains(preview_text, "lua/example.lua:1-2", "preview missing File Reference")
assert_contains(preview_text, "Check this calculation.", "preview missing body")

require("code-review.preview").close()
vim.api.nvim_set_current_buf(source_buf)
vim.api.nvim_buf_set_lines(source_buf, 0, 1, false, { "local a = 10" })
vim.cmd.write()
actions.preview()
assert(state.mode() ~= "preview", "preview should be blocked when File References are stale")
assert_contains(last_notification(), "stale references detected", "missing stale File Reference notification")
assert(comment.file_references[1].stale_state == "stale", "File Reference was not marked stale")

vim.ui.select = function(items, _opts, on_choice)
  on_choice(items[1])
end
local store_path = storage.path_for(state.get().root)
vim.wait(1000, function()
  return vim.uv.fs_stat(store_path) ~= nil
end)
assert(vim.uv.fs_stat(store_path), "store file was not written")
code_review.clear_data()
assert(not code_review.is_active(), "clear data should exit Review Mode")
assert(not vim.uv.fs_stat(store_path), "clear data did not remove store file")

print("code-review.nvim smoke passed")
