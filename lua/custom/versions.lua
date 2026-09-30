-- Versions: which text a file's marks are exact for, and how positions move
-- from that text to the text in the buffer now.
--
-- A mark (a haunt note, a vim-highlighter wash) is a position. A position is
-- only meaningful for the exact file text it was taken from, so this keeps
-- that text -- a *snapshot*, one per annotated file -- next to the marks, and
-- when a buffer comes back with different text, pushes every position through
-- the diff between the two. That is how a review tool keeps a comment on the
-- right line across pushes, and how Google Docs keeps a highlight on its
-- words while you type above it: not by looking for the text again, but by
-- accumulating the edits between then and now.
--
-- The diff is xdiff -- git's own engine, compiled into nvim as `vim.diff`
-- (`vim.text.diff` from 0.12) -- with whitespace ignored, since a re-indent
-- is the commonest way a whole file "changes" without changing, and with
-- `linematch`, which pairs similar lines inside a hunk so a one-line rewrite
-- (`vim.opt.number` -> `vim.o.number`) maps one-to-one instead of landing
-- somewhere in a block. Inside a hunk that is genuinely N lines -> M lines,
-- a position maps proportionally: a range keeps covering the replacement.
--
-- What a diff cannot say is where a *deleted* line went. Such a mark is
-- parked where the deletion happened and flagged stale, and keeps the text it
-- had (custom/anchor.lua) so that if the same lines reappear -- the branch is
-- checked back out, the block was moved rather than removed -- it snaps back.
-- That exact-text lookup is the only matching here, and only for that case.
--
-- One snapshot serves both stores, so the two are always re-based together:
-- `persist()` writes wash positions, note positions and the snapshot in one
-- go; `ensure_mapped()` maps both from the snapshot and then persists, so the
-- text on disk is again the text the positions describe. Positions live in
-- extmarks while a buffer is open and are exact there; the snapshot is
-- written whenever the stores are -- a mark made or erased, `:w`, leaving the
-- window, quitting -- so it always describes the text the stored positions
-- were taken from.
--
-- Why drop the marks on `BufReadPre`: a reload leaves extmarks *frozen* at
-- their old rows -- they neither move nor vanish (measured on 0.12) -- and both
-- plugins would otherwise trust them. And why nothing is saved at that
-- moment: the buffer is already empty by then, only the marks are left.
local M = {}

local api, uv = vim.api, vim.uv

local function diff_fn()
  return (vim.text and vim.text.diff) or vim.diff
end

local function real(bufnr)
  return (bufnr == nil or bufnr == 0) and api.nvim_get_current_buf() or bufnr
end

local function clamp(v, lo, hi)
  return math.max(lo, math.min(v, hi))
end

-- ---------------------------------------------------------------------------
-- File identity. Every worktree and clone of a repo shares its root commit,
-- and a file is the same file in each of them at the same relative path, so
-- `<root commit>/<relative path>` is the key -- from the *buffer's* path, not
-- nvim's cwd, so `:cd` elsewhere changes nothing.
-- ---------------------------------------------------------------------------

--- git root -> root commit, or false for a repo with no commits yet.
local pid_cache = {}

---@param root string
---@return string|false
local function project_id(root)
  local pid = pid_cache[root]
  if pid == nil then
    local r = vim.system({ 'git', '-C', root, 'rev-list', '--max-parents=0', 'HEAD' }, { text = true }):wait()
    pid = r.code == 0 and vim.split(r.stdout, '\n')[1] or ''
    pid = pid ~= '' and pid or false
    pid_cache[root] = pid
  end
  return pid
end

--- `<root commit:12>/<rel%path>` for a file in a repo, `_abs/<abs%path>`
--- outside one. Usable as a relative file path under any store directory.
---@param path string
---@return string|nil
function M.file_key(path)
  if not path or path == '' then
    return nil
  end
  path = vim.fs.normalize(path)
  local root = vim.fs.root(path, '.git')
  local pid = root and project_id(root)
  local dir, rel
  if pid then
    dir, rel = pid:sub(1, 12), path:sub(#root + 2)
  else
    dir, rel = '_abs', (path:gsub('^/', ''))
  end
  return dir .. '/' .. (rel:gsub('/', '%%'))
end

--- The key for a buffer, or nil for anything not a real file.
---@param bufnr? integer
---@return string|nil
function M.buf_key(bufnr)
  bufnr = real(bufnr)
  local name = api.nvim_buf_get_name(bufnr)
  if name == '' or vim.bo[bufnr].buftype ~= '' then
    return nil
  end
  return M.file_key(name)
end

-- ---------------------------------------------------------------------------
-- Snapshots
-- ---------------------------------------------------------------------------

local function snapshot_path(key)
  return vim.fs.joinpath(vim.fn.stdpath 'data', 'annot-snapshots', key)
end

---@return string[]|nil
local function read_snapshot(key)
  local p = snapshot_path(key)
  if not uv.fs_stat(p) then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, p)
  return ok and lines or nil
end

local function write_snapshot(key, lines)
  local p = snapshot_path(key)
  vim.fn.mkdir(vim.fs.dirname(p), 'p')
  vim.fn.writefile(lines, p)
end

local function delete_snapshot(key)
  local p = snapshot_path(key)
  if uv.fs_stat(p) then
    vim.fn.delete(p)
  end
end

-- ---------------------------------------------------------------------------
-- Mapping
-- ---------------------------------------------------------------------------

--- Map a byte column through a changed line: the part before the common
--- prefix and after the common suffix is untouched, the middle is what was
--- rewritten. A start inside the rewrite moves to its front, an end to its
--- back, so a range that covered the old words covers the new ones. At the
--- boundaries a start clings to the text after it and an end to the text
--- before it, so text inserted right at a range's edge is not swallowed.
---@param old string
---@param new string
---@param c integer 0-based byte column
---@param is_end boolean
---@return integer
local function map_col(old, new, c, is_end)
  if old == new then
    return clamp(c, 0, #new)
  end
  local n = math.min(#old, #new)
  local p = 0
  while p < n and old:byte(p + 1) == new:byte(p + 1) do
    p = p + 1
  end
  local s = 0
  while s < n - p and old:byte(#old - s) == new:byte(#new - s) do
    s = s + 1
  end
  local shift = #new - #old
  if is_end then
    if c <= p then
      return c
    elseif c >= #old - s then
      return c + shift
    end
    return #new - s
  end
  if c >= #old - s then
    return c + shift
  elseif c <= p then
    return c
  end
  return p
end

---@class annot.Mapper
---@field hunks integer[][]  `{start_a, count_a, start_b, count_b}` per hunk, 1-based like a unified header
---@field identity boolean   no hunks: every position maps to itself
---@field line fun(l: integer, is_end?: boolean): integer, 'exact'|'modified'|'deleted'
---@field pos fun(l: integer, c: integer, is_end?: boolean): integer, integer, 'exact'|'modified'|'deleted'

--- The mapper from `old_lines` to `new_lines`.
---@param old_lines string[]
---@param new_lines string[]
---@return annot.Mapper
function M.mapper(old_lines, new_lines)
  local n_new = math.max(#new_lines, 1)
  local hunks = diff_fn()(table.concat(old_lines, '\n') .. '\n', table.concat(new_lines, '\n') .. '\n', {
    result_type = 'indices',
    algorithm = 'histogram',
    ignore_whitespace = true,
    linematch = 60,
  })
  local m = { hunks = hunks, identity = #hunks == 0 }

  --- Where line `l` of the old text is in the new one. A line inside a
  --- deletion is 'deleted' and answers the line the gap now sits before
  --- (a start) or after (an end).
  function m.line(l, is_end)
    local delta = 0
    for _, h in ipairs(hunks) do
      local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
      if ca == 0 then
        -- Insertion after old line `sa`.
        if l <= sa then
          break
        end
        delta = delta + cb
      else
        if l < sa then
          break
        end
        if l <= sa + ca - 1 then
          if cb == 0 then
            -- The gap follows new line `sb`.
            return clamp(is_end and sb or sb + 1, 1, n_new), 'deleted'
          end
          local k = l - sa
          local off = is_end and (math.ceil((k + 1) * cb / ca) - 1) or math.floor(k * cb / ca)
          return sb + clamp(off, 0, cb - 1), 'modified'
        end
        delta = delta + cb - ca
      end
    end
    return clamp(l + delta, 1, n_new), 'exact'
  end

  --- Line and column together; the column is mapped through the two lines'
  --- texts whenever they differ, whitespace changes included.
  function m.pos(l, c, is_end)
    local nl, kind = m.line(l, is_end)
    local new = new_lines[nl] or ''
    if kind == 'deleted' then
      return nl, is_end and #new or 0, kind
    end
    return nl, map_col(old_lines[l] or '', new, c, is_end), kind
  end

  return m
end

-- ---------------------------------------------------------------------------
-- The buffer lifecycle
-- ---------------------------------------------------------------------------

--- bufnr -> true once its marks were mapped in from disk; cleared by a
--- detach, so a reload maps again. Not a changedtick: at `BufReadPost` the
--- tick is still the pre-reload value (measured on 0.12), so a tick-keyed
--- guard would treat a reload as already done.
local mapped = {}
--- bufnr -> true between BufReadPre and the next mapping: marks are gone on
--- purpose and nothing may be persisted from the buffer.
local detached = {}
--- bufnr -> sha256 of the text the snapshot on disk holds, to skip rewriting
--- 40 KB when nothing changed. By content for the same reason as above.
local snap_sha = {}
--- bufnr -> how many times its marks were mapped; consumers key one-shot
--- reports on it.
local generation = {}

local function sha(lines)
  return vim.fn.sha256(table.concat(lines, '\n'))
end

--- Which mapping of this buffer is current. Increments on every mapping.
---@param bufnr? integer
---@return integer
function M.generation(bufnr)
  return generation[real(bufnr)] or 0
end

local function consumers()
  local hi = require 'custom.hi_store'
  local ok, ha = pcall(require, 'custom.haunt_anchor')
  return hi, ok and ha or nil
end

local persisting = false

--- Write the marks of `only` (or of every mapped buffer) and the text they
--- are exact for. Everything about a file goes out together, so the stores
--- and the snapshot can never describe different versions.
---@param only? integer
function M.persist(only)
  if persisting then
    return
  end
  persisting = true
  local ok, err = pcall(function()
    local hi, ha = consumers()
    local bufs = only and { real(only) } or api.nvim_list_bufs()
    for _, b in ipairs(bufs) do
      if api.nvim_buf_is_valid(b) and api.nvim_buf_is_loaded(b) and mapped[b] and not detached[b] then
        local key = M.buf_key(b)
        if key then
          local has_washes = hi.write(b)
          local notes = ha and ha.capture_buffer(b) or 0
          if has_washes or notes > 0 then
            local lines = api.nvim_buf_get_lines(b, 0, -1, false)
            local h = sha(lines)
            if snap_sha[b] ~= h or not uv.fs_stat(snapshot_path(key)) then
              write_snapshot(key, lines)
              snap_sha[b] = h
            end
          else
            delete_snapshot(key)
            snap_sha[b] = nil
          end
        end
      end
    end
    if ha then
      ha.save_store()
    end
  end)
  persisting = false
  if not ok then
    vim.notify('annot: persist failed: ' .. tostring(err), vim.log.levels.WARN)
  end
end

--- Bring the buffer's marks in from disk, mapped from the snapshot to the
--- text now in the buffer, then re-base. Once per detach, so the several
--- paths that lead here (BufReadPost, haunt's restore, a manual reload) cost
--- one mapping between them.
---@param bufnr? integer
function M.ensure_mapped(bufnr)
  bufnr = real(bufnr)
  if not (api.nvim_buf_is_valid(bufnr) and api.nvim_buf_is_loaded(bufnr)) then
    return
  end
  if mapped[bufnr] and not detached[bufnr] then
    return
  end
  local key = M.buf_key(bufnr)
  if not key then
    return
  end
  local cur = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local snap = read_snapshot(key)
  local mapper = snap and M.mapper(snap, cur) or nil
  local hi, ha = consumers()
  hi.load(bufnr, cur, mapper)
  if ha then
    ha.reanchor(bufnr, cur, mapper)
  end
  mapped[bufnr] = true
  detached[bufnr] = nil
  generation[bufnr] = (generation[bufnr] or 0) + 1
  M.persist(bufnr)
end

--- Has this buffer's marks been brought in from disk? Gates pruning: a store
--- may only be deleted on the strength of a buffer whose marks were loaded.
---@param bufnr integer
---@return boolean
function M.is_mapped(bufnr)
  return mapped[real(bufnr)] ~= nil
end

--- Drop the marks: the text is about to change. Nothing is persisted here,
--- because at `BufReadPre` the buffer has *already* been emptied (one blank
--- line; the extmarks are still there, frozen) -- a snapshot taken now would
--- be blank. Nothing needs to be: every mutation persisted itself, so the
--- stores and snapshot already describe the last saved state, and unsaved
--- edits are exactly what the reload discards.
local function detach(bufnr)
  detached[bufnr] = true
  mapped[bufnr] = nil
  local hi, ha = consumers()
  hi.detach(bufnr)
  if ha then
    ha.detach(bufnr)
  end
end

--- Discard the live marks and load them from disk again. `<leader>Hl`.
---@param bufnr? integer
function M.remap(bufnr)
  bufnr = real(bufnr)
  detach(bufnr)
  M.ensure_mapped(bufnr)
  local _, ha = consumers()
  if ha then
    ha.redraw(bufnr)
  end
end

local function forget(bufnr)
  mapped[bufnr], detached[bufnr], snap_sha[bufnr], generation[bufnr] = nil, nil, nil, nil
end

--- Autocmds. Called once from the vim-highlighter spec's `init`.
function M.setup()
  local group = api.nvim_create_augroup('annot-versions', { clear = true })
  api.nvim_create_autocmd('BufReadPre', {
    group = group,
    desc = 'annot: save the exact state and drop the marks before the text changes',
    callback = function(args)
      detach(args.buf)
    end,
  })
  api.nvim_create_autocmd('BufReadPost', {
    group = group,
    desc = 'annot: map the marks from the snapshot to the new text',
    callback = function(args)
      M.ensure_mapped(args.buf)
    end,
  })
  api.nvim_create_autocmd({ 'BufWritePost', 'BufWinLeave' }, {
    group = group,
    desc = 'annot: persist marks and snapshot',
    callback = function(args)
      M.persist(args.buf)
    end,
  })
  api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    desc = 'annot: persist every buffer before quitting',
    callback = function()
      M.persist()
    end,
  })
  api.nvim_create_autocmd('BufWipeout', {
    group = group,
    callback = function(args)
      forget(args.buf)
    end,
  })
end

return M
