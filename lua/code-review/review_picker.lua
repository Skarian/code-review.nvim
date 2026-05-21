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
    table.insert(items, 3, { id = "__delete_all", name = "Delete all Reviews", updated_at = "" })
  end
  vim.ui.select(items, {
    prompt = "Code Review",
    format_item = function(item)
      if item.updated_at == "" then
        return item.name
      end
      return item.name .. " (" .. item.updated_at .. ")"
    end,
  }, function(choice)
    if choice and choice.id == "__new" then
      callbacks.create()
    elseif choice and choice.id == "__delete" then
      callbacks.delete()
    elseif choice and choice.id == "__delete_all" then
      callbacks.delete_all()
    elseif choice then
      callbacks.select(choice)
    elseif callbacks.cancel then
      callbacks.cancel()
    end
  end)
end

function M.adapter.input_review_name(callback, cancel)
  vim.ui.input({ prompt = "New Review Name: " }, function(value)
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
  local session_id = s.session_id
  local root = s.root
  local store = s.store
  local function start_request()
    local request_id = state.next_picker_request_id()
    return function()
      local current = state.get()
      return current.active
        and current.session_id == session_id
        and current.root == root
        and current.store == store
        and state.picker_request_id() == request_id
        and current.mode == "review_picker"
    end
  end
  local function restore_or_quit(still_current)
    if not still_current() then
      return
    end
    if s.active_review_id then
      state.set_mode(previous_mode)
    else
      require("code-review").quit()
    end
  end
  if #reviews == 0 then
    state.set_mode("review_picker")
    local still_current = start_request()
    M.adapter.input_review_name(function(name)
      if not still_current() then
        return
      end
      require("code-review.actions").create_review(name)
    end, function()
      restore_or_quit(still_current)
    end)
    return
  end
  state.set_mode("review_picker")
  local still_current = start_request()
  M.adapter.pick_review(reviews, {
    create = function()
      if not still_current() then
        return
      end
      M.adapter.input_review_name(function(name)
        if not still_current() then
          return
        end
        require("code-review.actions").create_review(name)
      end, function()
        restore_or_quit(still_current)
      end)
    end,
    delete = function()
      if not still_current() then
        return
      end
      require("code-review.actions").delete_review({
        cancel = function()
          restore_or_quit(still_current)
        end,
        request_current = still_current,
      })
    end,
    delete_all = function()
      if not still_current() then
        return
      end
      require("code-review.actions").delete_all_reviews({
        cancel = function()
          restore_or_quit(still_current)
        end,
        request_current = still_current,
      })
    end,
    select = function(review)
      if not still_current() then
        return
      end
      require("code-review.actions").select_review(review.id)
    end,
    cancel = function()
      restore_or_quit(still_current)
    end,
  })
end

return M
