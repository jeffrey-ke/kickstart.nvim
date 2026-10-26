-- Marks on windows: a flag a window carries, for whatever wants to act on a
-- chosen subset of the splits later. This module only stores, lists and shows
-- marks; what a mark *means* belongs to the caller (`custom.tab_take` opens the
-- marked windows of a tab in a new one).
--
-- The mark is the window variable `w:winmark`, so it lives and dies with the
-- window: no table of window ids to go stale, and Vimscript can read it too.
-- A split does not copy `w:` variables (measured), so the new half of a marked
-- window starts unmarked.
--
-- Every change fires `User WinMarkChanged` with `data = { win, marked }`.
local M = {}

local VAR = 'winmark'

-- Shown as the winbar of marked windows only. Not the statusline: it is global
-- (`laststatus=3`), so it could only ever show the focused window's mark.
local BAR = '%#WinMark# marked %*'

-- `win` may be nil or 0 for the current window, as in the API.
local function resolve(win)
  return (win == nil or win == 0) and vim.api.nvim_get_current_win() or win
end

function M.is_marked(win)
  return vim.w[resolve(win)][VAR] == true
end

-- Make `win`'s winbar match its mark. A winbar that is not ours is left alone
-- when unmarking.
local function sync(win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local marked = M.is_marked(win)
  local current = vim.api.nvim_get_option_value('winbar', { win = win, scope = 'local' })
  if marked and current ~= BAR then
    vim.api.nvim_set_option_value('winbar', BAR, { win = win, scope = 'local' })
  elseif not marked and current == BAR then
    vim.api.nvim_set_option_value('winbar', '', { win = win, scope = 'local' })
  end
end

function M.set(win, marked)
  win = resolve(win)
  vim.w[win][VAR] = marked or nil
  sync(win)
  vim.api.nvim_exec_autocmds('User', { pattern = 'WinMarkChanged', data = { win = win, marked = marked == true } })
end

function M.toggle(win)
  M.set(win, not M.is_marked(win))
end

-- Marked windows of `tab` (default: current), in window-number order, which is
-- layout order: top-left to bottom-right.
function M.list(tab)
  return vim.tbl_filter(M.is_marked, vim.api.nvim_tabpage_list_wins(tab or 0))
end

function M.clear(tab)
  for _, win in ipairs(M.list(tab)) do
    M.set(win, false)
  end
end

-- A split copies window-local options, so the new half of a marked window
-- inherits the bar without the mark. Scheduled, so that whatever created the
-- window has finished setting its options first (`tab_take` copies them in).
-- Every window, since one opened by `nvim_open_win(enter=false)` is not the
-- current window when WinNew fires.
vim.api.nvim_create_autocmd('WinNew', {
  group = vim.api.nvim_create_augroup('winmark-sync', { clear = true }),
  callback = function()
    vim.schedule(function()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        sync(win)
      end
    end)
  end,
})

-- Re-linked on ColorScheme, since `:hi clear` drops groups it did not define.
local function set_hl()
  vim.api.nvim_set_hl(0, 'WinMark', { link = 'IncSearch', default = true })
end
set_hl()
vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('winmark-hl', { clear = true }),
  callback = set_hl,
})

return M
