local model = require("code-review.model")
local state = require("code-review.state")

local M = {}

M.adapter = {}

function M.adapter.pick_review(reviews, callbacks)
  local items = vim.deepcopy(reviews)
  model.sort_reviews(items)
  table.insert(items, 1, { id = "__new", name = "Create new Review", updated_at = "" })
  if #reviews > 0 then
    table.insert(items, 2, { id = "__delete", name = "Delete current Review", updated_at = "" })
  end
  vim.ui.select(items, {
    prompt = "Code Review",
    format_item = function(item)
      return item.name .. " (" .. item.updated_at .. ")"
    end,
  }, function(choice)
    if choice and choice.id == "__new" then
      callbacks.create()
    elseif choice and choice.id == "__delete" then
      callbacks.delete()
    elseif choice then
      callbacks.select(choice)
    elseif callbacks.cancel then
      callbacks.cancel()
    end
  end)
end

function M.adapter.input_review_name(callback, cancel)
  vim.ui.input({ prompt = "Review name: " }, function(value)
    if value and vim.trim(value) ~= "" then
      callback(value)
    elseif cancel then
      cancel()
    end
  end)
end

function M.open()
  local s = state.get()
  local previous_mode = s.mode
  local reviews = s.store and s.store.reviews or {}
  if #reviews == 0 then
    state.set_mode("review_picker")
    M.adapter.input_review_name(function(name)
      require("code-review.actions").create_review(name)
    end, function()
      require("code-review").quit()
    end)
    return
  end
  state.set_mode("review_picker")
  M.adapter.pick_review(reviews, {
    create = function()
      M.adapter.input_review_name(function(name)
        require("code-review.actions").create_review(name)
      end, function()
        if s.active_review_id then
          state.set_mode(previous_mode)
        else
          require("code-review").quit()
        end
      end)
    end,
    delete = function()
      require("code-review.actions").delete_review()
    end,
    select = function(review)
      require("code-review.actions").select_review(review.id)
    end,
    cancel = function()
      if s.active_review_id then
        state.set_mode(previous_mode)
      else
        require("code-review").quit()
      end
    end,
  })
end

return M
