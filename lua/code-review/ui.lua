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
    title_pos = opts.title and "left" or nil,
    focusable = opts.focusable ~= false,
  })
end

local function composer_layout()
  local columns = math.max(1, vim.o.columns)
  local lines = math.max(8, vim.o.lines)
  local available_width = math.max(1, columns - 2)
  local width = math.min(92, available_width, math.max(40, math.floor(columns * 0.66)))
  local gap = 0
  local refs_height = lines >= 18 and 4 or 1
  local voice_height = 1
  local legend_height = lines >= 24 and 3 or (lines >= 18 and 2 or 1)
  local refs_outer = refs_height + 2
  local body_border = 2
  local voice_outer = voice_height + 2
  local function total_height_for(body_height)
    return refs_height + 2 + body_height + body_border + voice_height + 2 + legend_height + gap * 3
  end
  while total_height_for(1) > lines and gap > 0 do
    gap = gap - 1
  end
  while total_height_for(1) > lines and legend_height > 1 do
    legend_height = legend_height - 1
  end
  while total_height_for(1) > lines and refs_height > 1 do
    refs_height = refs_height - 1
  end
  while total_height_for(1) > lines and voice_height > 1 do
    voice_height = voice_height - 1
  end
  refs_outer = refs_height + 2
  voice_outer = voice_height + 2
  local fixed_height = refs_outer + body_border + voice_outer + legend_height + gap * 3
  local body_height = math.max(1, lines - fixed_height)
  body_height = math.min(16, body_height)
  local body_outer = body_height + body_border
  local total_height = refs_outer + body_outer + voice_outer + legend_height + gap * 3
  local row = math.max(0, math.floor((lines - total_height) / 2))
  local col = math.max(0, math.floor((columns - width - 2) / 2))
  return {
    width = width,
    col = col,
    refs = { row = row, height = refs_height, border = "rounded", title = " References ", focusable = true },
    body = {
      row = row + refs_outer + gap,
      height = body_height,
      border = "rounded",
      title = " Comment ",
      focusable = true,
    },
    voice = {
      row = row + refs_outer + body_outer + gap * 2,
      height = voice_height,
      border = "rounded",
      title = " Voice ",
      focusable = false,
    },
    legend = {
      row = row + refs_outer + body_outer + voice_outer + gap * 3,
      height = legend_height,
      border = "none",
      focusable = false,
    },
  }
end

local function float_config(layout, spec)
  local borderless = spec.border == "none"
  return {
    relative = "editor",
    row = spec.row,
    col = layout.col,
    width = borderless and layout.width + 2 or layout.width,
    height = spec.height,
    style = "minimal",
    border = spec.border,
    title = spec.title,
    title_pos = spec.title and "left" or nil,
    focusable = spec.focusable,
  }
end

local function composer_panes(handle)
  return {
    { buf = handle.refs_buf, win = handle.refs_win },
    { buf = handle.body_buf, win = handle.body_win },
    { buf = handle.voice_buf, win = handle.voice_win },
    { buf = handle.legend_buf, win = handle.legend_win },
  }
end

function M.layout_composer_stack(handle)
  if not handle then
    return
  end
  local layout = composer_layout()
  local specs = {
    { win = handle.refs_win, spec = layout.refs },
    { win = handle.body_win, spec = layout.body },
    { win = handle.voice_win, spec = layout.voice },
    { win = handle.legend_win, spec = layout.legend },
  }
  for _, item in ipairs(specs) do
    if item.win and vim.api.nvim_win_is_valid(item.win) then
      pcall(vim.api.nvim_win_set_config, item.win, float_config(layout, item.spec))
    end
  end
end

function M.open_composer_stack(body_lines)
  local layout = composer_layout()
  local refs_buf = make_float_buf("Code Review Composer References", {}, false)
  local body_buf = make_float_buf("Code Review Comment", body_lines or { "" }, true)
  local voice_buf = make_float_buf("Code Review Composer Voice", {}, false)
  local legend_buf = make_float_buf("Code Review Composer Legend", {}, false)

  local refs_win = open_float(refs_buf, {
    row = layout.refs.row,
    col = layout.col,
    width = layout.width,
    height = layout.refs.height,
    title = layout.refs.title,
    focusable = layout.refs.focusable,
  })
  local body_win = open_float(body_buf, {
    row = layout.body.row,
    col = layout.col,
    width = layout.width,
    height = layout.body.height,
    title = layout.body.title,
    focusable = layout.body.focusable,
    enter = true,
  })
  local voice_win = open_float(voice_buf, {
    row = layout.voice.row,
    col = layout.col,
    width = layout.width,
    height = layout.voice.height,
    title = layout.voice.title,
    focusable = layout.voice.focusable,
  })
  local legend_win = open_float(legend_buf, {
    row = layout.legend.row,
    col = layout.col,
    width = layout.width + 2,
    height = layout.legend.height,
    border = layout.legend.border,
    focusable = layout.legend.focusable,
  })
  for _, win in ipairs({ refs_win, body_win, voice_win, legend_win }) do
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].wrap = true
  end
  vim.bo[body_buf].filetype = "markdown"
  vim.wo[body_win].linebreak = true
  vim.wo[body_win].breakindent = true
  vim.wo[body_win].spell = true
  local handle = {
    refs_buf = refs_buf,
    refs_win = refs_win,
    body_buf = body_buf,
    body_win = body_win,
    voice_buf = voice_buf,
    voice_win = voice_win,
    legend_buf = legend_buf,
    legend_win = legend_win,
    close = function(self)
      for _, pane in ipairs(composer_panes(self)) do
        if pane.win and vim.api.nvim_win_is_valid(pane.win) then
          pcall(vim.api.nvim_win_close, pane.win, true)
        end
      end
    end,
  }
  return handle
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
    name = "Code Review Comment Editor Help",
    title = " code-review.nvim - Comment Editor Help ",
    lines = lines,
    width = math.min(104, math.max(72, math.floor(vim.o.columns * 0.72))),
    height = math.min(#lines + 2, math.max(14, math.floor(vim.o.lines * 0.62))),
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
