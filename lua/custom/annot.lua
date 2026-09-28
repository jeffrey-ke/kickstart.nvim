-- Highlight a region and annotate it in one stroke, in a color you choose.
--
-- Composes vim-highlighter's positional highlight with haunt.nvim's note, over
-- the same span: the wash marks the logical grouping, the note says what it is.
--
-- Color is one global "pen" -- `vim.g.annot_pen` -- and nothing here ever picks
-- a color on its own. Set it once; every highlight after that uses it, whether
-- it came from the operator below or from a bare `t<CR>`. Pin a default in your
-- config with `vim.g.annot_pen = 3` if 1 is not the one you want.
--
-- A pen is an index into vim-highlighter's *background-only* colors, not its
-- default palette: `HiColor1..14` each set a foreground too, so a wash of one
-- flattens the syntax highlighting underneath it -- every cell in the span
-- comes out the same color. `HiColor80..89` set only a background, so
-- treesitter's colors show through. The plugin calls those its multiline colors
-- (`s:MultilineColor`, autoload/highlighter.vim) and honors them anywhere.
--
-- `f<CR>`, the pattern highlighter, is the plugin's own key and still cycles the
-- opaque palette -- it colors every occurrence of a word, which is a different
-- job from washing a region.
--
-- `t<CR>` reaches the pen because `vim.g.HiSetSL = ''` suppresses the plugin's
-- own mapping (plugin/highlighter.vim skips a key whose g: override is empty)
-- and it is redefined here. `f<CR>` is deliberately left alone: passing it an
-- explicit color would disable its toggle-off behavior, since vim-highlighter
-- only honors `g:HiSetToggle` when no color argument is given.
local M = {}

local ESC = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
local CTRL_V = vim.api.nvim_replace_termcodes('<C-v>', true, false, true)

-- Pen 1 is `HiColor80`, the first background-only color.
local PACK_BASE = 79

-- vim-highlighter defines its color groups lazily, inside `s:Load()`, on the
-- first command -- so this can legitimately be 0 before anything has been
-- highlighted. Memoized only once nonzero. Counted rather than hardcoded at 6,
-- so a `HiColor86` defined by hand joins the pen automatically.
local max_pen
local function pen_count()
  if not max_pen or max_pen == 0 then
    max_pen = 0
    while vim.fn.hlexists('HiColor' .. (PACK_BASE + max_pen + 1)) == 1 do
      max_pen = max_pen + 1
    end
  end
  return max_pen
end

-- Force the color groups into existence. Every `highlighter#Command` runs
-- `s:Load()` first, and '/' is stripped to the empty command, whose only effect
-- is echoing the version banner -- hence `silent`.
local function ensure_loaded()
  if pen_count() == 0 then
    pcall(vim.cmd, 'silent! call highlighter#Command("/")')
    max_pen = nil
  end
  return pen_count()
end

--- The pen: a 1-based index into the background-only pack, clamped to what
--- actually exists.
---@return integer
local function pen()
  local i = math.floor(tonumber(vim.g.annot_pen) or 1)
  local n = pen_count()
  if n > 0 then
    i = math.min(math.max(i, 1), n)
  end
  return math.max(i, 1)
end

--- The same pen as vim-highlighter numbers its colors -- pen 1 is 80. This is
--- what `highlighter#Command` takes, and what the `HiColor` group names use.
---@param index? integer a one-off pen index, else the current pen
---@return integer
local function pen_color(index)
  return PACK_BASE + (index or pen())
end

--- Give haunt's note a wash of its own, in one fixed color:
--- `vim.g.annot_note_hl`, read here, *not* the pen.
---
--- A highlight group *name*, not a number, so it cannot be mistaken for a pen
--- index. It defaults into the opaque `HiColor1..14` palette rather than the
--- background-only pack the pens use: a note is virtual text with no code
--- underneath it, so there is no syntax to preserve and a solid chip reads
--- better than a tint. `'Comment'` gives faint blame-style ghost text instead.
---
--- Per-note colors are not
--- on offer -- haunt bakes the group name into each extmark but persists only
--- `{file, line, note}`, so every note re-rendered after a reload or a
--- `toggle_all_lines` would come back in whichever color was configured then.
---
--- A link rather than copied attributes: `:colorscheme` runs `hi clear`, and
--- vim-highlighter re-tunes `HiColor*` for dark/light from its own ColorScheme
--- autocmd. Linking resolves at draw time, so this follows that retune without
--- having to run after it.
function M.define_note_hl()
  -- Forced, not just linked: a file with notes but no saved washes never runs a
  -- `:Hi` command, and the link would resolve to an undefined group.
  ensure_loaded()
  vim.api.nvim_set_hl(0, 'HauntAnnotation', { link = vim.g.annot_note_hl or 'HiColor9' })
end

--- Echo every available color as a numbered swatch, in its own color.
function M.show_palette()
  local n = ensure_loaded()
  if n == 0 then
    return vim.notify('annot: vim-highlighter has no colors loaded', vim.log.levels.WARN)
  end
  local chunks = { { 'pen ' }, { (' %d '):format(pen()), 'HiColor' .. pen_color() }, { '   of   ' } }
  for i = 1, n do
    chunks[#chunks + 1] = { (' %d '):format(i), 'HiColor' .. pen_color(i) }
  end
  vim.api.nvim_echo(chunks, false, {})
end

--- Set the pen. No argument (or 0) shows the palette instead.
---@param color? integer
function M.set_pen(color)
  if not color or color <= 0 then
    return M.show_palette()
  end
  local n = ensure_loaded()
  if n > 0 and color > n then
    return vim.notify(('annot: color %d out of range, %d available'):format(color, n), vim.log.levels.WARN)
  end
  vim.g.annot_pen = color
  vim.api.nvim_echo({ { 'pen ' }, { (' %d '):format(color), 'HiColor' .. pen_color(color) } }, false, {})
end

-- vim-highlighter's own extmark namespace, `nvim_create_namespace('HiColor')`.
-- Its save routine enumerates these marks live rather than keeping a side
-- table, so deleting a mark is complete cleanup -- nothing goes stale.
local function hi_namespace()
  return vim.api.nvim_get_namespaces().HiColor
end

local function mark_ids(ns)
  local ids = {}
  if ns then
    for _, e in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})) do
      ids[e[1]] = true
    end
  end
  return ids
end

--- Delete whatever washes appeared since `before`. Exact rather than
--- positional, so an overlapping pre-existing highlight is never collateral.
local function rollback(ns, before)
  if not ns then
    return
  end
  for _, e in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})) do
    if not before[e[1]] then
      pcall(vim.api.nvim_buf_del_extmark, 0, ns, e[1])
    end
  end
end

--- Is a wash already covering `row` (1-based)? `overlap`, so a wash that began
--- on an earlier line counts.
---@param row integer
---@return boolean
local function washed(row)
  local ns = hi_namespace()
  if not ns then
    return false
  end
  local marks =
    vim.api.nvim_buf_get_extmarks(0, ns, { row - 1, 0 }, { row - 1, -1 }, { details = true, overlap = true })
  for _, m in ipairs(marks) do
    if m[4].hl_group or m[4].line_hl_group then
      return true
    end
  end
  return false
end

--- Highlight a span with the pen. Assumes '< and '> are set.
---@param index? integer one-off pen index, else the current pen
local function highlight(index)
  local ok, err = pcall(vim.fn['highlighter#Command'], '+x%', pen_color(index))
  if not ok then
    vim.notify('annot: highlight failed: ' .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  return true
end

--- Recolor the wash under the cursor to the current pen, in place.
---
--- Overwriting an extmark by `id` keeps its span, so this leaves the note and
--- any neighbouring wash alone -- `f<BS>` and re-marking would lose the span
--- and could take an overlapping wash with it.
---
--- A wash is either an `hl_group` over a span or a `line_hl_group` over whole
--- lines (`s:SetPosHighlight`), so whichever it carries is the one replaced.
function M.recolor()
  local ns = hi_namespace()
  if not ns then
    return vim.notify('annot: nothing highlighted yet', vim.log.levels.WARN)
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  local row, col = pos[1] - 1, pos[2]
  -- `overlap`, so a wash that began on an earlier line counts as under us.
  local marks = vim.api.nvim_buf_get_extmarks(0, ns, { row, col }, { row, col }, { details = true, overlap = true })
  local group = 'HiColor' .. pen_color()
  local n = 0
  for _, m in ipairs(marks) do
    local d = m[4]
    if d.hl_group or d.line_hl_group then
      vim.api.nvim_buf_set_extmark(0, ns, m[2], m[3], {
        id = m[1],
        end_row = d.end_row,
        end_col = d.line_hl_group and nil or d.end_col,
        hl_group = d.hl_group and group or nil,
        line_hl_group = d.line_hl_group and group or nil,
      })
      n = n + 1
    end
  end
  if n == 0 then
    return vim.notify('annot: no wash under the cursor', vim.log.levels.WARN)
  end
  M.autosave()
  vim.api.nvim_echo({ { ('recolored %d to '):format(n) }, { (' %d '):format(pen()), group } }, false, {})
end

--- Highlight a region and prompt for its annotation.
---
--- `reuse_wash` is for the single-line key, `<leader>nn`, which doubles as a
--- re-edit of the note already on the line: pressing it on a line that is
--- already washed keeps that wash rather than stacking a second identical mark
--- over it, which would then take two `f<BS>` to remove. Only the region's
--- first line is tested, since that is the line the key is about.
---@param opts? { visual?: boolean, count?: integer, color?: integer, reuse_wash?: boolean }
function M.region(opts)
  opts = opts or {}

  local origin = vim.api.nvim_win_get_cursor(0)

  if not opts.visual then
    -- Set '< and '> the way a real selection would, so `+x%` sees the span.
    -- Leaving visual mode is what writes the marks and visualmode().
    local n = math.max(opts.count or 1, 1)
    vim.cmd.normal { 'V' .. (n > 1 and (n - 1) .. 'j' or '') .. ESC, bang = true }
  end

  local ns = hi_namespace()
  local before = mark_ids(ns)

  if not (opts.reuse_wash and washed(vim.fn.line "'<")) and not highlight(opts.color) then
    return
  end
  -- The namespace only exists once the plugin has highlighted something.
  ns = ns or hi_namespace()

  -- The note belongs on the first line of the region; haunt annotates the
  -- cursor line, and after `V{n}j<Esc>` the cursor sits at the bottom.
  local top = vim.fn.line "'<"
  if top > 0 then
    vim.api.nvim_win_set_cursor(0, { top, 0 })
  end

  -- All or nothing: the pair is one gesture, so discarding the note (`:q!` out
  -- of the editor) undoes the wash too. The editor is a buffer rather than a
  -- prompt, so this arrives by callback -- the wash outlives this function and
  -- is removed later if the note never lands.
  --
  -- Either way the wash is persisted on the spot, so it survives a kill -9 as
  -- the note already would; after a rollback that just rewrites what was there.
  M.edit_note {
    on_done = function()
      M.autosave()
    end,
    on_cancel = function()
      rollback(ns, before)
      pcall(vim.api.nvim_win_set_cursor, 0, origin)
      M.autosave()
    end,
  }
end

--- `operatorfunc` target: called by `g@` once a motion completes, with `'[` and
--- `']` bracketing the operated text. Re-selects that span so `visualmode()`
--- and `'<`/`'>` agree, which is what vim-highlighter's `+x%` reads.
---@param motion 'line'|'char'|'block'
function M.opfunc(motion)
  local sel = (motion == 'line' and 'V') or (motion == 'block' and CTRL_V) or 'v'
  vim.cmd.normal { '`[' .. sel .. '`]' .. ESC, bang = true }
  M.region { visual = true }
end

--- `:{range}HiNote [color]` -- color is a one-off, it does not move the pen.
function M.command(args)
  vim.api.nvim_win_set_cursor(0, { args.line1, 0 })
  M.region {
    count = args.line2 - args.line1 + 1,
    color = tonumber(args.args),
  }
end

-- ---------------------------------------------------------------------------
-- Persistence. vim-highlighter saves only on demand, and bare `:Hi save`
-- shares a single `_.hl` whose positional records carry no file path -- so
-- every save here is keyed to the buffer's own path.
-- ---------------------------------------------------------------------------

--- `/home/jke/x/y.py` -> `home%jke%x%y.py`. nil for anything not a real file.
function M.slug()
  local path = vim.api.nvim_buf_get_name(0)
  if path == '' or vim.bo.buftype ~= '' then
    return nil
  end
  return (vim.fs.normalize(path):gsub('^/', ''):gsub('/', '%%'))
end

local function store_path(name)
  return vim.fs.joinpath(vim.g.HiKeywords or vim.fs.joinpath(vim.fn.stdpath 'data', 'highlighter'), name .. '.hl')
end

--- Does this window hold anything `:Hi save` would write? Positional washes are
--- extmarks in the `HiColor` namespace; pattern highlights are window matches.
function M.has_highlights()
  local ns = hi_namespace()
  if ns and #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) > 0 then
    return true
  end
  for _, m in ipairs(vim.fn.getmatches()) do
    if tostring(m.group):match('^HiColor') then
      return true
    end
  end
  return false
end

--- Write this file's highlights, or delete the store when none are left, so a
--- deleted highlight never comes back. Silent -- for autocmds and hot paths.
function M.autosave()
  local name = M.slug()
  if not name then
    return
  end
  if M.has_highlights() then
    pcall(vim.cmd, { cmd = 'Hi', args = { 'save', name }, mods = { silent = true } })
  -- Only prune once a load has actually run for this buffer. Deleting on the
  -- strength of an empty buffer we never restored would discard the store.
  elseif vim.b.hi_load_ok then
    -- `.hl.o` too: vim-highlighter renames the old store to that on every save
    -- (autoload/highlighter.vim:1220), so leaving it behind would keep a copy
    -- of exactly the highlights that were just deleted.
    for _, p in ipairs { store_path(name), store_path(name) .. '.o' } do
      if vim.uv.fs_stat(p) then
        vim.fn.delete(p)
      end
    end
  end
end

--- Manual save, with a message. `<leader>Hs`.
function M.save()
  local name = M.slug()
  if not name then
    return vim.notify('highlighter: buffer has no file to key highlights to', vim.log.levels.WARN)
  end
  M.autosave()
  vim.notify(
    M.has_highlights() and ('highlighter: saved -> ' .. name .. '.hl') or 'highlighter: no highlights, store cleared',
    vim.log.levels.INFO
  )
end

--- Restore this file's highlights. Sets `b:hi_load_ok`, which gates pruning.
---@param quiet? boolean
function M.load(quiet)
  local name = M.slug()
  if not name then
    return
  end
  if not vim.uv.fs_stat(store_path(name)) then
    -- Nothing saved is a legitimate "loaded" state: an empty buffer is then
    -- known-good, and autosave may prune later.
    vim.b.hi_load_ok = true
    if not quiet then
      vim.notify('highlighter: nothing saved for this file', vim.log.levels.INFO)
    end
    return
  end
  local ok = pcall(vim.cmd, { cmd = 'Hi', args = { 'load', name }, mods = { silent = true } })
  vim.b.hi_load_ok = ok
end

--- Redefine the mutating vim-highlighter keys: `t<CR>` so a bare region
--- highlight uses the pen, and `f<BS>`/`f<C-L>` so a deletion is persisted
--- immediately. Call after the plugin has loaded; requires the matching
--- `vim.g.HiSetSL`/`HiErase`/`HiClear` to be emptied first.
function M.use_pen_for_hi_keys()
  local function wrap(mode, lhs, fn, desc)
    vim.keymap.set(mode, lhs, function()
      fn()
      M.autosave()
    end, { silent = true, desc = desc })
  end

  -- 'n%' highlights the current line positionally.
  wrap('n', 't<CR>', function()
    pcall(vim.fn['highlighter#Command'], '+%', pen_color())
  end, 'Highlight this line (pen color)')

  wrap('x', 't<CR>', function()
    vim.cmd.normal { ESC, bang = true }
    highlight()
  end, 'Highlight selection (pen color)')

  wrap('n', 'f<BS>', function()
    pcall(vim.fn['highlighter#Command'], '-')
  end, 'Erase highlight under cursor')

  wrap('x', 'f<BS>', function()
    vim.cmd.normal { ESC, bang = true }
    pcall(vim.fn['highlighter#Command'], '-x')
  end, 'Erase highlight in selection')

  wrap('n', 'f<C-L>', function()
    pcall(vim.fn['highlighter#Command'], 'clear')
  end, 'Clear all highlights in window')
end

-- ---------------------------------------------------------------------------
-- The note editor, and the fold.
--
-- haunt prompts with `vim.fn.input`, which is cmdline editing and nothing else
-- -- no motions, no undo, no text objects. A scratch buffer in a float is a
-- real buffer, so every vim key works. `api.annotate(text)` takes the string
-- directly, skipping the prompt, and updates an existing note rather than
-- duplicating it, so the editor only has to produce text.
--
-- Same contract as the commit popup in custom/stage_commit.lua: `acwrite`
-- buffer, the work happens in `BufWriteCmd`, `:q!` discards.
-- ---------------------------------------------------------------------------

-- A note keeps its line breaks as a literal backslash-n, which is what haunt's
-- box renderer splits on (display.lua build_box_lines). The editor shows those
-- as real lines; `eol` shows them escaped, which is a fair rendering of a
-- collapsed multi-line note.
local BREAK = '\\n'

local editor = {}

--- Every note on `line` of the current buffer, and where it now sits. Matched
--- on the extmark's *current* line, since `bookmark.line` goes stale as the
--- buffer is edited.
---@return { bm: table, line: integer }[]
local function bookmarks_here()
  local found = {}
  local file = require('haunt.utils').normalize_filepath(vim.api.nvim_buf_get_name(0))
  for _, bm in ipairs(require('haunt.store').get_all_raw()) do
    if bm.file == file and bm.note then
      local at = bm.extmark_id and require('haunt.display').get_extmark_line(0, bm.extmark_id) or bm.line
      if at then
        found[#found + 1] = { bm = bm, line = at }
      end
    end
  end
  return found
end

--- Is this note currently drawn as a box, or inline? The extmark answers it:
--- `above` renders `virt_lines`, `eol` renders `virt_text`.
---@return 'above'|'eol'
local function mode_of(bm)
  local display = require 'haunt.display'
  local mark = bm.annotation_extmark_id
    and vim.api.nvim_buf_get_extmark_by_id(0, display.get_namespace(), bm.annotation_extmark_id, { details = true })
  return (mark and mark[3] and mark[3].virt_lines) and 'above' or 'eol'
end

--- Re-render one note in `pos` mode, reassigning its extmark in place. The
--- global `virt_text_pos` is what haunt reads, so it is flipped and restored
--- around the single render, leaving every other note as it was.
---@param pos 'above'|'eol'
local function render_as(bm, line, pos)
  local display = require 'haunt.display'
  local config = require 'haunt.config'
  local restore = config.get().virt_text_pos or 'eol'
  config.setup { virt_text_pos = pos }
  if bm.annotation_extmark_id then
    display.hide_annotation(0, bm.annotation_extmark_id)
  end
  local ok, id = pcall(display.show_annotation, 0, line, bm.note)
  bm.annotation_extmark_id = ok and id or nil
  config.setup { virt_text_pos = restore }
end

--- The live bookmark on `line` of the current buffer, or nil.
---@param line integer
---@return table|nil
local function bookmark_at(line)
  for _, e in ipairs(bookmarks_here()) do
    if e.line == line then
      return e.bm
    end
  end
end

--- Edit the note on the cursor line -- or write a new one -- with full vim
--- keys. `:w` applies, `:q!` discards.
---
--- Asynchronous, unlike the prompt it replaces: the caller learns the outcome
--- through `on_done`/`on_cancel` rather than a return value, which is what
--- keeps `M.region`'s all-or-nothing rollback working.
---@param opts? { on_done?: fun(), on_cancel?: fun() }
function M.edit_note(opts)
  opts = opts or {}

  if editor.win and vim.api.nvim_win_is_valid(editor.win) then
    return vim.api.nvim_set_current_win(editor.win)
  end

  local target_win = vim.api.nvim_get_current_win()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local existing = bookmark_at(line)

  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, vim.fn.tempname() .. '/ANNOTATION')
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  local body = existing and vim.split(existing.note, BREAK, { plain = true }) or { '' }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, body)
  vim.bo[buf].modified = false

  -- Width follows `above_max_width`, so a line that fits here fits the box.
  local width = math.min(require('haunt.config').get().above_max_width or 80, math.floor(vim.o.columns * 0.8))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = width,
    height = math.min(10, math.max(2, #body + 1)),
    border = 'rounded',
    title = existing and ' edit annotation ' or ' annotation ',
    style = 'minimal',
  })
  editor.win, editor.buf = win, buf

  local applied = false
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = function()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      while #lines > 0 and lines[#lines]:match '^%s*$' do
        lines[#lines] = nil
      end
      -- Left modified on purpose, so `:wq` blocks rather than dropping the
      -- note silently. `:q!` is how you abandon it.
      if #lines == 0 then
        return vim.notify('annot: empty annotation', vim.log.levels.ERROR)
      end
      local text = table.concat(lines, BREAK)
      vim.api.nvim_win_call(target_win, function()
        vim.api.nvim_win_set_cursor(target_win, { line, 0 })
        require('haunt.api').annotate(text)
      end)
      vim.bo[buf].modified = false
      applied = true
    end,
  })

  -- Deferred, and run in the window the note belongs to: during `BufWipeout`
  -- the editor is still the current buffer, so a callback reaching for buffer 0
  -- -- as the wash rollback and the highlight autosave both do -- would act on
  -- the wrong one and silently do nothing.
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    callback = function()
      editor.win, editor.buf = nil, nil
      local done = applied and opts.on_done or opts.on_cancel
      if not done then
        return
      end
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(target_win) then
          vim.api.nvim_win_call(target_win, done)
        end
      end)
    end,
  })

  vim.cmd 'startinsert!'
end

--- Clip an inline note to the room left on its line, marking the cut with an
--- ellipsis. Nothing can reach eol virtual text -- no motion, no `$` -- so an
--- unclipped long note is simply unreadable past the window edge; the ellipsis
--- says the fold has the rest.
local function clip(bufnr, line, note)
  local cfg = require('haunt.config').get()
  if (cfg.virt_text_pos or 'eol') == 'above' then
    return note
  end
  -- `win_findbuf` does not take nvim's buffer-0-means-current convention, which
  -- the render paths do pass; left as 0 it finds no window and nothing is
  -- clipped at all.
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local wins = vim.fn.win_findbuf(bufnr)
  if #wins == 0 then
    return note
  end
  local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ''
  -- The extmark belongs to the buffer, not to a window, so a buffer open in two
  -- splits of different widths has one clip to serve both. Take the narrowest,
  -- which is the only choice that cannot overflow in either.
  local room = math.huge
  for _, win in ipairs(wins) do
    local info = vim.fn.getwininfo(win)[1]
    room = math.min(
      room,
      info.width
        - info.textoff
        - vim.fn.strdisplaywidth(text)
        - vim.fn.strdisplaywidth(cfg.annotation_prefix or '')
        - vim.fn.strdisplaywidth(cfg.annotation_suffix or '')
    )
  end
  if vim.fn.strdisplaywidth(note) <= room then
    return note
  end
  -- Nothing beyond the window edge, ever: the renderer clips there, which would
  -- take the marker with it and leave a long note looking complete.
  if room <= 0 then
    return ''
  end
  -- Measured in cells rather than characters, so a note carrying anything
  -- double-width still lands inside the budget. Seeded at `room` characters,
  -- already the answer for the ASCII case.
  local kept = vim.fn.strcharpart(note, 0, room)
  while kept ~= '' and vim.fn.strdisplaywidth(kept .. '…') > room do
    kept = vim.fn.strcharpart(kept, 0, vim.fn.strchars(kept) - 1)
  end
  return kept .. '…'
end

--- Re-clip every collapsed note in the current buffer. Called whenever the
--- window geometry changes, since the clip is measured against it.
function M.reclip()
  for _, e in ipairs(bookmarks_here()) do
    if mode_of(e.bm) == 'eol' then
      render_as(e.bm, e.line, 'eol')
    end
  end
end

--- Wrap haunt's renderer so the clip applies to every path that draws a note --
--- create, restore, toggle, reload, the fold -- rather than to a list of events
--- that would have to be kept in step with the plugin. Only the string handed
--- to the renderer is clipped; the store keeps the whole note.
function M.install_clipping()
  local display = require 'haunt.display'
  if display._annot_clipping then
    return
  end
  display._annot_clipping = true

  local show = display.show_annotation
  display.show_annotation = function(bufnr, line, note)
    return show(bufnr, line, clip(bufnr, line, note))
  end

  -- The clip is computed against the window width, so it has to be redone when
  -- the geometry changes. `WinResized` does not cover a split -- opening one
  -- fires only `WinNew`, though it halves the width -- hence all four events.
  -- Deferred, because at `WinNew` the new window's width is not settled yet.
  --
  -- Collapsed notes only: an open box is already wrapped to `above_max_width`
  -- and clamped to the window by haunt itself.
  vim.api.nvim_create_autocmd({ 'VimResized', 'WinResized', 'WinNew', 'WinClosed' }, {
    desc = 'Re-clip inline annotations when the window geometry changes',
    group = vim.api.nvim_create_augroup('annot-reclip', { clear = true }),
    callback = function()
      vim.schedule(M.reclip)
    end,
  })
end

--- Fold the note on this line: inline (as stored) or a box above the line.
---
--- haunt reads `virt_text_pos` once per render and bakes the outcome into the
--- extmark -- `above` yields `virt_lines`, `eol` yields `virt_text` -- so one
--- note can be re-rendered in the other mode while the rest stay put. The
--- extmark therefore *is* the fold state; there is nothing to track separately
--- and nothing that can fall out of sync.
---
--- Not persisted, deliberately: like folds, every note comes back collapsed.
function M.toggle_box()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local bm = bookmark_at(line)
  if not bm then
    return vim.notify('annot: no annotation on this line', vim.log.levels.WARN)
  end

  render_as(bm, line, mode_of(bm) == 'above' and 'eol' or 'above')
end

--- @param prefix string
function M.setup(prefix)
  -- Re-linked on every colorscheme switch, since `:colorscheme` clears the
  -- group outright and haunt would then link it back to its own default.
  M.define_note_hl()
  vim.api.nvim_create_autocmd('ColorScheme', {
    desc = "Keep haunt's note in the annot note color",
    group = vim.api.nvim_create_augroup('annot-note-hl', { clear = true }),
    callback = M.define_note_hl,
  })

  -- Operator: takes a motion, like `d`. A count typed before it is handed to
  -- the motion by Vim, exactly as in `4dj`.
  vim.keymap.set('n', prefix .. 'a', function()
    vim.o.operatorfunc = "v:lua.require'custom.annot'.opfunc"
    return 'g@'
  end, { expr = true, desc = 'Highlight + annotate {motion}' })

  vim.keymap.set('x', prefix .. 'a', ':<C-u>lua require("custom.annot").region { visual = true }<CR>', {
    silent = true,
    desc = 'Highlight + annotate selection',
  })

  -- Pen selection: digits for the first nine, `p` for the palette or a count.
  for i = 1, 9 do
    vim.keymap.set({ 'n', 'x' }, prefix .. i, function()
      M.set_pen(i)
    end, { desc = 'Set pen to color ' .. i })
  end
  vim.keymap.set('n', prefix .. 'r', function()
    M.recolor()
  end, { desc = '[R]ecolor the wash under the cursor to the pen' })

  vim.keymap.set({ 'n', 'x' }, prefix .. 'p', function()
    M.set_pen(vim.v.count > 0 and vim.v.count or nil)
  end, { desc = 'Show palette, or {count} to set the pen' })

  vim.api.nvim_create_user_command('HiNote', M.command, {
    range = true,
    nargs = '?',
    desc = 'Highlight the range and annotate it: :10,20HiNote [color]',
  })
  vim.api.nvim_create_user_command('HiPen', function(args)
    M.set_pen(tonumber(args.args))
  end, { nargs = '?', desc = 'Set the highlight pen color, or show the palette' })
end

return M
