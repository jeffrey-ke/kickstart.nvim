-- The filesystem side of C++ lookups: parse a file into a unit, and resolve an
-- `#include` to a path. members.lua and rank.lua take these as injected `io`
-- so their logic stays testable on in-memory sources; this is the real thing.
--
--   unit = { path, root, source }

local M = {}

-- Include paths in this monorepo are written from the workspace root.
local ROOT_MARKERS = { 'MODULE.bazel', 'WORKSPACE', 'WORKSPACE.bazel', '.git' }

-- Files are reparsed only when they change on disk.
local parsed = {}

--- The parsed file at `path`, or nil if it cannot be read.
function M.load(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil
  end
  local cached = parsed[path]
  if cached and cached.mtime == stat.mtime.sec then
    return cached.unit
  end
  local file = io.open(path)
  if not file then
    return nil
  end
  local source = file:read 'a'
  file:close()
  local root = vim.treesitter.get_string_parser(source, 'cpp'):parse()[1]:root()
  local unit = { path = path, root = root, source = source }
  parsed[path] = { mtime = stat.mtime.sec, unit = unit }
  return unit
end

--- The file `#include "<include>"` names from `from`, or nil.
function M.include_path(from, include)
  local candidates = { vim.fs.joinpath(vim.fs.dirname(from), include) }
  local root = vim.fs.root(from, ROOT_MARKERS)
  if root then
    table.insert(candidates, 1, vim.fs.joinpath(root, include))
  end
  for _, path in ipairs(candidates) do
    if vim.uv.fs_stat(path) then
      return path
    end
  end
end

return M
