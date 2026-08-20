-- `:Cload` -- reload a saved code-pointer quickfix list, picked in Telescope.
--
-- Claude's pointing-to-code skill pushes a quickfix list of `file:line` pointers
-- into this session, and its save_qf.sh writes that list to disk as a pair under
-- a `code-pointers/` directory:
--
--   walkthru.quickfix       path:lnum:col: text  -- what :cfile parses
--   walkthru.quickfix.json  title, saved date, commit, setqflist-ready items
--
-- A quickfix list dies with the session; these outlive it. This module finds
-- them and puts them back.
--
-- Why prefer the .json over `:cfile` on the .quickfix: it restores the list
-- *title*, which is the only thing distinguishing "sceneset -> scenes -> Gemini"
-- from whatever `:Make` left behind, and it needs no `errorformat` cooperation.
-- `setqflist` ignores the metadata keys sitting beside `items`, so the whole
-- decoded object can be passed as the `what` dict. The .quickfix file stays the
-- fallback, and stays free of frontmatter for that reason: `:cfile` keeps any
-- line matching no errorformat pattern as a valid=0 entry, so a YAML header
-- would show up as clutter in :copen.

local M = {}

local DIRNAME = 'code-pointers'

--- How far up the tree to look. 'home' | 'git'.
---
--- 'home' collects every `code-pointers/` from the starting directory up to and
--- including $HOME. 'git' stops at the first directory holding a `.git`.
---
--- 'home' is the default because the first `.git` is the wrong ceiling inside a
--- submodule. This very file lives in ~/dotfiles/nvim, a submodule of
--- ~/dotfiles, so a git ceiling would hide ~/dotfiles/code-pointers/ whenever
--- the buffer is nvim config. `code-pointers/` directories are deliberate and
--- rare, so walking further is cheap, and results are ordered nearest-first
--- either way -- a distant match sorts below the local one rather than
--- displacing it. Set `vim.g.code_pointers_ceiling = 'git'` to tighten it.
local function ceiling()
  return vim.g.code_pointers_ceiling or 'home'
end

-- Search from the current file's directory rather than the cwd: the buffer is
-- the better guess at which project you mean, and it differs from the cwd
-- exactly in the submodule case above.
local function start_dir()
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= '' and vim.uv.fs_stat(name) then
    return vim.fs.dirname(vim.fn.fnamemodify(name, ':p'))
  end
  return vim.uv.cwd()
end

-- `stop` in vim.fs.find is exclusive -- the directory named is not itself
-- searched -- so to include D we pass its parent.
local function stop_dir(from)
  if ceiling() == 'git' then
    -- No `type` filter: `.git` is a directory in a normal clone and a file
    -- holding a gitdir: pointer in a submodule or linked worktree.
    local git = vim.fs.find('.git', { path = from, upward = true, limit = 1 })[1]
    if git then
      return vim.fs.dirname(vim.fs.dirname(git))
    end
  end
  local home = vim.uv.os_homedir()
  return home and vim.fs.dirname(home) or nil
end

local function read_json(path)
  local fd = io.open(path, 'r')
  if not fd then
    return nil
  end
  local raw = fd:read '*a'
  fd:close()
  local ok, decoded = pcall(vim.json.decode, raw)
  if ok and type(decoded) == 'table' then
    return decoded
  end
  return nil
end

local function read_lines(path)
  local lines = {}
  local fd = io.open(path, 'r')
  if not fd then
    return lines
  end
  for line in fd:lines() do
    lines[#lines + 1] = line
  end
  fd:close()
  return lines
end

--- Every saved list reachable from the current buffer, nearest directory first.
function M.discover()
  local from = start_dir()
  local dirs = vim.fs.find(DIRNAME, {
    path = from,
    upward = true,
    type = 'directory',
    limit = math.huge,
    stop = stop_dir(from),
  })

  local entries = {}
  for _, dir in ipairs(dirs) do
    local files = vim.fn.globpath(dir, '*.quickfix', false, true)
    table.sort(files)
    for _, qf in ipairs(files) do
      entries[#entries + 1] = {
        name = vim.fn.fnamemodify(qf, ':t:r'),
        qf_path = qf,
        json_path = qf .. '.json',
        dir = dir,
        meta = read_json(qf .. '.json'),
      }
    end
  end
  return entries
end

local function display(entry)
  local parts = { entry.name }
  local meta = entry.meta
  if meta and meta.saved then
    -- Date only: the picker line is not the place for seconds.
    parts[#parts + 1] = (meta.saved:gsub(' at .*', ''))
  end
  parts[#parts + 1] = vim.fn.fnamemodify(entry.dir, ':~:.')
  return table.concat(parts, '  ·  ')
end

local function preview_lines(entry)
  local meta = entry.meta or {}
  local out = {}
  if meta.title then
    out[#out + 1] = meta.title
  end
  if meta.description then
    out[#out + 1] = meta.description
  end
  if meta.saved then
    out[#out + 1] = 'saved   ' .. meta.saved
  end
  if meta.commit and meta.commit ~= '' then
    out[#out + 1] = ('commit  %s (%s)'):format(meta.commit:sub(1, 12), meta.tree_state or '?')
  end
  out[#out + 1] = ('%s'):format(vim.fn.fnamemodify(entry.qf_path, ':~'))
  out[#out + 1] = ('─'):rep(72)
  for i, line in ipairs(read_lines(entry.qf_path)) do
    -- "/abs/path:12:1: text" -> "12  text", with the path shortened.
    local path, lnum, text = line:match '^(.-):(%d+):%d+: (.*)$'
    if path then
      out[#out + 1] = ('%4s  %s  %s'):format(lnum, vim.fn.fnamemodify(path, ':t'), text)
    else
      out[#out + 1] = ('%4d  %s'):format(i, line)
    end
  end
  return out
end

-- The sidecar pins the commit its line numbers were read at. Drifting off that
-- commit is the one silent way a saved list goes wrong, so say so.
local function warn_if_stale(entry)
  local meta = entry.meta
  if not meta or not meta.commit or meta.commit == '' then
    return
  end
  local ok, res = pcall(function()
    return vim.system({ 'git', 'rev-parse', 'HEAD' }, { cwd = entry.dir, text = true }):wait()
  end)
  if not ok or res.code ~= 0 then
    return
  end
  local head = vim.trim(res.stdout or '')
  if head ~= '' and head ~= meta.commit then
    vim.notify(
      ('%s was saved at %s, HEAD is %s -- line numbers may have drifted'):format(entry.name, meta.commit:sub(1, 8), head:sub(1, 8)),
      vim.log.levels.WARN
    )
  end
end

function M.load(entry)
  local meta = entry.meta
  if meta and type(meta.items) == 'table' and #meta.items > 0 then
    -- ' ' rather than 'r': push a *new* list, so whatever was loaded before
    -- stays reachable with :colder.
    vim.fn.setqflist({}, ' ', meta)
  elseif vim.uv.fs_stat(entry.qf_path) then
    vim.cmd('cfile ' .. vim.fn.fnameescape(entry.qf_path))
  else
    vim.notify('Cload: nothing to read at ' .. entry.qf_path, vim.log.levels.ERROR)
    return
  end

  local size = vim.fn.getqflist({ size = 0 }).size
  vim.cmd 'botright copen'
  vim.notify(('%s: %d pointer%s'):format(entry.name, size, size == 1 and '' or 's'))
  warn_if_stale(entry)
end

local function pick(entries)
  local ok, pickers = pcall(require, 'telescope.pickers')
  if not ok then
    -- telescope-ui-select routes this through Telescope anyway; this branch is
    -- for a session where Telescope has not loaded at all.
    vim.ui.select(entries, { prompt = 'Code pointers', format_item = display }, function(choice)
      if choice then
        M.load(choice)
      end
    end)
    return
  end

  local finders = require 'telescope.finders'
  local conf = require('telescope.config').values
  local previewers = require 'telescope.previewers'
  local actions = require 'telescope.actions'
  local action_state = require 'telescope.actions.state'

  pickers
    .new({}, {
      prompt_title = 'Code Pointers',
      finder = finders.new_table {
        results = entries,
        entry_maker = function(entry)
          local meta = entry.meta or {}
          return {
            value = entry,
            display = display(entry),
            -- Searchable on name, title and description, not just the filename.
            ordinal = table.concat({ entry.name, meta.title or '', meta.description or '' }, ' '),
          }
        end,
      },
      sorter = conf.generic_sorter {},
      previewer = previewers.new_buffer_previewer {
        title = 'Pointers',
        define_preview = function(self, entry)
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, preview_lines(entry.value))
        end,
      },
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            M.load(selection.value)
          end
        end)
        return true
      end,
    })
    :find()
end

function M.open(name)
  local entries = M.discover()
  if #entries == 0 then
    vim.notify(('Cload: no %s/ found above %s (ceiling: %s)'):format(DIRNAME, vim.fn.fnamemodify(start_dir(), ':~'), ceiling()), vim.log.levels.WARN)
    return
  end

  if name and name ~= '' then
    local matches = vim.tbl_filter(function(entry)
      return entry.name == name
    end, entries)
    if #matches == 0 then
      vim.notify('Cload: no saved list named ' .. name, vim.log.levels.ERROR)
      return
    end
    if #matches > 1 then
      vim.notify(('Cload: %d lists named %s, taking the nearest'):format(#matches, name), vim.log.levels.WARN)
    end
    -- discover() is nearest-first, so matches[1] is the closest one.
    M.load(matches[1])
    return
  end

  if #entries == 1 then
    M.load(entries[1])
    return
  end
  pick(entries)
end

function M.setup()
  vim.api.nvim_create_user_command('Cload', function(opts)
    M.open(opts.args)
  end, {
    nargs = '?',
    desc = 'Load a saved code-pointers quickfix list',
    complete = function(lead)
      local names = {}
      local seen = {}
      for _, entry in ipairs(M.discover()) do
        if not seen[entry.name] and entry.name:find(lead, 1, true) == 1 then
          seen[entry.name] = true
          names[#names + 1] = entry.name
        end
      end
      return names
    end,
  })
end

return M
