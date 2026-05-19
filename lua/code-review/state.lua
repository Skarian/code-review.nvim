local M = {}

local state = {
  active = false,
  mode = "inactive",
  session_id = 0,
  root = nil,
  root_hash = nil,
  store = nil,
  active_review_id = nil,
  current_comment_id = nil,
  current_reference_index = 1,
  sidebar = nil,
  preview = nil,
  editor = nil,
  mappings = {},
  augroup = nil,
  storage = nil,
  voice = nil,
}

function M.get()
  return state
end

function M.mode()
  return state.mode
end

function M.is_active()
  return state.active
end

function M.status()
  return state.active and "REVIEW" or ""
end

function M.set_mode(mode)
  state.mode = mode
end

function M.activate(root, root_hash, store, storage)
  state.active = true
  state.mode = "comment_list"
  state.session_id = state.session_id + 1
  state.root = root
  state.root_hash = root_hash
  state.store = store
  state.storage = storage
  state.active_review_id = store.last_active_review_id
  state.current_comment_id = nil
  state.current_reference_index = 1
end

function M.deactivate()
  state.active = false
  state.mode = "inactive"
  state.session_id = state.session_id + 1
  state.root = nil
  state.root_hash = nil
  state.store = nil
  state.active_review_id = nil
  state.current_comment_id = nil
  state.current_reference_index = 1
  state.storage = nil
  state.voice = nil
end

function M.reset()
  local session_id = state.session_id + 1
  for key in pairs(state) do
    state[key] = nil
  end
  state.active = false
  state.mode = "inactive"
  state.session_id = session_id
  state.current_reference_index = 1
  state.mappings = {}
end

return M
