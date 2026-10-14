-- Telescope picker over tab pages, the tab counterpart of `builtin.buffers`.
--
-- Telescope ships no tab picker. Each entry is one tab: its number, then the
-- file of every window in it, the focused window first since that is the one
-- you land in. The preview is that focused window's buffer at its cursor line,
-- copied from memory: a tab's buffers are always loaded, and `grep_previewer`
-- would read a fugitive buffer's URL as a path on disk (fugitive leaves
-- `buftype` empty, the field telescope checks) and preview nothing.
--
-- A tab whose windows all show one file at different revisions -- what
-- `:Git difftool -y` (and so `git ndt`) opens per file -- collapses to one
-- line: path, status, revisions. Its buffer names are fugitive:// URLs carrying
-- the git dir and a full sha, which bury the path and drown the fuzzy match.
local M = {}

-- Revision and repo-relative path of a fugitive buffer, or nil for any other.
-- `FugitiveParse` yields `<sha>:<path>`, or `:<stage>:<path>` for the index.
local function fugitive_side(name)
  if not vim.startswith(name, 'fugitive://') then
    return nil
  end
  local ok, parsed = pcall(vim.fn.FugitiveParse, name)
  if not ok then
    return nil
  end
  local object, dir = parsed[1], parsed[2]
  local stage, staged_path = object:match '^:(%d):(.*)$'
  if stage then
    return { rev = stage == '0' and 'index' or ':' .. stage, path = staged_path, dir = dir }
  end
  local commit, path = object:match '^(.-):(.*)$'
  if not commit then
    return nil
  end
  return { rev = commit:match '^%x+$' and commit:sub(1, 7) or commit, path = path, dir = dir }
end

local function buf_label(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local side = fugitive_side(name)
  if side then
    return side.rev .. ':' .. side.path
  end
  name = vim.fn.fnamemodify(name, ':~:.')
  return name == '' and '[No Name]' or name
end

-- Floating windows (Telescope's own, notifications) are not part of the tab's
-- layout.
local function layout_wins(tab)
  return vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).relative == ''
  end, vim.api.nvim_tabpage_list_wins(tab))
end

-- `{ path, status, revs }` when every window in the tab shows the same file at
-- a different revision, else nil. Windows come in layout order, so the
-- leftmost is the old side. A side fugitive could not find is an empty buffer
-- with `b:fugitive_type` unset (fugitive#BufReadCmd), which is how an added
-- or deleted file is told apart without asking git.
local function diff_summary(tab)
  local wins = layout_wins(tab)
  if #wins < 2 then
    return nil
  end
  local sides, dir = {}, nil
  for _, win in ipairs(wins) do
    local buf = vim.api.nvim_win_get_buf(win)
    local name = vim.api.nvim_buf_get_name(buf)
    local side = fugitive_side(name)
    if side then
      side.missing = vim.b[buf].fugitive_type == nil
      dir = dir or side.dir
    else
      side = { rev = 'worktree', abs = name, missing = vim.fn.filereadable(name) == 0 }
    end
    table.insert(sides, side)
  end
  if not dir then
    return nil
  end
  local worktree = vim.fn.FugitiveWorkTree(dir)
  for _, side in ipairs(sides) do
    if side.abs then
      if worktree == '' or not vim.startswith(side.abs, worktree .. '/') then
        return nil
      end
      side.path = side.abs:sub(#worktree + 2)
    end
    if side.path ~= sides[1].path then
      return nil
    end
  end
  local status = sides[1].missing and 'A' or sides[#sides].missing and 'D' or 'M'
  local revs = vim.tbl_map(function(side)
    return side.rev
  end, sides)
  return { path = sides[1].path, status = status, revs = table.concat(revs, '..') }
end

local function window_list(tab)
  local focused = vim.api.nvim_tabpage_get_win(tab)
  local names = { buf_label(vim.api.nvim_win_get_buf(focused)) }
  for _, win in ipairs(layout_wins(tab)) do
    if win ~= focused then
      table.insert(names, buf_label(vim.api.nvim_win_get_buf(win)))
    end
  end
  return table.concat(names, ', ')
end

local function tab_entries()
  local current = vim.api.nvim_get_current_tabpage()
  local entries = {}
  for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local focused = vim.api.nvim_tabpage_get_win(tab)
    local prefix = ('%s%d: '):format(tab == current and '%' or ' ', i)
    local diff = diff_summary(tab)
    table.insert(entries, {
      tab = tab,
      prefix = prefix,
      diff = diff,
      label = diff and (diff.status .. ' ' .. diff.path) or window_list(tab),
      bufnr = vim.api.nvim_win_get_buf(focused),
      lnum = vim.api.nvim_win_get_cursor(focused)[1],
    })
  end
  -- Pad diff labels to a common width so their revisions line up in a column.
  local width = 0
  for _, e in ipairs(entries) do
    if e.diff then
      width = math.max(width, vim.fn.strdisplaywidth(e.label))
    end
  end
  for _, e in ipairs(entries) do
    local label = e.label
    if e.diff then
      label = label .. (' '):rep(width - vim.fn.strdisplaywidth(label)) .. '  ' .. e.diff.revs
    end
    e.label = e.prefix .. label
  end
  return entries
end

local function buffer_previewer()
  local previewers = require 'telescope.previewers'
  local highlighter = require('telescope.previewers.utils').highlighter
  return previewers.new_buffer_previewer {
    title = 'Tab',
    define_preview = function(self, entry)
      local lines = vim.api.nvim_buf_get_lines(entry.bufnr, 0, -1, false)
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
      highlighter(self.state.bufnr, vim.bo[entry.bufnr].filetype)
      local lnum = math.min(entry.lnum, math.max(#lines, 1))
      pcall(vim.api.nvim_win_set_cursor, self.state.winid, { lnum, 0 })
      vim.api.nvim_win_call(self.state.winid, function()
        vim.cmd 'normal! zz'
      end)
    end,
  }
end

function M.pick(opts)
  local pickers = require 'telescope.pickers'
  local finders = require 'telescope.finders'
  local actions = require 'telescope.actions'
  local action_state = require 'telescope.actions.state'
  local conf = require('telescope.config').values

  opts = opts or {}
  pickers
    .new(opts, {
      prompt_title = 'Tabs',
      finder = finders.new_table {
        results = tab_entries(),
        entry_maker = function(e)
          return {
            value = e.tab,
            display = e.label,
            ordinal = e.label,
            bufnr = e.bufnr,
            lnum = e.lnum,
          }
        end,
      },
      sorter = conf.generic_sorter(opts),
      previewer = buffer_previewer(),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry and vim.api.nvim_tabpage_is_valid(entry.value) then
            vim.api.nvim_set_current_tabpage(entry.value)
          end
        end)
        return true
      end,
    })
    :find()
end

-- Exposed for tests: the labels `pick` would show.
M._labels = function()
  return vim.tbl_map(function(e)
    return e.label
  end, tab_entries())
end

return M
