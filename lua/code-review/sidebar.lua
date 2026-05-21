local config = require("code-review.config")
local model = require("code-review.model")
local path = require("code-review.path")
local state = require("code-review.state")
local time = require("code-review.time")
local ui = require("code-review.ui")

local M = {}
local ns = vim.api.nvim_create_namespace("code-review.nvim.sidebar")
local pad = "  "
local footer_height = 1
local render_scheduled = false

local function truncate_to_width(text, width)
  text = text or ""
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  if width <= 3 then
    return string.sub("...", 1, width)
  end

  local out = ""
  for _, char in ipairs(vim.fn.split(text, "\\zs")) do
    if vim.fn.strdisplaywidth(out .. char .. "...") > width then
      break
    end
    out = out .. char
  end
  return out .. "..."
end

local function padded(line, width)
  if line == "" then
    return ""
  end
  if not width then
    return pad .. line
  end
  return pad .. truncate_to_width(line, width - vim.fn.strdisplaywidth(pad))
end

local function center_line(text, width)
  text = truncate_to_width(text, width)
  local available = math.max(0, width - vim.fn.strdisplaywidth(text))
  return string.rep(" ", math.floor(available / 2)) .. text
end

local function statusline_escape(text)
  return (text or ""):gsub("%%", "%%%%")
end

local function footer_lines(width)
  return {
    center_line("? help   q quit", width),
  }
end

local function configured_key(action)
  local cfg = config.get().keymaps
  if not cfg.enabled then
    return nil
  end
  local suffix = cfg[action]
  if suffix == false or suffix == nil then
    return nil
  end
  return cfg.prefix .. suffix
end

local function add_key_line(lines, key, description)
  if key then
    lines[#lines + 1] = string.format("  %-12s %s", key, description)
  end
end

local function sidebar_help_lines()
  local lines = {
    "Overview",
    "  The sidebar lists comments for the active review",
    "  A referenced source line is a line included in at least one comment",
    "  On a referenced source line, the sidebar filters to matching comments",
    "  Elsewhere, it lists all comments",
    "  The sidebar is a read-only throwaway buffer",
    "",
    "Normal mode",
    "  Key          Action",
  }
  if config.get().keymaps.enabled then
    add_key_line(lines, configured_key("review_picker"), "Open the review picker to create, delete, delete all, or switch reviews")
    add_key_line(lines, configured_key("edit_comment"), "Open the comment picker")
    lines[#lines + 1] = "                Enter opens the comment editor; in picker Normal mode, d deletes and o goes to the comment"
    add_key_line(lines, configured_key("edit_comment_under_cursor"), "Open the comment on the current line")
    lines[#lines + 1] = "                If more than one comment matches, choose from the picker"
    add_key_line(lines, configured_key("preview"), "Preview the current review in a throwaway buffer")
    add_key_line(lines, configured_key("toggle"), "Toggle Code Review")
  else
    lines[#lines + 1] = "  Default keymaps are disabled by configuration"
  end
  vim.list_extend(lines, {
    "",
    "Visual mode",
    "  Key          Action",
  })
  add_key_line(lines, configured_key("add_reference"), "Create a comment from the selected lines")
  add_key_line(lines, configured_key("append_reference"), "Add a File Reference to a comment")
  vim.list_extend(lines, {
    "",
    "Sidebar buffer",
    "  Key          Action",
    "  ?            Show help",
    "  q            Quit Code Review",
  })
  return lines
end

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function owned_window(win, buf, filetype)
  return valid_win(win) and valid_buf(buf) and vim.api.nvim_win_get_buf(win) == buf and vim.bo[buf].filetype == filetype
end

local function owned_buffer(buf, filetype)
  return valid_buf(buf) and vim.bo[buf].filetype == filetype
end

local function close_owned_sidebar_resources(sidebar)
  if not sidebar then
    return
  end
  if owned_window(sidebar.footer_win, sidebar.footer_buf, "code-review-sidebar-footer") then
    pcall(vim.api.nvim_win_close, sidebar.footer_win, true)
  end
  if owned_window(sidebar.win, sidebar.buf, "code-review-sidebar") then
    pcall(vim.api.nvim_win_close, sidebar.win, true)
  end
  if owned_buffer(sidebar.footer_buf, "code-review-sidebar-footer") then
    pcall(vim.api.nvim_buf_delete, sidebar.footer_buf, { force = true })
  end
  if owned_buffer(sidebar.buf, "code-review-sidebar") then
    pcall(vim.api.nvim_buf_delete, sidebar.buf, { force = true })
  end
end

local function close_orphan_sidebar_windows(sidebar)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if not sidebar or (win ~= sidebar.win and win ~= sidebar.footer_win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local ft = vim.bo[buf].filetype
      if ft == "code-review-sidebar" or ft == "code-review-sidebar-footer" then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end
end

local function sidebar_buf(sidebar, bufnr)
  return sidebar and (sidebar.buf == bufnr or sidebar.footer_buf == bufnr)
end

local function stale_sidebar(sidebar)
  return sidebar
    and (
      not valid_win(sidebar.win)
      or not valid_buf(sidebar.buf)
      or not valid_win(sidebar.footer_win)
      or not valid_buf(sidebar.footer_buf)
      or vim.api.nvim_win_get_buf(sidebar.win) ~= sidebar.buf
      or vim.api.nvim_win_get_buf(sidebar.footer_win) ~= sidebar.footer_buf
      or vim.bo[sidebar.buf].filetype ~= "code-review-sidebar"
      or vim.bo[sidebar.footer_buf].filetype ~= "code-review-sidebar-footer"
    )
end

local function with_winenter_ignored(fn)
  local previous = vim.o.eventignore
  if previous ~= "all" and not vim.tbl_contains(vim.split(previous, ",", { plain = true }), "WinEnter") then
    vim.o.eventignore = previous == "" and "WinEnter" or (previous .. ",WinEnter")
  end
  local ok, result = pcall(fn)
  vim.o.eventignore = previous
  if not ok then
    error(result, 2)
  end
  return result
end

local function apply_window_options(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  vim.wo[win].spell = false
  pcall(function()
    vim.wo[win].eventignorewin = "WinEnter"
  end)
end

local function apply_buffer_options(buf, filetype)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = filetype
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].readonly = true
  vim.bo[buf].modifiable = false
end

local function set_readonly_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
end

local function open_sidebar_window(buf)
  local position = config.get().sidebar.position
  return vim.api.nvim_open_win(buf, false, {
    win = -1,
    vertical = true,
    split = position == "left" and "left" or "right",
    width = config.get().sidebar.width,
    noautocmd = true,
  })
end

local function open_footer_window(content_win, footer_buf)
  return vim.api.nvim_open_win(footer_buf, false, {
    win = content_win,
    split = "below",
    height = footer_height,
    noautocmd = true,
  })
end

local function apply_sidebar_keymaps(buf)
  vim.keymap.set("n", "q", function()
    require("code-review").quit()
  end, { buffer = buf, nowait = true, desc = "Quit Review Mode" })
  local keymaps = config.get().keymaps
  if keymaps.enabled and keymaps.toggle ~= false and keymaps.toggle ~= nil then
    vim.keymap.set("n", keymaps.prefix .. keymaps.toggle, function()
      require("code-review").quit()
    end, { buffer = buf, nowait = true, desc = "Quit Review Mode" })
  end
  vim.keymap.set("n", "?", function()
    require("code-review.sidebar").show_help()
  end, { buffer = buf, nowait = true, desc = "Show Code Review help" })
end

local function desired_width(sidebar)
  return sidebar and sidebar.desired_width or config.get().sidebar.width
end

function M.apply_desired_width()
  local s = state.get()
  local sidebar = s.sidebar
  if not sidebar or sidebar.reapplying_width then
    return
  end
  local width = desired_width(sidebar)
  if not width then
    return
  end
  sidebar.reapplying_width = true
  for _, item in ipairs({
    { win = sidebar.win, buf = sidebar.buf, filetype = "code-review-sidebar" },
    { win = sidebar.footer_win, buf = sidebar.footer_buf, filetype = "code-review-sidebar-footer" },
  }) do
    if owned_window(item.win, item.buf, item.filetype) and vim.api.nvim_win_get_width(item.win) ~= width then
      pcall(vim.api.nvim_win_set_width, item.win, width)
    end
  end
  sidebar.reapplying_width = false
end

function M.capture_width_from_sidebar()
  local s = state.get()
  local sidebar = s.sidebar
  if
    not sidebar
    or sidebar.reapplying_width
    or s.recreating_sidebar
    or #require("code-review.navigation").tab_content_windows(0) == 0
  then
    return
  end
  local current = vim.api.nvim_get_current_win()
  local is_owned_sidebar = current == sidebar.win and owned_window(sidebar.win, sidebar.buf, "code-review-sidebar")
  local is_owned_footer = current == sidebar.footer_win and owned_window(sidebar.footer_win, sidebar.footer_buf, "code-review-sidebar-footer")
  if not is_owned_sidebar and not is_owned_footer then
    return
  end
  local width = vim.api.nvim_win_get_width(current)
  if width > 0 then
    sidebar.desired_width = width
  end
end

function M.handle_resize()
  local s = state.get()
  local sidebar = s.sidebar
  if not sidebar then
    return
  end
  local event = vim.v.event or {}
  local resized = event.windows
  if type(resized) == "table" then
    local touched = false
    for _, win in ipairs(resized) do
      if win == sidebar.win or win == sidebar.footer_win then
        touched = true
        break
      end
    end
    if not touched then
      return
    end
  end
  M.apply_desired_width()
end

local function apply_content_window_defaults(win)
  if not valid_win(win) then
    return
  end
  pcall(function()
    vim.wo[win].eventignorewin = ""
  end)
  vim.wo[win].winfixwidth = false
  vim.wo[win].winfixheight = false
  pcall(function()
    vim.wo[win].winbar = ""
  end)
  for _, field in ipairs({ "number", "relativenumber", "cursorline", "wrap", "spell", "list" }) do
    pcall(function()
      vim.wo[win][field] = vim.o[field]
    end)
  end
  for _, field in ipairs({ "signcolumn", "foldcolumn", "cursorlineopt" }) do
    pcall(function()
      vim.wo[win][field] = vim.o[field]
    end)
  end
end

function M.replace_with_content_buffer(buf)
  local s = state.get()
  local sidebar = s.sidebar
  if not (sidebar and valid_buf(buf)) then
    return nil
  end
  local target = owned_window(sidebar.win, sidebar.buf, "code-review-sidebar") and sidebar.win
    or (owned_window(sidebar.footer_win, sidebar.footer_buf, "code-review-sidebar-footer") and sidebar.footer_win or nil)
  if not target then
    return nil
  end
  local desired_width = sidebar.desired_width
  local filter = sidebar.filter
  local old_wins = { sidebar.footer_win, sidebar.win }
  s.recreating_sidebar = true
  for _, win in ipairs(old_wins) do
    local old_buf = win == sidebar.footer_win and sidebar.footer_buf or sidebar.buf
    local old_ft = win == sidebar.footer_win and "code-review-sidebar-footer" or "code-review-sidebar"
    if win ~= target and owned_window(win, old_buf, old_ft) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  vim.api.nvim_win_set_buf(target, buf)
  apply_content_window_defaults(target)
  if sidebar.footer_buf ~= buf and owned_buffer(sidebar.footer_buf, "code-review-sidebar-footer") then
    pcall(vim.api.nvim_buf_delete, sidebar.footer_buf, { force = true })
  end
  if sidebar.buf ~= buf and owned_buffer(sidebar.buf, "code-review-sidebar") then
    pcall(vim.api.nvim_buf_delete, sidebar.buf, { force = true })
  end
  s.sidebar = nil
  s.recreating_sidebar = false
  M.render()
  if s.sidebar then
    s.sidebar.filter = filter
    s.sidebar.desired_width = desired_width or s.sidebar.desired_width
    M.apply_desired_width()
  end
  return target
end

local function ensure()
  local s = state.get()
  if valid_win(s.sidebar and s.sidebar.win) and valid_buf(s.sidebar.buf) and valid_win(s.sidebar.footer_win) and valid_buf(s.sidebar.footer_buf) then
    return s.sidebar.buf, s.sidebar.win, s.sidebar.footer_buf, s.sidebar.footer_win
  end
  local previous_filter = s.sidebar and s.sidebar.filter or nil
  local previous_desired_width = s.sidebar and s.sidebar.desired_width or nil
  local current = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  local win = with_winenter_ignored(function()
    return open_sidebar_window(buf)
  end)
  local footer_bufnr = vim.api.nvim_create_buf(false, true)
  local footer_win = with_winenter_ignored(function()
    return open_footer_window(win, footer_bufnr)
  end)
  vim.api.nvim_win_set_width(win, config.get().sidebar.width)
  vim.api.nvim_win_set_width(footer_win, config.get().sidebar.width)
  vim.wo[win].winfixwidth = true
  vim.wo[footer_win].winfixwidth = true
  vim.wo[footer_win].winfixheight = true
  apply_window_options(win)
  apply_window_options(footer_win)
  vim.wo[footer_win].winbar = ""
  apply_buffer_options(buf, "code-review-sidebar")
  apply_buffer_options(footer_bufnr, "code-review-sidebar-footer")
  pcall(vim.api.nvim_buf_set_name, buf, "Code Review")
  pcall(vim.api.nvim_buf_set_name, footer_bufnr, "Code Review Footer")
  apply_sidebar_keymaps(buf)
  apply_sidebar_keymaps(footer_bufnr)
  s.sidebar = {
    buf = buf,
    win = win,
    footer_buf = footer_bufnr,
    footer_win = footer_win,
    filter = previous_filter,
    desired_width = previous_desired_width or config.get().sidebar.width,
  }
  M.apply_desired_width()
  if valid_win(current) and vim.api.nvim_get_current_win() ~= current then
    with_winenter_ignored(function()
      vim.api.nvim_set_current_win(current)
    end)
  end
  return buf, win, footer_bufnr, footer_win
end

local function schedule_render()
  if render_scheduled then
    return
  end
  render_scheduled = true
  vim.schedule(function()
    render_scheduled = false
    local s = state.get()
    if not s.active then
      return
    end
    M.render()
  end)
end

local function wrap_preview_line(line, width)
  local out = {}
  local current = ""
  for word in line:gmatch("%S+") do
    if current == "" then
      current = word
    elseif vim.fn.strdisplaywidth(current .. " " .. word) <= width then
      current = current .. " " .. word
    else
      out[#out + 1] = truncate_to_width(current, width)
      current = word
    end
  end
  if current ~= "" then
    out[#out + 1] = truncate_to_width(current, width)
  end
  return out
end

local function preview_body(body, width)
  local lines = vim.split(body or "", "\n", { plain = true })
  local out = {}
  local available = width - vim.fn.strdisplaywidth(pad)
  if available <= 0 then
    return out
  end
  for _, line in ipairs(lines) do
    if line ~= "" then
      for _, wrapped in ipairs(wrap_preview_line(line, available)) do
        out[#out + 1] = wrapped
        if #out == 4 then
          return out
        end
      end
    end
  end
  return out
end

local function filter_comments(comments, filter)
  if not filter or not filter.ids then
    return comments
  end
  local allowed = {}
  for _, id in ipairs(filter.ids) do
    allowed[id] = true
  end
  local out = {}
  for _, comment in ipairs(comments) do
    if allowed[comment.id] then
      out[#out + 1] = comment
    end
  end
  return out
end

local function build_header(review, filter, width)
  local prefix = "Code Review"
  if not review then
    return prefix
  end
  return truncate_to_width(prefix .. " | " .. review.name, width)
end

local function scope_line(comment_count, filter)
  local noun = comment_count == 1 and "Comment" or "Comments"
  if filter and filter.ids then
    return string.format("%d %s on this line only", comment_count, noun)
  end
  return string.format("%d Total %s", comment_count, noun)
end

local function vertically_centered_message(text, width, height)
  local lines = {}
  local top_padding = math.max(0, math.floor((height - 1) / 2))
  for _ = 1, top_padding do
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = center_line(text, width)
  return lines
end

local function build_lines(review, filter, width, height)
  local content_width = math.max(1, width)
  local content_height = math.max(1, height or 1)
  local lines = {}
  local highlights = {}
  local metadata = { comment_lines = {} }
  if review then
    local comments = filter_comments(model.comments_newest(review), filter)
    if #comments > 0 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = center_line(scope_line(#comments, filter), content_width)
      highlights[#highlights + 1] = { line = #lines - 1, group = "CodeReviewSidebarScope" }
      lines[#lines + 1] = ""
    end
    for _, comment in ipairs(comments) do
      local flags = {}
      local incomplete = not model.comment_complete(comment)
      local stale = false
      if incomplete then
        flags[#flags + 1] = "incomplete"
      end
      for _, ref in ipairs(comment.file_references or {}) do
        if ref.stale_state == "stale" then
          stale = true
          flags[#flags + 1] = "stale"
          break
        end
      end
      lines[#lines + 1] = padded(time.relative(comment.updated_at) .. (#flags > 0 and (" [" .. table.concat(flags, ", ") .. "]") or ""), content_width)
      metadata.comment_lines[comment.id] = #lines
      if incomplete then
        highlights[#highlights + 1] = { line = #lines - 1, group = "CodeReviewSidebarIncomplete" }
      elseif stale then
        highlights[#highlights + 1] = { line = #lines - 1, group = "CodeReviewSidebarStale" }
      end
      for _, ref in ipairs(comment.file_references or {}) do
        lines[#lines + 1] = padded(string.format("%s:%d-%d%s", ref.relative_path, ref.start_line, ref.end_line, ref.stale_state == "stale" and " !" or ""), content_width)
        if ref.stale_state == "stale" then
          highlights[#highlights + 1] = { line = #lines - 1, group = "CodeReviewSidebarStale" }
        end
      end
      for _, body_line in ipairs(preview_body(comment.body, content_width)) do
        lines[#lines + 1] = padded(body_line, content_width)
      end
      lines[#lines + 1] = ""
    end
    if #comments == 0 then
      lines = vertically_centered_message("No Comments", content_width, content_height)
      highlights[#highlights + 1] = { line = #lines - 1, group = "CodeReviewSidebarHeader" }
    end
  else
    lines = vertically_centered_message("No active review", content_width, content_height)
    highlights[#highlights + 1] = { line = #lines - 1, group = "CodeReviewSidebarHeader" }
  end
  if #lines == 0 then
    lines[1] = ""
  end
  return lines, highlights, metadata
end

local function apply_highlights(buf, highlights)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, hl in ipairs(highlights) do
    pcall(vim.api.nvim_buf_add_highlight, buf, ns, hl.group, hl.line, 0, -1)
  end
end

local function same_filter(a, b)
  local a_ids = a and a.ids or nil
  local b_ids = b and b.ids or nil
  if not a_ids and not b_ids then
    return true
  end
  if not a_ids or not b_ids or #a_ids ~= #b_ids then
    return false
  end
  for index, id in ipairs(a_ids) do
    if b_ids[index] ~= id then
      return false
    end
  end
  return true
end

local function set_filter(filter)
  local s = state.get()
  if stale_sidebar(s.sidebar) then
    s.sidebar = nil
  end
  if not s.sidebar then
    return
  end
  if same_filter(s.sidebar.filter, filter) then
    return
  end
  s.sidebar.filter = filter
  M.render()
end

function M.clear_filter()
  set_filter(nil)
end

function M.suppress_next_source_filter()
  local s = state.get()
  if stale_sidebar(s.sidebar) then
    s.sidebar = nil
  end
  if s.sidebar then
    s.sidebar.suppress_next_source_filter = true
  end
  M.clear_filter()
end

function M.update_filter_for_buffer(bufnr)
  if not state.is_active() then
    return
  end
  local s = state.get()
  if sidebar_buf(s.sidebar, bufnr) then
    M.clear_filter()
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
    return
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return
  end
  local rel = path.relative(s.root, name)
  if not rel then
    M.clear_filter()
    return
  end
  local review = model.find_review(s.store, s.active_review_id)
  if not review then
    M.clear_filter()
    return
  end
  if s.sidebar and s.sidebar.suppress_next_source_filter then
    s.sidebar.suppress_next_source_filter = false
    M.clear_filter()
    return
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local matches = {}
  for _, comment in ipairs(model.comments_newest(review)) do
    for _, ref in ipairs(comment.file_references or {}) do
      if ref.relative_path == rel and line >= ref.start_line and line <= ref.end_line then
        matches[#matches + 1] = comment.id
        break
      end
    end
  end
  if #matches == 0 then
    M.clear_filter()
  else
    set_filter({ ids = matches, count = #matches })
  end
end

function M.render()
  local s = state.get()
  if not s.active then
    return
  end
  if stale_sidebar(s.sidebar) then
    local previous = s.sidebar
    close_owned_sidebar_resources(previous)
    s.sidebar = {
      filter = previous and previous.filter or nil,
      desired_width = previous and previous.desired_width or nil,
    }
  end
  close_orphan_sidebar_windows(s.sidebar)
  local buf, win, footer_buf = ensure()
  local width = valid_win(win) and vim.api.nvim_win_get_width(win) or config.get().sidebar.width
  local height = valid_win(win) and vim.api.nvim_win_get_height(win) or 1
  local review = model.find_review(s.store, s.active_review_id)
  local filter = s.sidebar and s.sidebar.filter or nil
  local view = valid_win(win) and vim.api.nvim_win_call(win, vim.fn.winsaveview) or nil
  local lines, highlights, metadata = build_lines(review, filter, width, height)
  vim.wo[win].winbar = "%#CodeReviewSidebarTitle#%=" .. statusline_escape(build_header(review, filter, width)) .. "%="
  set_readonly_lines(buf, lines)
  apply_highlights(buf, highlights)
  set_readonly_lines(footer_buf, footer_lines(width))
  M.apply_desired_width()
  if view and valid_win(win) then
    pcall(vim.api.nvim_win_call, win, function()
      vim.fn.winrestview(view)
    end)
  end
  s.sidebar.metadata = metadata
  pcall(vim.cmd.redrawstatus)
end

function M.close()
  local s = state.get()
  if s.sidebar then
    close_owned_sidebar_resources(s.sidebar)
  end
  s.sidebar = nil
end

function M.show_help()
  return ui.open_help({
    name = "Code Review Help",
    title = " code-review.nvim - Sidebar Help ",
    lines = sidebar_help_lines(),
  })
end

return M
