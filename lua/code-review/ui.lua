local M = {}

local function callable(value)
  if type(value) == "function" then
    return true
  end
  local mt = type(value) == "table" and getmetatable(value) or nil
  return type(mt) == "table" and type(mt.__call) == "function"
end

local function snacks()
  local ok, mod = pcall(require, "snacks")
  if not ok then
    error("code-review.nvim requires folke/snacks.nvim at runtime", 2)
  end
  if not callable(mod.win) then
    error("code-review.nvim requires Snacks.win", 2)
  end
  return mod
end

local function picker()
  local mod = snacks()
  if type(mod.picker) == "table" and type(mod.picker.pick) == "function" then
    return mod.picker.pick
  end
  if callable(mod.picker) then
    return mod.picker
  end
  error("code-review.nvim requires Snacks.picker", 2)
end

local function close_window(win, handle)
  if handle and type(handle.close) == "function" then
    pcall(handle.close, handle)
  elseif win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

function M.open_composer(buf)
  local win = snacks().win({
    buf = buf,
    title = " Code Review Comment ",
    border = "rounded",
    width = math.min(88, math.max(56, math.floor(vim.o.columns * 0.62))),
    height = math.min(22, math.max(10, math.floor(vim.o.lines * 0.45))),
    wo = {
      number = false,
      relativenumber = false,
      signcolumn = "no",
      wrap = true,
    },
  })
  if type(win) == "table" then
    return win.win or win.winid or win[1], win
  end
  return win, nil
end

local function make_float_buf(name, lines, modifiable)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
  if lines then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  vim.bo[buf].modifiable = modifiable
  return buf
end

local function open_float(buf, opts)
  return vim.api.nvim_open_win(buf, opts.enter or false, {
    relative = "editor",
    row = opts.row,
    col = opts.col,
    width = opts.width,
    height = opts.height,
    style = "minimal",
    border = opts.border or "rounded",
    title = opts.title,
    focusable = opts.focusable ~= false,
  })
end

function M.open_composer_stack(body_lines)
  local width = math.min(92, math.max(60, math.floor(vim.o.columns * 0.66)))
  local body_height = math.min(16, math.max(8, math.floor(vim.o.lines * 0.32)))
  local refs_height = 4
  local status_height = 2
  local gap = 2
  local total_height = status_height + refs_height + body_height + gap * 2
  local row = math.max(0, math.floor((vim.o.lines - total_height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  local status_buf = make_float_buf("Code Review Composer Status", {}, false)
  local refs_buf = make_float_buf("Code Review Composer References", {}, false)
  local body_buf = make_float_buf("Code Review Comment", body_lines or { "" }, true)

  local status_win = open_float(status_buf, {
    row = row,
    col = col,
    width = width,
    height = status_height,
    title = " Code Review ",
    focusable = false,
  })
  local refs_win = open_float(refs_buf, {
    row = row + status_height + gap,
    col = col,
    width = width,
    height = refs_height,
    title = " References ",
    focusable = true,
  })
  local body_win = open_float(body_buf, {
    row = row + status_height + refs_height + gap * 2,
    col = col,
    width = width,
    height = body_height,
    title = " Comment ",
    focusable = true,
    enter = true,
  })
  for _, win in ipairs({ status_win, refs_win, body_win }) do
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].wrap = true
  end
  vim.bo[body_buf].filetype = "markdown"
  vim.wo[body_win].linebreak = true
  vim.wo[body_win].breakindent = true
  vim.wo[body_win].spell = true
  return {
    status_buf = status_buf,
    status_win = status_win,
    refs_buf = refs_buf,
    refs_win = refs_win,
    body_buf = body_buf,
    body_win = body_win,
    close = function(self)
      for _, win in ipairs({ self.status_win, self.refs_win, self.body_win }) do
        if win and vim.api.nvim_win_is_valid(win) then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
    end,
  }
end

function M.open_help(opts)
  opts = opts or {}
  local title = opts.title or " Code Review Help "
  local name = opts.name or "Code Review Help"
  local lines = opts.lines or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width = opts.width or math.min(104, math.max(72, math.floor(vim.o.columns * 0.72)))
  local height = opts.height or math.min(#lines + 2, math.max(14, math.floor(vim.o.lines * 0.62)))
  local result = snacks().win({
    buf = buf,
    title = title,
    border = "rounded",
    width = width,
    height = height,
    wo = {
      number = false,
      relativenumber = false,
      signcolumn = "no",
      wrap = true,
    },
  })
  local win, handle
  if type(result) == "table" then
    win = result.win or result.winid or result[1]
    handle = result
  else
    win = result
  end
  local close = function()
    close_window(win, handle)
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, desc = "Close Code Review help" })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true, desc = "Close Code Review help" })
  return win, handle, buf
end

function M.open_composer_help(lines)
  return M.open_help({
    name = "Code Review Composer Help",
    title = " Code Review Composer Help ",
    lines = lines,
    width = math.min(72, math.max(48, math.floor(vim.o.columns * 0.5))),
    height = math.min(#lines + 2, math.max(8, math.floor(vim.o.lines * 0.35))),
  })
end

function M.pick_comments(items, callbacks)
  return picker()({
    title = "Code Review Comments",
    finder = function()
      local out = {}
      for index, item in ipairs(items) do
        out[#out + 1] = {
          idx = index,
          text = item.label,
          item = item,
        }
      end
      return out
    end,
    format = function(item)
      return { { item.text } }
    end,
    preview = function(ctx)
      if not ctx or not ctx.buf or not ctx.item then
        return
      end
      vim.bo[ctx.buf].modifiable = true
      vim.api.nvim_buf_set_lines(ctx.buf, 0, -1, false, vim.split(ctx.item.item.preview or "", "\n", { plain = true }))
      vim.bo[ctx.buf].modifiable = false
    end,
    confirm = function(active_picker, item)
      if active_picker and active_picker.close then
        active_picker:close()
      end
      if item and item.item then
        callbacks.select(item.item)
      elseif callbacks.cancel then
        callbacks.cancel()
      end
    end,
    actions = {
      delete = function(active_picker, item)
        if active_picker and active_picker.close then
          active_picker:close()
        end
        if item and item.item then
          callbacks.delete(item.item)
        end
      end,
      jump = function(active_picker, item)
        if active_picker and active_picker.close then
          active_picker:close()
        end
        if item and item.item then
          callbacks.jump(item.item)
        end
      end,
    },
    win = {
      input = {
        keys = {
          ["d"] = { "delete", mode = { "n" }, desc = "Delete Comment" },
          ["o"] = { "jump", mode = { "n" }, desc = "Jump to File Reference" },
        },
      },
    },
  })
end

return M
