local model = require("code-review.model")
local notify = require("code-review.notify")
local preview = require("code-review.preview")
local state = require("code-review.state")
local storage = require("code-review.storage")
local time = require("code-review.time")
local ui = require("code-review.ui")

local M = {}

M.adapter = {}

local function active_review()
  local s = state.get()
  return model.find_review(s.store, s.active_review_id)
end

local function persist()
  local s = state.get()
  storage.mark_dirty(s.storage)
  require("code-review.sidebar").render()
  require("code-review.highlights").refresh_all()
end

local function first_body_line(comment)
  for _, line in ipairs(vim.split(comment.body or "", "\n", { plain = true })) do
    line = vim.trim(line)
    if line ~= "" then
      return line
    end
  end
  return "(empty)"
end

local function render_comment(comment)
  local review = model.new_review("Selected")
  review.comments = { vim.deepcopy(comment) }
  local rendered = preview.render_review(review)
  local lines = vim.split(rendered, "\n", { plain = true })
  return table.concat(vim.list_slice(lines, 3), "\n")
end

local function items_for(review)
  local items = {}
  for _, comment in ipairs(model.comments_newest(review)) do
    items[#items + 1] = {
      comment = comment,
      label = string.format("%s  %s", time.relative(comment.updated_at), first_body_line(comment)),
      preview = render_comment(comment),
    }
  end
  return items
end

function M.adapter.pick_comments(items, callbacks)
  ui.pick_comments(items, callbacks)
end

local function delete_comment(comment)
  local review = active_review()
  if not review then
    return
  end
  vim.ui.select({ "Delete", "Cancel" }, { prompt = "Delete Comment?" }, function(choice)
    if choice ~= "Delete" then
      return
    end
    for index, item in ipairs(review.comments) do
      if item.id == comment.id then
        table.remove(review.comments, index)
        break
      end
    end
    model.touch_review(review)
    persist()
  end)
end

local function jump_to_comment(comment)
  local s = state.get()
  local ref = comment.file_references and comment.file_references[1]
  if not ref then
    notify.warn("Comment has no File References.")
    return
  end
  vim.cmd.edit(vim.fs.joinpath(s.root, ref.relative_path))
  vim.api.nvim_win_set_cursor(0, { ref.start_line, 0 })
  require("code-review.sidebar").render()
  require("code-review.highlights").refresh()
end

local function append_reference(comment, reference)
  local review = active_review()
  if not review then
    return
  end
  comment = model.find_comment(review, comment.id)
  if not comment then
    notify.warn("Comment no longer exists.")
    return
  end
  table.insert(comment.file_references, reference)
  model.touch_comment(review, comment)
  persist()
end

function M.open(opts)
  opts = opts or {}
  local review = active_review()
  if not review then
    notify.warn("Create or select a Review first.")
    return
  end
  local items = items_for(review)
  if #items == 0 then
    notify.warn("No Comments in this Review.")
    return
  end
  M.adapter.pick_comments(items, {
    select = function(item)
      if opts.append_reference then
        append_reference(item.comment, opts.append_reference)
      else
        require("code-review.composer").open_edit(item.comment)
      end
    end,
    delete = function(item)
      delete_comment(item.comment)
    end,
    jump = function(item)
      jump_to_comment(item.comment)
    end,
    cancel = function()
      state.set_mode("comment_list")
    end,
  })
end

return M
