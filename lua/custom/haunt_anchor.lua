-- Content anchors for haunt.nvim notes, so a note follows its line across a
-- checkout, a worktree, a pull, a formatter -- anything that changes the file
-- while nvim is not tracking it.
--
-- haunt persists `{file, line, note, id}` and nothing else, and places each
-- note back on that exact line number. This adds an `anchor` (custom/anchor.lua:
-- the line's text plus its neighbours) to every bookmark it saves, and looks
-- the line up again by content before haunt draws it.
--
-- Three seams into the plugin, none of them a fork:
--
--   * `persistence._build_serializable` is what turns bookmarks into JSON. It
--     copies a fixed list of fields and drops the rest, so the anchor is added
--     to its result. Loading keeps unknown fields as they are, so nothing is
--     needed on that side.
--   * `restoration.restore_buffer_bookmarks(bufnr)` is the one function every
--     placement goes through -- BufReadPost, the startup pass over already-open
--     buffers, and `api.reload`. Called as a module field, so replacing it on
--     the module table intercepts all three. The anchors are resolved against
--     the buffer just before the original runs.
--   * `BufReadPre`. A reload (`:e`, autoread after a checkout) does *not* move
--     or drop the extmarks: they stay frozen at their old rows (verified on
--     0.12). haunt then (a) refuses to restore a buffer that still has any
--     extmark in its namespace and (b) syncs `bookmark.line` from those frozen
--     rows on every read -- which would overwrite a resolved line with the old
--     number and then persist it. So before the read, the store is synced once
--     (the frozen row *is* the exact pre-reload line, which is the best
--     `expect` there is), then the buffer's marks, signs and ids are dropped
--     and its restore tracking cleared.
--
-- An anchor that cannot be found anywhere keeps its old line (clamped to the
-- file) and is *stale*: drawn with a `⚠` in front, listed once per buffer,
-- and -- the part that matters -- its anchor is not recaptured, so the text it
-- is looking for survives until the line reappears (checking the original
-- branch back out heals it) or the note is edited or deleted. Editing the note
-- counts as the user confirming the line.
--
-- Anchors are captured on every save (haunt saves after each mutation and at
-- exit -- it has no TextChanged autosave, whatever its docs say), on
-- `BufWritePost`, and after every restore. In the ordinary case -- buffer
-- written, then something changes the file -- they are exact.
local M = {}

local STALE_MARK = '⚠ '

--- id -> true for a bookmark whose line was not found on the last restore.
local stale = {}

local function anchor()
  return require 'custom.anchor'
end

local function file_of(bufnr)
  return require('haunt.utils').normalize_filepath(vim.api.nvim_buf_get_name(bufnr))
end

local function lines_of(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

--- Is this note drawn with the stale marker? annot.lua asks when it redraws
--- a note itself (the inline/box fold), so the marker survives that too.
---@param bm table
---@return boolean
function M.is_stale(bm)
  return stale[bm.id] == true
end

--- The note as it should be drawn: marked when stale.
---@param bm table
---@return string
function M.display_note(bm)
  return (M.is_stale(bm) and STALE_MARK or '') .. (bm.note or '')
end

--- Refresh the anchors of every non-stale bookmark in `bufnr` from its
--- current text.
---@param bufnr integer
function M.capture_buffer(bufnr)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local file = file_of(bufnr)
  if file == '' then
    return
  end
  local lines = lines_of(bufnr)
  for _, bm in ipairs(require('haunt.store').get_all_raw()) do
    if bm.file == file and not stale[bm.id] and bm.line and bm.line >= 1 and bm.line <= #lines then
      bm.anchor = anchor().capture(lines, bm.line)
    end
  end
end

--- `on_pre_save`: capture from every loaded buffer that holds bookmarks.
--- `ctx.bookmarks` is already extmark-synced.
local function capture_loaded(ctx)
  local seen = {}
  for _, bm in ipairs(ctx.bookmarks) do
    if not seen[bm.file] then
      seen[bm.file] = true
      local bufnr = vim.fn.bufnr(bm.file)
      if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        M.capture_buffer(bufnr)
      end
    end
  end
end

--- Before the buffer is re-read: sync once, then forget the marks.
local function detach(bufnr)
  local file = file_of(bufnr)
  if file == '' then
    return
  end
  local display = require 'haunt.display'
  local any = false
  for _, bm in ipairs(require('haunt.store').get_all_raw()) do
    if bm.file == file then
      bm.extmark_id = nil
      bm.annotation_extmark_id = nil
      any = true
    end
  end
  if any then
    display.clear_buffer_marks(bufnr)
    display.clear_buffer_signs(bufnr)
  end
  require('haunt.restoration').cleanup_buffer_tracking(bufnr)
end

--- Move each of this file's bookmarks to where its anchor now is. Returns the
--- ones that were not found.
---@param bufnr integer
---@return table[] orphans
local function reanchor(bufnr)
  local file = file_of(bufnr)
  local lines = lines_of(bufnr)
  local orphans = {}
  for _, bm in ipairs(require('haunt.store').get_all_raw()) do
    if bm.file == file then
      local at = bm.anchor and anchor().resolve(lines, bm.anchor, bm.line)
      if at then
        bm.line = at
        stale[bm.id] = nil
      else
        -- Clamped either way, so it renders; a store written before anchors
        -- existed has none and simply keeps its number, un-flagged.
        bm.line = math.max(1, math.min(bm.line, #lines))
        if bm.anchor then
          stale[bm.id] = true
          orphans[#orphans + 1] = bm
        end
      end
    end
  end
  return orphans
end

--- Wrap haunt's restore: resolve first, draw, then mark the orphans.
local function install_restore()
  local restoration = require 'haunt.restoration'
  local display = require 'haunt.display'
  local restore = restoration.restore_buffer_bookmarks
  restoration.restore_buffer_bookmarks = function(bufnr, annotations_visible)
    if not (vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)) then
      return restore(bufnr, annotations_visible)
    end
    local orphans = reanchor(bufnr)
    local ok = restore(bufnr, annotations_visible)
    for _, bm in ipairs(orphans) do
      if bm.note and bm.annotation_extmark_id then
        display.hide_annotation(bufnr, bm.annotation_extmark_id)
        bm.annotation_extmark_id = display.show_annotation(bufnr, bm.line, M.display_note(bm))
      end
    end
    if #orphans > 0 then
      vim.notify(
        ('haunt: %d annotation%s not re-anchored in %s (kept at old line, marked %s)'):format(
          #orphans,
          #orphans == 1 and '' or 's',
          vim.fn.fnamemodify(file_of(bufnr), ':~:.'),
          vim.trim(STALE_MARK)
        ),
        vim.log.levels.WARN
      )
    end
    M.capture_buffer(bufnr)
    return ok
  end
end

--- Wrap the serializer so `anchor` reaches the JSON. Its result is
--- index-aligned with its input.
local function install_serializer()
  local persistence = require 'haunt.persistence'
  local build = persistence._build_serializable
  persistence._build_serializable = function(bookmarks, project_root)
    local out = build(bookmarks, project_root)
    for i, bm in ipairs(bookmarks) do
      if out[i] and bm.anchor then
        out[i].anchor = bm.anchor
      end
    end
    return out
  end
end

--- Call once after `require('haunt').setup()`.
function M.install()
  local hooks = require 'haunt.hooks'
  if hooks._annot_anchor then
    return
  end
  hooks._annot_anchor = true

  install_serializer()
  install_restore()

  hooks.on_pre_save(capture_loaded)
  -- A rewritten note is the user vouching for the line it is on now.
  hooks.on_update(function(ctx)
    stale[ctx.bookmark.id] = nil
    if ctx.bufnr then
      M.capture_buffer(ctx.bufnr)
    end
  end)
  hooks.on_delete(function(ctx)
    stale[ctx.bookmark.id] = nil
  end)

  local group = vim.api.nvim_create_augroup('haunt-anchor', { clear = true })
  vim.api.nvim_create_autocmd('BufReadPre', {
    group = group,
    desc = 'haunt: sync and drop marks before the buffer is re-read',
    callback = function(args)
      detach(args.buf)
    end,
  })
  -- Capture *and* save: haunt writes its store only after its own mutations
  -- and at exit, so without this the numbers on disk would lag a re-anchor
  -- until the next note was touched.
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    desc = 'haunt: refresh annotation anchors from the written text',
    callback = function(args)
      M.capture_buffer(args.buf)
      local store = require 'haunt.store'
      if store.has_bookmarks() then
        store.save()
      end
    end,
  })

  vim.api.nvim_create_user_command('HauntMergeBranches', function()
    M.merge_branches()
  end, { desc = 'Merge the per-branch haunt stores of this repo into its shared store' })
end

-- ---------------------------------------------------------------------------
-- One-off migration from per-branch stores.
--
-- With `per_branch_bookmarks = true` haunt keyed each store by
-- `sha256(root_commit .. '|' .. branch)`; with it off the key is
-- `sha256(root_commit)`. The old files are not deleted by the switch, just
-- unreachable, and their names cannot be inverted -- but every branch name
-- this repo has is known, so each candidate key can be recomputed and merged.
-- ---------------------------------------------------------------------------

---@param args string[]
---@return string[]|nil lines nil on failure
local function git(args)
  local r = vim.system(vim.list_extend({ 'git' }, args), { text = true }):wait()
  if r.code ~= 0 then
    return nil
  end
  return vim.split(vim.trim(r.stdout), '\n', { trimempty = true })
end

local function read_json(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or #lines == 0 then
    return nil
  end
  local ok2, data = pcall(vim.json.decode, table.concat(lines, '\n'))
  return ok2 and type(data) == 'table' and data or nil
end

--- Merge every branch-keyed store of the repo at cwd into the shared one.
function M.merge_branches()
  local persistence = require 'haunt.persistence'
  local utils = require 'haunt.utils'
  local root = (git { 'rev-parse', '--show-toplevel' } or {})[1]
  local pid = (git { 'rev-list', '--max-parents=0', 'HEAD' } or {})[1]
  if not (root and pid) then
    return vim.notify('haunt: cwd is not inside a git repo', vim.log.levels.ERROR)
  end
  local dir = persistence.get_data_dir()
  local function path_for(key)
    return dir .. vim.fn.sha256(key):sub(1, 12) .. '.json'
  end

  -- Current branch first, so it wins a duplicate id; the shared store, if it
  -- already exists, ahead of that.
  local current = (git { 'branch', '--show-current' } or {})[1]
  local names = {}
  if current and current ~= '' then
    names[#names + 1] = current
  end
  for _, b in ipairs(git { 'for-each-ref', '--format=%(refname:short)', 'refs/heads' } or {}) do
    names[#names + 1] = b
  end
  -- A detached worktree is keyed by its short hash.
  for _, l in ipairs(git { 'worktree', 'list', '--porcelain' } or {}) do
    local h = l:match '^HEAD (%x+)$'
    if h then
      names[#names + 1] = (git { 'rev-parse', '--short', h } or {})[1]
    end
  end
  names[#names + 1] = '__default__'

  local target = path_for(pid)
  local merged, seen, sources = {}, {}, {}
  local function absorb(path)
    local data = read_json(path)
    if not data or type(data.bookmarks) ~= 'table' then
      return false
    end
    for _, bm in ipairs(data.bookmarks) do
      if bm.id and not seen[bm.id] then
        seen[bm.id] = true
        -- A v1 store carried absolute paths; give the shared store the
        -- relative form it expects.
        if type(bm.file) == 'string' and bm.file:sub(1, 1) == '/' and not bm.absolute then
          local rel = utils.to_relative(bm.file, root)
          if rel then
            bm.file = rel
          else
            bm.absolute = true
          end
        end
        merged[#merged + 1] = bm
      end
    end
    return true
  end

  absorb(target)
  local done = {}
  for _, name in ipairs(names) do
    if name and not done[name] then
      done[name] = true
      local p = path_for(pid .. '|' .. name)
      if p ~= target and vim.uv.fs_stat(p) and absorb(p) then
        sources[#sources + 1] = { name = name, path = p }
      end
    end
  end

  if #sources == 0 then
    return vim.notify('haunt: no per-branch stores found for this repo', vim.log.levels.INFO)
  end

  vim.fn.mkdir(dir, 'p')
  vim.fn.writefile({ vim.json.encode { version = 2, bookmarks = merged } }, target)
  for _, s in ipairs(sources) do
    os.rename(s.path, s.path .. '.bak')
  end
  require('haunt.api').reload 'manual'

  local report = { ('haunt: merged %d bookmarks into %s'):format(#merged, vim.fn.fnamemodify(target, ':~')) }
  for _, s in ipairs(sources) do
    report[#report + 1] = '  from ' .. s.name .. '  (' .. vim.fn.fnamemodify(s.path, ':t') .. ' -> .bak)'
  end

  -- Whatever is left in the data dir belongs to another repo, a deleted
  -- branch, or an old detached checkout: list it so nothing is silently lost.
  local known = { [target] = true }
  for _, s in ipairs(sources) do
    known[s.path] = true
  end
  local others = {}
  for _, p in ipairs(vim.fn.glob(dir .. '*.json', false, true)) do
    if not known[p] then
      local data = read_json(p)
      local files = {}
      for _, bm in ipairs(data and data.bookmarks or {}) do
        files[bm.file or '?'] = true
      end
      others[#others + 1] = ('  %s: %s'):format(vim.fn.fnamemodify(p, ':t'), table.concat(vim.tbl_keys(files), ', '))
    end
  end
  if #others > 0 then
    report[#report + 1] = 'not matched to any branch of this repo (left as they are):'
    vim.list_extend(report, others)
  end
  vim.notify(table.concat(report, '\n'), vim.log.levels.INFO)
end

return M
