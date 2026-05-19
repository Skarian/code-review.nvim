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
