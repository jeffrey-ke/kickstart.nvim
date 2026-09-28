-- A location list, in memory, in one shape every producer and consumer agrees
-- on -- so a search does not decide where its results go, and a list does not
-- care what produced it.
--
--   location = { filename = path | bufnr = n,  lnum = 1-based,  col = 1-based,  text = comment }
--
-- That is the item shape setqflist and setloclist take, so loading needs no
-- conversion, and it is the shape the pointer skill's saved .json lists use.
--
-- Producers: `from_vimgrep` (rg output), custom.local_def (scope lookup).
-- Consumer: `load`, into a window's location list or the quickfix list.

local M = {}

--- Pure. rg/grep `--vimgrep` lines (`path:lnum:col:text`) to locations.
function M.from_vimgrep(lines)
  local out = {}
  for _, line in ipairs(lines) do
    local filename, lnum, col, text = line:match '^(.-):(%d+):(%d+):(.*)$'
    if filename then
      out[#out + 1] = { filename = filename, lnum = tonumber(lnum), col = tonumber(col), text = text }
    end
  end
  return out
end

--- Load `locations` into a list and optionally jump and open it.
---
---   opts.target  'loclist' (default) | 'quickfix'
---   opts.win     window owning the location list; default the current one
---   opts.title   list title
---   opts.jump    go to the first entry (default true)
---   opts.open    open the list window (default false)
---
--- Jumping and opening run in `opts.win`, and focus stays where it was: the
--- cursor lands on the first hit in that window, and an opened list appears
--- below it without taking over. The location list is the default because the
--- quickfix list holds what was deliberately loaded -- a pointer list, a
--- `:Cload`, a `:Make` -- and a throwaway search should not replace it.
---
--- Returns false, touching nothing, when `locations` is empty.
function M.load(locations, opts)
  opts = opts or {}
  if #locations == 0 then
    return false
  end
  local win = opts.win or vim.api.nvim_get_current_win()
  local what = { title = opts.title, items = locations }
  local quickfix = opts.target == 'quickfix'
  if quickfix then
    vim.fn.setqflist({}, ' ', what)
  else
    vim.fn.setloclist(win, {}, ' ', what)
  end
  vim.api.nvim_win_call(win, function()
    if opts.jump ~= false then
      pcall(vim.cmd, quickfix and 'cfirst' or 'lfirst')
    end
    if opts.open then
      vim.cmd(quickfix and 'copen' or 'lopen')
    end
  end)
  return true
end

return M
