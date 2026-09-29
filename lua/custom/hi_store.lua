-- Persistence for vim-highlighter's positional washes, keyed by repo and
-- anchored by content.
--
-- The plugin's own `:Hi save` / `:Hi load` are not used. Its `.hl` format is
-- `%:color,line,col,line,col` and nothing else -- no room for the text that
-- would let a wash find its line again -- and this config used to key those
-- files by the buffer's absolute path, so a worktree of the same repo saw
-- nothing. A wash, though, is only an extmark in the plugin's `HiColor`
-- namespace with `{end_row, end_col, hl_group = 'HiColorN'}`, and the plugin
-- keeps no side table: it enumerates the namespace for save, erase (`f<BS>`)
-- and the `Hi{}` jumps. A mark placed here with the same shape is therefore
-- indistinguishable from one it made, and everything of the plugin's keeps
-- working on it. Verified against 1.64.1.
--
-- Store: one JSON per file under
--   stdpath('data')/highlighter/<root commit, 12 hex>/<path relative to repo root, / -> %>.json
-- (`_abs/<absolute path>` for a file outside any repo). The root commit is what
-- every clone and worktree of a repo shares, and what haunt keys its notes by
-- too, so a note and its wash travel together. The root is found from the
-- buffer's own path, not nvim's cwd, so `:cd` elsewhere changes nothing.
--
-- Each record is `{color, l1, c1, l2, c2, anchor, end_anchor}` -- the extmark
-- as it was (0-based, end exclusive) plus a content anchor for each end
-- (custom/anchor.lua). On load the span is looked up by content; the old
-- numbers are the fallback, clamped, and such a wash is *stale*: its stored
-- record is kept verbatim through later saves, so the text it is looking for
-- survives until it reappears or the wash is erased.
--
-- Loading is tied to `BufReadPost`, with the namespace cleared on
-- `BufReadPre`: a reload leaves extmarks frozen at their old rows rather than
-- moving or dropping them, so the old `BufWinEnter` + `b:hi_restored` guard
-- meant a checkout under an open buffer kept the wrong rows and then saved
-- them. Pattern highlights (`f<CR>`, window matches) are not persisted any
-- more; the plugin's own `:Hi save` still does that by hand.
local M = {}

local NS_NAME = 'HiColor'

--- bufnr -> { [extmark_id] = record } for washes whose anchor was not found.
local stale = {}

local function ns()
  -- Named, so this is the plugin's own id whichever side creates it first.
  return vim.api.nvim_create_namespace(NS_NAME)
end

local function anchor()
  return require 'custom.anchor'
end

local function base_dir()
  return vim.fs.joinpath(vim.fn.stdpath 'data', 'highlighter')
end

-- ---------------------------------------------------------------------------
-- Keys
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

--- The store file for an absolute path.
---@param path string
---@return string
function M.path_for_file(path)
  path = vim.fs.normalize(path)
  local root = vim.fs.root(path, '.git')
  local pid = root and project_id(root)
  local dir, rel
  if pid then
    dir, rel = pid:sub(1, 12), path:sub(#root + 2)
  else
    dir, rel = '_abs', path:gsub('^/', '')
  end
  return vim.fs.joinpath(base_dir(), dir, (rel:gsub('/', '%%')) .. '.json')
end

--- The store file for a buffer, or nil for anything not a real file.
---@param bufnr? integer
---@return string|nil
function M.path_for_buf(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' or vim.bo[bufnr].buftype ~= '' then
    return nil
  end
  return M.path_for_file(name)
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
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return #vim.api.nvim_buf_get_extmarks(bufnr, ns(), 0, -1, { limit = 1 }) > 0
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
      -- Verbatim, except a recolor is real and should stick.
      rec.color = w.color
      out[#out + 1] = rec
    elseif not (w.row == w.end_row and w.end_col <= w.col) then
      -- Zero-width marks are what edits leave behind; the plugin's own jump
      -- deletes them on sight, so they are not worth carrying.
      out[#out + 1] = {
        color = w.color,
        l1 = w.row,
        c1 = w.col,
        l2 = w.end_row,
        c2 = w.end_col,
        anchor = anchor().capture(lines, w.row + 1),
        end_anchor = anchor().capture(lines, w.end_row + 1),
      }
    end
  end
  return out
end

--- Write the buffer's washes, or delete the store when none are left, so an
--- erased wash never comes back. Silent -- for autocmds and hot paths.
---@param bufnr? integer
function M.autosave(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  -- Between BufReadPre and BufReadPost the namespace is deliberately empty.
  if vim.b[bufnr].hi_detached then
    return
  end
  local path = M.path_for_buf(bufnr)
  if not path then
    return
  end
  local records = records_of(bufnr)
  if #records > 0 then
    write_store(path, records)
  -- Only prune once a load has run for this buffer. Deleting on the strength
  -- of an empty buffer that was never restored would discard the store.
  elseif vim.b[bufnr].hi_load_ok and vim.uv.fs_stat(path) then
    vim.fn.delete(path)
  end
end

--- Manual save, with a message. `<leader>Hs`.
function M.save()
  local path = M.path_for_buf()
  if not path then
    return vim.notify('highlighter: buffer has no file to key highlights to', vim.log.levels.WARN)
  end
  M.autosave()
  vim.notify(
    M.has_highlights() and ('highlighter: saved -> ' .. vim.fn.fnamemodify(path, ':~')) or 'highlighter: no highlights, store cleared',
    vim.log.levels.INFO
  )
end

--- Forget the buffer's marks ahead of a re-read. See the header.
---@param bufnr integer
function M.detach(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns(), 0, -1)
  stale[bufnr] = nil
  vim.b[bufnr].hi_detached = true
end

--- Place one record, resolving its ends by content. Returns the extmark id
--- and whether the record had to fall back to its old numbers.
---@return integer|nil id, boolean is_stale
local function place(bufnr, lines, rec)
  local s, e, exact
  if rec.anchor and rec.end_anchor then
    s, e, exact = anchor().resolve_span(lines, rec.anchor, rec.end_anchor, rec.l1 + 1, rec.l2 + 1)
  end
  -- A store written before anchors existed keeps its numbers, un-flagged.
  local is_stale = rec.anchor ~= nil and not exact
  if not s then
    s = math.max(1, math.min(rec.l1 + 1, #lines))
    e = math.max(s, math.min(rec.l2 + 1, #lines))
  end
  local c1 = math.min(rec.c1, #(lines[s] or ''))
  local c2 = math.min(rec.c2, #(lines[e] or ''))
  if s == e and c2 <= c1 then
    return nil, is_stale
  end
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns(), s - 1, c1, {
    end_row = e - 1,
    end_col = c2,
    hl_group = 'HiColor' .. rec.color,
  })
  return ok and id or nil, is_stale
end

--- Restore the buffer's washes. Sets `b:hi_load_ok`, which gates pruning.
---@param bufnr? integer
---@param quiet? boolean
function M.load(bufnr, quiet)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  vim.b[bufnr].hi_detached = nil
  local path = M.path_for_buf(bufnr)
  if not path then
    return
  end
  local data = read_store(path)
  if not data then
    -- Nothing saved is a legitimate "loaded" state: an empty buffer is then
    -- known-good, and autosave may prune later.
    vim.b[bufnr].hi_load_ok = true
    if not quiet then
      vim.notify('highlighter: nothing saved for this file', vim.log.levels.INFO)
    end
    return
  end
  -- The `HiColorN` groups only exist once the plugin has run `s:Load()`.
  require('custom.annot').ensure_loaded()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  stale[bufnr] = {}
  local n_stale = 0
  for _, rec in ipairs(data.marks) do
    local id, is_stale = place(bufnr, lines, rec)
    if id and is_stale then
      stale[bufnr][id] = rec
      n_stale = n_stale + 1
    end
  end
  vim.b[bufnr].hi_load_ok = true
  if n_stale > 0 then
    vim.notify(
      ('highlighter: %d wash%s not re-anchored in %s (kept at old lines)'):format(
        n_stale,
        n_stale == 1 and '' or 'es',
        vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ':~:.')
      ),
      vim.log.levels.WARN
    )
  elseif not quiet then
    vim.notify(('highlighter: loaded %d'):format(#data.marks), vim.log.levels.INFO)
  end
end

--- Autocmds. Called from the plugin spec's `init`.
function M.setup()
  local group = vim.api.nvim_create_augroup('highlighter-persist', { clear = true })
  vim.api.nvim_create_autocmd('BufReadPre', {
    group = group,
    desc = 'Drop washes before the buffer is re-read',
    callback = function(args)
      M.detach(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd('BufReadPost', {
    group = group,
    desc = 'Restore saved washes for this file',
    callback = function(args)
      M.load(args.buf, true)
    end,
  })
  -- Adds and deletes made through our own keys already write through; these
  -- catch the rest (`:Hi` used directly, edits that moved a wash).
  vim.api.nvim_create_autocmd({ 'BufWinLeave', 'BufWritePost' }, {
    group = group,
    desc = 'Save washes for this file',
    callback = function(args)
      M.autosave(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    desc = 'Save washes in every buffer before quitting',
    callback = function()
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
          M.autosave(bufnr)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    callback = function(args)
      stale[args.buf] = nil
    end,
  })

  vim.api.nvim_create_user_command('AnnotMigrateHl', function()
    M.migrate_hl()
  end, { desc = "Convert vim-highlighter's old per-path .hl stores to the anchored per-repo store" })
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
              anchor = anchor().capture(lines, l1 + 1),
              end_anchor = anchor().capture(lines, l2 + 1),
            }
          end
        end
      end
      local target = M.path_for_file(path)
      -- Two worktrees' copies of one file land on one key: append, minus
      -- exact duplicates.
      local existing = read_store(target)
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
      if #marks > 0 then
        write_store(target, marks)
      end
      os.rename(hl, hl .. '.bak')
      if vim.uv.fs_stat(hl .. '.o') then
        os.rename(hl .. '.o', hl .. '.o.bak')
      end
      report[#report + 1] = ('%d wash%s: %s -> %s'):format(added, added == 1 and '' or 'es', tag, vim.fn.fnamemodify(target, ':~'))
    end
  end
  if #report == 0 then
    report[1] = 'nothing to migrate in ' .. dir
  end
  vim.notify(table.concat(report, '\n'), vim.log.levels.INFO)
end

return M
