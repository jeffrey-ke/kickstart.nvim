-- The fallback for a search rg answered with nothing: the same search over the
-- git index, for a worktree whose index lists files its working tree does not
-- have. A preview worktree checks out only the files a change touches and marks
-- the other ~170k skip-worktree, so a definition in an untouched header is not
-- on disk for rg to read. `git grep --cached` reads the blob the index records
-- for it instead -- 1.5 s for a C++ definition across the monorepo.
--
--   query = { pattern, dir, types = rg types | nil, globs = rg globs | nil }
--
-- A hit is opened as fugitive's index buffer for the path, the one `:Gedit
-- :0:<path>` opens, since there is no file to open.

local locations = require 'custom.locations'

local M = {}

-- rg names file types, git takes pathspecs; `rg --type-list` is the table
-- between them. Read once, on the main loop, since vim.fn is off limits in a
-- vim.system callback.
local type_globs
local function rg_type_globs()
  if not type_globs then
    type_globs = {}
    for _, line in ipairs(vim.fn.systemlist { 'rg', '--type-list' }) do
      local name, globs = line:match '^(%S+): (.*)$'
      if name then
        type_globs[name] = vim.split(globs, ', ', { plain = true })
      end
    end
  end
  return type_globs
end

-- git's glob pathspec has no `{a,b}`, which rg's globs use.
local function expand_braces(glob)
  local before, alternatives, after = glob:match '^(.-){(.-)}(.*)$'
  if not before then
    return { glob }
  end
  local out = {}
  for _, alternative in ipairs(vim.split(alternatives, ',', { plain = true })) do
    vim.list_extend(out, expand_braces(before .. alternative .. after))
  end
  return out
end

--- Pure. The pathspecs selecting the files `query` would have rg search, given
--- rg's type -> globs table. rg matches a glob with no `/` against the file name
--- at any depth, which in git is `**/`; a leading `!` excludes.
function M.pathspecs(query, globs_of_type)
  local specs = {}
  local function add(magic, glob)
    for _, expanded in ipairs(expand_braces(glob)) do
      specs[#specs + 1] = ':(' .. magic .. ')' .. (expanded:find '/' and expanded or '**/' .. expanded)
    end
  end
  for _, rg_type in ipairs(query.types or {}) do
    for _, glob in ipairs(assert(globs_of_type[rg_type], 'unknown rg type ' .. rg_type)) do
      add('glob', glob)
    end
  end
  for _, glob in ipairs(query.globs or {}) do
    if vim.startswith(glob, '!') then
      add('exclude,glob', glob:sub(2))
    else
      add('glob', glob)
    end
  end
  return specs
end

--- Pure. `git grep` over the index, printing what `rg --vimgrep` prints. -P
--- because the patterns are written for rg, whose syntax PCRE covers;
--- --full-name because the hits are joined to the top level, not the cwd.
function M.argv(query, globs_of_type)
  local argv = { 'git', 'grep', '--cached', '-P', '-I', '-n', '--column', '--full-name', '-e', query.pattern, '--' }
  return vim.list_extend(argv, M.pathspecs(query, globs_of_type))
end

--- Calls `on_done(found, err)` on the main loop. `found` is empty when `dir` is
--- not in a git worktree or its index has no skip-worktree entries, so a miss in
--- an ordinary checkout costs one `git ls-files` (60 ms on the monorepo), not a
--- second search. A hit whose file is on disk is dropped: rg already searched it,
--- and the disk, not the index, has its current text.
function M.search(query, on_done)
  local argv = M.argv(query, rg_type_globs())
  local function finish(found, err)
    vim.schedule(function()
      on_done(found, err)
    end)
  end
  vim.system({ 'git', 'rev-parse', '--absolute-git-dir', '--show-toplevel' }, { cwd = query.dir, text = true }, function(repo)
    if repo.code ~= 0 then
      return finish {}
    end
    local git_dir, top = unpack(vim.split(vim.trim(repo.stdout), '\n'))
    vim.system({ 'git', 'ls-files', '-t' }, { cwd = query.dir, text = true }, function(listed)
      if not ('\n' .. listed.stdout):find '\nS ' then
        return finish {}
      end
      vim.system(argv, { cwd = query.dir, text = true }, function(result)
        if result.code > 1 then
          return finish({}, result.stderr ~= '' and result.stderr or ('git grep exited ' .. result.code))
        end
        vim.schedule(function()
          local found = {}
          for _, location in ipairs(locations.from_vimgrep(vim.split(result.stdout, '\n', { trimempty = true }))) do
            if not vim.uv.fs_stat(top .. '/' .. location.filename) then
              location.filename = vim.fn.FugitiveFind(':0:' .. location.filename, git_dir)
              found[#found + 1] = location
            end
          end
          on_done(found)
        end)
      end)
    end)
  end)
end

return M
