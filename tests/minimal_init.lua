vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.shadafile = "NONE"
vim.opt.swapfile = false

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.env.XDG_DATA_HOME = tmp .. "/data"
vim.env.XDG_CACHE_HOME = tmp .. "/cache"
vim.env.XDG_STATE_HOME = tmp .. "/state"
vim.fn.mkdir(vim.env.XDG_DATA_HOME, "p")
vim.fn.mkdir(vim.env.XDG_CACHE_HOME, "p")
vim.fn.mkdir(vim.env.XDG_STATE_HOME, "p")

local plenary_path = vim.env.PLENARY_PATH
if plenary_path and #plenary_path > 0 then
  vim.opt.runtimepath:append(plenary_path)
end

runtime_plugin_loaded = false

package.preload["snacks"] = function()
  return {
    win = function(opts)
      local width = opts.width or 80
      local height = opts.height or 16
      local win = vim.api.nvim_open_win(opts.buf, true, {
        relative = "editor",
        row = 1,
        col = 1,
        width = math.min(width, math.max(20, vim.o.columns - 4)),
        height = math.min(height, math.max(3, vim.o.lines - 4)),
        style = "minimal",
        border = "single",
      })
      return {
        win = win,
        buf = opts.buf,
        close = function(self)
          if vim.api.nvim_win_is_valid(self.win) then
            vim.api.nvim_win_close(self.win, true)
          end
        end,
      }
    end,
  }
end

local function run_specs(dir)
  local failures = {}
  local total = 0

  _G.describe = function(name, fn)
    print("DESCRIBE " .. name)
    fn()
  end

  _G.it = function(name, fn)
    total = total + 1
    local ok, err = pcall(fn)
    if ok then
      print("  PASS " .. name)
    else
      failures[#failures + 1] = name .. ": " .. tostring(err)
      print("  FAIL " .. name .. ": " .. tostring(err))
    end
  end

  _G.before_each = function()
  end

  _G.after_each = function()
  end

  local native_assert = assert
  local base_assert = setmetatable({}, {
    __call = function(_, value, message)
      return native_assert(value, message)
    end,
  })
  base_assert.is_true = function(value)
    native_assert(value == true, "expected true, got " .. vim.inspect(value))
  end
  base_assert.is_false = function(value)
    native_assert(value == false, "expected false, got " .. vim.inspect(value))
  end
  base_assert.equals = function(expected, actual)
    native_assert(vim.deep_equal(expected, actual), "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
  end
  base_assert.same = base_assert.equals
  base_assert.truthy = function(value)
    native_assert(value, "expected truthy value")
  end
  base_assert.falsy = function(value)
    native_assert(not value, "expected falsy value")
  end
  _G.assert = base_assert

  local files = vim.fn.glob(dir .. "/*_spec.lua", false, true)
  for i, file in ipairs(files) do
    files[i] = vim.fn.fnamemodify(file, ":p")
  end
  for _, file in ipairs(files) do
    dofile(file)
  end

  if #failures > 0 then
    error(table.concat(failures, "\n"))
  end
  print(string.format("PASS %d specs", total))
end

vim.api.nvim_create_user_command("PlenaryBustedDirectory", function(opts)
  local dir = opts.fargs[1] or "tests/spec"
  run_specs(dir)
end, { nargs = "*" })
