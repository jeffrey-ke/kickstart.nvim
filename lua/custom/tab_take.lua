-- Open the marked windows (`custom.winmark`) of the current tab in a new tab,
-- keeping their arrangement: the tab's split tree (`winlayout()`) is pruned to
-- the marked leaves and rebuilt. With nothing marked it is plain `:tab split`.
--
-- The windows are copies, as with `:tab split`: each keeps its buffer, view and
-- window-local options ('diff' and 'scrollbind' included, so a diff pair stays
-- one). Manual folds and exact split sizes are not carried; `equalalways`
-- shares the space out evenly. The marks are cleared once taken.
local winmark = require 'custom.winmark'

local M = {}

-- `winlayout()` cut down to the leaves in `keep`. A branch left with one child
-- is replaced by it, and a child running the same way as its parent is spliced
-- in, so the rebuilt tree has no splits that divide nothing.
local function prune(node, keep)
  if node[1] == 'leaf' then
    return keep[node[2]] and node or nil
  end
  local kids = {}
  for _, child in ipairs(node[2]) do
    local kept = prune(child, keep)
    if kept and kept[1] == node[1] then
      vim.list_extend(kids, kept[2])
    elseif kept then
      table.insert(kids, kept)
    end
  end
  if #kids == 0 then
    return nil
  end
  return #kids == 1 and kids[1] or { node[1], kids }
end

-- Derived from the window height, so a copy into a shorter window is invalid.
local SKIP_OPTIONS = { scroll = true }

local function copy_win_options(from, to)
  for name, info in pairs(vim.api.nvim_get_all_options_info()) do
    if info.scope == 'win' and not SKIP_OPTIONS[name] then
      local value = vim.api.nvim_get_option_value(name, { win = from, scope = 'local' })
      vim.api.nvim_set_option_value(name, value, { win = to, scope = 'local' })
    end
  end
end

-- Split `win` into one window per child of `node`, recursively. Returns the
-- pairs { new window, original window } at the leaves.
local function build(node, win, pairs_out)
  if node[1] == 'leaf' then
    table.insert(pairs_out, { win, node[2] })
    return
  end
  local direction = node[1] == 'row' and 'right' or 'below'
  local wins = { win }
  for i = 2, #node[2] do
    wins[i] = vim.api.nvim_open_win(0, false, { split = direction, win = wins[i - 1] })
  end
  for i, child in ipairs(node[2]) do
    build(child, wins[i], pairs_out)
  end
end

function M.open()
  local marked = winmark.list()
  if #marked == 0 then
    vim.cmd 'tab split'
    return
  end
  local keep = {}
  for _, win in ipairs(marked) do
    keep[win] = true
  end
  -- nil when only floats are marked: they are not in the layout.
  local layout = prune(vim.fn.winlayout(), keep)
  if not layout then
    vim.cmd 'tab split'
    return
  end
  local focused = vim.api.nvim_get_current_win()

  -- `:tab split` rather than `:tabnew`, which would leave an empty [No Name]
  -- buffer behind in the buffer list once every window is reassigned.
  vim.cmd 'tab split'
  local leaves = {}
  build(layout, vim.api.nvim_get_current_win(), leaves)

  -- Views last: every later split shrinks a window and may scroll it.
  local land = leaves[1][1]
  for _, pair in ipairs(leaves) do
    local new, orig = pair[1], pair[2]
    vim.api.nvim_win_set_buf(new, vim.api.nvim_win_get_buf(orig))
    copy_win_options(orig, new)
    if orig == focused then
      land = new
    end
  end
  for _, pair in ipairs(leaves) do
    local view = vim.api.nvim_win_call(pair[2], vim.fn.winsaveview)
    vim.api.nvim_win_call(pair[1], function()
      vim.fn.winrestview(view)
    end)
  end
  vim.api.nvim_set_current_win(land)
  winmark.clear(vim.api.nvim_win_get_tabpage(marked[1]))
end

return M
