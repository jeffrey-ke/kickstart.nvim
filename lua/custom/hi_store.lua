-- Persistence for vim-highlighter's positional washes, keyed by repo and
-- carried across versions of the file by custom/versions.lua.
--
-- The plugin's own `:Hi save` / `:Hi load` are not used. Its `.hl` format is
-- `%:color,line,col,line,col` and nothing else, and this config used to key
-- those files by the buffer's absolute path, so a worktree of the same repo
-- saw nothing. A wash, though, is only an extmark in the plugin's `HiColor`
-- namespace with `{end_row, end_col, hl_group = 'HiColorN'}`, and the plugin
-- keeps no side table: it enumerates the namespace for save, erase (`f<BS>`)
-- and the `Hi{}` jumps. A mark placed here with the same shape is therefore
-- indistinguishable from one it made, and everything of the plugin's keeps
-- working on it. Verified against 1.64.1.
--
-- Store: one JSON per file under `stdpath('data')/highlighter/<file key>.json`,
-- the key being `versions.file_key` (root commit + relative path). Each record
-- is `{color, l1, c1, l2, c2, anchor, end_anchor}` -- the extmark as it was
-- (0-based, end exclusive) against the file's snapshot, plus the text of each
-- end for the one case a diff cannot answer, a deleted range. On load the
-- ends are mapped through the snapshot -> buffer diff; a range that was
-- deleted is parked where the deletion happened, flagged *stale*, and keeps
-- its original anchors through later saves so it can snap back when the text
-- reappears.
--
-- Loading happens on `BufReadPost` with the namespace cleared on `BufReadPre`
-- (versions.lua owns those autocmds): a reload leaves extmarks frozen at
-- their old rows rather than moving or dropping them. Pattern highlights
-- (`f<CR>`, window matches) are not persisted; the plugin's own `:Hi save`
-- still does that by hand.
--
-- Model, data formats and invariants: .docs_claude/design/annotations.md.
local M = {}

local NS_NAME = 'HiColor'

--- bufnr -> { [extmark_id] = record } for washes whose range is gone.
local stale = {}
--- bufnr -> true once a load ran, which is what allows pruning the store.
local loaded = {}

local function ns()
  -- Named, so this is the plugin's own id whichever side creates it first.
  return vim.api.nvim_create_namespace(NS_NAME)
end

local function anchor()
  return require 'custom.anchor'
end

local function versions()
  return require 'custom.versions'
end

local function base_dir()
  return vim.fs.joinpath(vim.fn.stdpath 'data', 'highlighter')
end

local function real(bufnr)
  return (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
end

local function clamp(v, lo, hi)
  return math.max(lo, math.min(v, hi))
end

--- The store file for an absolute path.
---@param path string
---@return string|nil
function M.path_for_file(path)
  local key = versions().file_key(path)
  return key and vim.fs.joinpath(base_dir(), key .. '.json') or nil
end

--- The store file for a buffer, or nil for anything not a real file.
---@param bufnr? integer
---@return string|nil
function M.path_for_buf(bufnr)
  local key = versions().buf_key(bufnr)
  return key and vim.fs.joinpath(base_dir(), key .. '.json') or nil
end

-- ---------------------------------------------------------------------------
-- Records <-> extmarks
-- ---------------------------------------------------------------------------

local function read_store(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or #lines == 0 then
    return nil
  end
  local ok2, data = pcall(vim.json.decode, table.concat(lines, '\n'))
  if ok2 and type(data) == 'table' and type(data.marks) == 'table' then
    return data
  end
  return nil
end

local function write_store(path, marks)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile({ vim.json.encode { version = 1, marks = marks } }, path)
end

--- The washes in `bufnr`, as extmarks with details. Only `hl_group` spans:
--- nothing here creates a `line_hl_group` mark, and the plugin's own save
--- errors on one.
local function washes(bufnr)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns(), 0, -1, { details = true })) do
    local d = m[4]
    local color = d.hl_group and tonumber(tostring(d.hl_group):match '^HiColor(%d+)$')
    if color then
      out[#out + 1] = { id = m[1], row = m[2], col = m[3], end_row = d.end_row or m[2], end_col = d.end_col or m[3], color = color }
    end
  end
  return out
end

--- Does the buffer hold anything worth saving?
---@param bufnr? integer
---@return boolean
function M.has_highlights(bufnr)
  return #vim.api.nvim_buf_get_extmarks(real(bufnr), ns(), 0, -1, { limit = 1 }) > 0
end

--- An anchor for a wash end: the line's text plus the column, so a range
--- that snaps back after a deletion gets its original width back.
local function end_anchor(lines, row, col)
  local a = anchor().capture(lines, row + 1)
  a.col = col
  return a
end

---@param bufnr integer
---@return table[] records
local function records_of(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local kept = stale[bufnr] or {}
  local out = {}
  for _, w in ipairs(washes(bufnr)) do
    local rec = kept[w.id]
    if rec then
      -- Where it is parked now, with the anchors of where it was.
      out[#out + 1] = {
        color = w.color,
        l1 = w.row,
        c1 = w.col,
        l2 = w.end_row,
        c2 = w.end_col,
        anchor = rec.anchor,
        end_anchor = rec.end_anchor,
        stale = true,
      }
    elseif not (w.row == w.end_row and w.end_col <= w.col) then
      -- Zero-width marks are what edits leave behind; the plugin's own jump
      -- deletes them on sight, so they are not worth carrying.
      out[#out + 1] = {
        color = w.color,
        l1 = w.row,
        c1 = w.col,
        l2 = w.end_row,
        c2 = w.end_col,
        anchor = end_anchor(lines, w.row, w.col),
        end_anchor = end_anchor(lines, w.end_row, w.end_col),
      }
    end
  end
  return out
end

--- Write the buffer's washes, or delete the store when none are left, so an
--- erased wash never comes back. Returns whether anything was written.
--- Called by `versions.persist`, which pairs it with the snapshot.
---@param bufnr integer
---@return boolean
function M.write(bufnr)
  local path = M.path_for_buf(bufnr)
  if not path then
    return false
  end
  local records = records_of(bufnr)
  if #records > 0 then
    write_store(path, records)
    return true
  end
  -- Only prune once a load has run for this buffer. Deleting on the strength
  -- of an empty buffer that was never restored would discard the store.
  if loaded[bufnr] and vim.uv.fs_stat(path) then
    vim.fn.delete(path)
  end
  return false
end

--- Persist the current buffer's marks. Silent -- for the mutating keys.
function M.autosave()
  versions().persist(0)
end

--- Manual save, with a message. `<leader>Hs`.
function M.save()
  local path = M.path_for_buf()
  if not path then
    return vim.notify('highlighter: buffer has no file to key highlights to', vim.log.levels.WARN)
  end
  versions().persist(0)
  vim.notify(
    M.has_highlights() and ('highlighter: saved -> ' .. vim.fn.fnamemodify(path, ':~')) or 'highlighter: no highlights, store cleared',
    vim.log.levels.INFO
  )
end

--- Forget the buffer's marks ahead of a re-read.
---@param bufnr integer
function M.detach(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns(), 0, -1)
  stale[bufnr] = nil
end

--- Place one record. Returns 'ok', 'stale', or nil when it could not be set.
---@param bufnr integer
---@param lines string[]
---@param rec table
---@param mapper annot.Mapper|nil  nil when the file has no snapshot yet
---@return 'ok'|'stale'|nil
local function place(bufnr, lines, rec, mapper)
  local n = #lines
  local s, e, c1, c2, is_stale

  --- The one text lookup: the range as it was, wherever it is now.
  local function resurrect()
    if not (rec.anchor and rec.end_anchor) then
      return false
    end
    local rs, re, exact = anchor().resolve_span(lines, rec.anchor, rec.end_anchor, rec.l1 + 1, rec.l2 + 1)
    if not rs then
      return false
    end
    s, e = rs, re
    c1 = rec.anchor.col or rec.c1
    c2 = rec.end_anchor.col or rec.c2
    is_stale = not exact
    return true
  end

  --- Parked on a line, whole: visible, and nothing to mistake for the range.
  local function park(line)
    s, e = line, line
    c1, c2 = 0, #lines[line]
    is_stale = true
  end

  if rec.stale then
    if not resurrect() then
      park(mapper and mapper.line(rec.l1 + 1) or clamp(rec.l1 + 1, 1, n))
    end
  elseif mapper then
    local ks, ke
    s, c1, ks = mapper.pos(rec.l1 + 1, rec.c1, false)
    e, c2, ke = mapper.pos(rec.l2 + 1, rec.c2, true)
    if ks == 'deleted' and ke == 'deleted' then
      if not resurrect() then
        park(s)
      end
    else
      -- One end fell into a deletion right next to the other: shrink to it.
      if e < s then
        e, c2 = s, #lines[s]
      end
      is_stale = false
    end
  else
    -- A store from before snapshots existed: text anchors, else the numbers.
    if not resurrect() then
      s = clamp(rec.l1 + 1, 1, n)
      e = clamp(rec.l2 + 1, s, n)
      c1, c2 = rec.c1, rec.c2
      is_stale = rec.anchor ~= nil
    end
  end

  c1 = clamp(c1, 0, #lines[s])
  c2 = clamp(c2, 0, #lines[e])
  if s == e and c2 < c1 then
    c1, c2 = c2, c1
  end
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns(), s - 1, c1, {
    end_row = e - 1,
    end_col = c2,
    hl_group = 'HiColor' .. rec.color,
  })
  if not ok then
    return nil
  end
  if is_stale then
    stale[bufnr][id] = rec
    return 'stale'
  end
  return 'ok'
end

--- Bring the buffer's washes in from disk. Called by `versions.ensure_mapped`
--- with the buffer's lines and the mapper from the snapshot (nil if none).
---@param bufnr integer
---@param lines string[]
---@param mapper annot.Mapper|nil
function M.load(bufnr, lines, mapper)
  vim.api.nvim_buf_clear_namespace(bufnr, ns(), 0, -1)
  stale[bufnr] = {}
  loaded[bufnr] = true
  local path = M.path_for_buf(bufnr)
  if not path then
    return
  end
  local data = read_store(path)
  if not data then
    return
  end
  -- The `HiColorN` groups only exist once the plugin has run `s:Load()`.
  require('custom.annot').ensure_loaded()
  local n_stale = 0
  for _, rec in ipairs(data.marks) do
    if place(bufnr, lines, rec, mapper) == 'stale' then
      n_stale = n_stale + 1
    end
  end
  if n_stale > 0 then
    vim.notify(
      ('highlighter: %d wash%s lost %s range in %s (parked, kept)'):format(
        n_stale,
        n_stale == 1 and '' or 'es',
        n_stale == 1 and 'its' or 'their',
        vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ':~:.')
      ),
      vim.log.levels.WARN
    )
  end
end

--- Commands. Autocmds live in versions.lua.
function M.setup()
  vim.api.nvim_create_user_command('AnnotMigrateHl', function()
    M.migrate_hl()
  end, { desc = "Convert vim-highlighter's old per-path .hl stores to the per-repo store" })
end

-- ---------------------------------------------------------------------------
-- One-off migration from the `.hl` files this config used to write:
-- `<data>/highlighter/<absolute path, / -> %>.hl`, records
-- `%:color,l1,c1,l2,c2` with 1-based lines and columns, end exclusive.
-- ---------------------------------------------------------------------------

function M.migrate_hl()
  local dir = base_dir()
  local report = {}
  for _, hl in ipairs(vim.fn.glob(dir .. '/*.hl', false, true)) do
    local slug = vim.fn.fnamemodify(hl, ':t:r')
    local path = '/' .. slug:gsub('%%', '/')
    local tag = vim.fn.fnamemodify(path, ':~')
    if not vim.uv.fs_stat(path) then
      report[#report + 1] = 'skip (file gone): ' .. tag
    else
      local lines = vim.fn.readfile(path)
      local recs = {}
      for _, l in ipairs(vim.fn.readfile(hl)) do
        local color, l1, c1, l2, c2 = l:match '^%%:(%d+),(%d+),(%d+),(%d+),(%d+)$'
        if color then
          l1, c1, l2, c2 = tonumber(l1) - 1, tonumber(c1) - 1, tonumber(l2) - 1, tonumber(c2) - 1
          -- Edits leave zero-width and inverted records behind; the plugin
          -- itself would not restore those.
          if l2 > l1 or (l2 == l1 and c2 > c1) then
            recs[#recs + 1] = {
              color = tonumber(color),
              l1 = l1,
              c1 = c1,
              l2 = l2,
              c2 = c2,
              anchor = end_anchor(lines, l1, c1),
              end_anchor = end_anchor(lines, l2, c2),
            }
          end
        end
      end
      local target = M.path_for_file(path)
      -- Two worktrees' copies of one file land on one key: append, minus
      -- exact duplicates.
      local existing = target and read_store(target)
      local marks = existing and existing.marks or {}
      local seen = {}
      for _, r in ipairs(marks) do
        seen[('%d:%d:%d:%d:%d'):format(r.color, r.l1, r.c1, r.l2, r.c2)] = true
      end
      local added = 0
      for _, r in ipairs(recs) do
        local k = ('%d:%d:%d:%d:%d'):format(r.color, r.l1, r.c1, r.l2, r.c2)
        if not seen[k] then
          seen[k] = true
          marks[#marks + 1] = r
          added = added + 1
        end
      end
      if target and #marks > 0 then
        write_store(target, marks)
      end
      os.rename(hl, hl .. '.bak')
      if vim.uv.fs_stat(hl .. '.o') then
        os.rename(hl .. '.o', hl .. '.o.bak')
      end
      report[#report + 1] = ('%d wash%s: %s -> %s'):format(added, added == 1 and '' or 'es', tag, vim.fn.fnamemodify(target or '?', ':~'))
    end
  end
  if #report == 0 then
    report[1] = 'nothing to migrate in ' .. dir
  end
  vim.notify(table.concat(report, '\n'), vim.log.levels.INFO)
end

return M
