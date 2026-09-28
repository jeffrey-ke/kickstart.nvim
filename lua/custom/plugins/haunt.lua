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

-- The stock snacks row is `filename dir/:line note` in the left half of the
-- float, so under a deep tree the note -- the one part worth reading -- runs
-- off the edge. This shortens the path to initials (`pathshorten`:
-- `learning/behavior/x.cc` -> `l/b/x.cc`), pads it to one column so the notes
-- line up, and stacks the file preview under a full-width list instead of
-- beside it. Search still sees the full path: that is `item.text`, untouched.
--
-- Wrapping `show` rather than passing these from the keymap is what keeps
-- the view after an `a` edit in the picker, which reopens via a bare `show()`.
local function install_picker_view()
  local router = require 'haunt.picker'
  local show = router.show
  router.show = function(opts)
    local width = 0
    show(vim.tbl_deep_extend('force', {
      layout = { preset = 'vertical', layout = { width = 0.8 } },
      finder = function()
        local items = require('haunt.picker.utils').build_picker_items(require('haunt.api').get_bookmarks())
        width = 0
        for _, item in ipairs(items) do
          item.short = vim.fn.pathshorten(item.relpath)
          width = math.max(width, vim.fn.strdisplaywidth(item.short .. ':' .. item.line))
        end
        return items
      end,
      format = function(item)
        local dir, base = item.short:match '^(.*/)(.*)$'
        local loc = ':' .. item.line
        local pad = width - vim.fn.strdisplaywidth(item.short .. loc)
        return {
          { dir or '', 'SnacksPickerDir' },
          { base or item.short, 'SnacksPickerFile' },
          { loc, 'SnacksPickerMatch' },
          { string.rep(' ', pad + 2) },
          { item.note or '' },
        }
      end,
    }, opts or {}))
  end
end

return {
  'TheNoeTrevino/haunt.nvim',
  opts = {
    -- End of line, washed like a highlight: `HauntAnnotation` is linked to a
    -- fixed group in custom/annot.lua (`vim.g.annot_note_hl`), so a note reads
    -- as a solid chip. That is the opaque `HiColor` palette, not the
    -- background-only pack the pens use -- there is no code under a note to
    -- keep legible. Set it to 'Comment' for faint blame-style ghost text.
    virt_text_pos = 'eol',
    virt_text_hl = 'HauntAnnotation',
    annotation_prefix = '  󰆉 ',
    sign = '󱙝',
    sign_hl = 'DiagnosticInfo',
    per_branch_bookmarks = true,
    -- Pinned, not 'auto': install_picker_view() passes snacks-shaped opts.
    picker = 'snacks',
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

    -- Both go through custom/annot.lua's editor rather than haunt's own
    -- `vim.fn.input`: a scratch buffer in a float, so vim keys work while
    -- writing a note. It prefills from the note already on the line, which is
    -- what makes these two the same key in different clothes.
    local function edit_note()
      require('custom.annot').edit_note()
    end

    -- `nn` washes the line as well as noting it -- the same pen, the same
    -- all-or-nothing rollback as `na`, just with the motion fixed at one line
    -- (`{count}` takes more). An annotated line then reads as annotated at a
    -- glance instead of as ordinary code with something trailing off the end.
    -- `reuse_wash` is what keeps it re-pressable on a line already washed.
    --
    -- `ne` stays the bare editor, for rewording a note without touching a wash
    -- -- including on a line whose wash came from the middle of an `na` region,
    -- where laying a one-line wash of the current pen would streak it.
    map('n', prefix .. 'n', function()
      require('custom.annot').region { count = vim.v.count, reuse_wash = true }
    end, { desc = 'A[n]notate this line, washed in the pen color' })
    map('n', prefix .. 'e', edit_note, { desc = '[E]dit this annotation (no wash)' })
    map('n', prefix .. 'z', function()
      require('custom.annot').toggle_box()
    end, { desc = 'Fold this annotation: inline <-> box above the line' })
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
  -- Explicit, so the inline-note clipping is installed over `haunt.display`
  -- before anything renders -- `init` runs too early to require that module.
  config = function(_, opts)
    require('haunt').setup(opts)
    require('custom.annot').install_clipping()
    install_picker_view()
  end,
}
