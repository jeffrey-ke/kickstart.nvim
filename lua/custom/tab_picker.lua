-- Telescope picker over tab pages, the tab counterpart of `builtin.buffers`.
--
-- Telescope ships no tab picker. Each entry is one tab: its number, then the
-- file of every window in it, the focused window first since that is the one
-- you land in. The preview is that focused window's buffer at its cursor line.
-- Entries carry `bufnr`/`lnum` because that is what `grep_previewer` reads --
-- the same fields `builtin.buffers` hands it -- so unsaved and non-file buffers
-- (terminals, scratch) preview from memory rather than from disk.
local M = {}

local function buf_label(buf)
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':~:.')
  return name == '' and '[No Name]' or name
end

local function tab_entries()
  local current = vim.api.nvim_get_current_tabpage()
  local entries = {}
  for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local focused = vim.api.nvim_tabpage_get_win(tab)
    local buf = vim.api.nvim_win_get_buf(focused)
    local names = { buf_label(buf) }
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      -- Floating windows (Telescope's own, notifications) are not part of the
      -- tab's layout.
      if win ~= focused and vim.api.nvim_win_get_config(win).relative == '' then
        table.insert(names, buf_label(vim.api.nvim_win_get_buf(win)))
      end
    end
    local label = ('%s%d: %s'):format(tab == current and '%' or ' ', i, table.concat(names, ', '))
    table.insert(entries, {
      tab = tab,
      label = label,
      bufnr = buf,
      lnum = vim.api.nvim_win_get_cursor(focused)[1],
    })
  end
  return entries
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
            filename = vim.api.nvim_buf_get_name(e.bufnr),
            lnum = e.lnum,
          }
        end,
      },
      sorter = conf.generic_sorter(opts),
      previewer = conf.grep_previewer(opts),
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

return M
