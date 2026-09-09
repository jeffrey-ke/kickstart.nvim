-- haunt.nvim -- annotations that live outside the file.
--
-- A note is an extmark (`right_gravity = true`) rendered as `virt_text`, so it
-- rides the line it is attached to while you edit above, below, or inside it.
-- Storage is one JSON file per project *per git branch*, keyed by the git root
-- commit, under `data_dir` -- nothing is ever written into the source file, so
-- nothing reaches git.
--
-- The one gap: only `{file, line, note, id}` is persisted. Line drift is exact
-- while the buffer is open, but a change made to the file while nvim is closed
-- (a pull, a formatter) is not re-anchored -- the note comes back on its old
-- line number.
--
-- Upstream suggests `<leader>h` as the prefix; that is taken here twice over
-- (window-left in lua/keymaps.lua, and which-key's 'Git [H]unk' group), so this
-- uses `<leader>n` for a[n]notation.
return {
  'TheNoeTrevino/haunt.nvim',
  opts = {
    -- Faint, blame-style: end of line, comment-colored.
    virt_text_pos = 'eol',
    virt_text_hl = 'Comment',
    annotation_prefix = '  󰆉 ',
    sign = '󱙝',
    sign_hl = 'DiagnosticInfo',
    per_branch_bookmarks = true,
    picker = 'auto',
  },
  init = function()
    local map = vim.keymap.set
    local prefix = '<leader>n'

    -- Deferred requires: the modules load with the plugin, not with this file.
    local function api(fn, ...)
      local args = { ... }
      return function()
        require('haunt.api')[fn](unpack(args))
      end
    end

    map('n', prefix .. 'n', api 'annotate', { desc = 'A[n]notate this line' })
    map('n', prefix .. 'e', api 'annotate', { desc = '[E]dit this annotation' })
    map('n', prefix .. 'd', api 'delete', { desc = '[D]elete annotation on this line' })
    map('n', prefix .. 'c', api 'clear', { desc = '[C]lear this file\'s annotations' })
    map('n', prefix .. 'C', api 'clear_all', { desc = '[C]lear every annotation, all files' })
    map('n', prefix .. 't', api 'toggle_annotation', { desc = '[T]oggle this annotation (hide, keep)' })
    map('n', prefix .. 'T', api 'toggle_all_lines', { desc = '[T]oggle all annotations' })
    map('n', prefix .. 'j', api 'next', { desc = 'Next annotation' })
    map('n', prefix .. 'k', api 'prev', { desc = 'Previous annotation' })
    map('n', prefix .. 'l', function()
      require('haunt.picker').show()
    end, { desc = '[L]ist annotations (picker)' })
    map('n', prefix .. 'q', api 'to_quickfix', { desc = 'Annotations to [q]uickfix' })

    -- Region highlight + note in one stroke: <prefix>a / <prefix>1-9, visual or
    -- with a count. Needs vim-highlighter too (lua/custom/plugins/highlighter.lua).
    require('custom.annot').setup(prefix)
  end,
}
