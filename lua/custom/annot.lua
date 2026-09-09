-- Highlight a region and annotate it in one stroke, in a color you choose.
--
-- Composes vim-highlighter's positional highlight with haunt.nvim's note, over
-- the same span: the wash marks the logical grouping, the note says what it is.
--
-- Color is one global "pen" -- `vim.g.annot_color` -- and nothing here ever
-- picks a color on its own. Set it once; every highlight after that uses it,
-- whether it came from the operator below or from a bare `t<CR>`. Pin a default
-- in your config with `vim.g.annot_color = 7` if 1 is not the one you want.
--
-- `t<CR>` reaches the pen because `vim.g.HiSetSL = ''` suppresses the plugin's
-- own mapping (plugin/highlighter.vim skips a key whose g: override is empty)
-- and it is redefined here. `f<CR>` is deliberately left alone: passing it an
-- explicit color would disable its toggle-off behavior, since vim-highlighter
-- only honors `g:HiSetToggle` when no color argument is given.
local M = {}

local ESC = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
local CTRL_V = vim.api.nvim_replace_termcodes('<C-v>', true, false, true)

-- vim-highlighter defines HiColor1..HiColorN lazily, inside `s:Load()`, on its
-- first command -- so this can legitimately be 0 before anything has been
-- highlighted. Memoized only once nonzero.
local max_color
local function color_count()
  if not max_color or max_color == 0 then
    max_color = 0
    while vim.fn.hlexists('HiColor' .. (max_color + 1)) == 1 do
      max_color = max_color + 1
    end
  end
  return max_color
end

-- Force the color groups into existence. Every `highlighter#Command` runs
-- `s:Load()` first, and '/' is stripped to the empty command, whose only effect
-- is echoing the version banner -- hence `silent`.
local function ensure_loaded()
  if color_count() == 0 then
    pcall(vim.cmd, 'silent! call highlighter#Command("/")')
    max_color = nil
  end
  return color_count()
end

--- The current pen, clamped into range.
---@return integer
local function pen()
  local c = math.floor(tonumber(vim.g.annot_color) or 1)
  local n = color_count()
  if n > 0 then
    c = math.min(math.max(c, 1), n)
  end
  return math.max(c, 1)
end

--- Echo every available color as a numbered swatch, in its own color.
function M.show_palette()
  local n = ensure_loaded()
  if n == 0 then
    return vim.notify('annot: vim-highlighter has no colors loaded', vim.log.levels.WARN)
  end
  local chunks = { { 'pen ' }, { (' %d '):format(pen()), 'HiColor' .. pen() }, { '   of   ' } }
  for i = 1, n do
    chunks[#chunks + 1] = { (' %d '):format(i), 'HiColor' .. i }
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
  vim.g.annot_color = color
  vim.api.nvim_echo({ { 'pen ' }, { (' %d '):format(color), 'HiColor' .. color } }, false, {})
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

--- Highlight a span with the pen. Assumes '< and '> are set.
---@param color? integer one-off override
local function highlight(color)
  local ok, err = pcall(vim.fn['highlighter#Command'], '+x%', color or pen())
  if not ok then
    vim.notify('annot: highlight failed: ' .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  return true
end

--- Highlight a region and prompt for its annotation.
---@param opts? { visual?: boolean, count?: integer, color?: integer }
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

  if not highlight(opts.color) then
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

  -- All or nothing: the pair is one gesture, so abandoning the prompt undoes
  -- the wash too. `<C-c>` raises out of `vim.fn.input`, Esc and a bare Enter
  -- come back as an empty string, which haunt reports as `false`.
  local ok, created = pcall(require('haunt.api').annotate)
  if not ok or created == false then
    rollback(ns, before)
    pcall(vim.api.nvim_win_set_cursor, 0, origin)
  end

  -- Persist the wash immediately, so it survives a kill -9 as the note already
  -- would. After a rollback this just rewrites the pre-existing state.
  M.autosave()
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
    pcall(vim.fn['highlighter#Command'], '+%', pen())
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

--- @param prefix string
function M.setup(prefix)
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
