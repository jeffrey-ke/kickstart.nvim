-- `:Def` for local names: resolve the identifier under the cursor to the
-- binding its enclosing scopes give it, instead of grepping for its spelling.
--
-- This file is the only part that reads editor state and the filesystem -- the
-- buffer's parser, a position, the headers a C++ file includes. collect.lua
-- turns the tree into plain tables, members.lua finds a method's class, and
-- resolve.lua applies the scoping rules, all without touching nvim or disk, so
-- their behavior is pinned by tests/local_def_test.lua.
--
-- Anything that is not a local or a member -- a function, a type, a name from
-- another file -- resolves to nothing, and the caller falls back to its
-- repo-wide grep.

local collect = require 'custom.local_def.collect'
local disk = require 'custom.local_def.disk'
local languages = require 'custom.local_def.languages'
local members = require 'custom.local_def.members'
local resolve = require 'custom.local_def.resolve'

local M = {}

--- Definitions of the identifier at the 0-based (row, col) of `bufnr`, nearest
--- first, as { {row, col, name, path} }. `path` is set only for a definition
--- in another file. {} when the buffer has no supported parser, the position
--- is not on a variable name, or nothing in scope binds it.
function M.find(bufnr, row, col)
  local lang = vim.treesitter.language.get_lang(vim.bo[bufnr].filetype)
  local spec = lang and languages[lang]
  if not spec then
    return {}
  end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
  if not ok or not parser then
    return {}
  end
  local root = parser:parse()[1]:root()
  local node = root:named_descendant_for_range(row, col, row, col)
  if not node or not spec.is_reference(node) then
    return {}
  end
  local name = vim.treesitter.get_node_text(node, bufnr)

  local buffer_path = vim.api.nvim_buf_get_name(bufnr)
  local members_for
  if spec.out_of_line_members then
    local unit = { path = buffer_path ~= '' and buffer_path or nil, root = root, source = bufnr }
    members_for = function(fn)
      local class = members.method_class(fn, bufnr)
      return class and members.lookup(class, name, unit, disk)
    end
  end

  local scopes, defs, ref_scope = collect.collect(root, bufnr, spec, node, members_for)
  local ref = { name = name, scope = ref_scope, pos = { node:start() } }
  return vim.tbl_map(function(def)
    local elsewhere = def.path and def.path ~= buffer_path
    return { row = def.pos[1], col = def.pos[2], name = def.name, path = elsewhere and def.path or nil }
  end, resolve.resolve(scopes, defs, ref, spec.rules))
end

local function line_at(bufnr, def)
  if def.path then
    return vim.fn.readfile(def.path, '', def.row + 1)[def.row + 1] or ''
  end
  return vim.api.nvim_buf_get_lines(bufnr, def.row, def.row + 1, false)[1] or ''
end

--- Definitions of the word under the cursor as custom.locations entries,
--- nearest first, plus the name looked up (for a list title). An empty list
--- when there is no local definition. Loading them anywhere is the caller's
--- job -- see custom.locations.load.
function M.at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local found = M.find(bufnr, cursor[1] - 1, cursor[2])
  local locations = vim.tbl_map(function(def)
    local location = { lnum = def.row + 1, col = def.col + 1, text = vim.trim(line_at(bufnr, def)) }
    if def.path then
      location.filename = def.path
    else
      location.bufnr = bufnr
    end
    return location
  end, found)
  return locations, found[1] and found[1].name
end

return M
