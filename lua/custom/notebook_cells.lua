-- Cells for jupytext's `# %%` notebooks (.ipynb buffers, filetype python): every cell drawn
-- as a box with the blank line between cells left as a margin, code boxes numbered and
-- foldable, markdown drawn like markdown.
--
-- Nothing here edits the text -- pyright, NotebookNavigator, molten and jupytext's write
-- back all need the plain `# %%` script -- so it is all extmarks plus window-local
-- options. On the row under the cursor everything that hides text (conceals, overlays)
-- is lifted so it can be edited.
--
-- Folds: each code cell is a level-1 fold opened at its marker, with treesitter's folds
-- shifted one level deeper inside it; markdown cells are level 0 and never fold, so zM
-- leaves an outline of headings and one closed box per code cell.
local M = {}

local ns = vim.api.nvim_create_namespace 'notebook-cells'
local MARKER = '^# %%%%'
-- render-markdown's default heading icons (render-markdown/settings.lua, heading.icons)
local HEADING_ICONS = { '󰲡 ', '󰲣 ', '󰲥 ', '󰲧 ', '󰲩 ', '󰲫 ' }
-- above treesitter (100) and LSP semantic tokens (125), which paint these lines as comments
local PRIORITY = 200

---@class NotebookCell
---@field kind 'header'|'markdown'|'code'
---@field first integer  1-based; the `# %%` marker line, except for the header
---@field last integer  last non-blank line: the blank lines jupytext writes between cells
---                     belong to no cell, so they stay outside every box and fold
---@field number? integer  code cells only, counted from the top

---@param lines string[]
---@return NotebookCell[]
function M.parse(lines)
  local cells = {}
  local code_count = 0
  for lnum, line in ipairs(lines) do
    if line:match(MARKER) then
      if #cells > 0 then
        cells[#cells].last = lnum - 1
      end
      local cell = { kind = line:find('[markdown]', 1, true) and 'markdown' or 'code', first = lnum }
      if cell.kind == 'code' then
        code_count = code_count + 1
        cell.number = code_count
      end
      table.insert(cells, cell)
    elseif lnum == 1 then
      table.insert(cells, { kind = 'header', first = 1 })
    end
  end
  if #cells > 0 then
    cells[#cells].last = #lines
  end
  for _, cell in ipairs(cells) do
    while cell.last > cell.first and lines[cell.last]:match '^%s*$' do
      cell.last = cell.last - 1
    end
  end
  return cells
end

--- One level deeper, in foldexpr's own notation: 2 -> '3', '>1' -> '>2', '=' -> '='.
---@param level string|integer
---@return string
function M.shift_level(level)
  local n = tonumber(level)
  if n then
    return tostring(n + 1)
  end
  local prefix, digits = tostring(level):match '^([<>])(%d+)$'
  if prefix then
    return prefix .. (tonumber(digits) + 1)
  end
  return tostring(level)
end

---@param buf integer
function M.is_notebook(buf)
  return vim.api.nvim_buf_get_name(buf):match '%.ipynb$' ~= nil
end

---@type table<integer, { tick: integer, cells: NotebookCell[], cell_at: table<integer, integer>, shape: string }>
local cache = {}

local function shape_of(cells)
  local parts = {}
  for _, cell in ipairs(cells) do
    table.insert(parts, cell.kind:sub(1, 1) .. cell.first)
  end
  return table.concat(parts, ',')
end

local function cells_of(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local entry = cache[buf]
  if entry and entry.tick == tick then
    return entry
  end
  local cells = M.parse(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  local cell_at = {}
  for index, cell in ipairs(cells) do
    for lnum = cell.first, cell.last do
      cell_at[lnum] = index
    end
  end
  local shape = shape_of(cells)
  -- Vim re-evaluates foldexpr only around an edit, but adding, removing or retyping a
  -- marker changes the level of every line down to the next one; refold the windows.
  -- vim._foldupdate is what treesitter's own foldexpr calls (treesitter/_fold.lua).
  if entry and entry.shape ~= shape then
    vim.schedule(function()
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        vim._foldupdate(win, 0, vim.api.nvim_buf_line_count(buf))
      end
    end)
  end
  cache[buf] = { tick = tick, cells = cells, cell_at = cell_at, shape = shape }
  return cache[buf]
end

function M.foldexpr()
  local buf = vim.api.nvim_get_current_buf()
  local lnum = vim.v.lnum
  -- the window-local option follows the window to the next buffer it shows
  if not M.is_notebook(buf) then
    return vim.treesitter.foldexpr(lnum)
  end
  local entry = cells_of(buf)
  local cell = entry.cells[entry.cell_at[lnum]]
  if not cell or cell.kind == 'markdown' then
    return '0'
  end
  if lnum == cell.first then
    return '>1'
  end
  if cell.kind == 'header' then
    return '1'
  end
  return M.shift_level(vim.treesitter.foldexpr(lnum))
end

local function mark(buf, lnum, col, opts)
  opts.priority = opts.priority or PRIORITY
  vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, col, opts)
end

local function code_label(cell)
  local count = cell.last - cell.first
  return ('── [%d] python · %d %s '):format(cell.number, count, count == 1 and 'line' or 'lines')
end

--- The cell's box, drawn like haunt's annotation boxes (haunt/display.lua): the `# %%` line
--- overlaid as the top edge, a `│` inlined before and pinned after each line inside, and
--- the bottom edge as a virtual line. The inlined left edge moves the cell's text two
--- screen columns right; the text itself is untouched.
local function draw_box(buf, lines, cell, label, width, raw_row)
  if cell.first ~= raw_row then
    local top = '╭' .. label
    local fill = math.max(0, width - vim.fn.strdisplaywidth(top) - 1)
    mark(buf, cell.first, 0, {
      virt_text = { { top .. string.rep('─', fill) .. '╮', 'NotebookCellBorder' } },
      virt_text_pos = 'overlay',
      hl_mode = 'combine',
    })
  end
  for lnum = cell.first + 1, cell.last do
    -- kept on the cursor row too, or the row would jump two columns left under the cursor
    mark(buf, lnum, 0, {
      virt_text = { { '│ ', 'NotebookCellBorder' } },
      virt_text_pos = 'inline',
      hl_mode = 'combine',
    })
    mark(buf, lnum, 0, {
      virt_text = { { '│', 'NotebookCellBorder' } },
      virt_text_win_col = width - 1,
      hl_mode = 'combine',
    })
  end

  local bottom = { { { '╰' .. string.rep('─', width - 2) .. '╯', 'NotebookCellBorder' } } }
  local below = cell.last + 1
  if lines[below] and lines[below]:match '^%s*$' then
    -- on the blank separator, which sits outside every fold, so a closed cell still
    -- shows as a closed box
    mark(buf, below, 0, { virt_lines = bottom, virt_lines_above = true })
  else
    -- a cell typed flush against the next one: keep a margin between the two boxes
    if lines[below] then
      table.insert(bottom, { { '', 'Normal' } })
    end
    mark(buf, cell.last, 0, { virt_lines = bottom })
  end
end

local function draw_markdown_line(buf, lnum, line)
  local hashes, title = line:match '^# (#+) (.*)$'
  if hashes and #hashes <= #HEADING_ICONS then
    local level = #hashes
    local prefix = 2 + level + 1
    mark(buf, lnum, 0, { end_col = prefix, conceal = '' })
    -- after the concealed `# ##`, not at column 0, so it lands inside the box's left edge
    mark(buf, lnum, prefix, {
      virt_text = { { HEADING_ICONS[level], 'RenderMarkdownH' .. level } },
      virt_text_pos = 'inline',
      hl_mode = 'combine',
    })
    mark(buf, lnum, prefix, {
      end_col = prefix + #title,
      hl_group = 'RenderMarkdownH' .. level,
      line_hl_group = 'RenderMarkdownH' .. level .. 'Bg',
    })
    return
  end

  local prefix = line:match '^# ' and 2 or (line == '#' and 1 or 0)
  if prefix == 0 then
    return
  end
  mark(buf, lnum, 0, { end_col = prefix, conceal = '' })
  mark(buf, lnum, prefix, { end_col = #line, hl_group = 'Normal' })
  local from = prefix + 1
  while true do
    local s, e = line:find('`[^`]+`', from)
    if not s then
      break
    end
    mark(buf, lnum, s - 1, { end_col = e, hl_group = 'RenderMarkdownCodeInline', priority = PRIORITY + 1 })
    from = e + 1
  end
end

local function draw_markdown_cell(buf, lines, cell, raw_row)
  for lnum = cell.first + 1, cell.last do
    if lnum ~= raw_row then
      draw_markdown_line(buf, lnum, lines[lnum])
    end
  end
end

---@type table<integer, string>
local drawn = {}

--- Width of the text area in the window `win` (no gutter).
local function text_width(win)
  local info = vim.fn.getwininfo(win)[1]
  return info.width - info.textoff
end

---@param buf integer
---@param raw_row? integer  1-based row to leave undecorated (the cursor's)
function M.draw(buf, raw_row)
  local wins = vim.fn.win_findbuf(buf)
  if #wins == 0 then
    return
  end
  local width = text_width(wins[1])
  local entry = cells_of(buf)
  local key = ('%d:%s:%d'):format(entry.tick, tostring(raw_row), width)
  if drawn[buf] == key then
    return
  end
  drawn[buf] = key

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, cell in ipairs(entry.cells) do
    if cell.kind ~= 'header' then
      draw_box(buf, lines, cell, cell.kind == 'code' and code_label(cell) or '', width, raw_row)
      if cell.kind == 'markdown' then
        draw_markdown_cell(buf, lines, cell, raw_row)
      end
    end
  end
end

local function cursor_row(buf)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= buf then
    return nil
  end
  return vim.api.nvim_win_get_cursor(win)[1]
end

local WINDOW_OPTIONS = {
  foldexpr = "v:lua.require'custom.notebook_cells'.foldexpr()",
  conceallevel = 2,
}

local function set_window_options(win)
  for name, value in pairs(WINDOW_OPTIONS) do
    vim.api.nvim_set_option_value(name, value, { scope = 'local', win = win })
  end
end

--- A window-local option is copied to the next buffer the window shows (and to a window
--- split off it); put the global value back wherever ours reached a non-notebook buffer.
local function clear_window_options(win)
  for name, value in pairs(WINDOW_OPTIONS) do
    if vim.api.nvim_get_option_value(name, { scope = 'local', win = win }) == value then
      local global = vim.api.nvim_get_option_value(name, { scope = 'global' })
      vim.api.nvim_set_option_value(name, global, { scope = 'local', win = win })
    end
  end
end

---@type table<integer, true>
local attached = {}

local function attach(buf)
  if attached[buf] then
    return
  end
  attached[buf] = true
  local group = vim.api.nvim_create_augroup('notebook-cells-' .. buf, { clear = true })
  local redraw = function()
    M.draw(buf, cursor_row(buf))
  end
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'CursorMoved', 'CursorMovedI', 'BufWinEnter' }, {
    group = group,
    buffer = buf,
    callback = redraw,
  })
  vim.api.nvim_create_autocmd('WinLeave', {
    group = group,
    buffer = buf,
    callback = function()
      M.draw(buf, nil)
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = function()
      attached[buf], cache[buf], drawn[buf] = nil, nil, nil
      vim.api.nvim_del_augroup_by_id(group)
    end,
  })
end

local function apply_highlights()
  vim.api.nvim_set_hl(0, 'NotebookCellBorder', { link = 'FoldColumn' })
end

function M.setup()
  apply_highlights()
  local group = vim.api.nvim_create_augroup('notebook-cells', { clear = true })
  -- :colorscheme runs :hi clear
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = apply_highlights })
  -- jupytext.nvim sets the filetype from inside its BufReadCmd, so this is the first point
  -- where the buffer holds the script rather than the JSON
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'python',
    callback = function(event)
      if not M.is_notebook(event.buf) then
        return
      end
      attach(event.buf)
      for _, win in ipairs(vim.fn.win_findbuf(event.buf)) do
        set_window_options(win)
      end
      M.draw(event.buf, cursor_row(event.buf))
    end,
  })
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    callback = function(event)
      local win = vim.api.nvim_get_current_win()
      if not M.is_notebook(event.buf) then
        clear_window_options(win)
        return
      end
      set_window_options(win)
      if attached[event.buf] then
        M.draw(event.buf, cursor_row(event.buf))
      end
    end,
  })
  vim.api.nvim_create_autocmd('WinResized', {
    group = group,
    callback = function()
      for _, win in ipairs(vim.v.event.windows) do
        local buf = vim.api.nvim_win_get_buf(win)
        if attached[buf] then
          M.draw(buf, cursor_row(buf))
        end
      end
    end,
  })
end

return M
