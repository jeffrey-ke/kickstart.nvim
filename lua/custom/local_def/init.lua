-- `:Def` for local names: resolve the identifier under the cursor to the
-- binding its enclosing scopes give it, instead of grepping for its spelling.
--
-- This file is the only part that reads editor state and the filesystem -- the
-- buffer's parser, a position, the headers a C++ file includes. collect.lua
-- turns the tree into plain tables, members.lua finds a method's class, and
-- resolve.lua applies the scoping rules, all without touching nvim or disk, so
-- their behavior is pinned by tests/local_def_test.lua.
--
-- A C++ member access, `obj.x`, resolves through the class `obj` is declared
-- as. Anything that is not a local or a member -- a function, a type, a name from
-- another file -- resolves to nothing, and the caller falls back to jedi
-- (Python) or its repo-wide grep. A Python import does resolve, flagged: it is
-- a binding, but it only says the definition is in another file.

local collect = require 'custom.local_def.collect'
local disk = require 'custom.local_def.disk'
local languages = require 'custom.local_def.languages'
local members = require 'custom.local_def.members'
local resolve = require 'custom.local_def.resolve'

local M = {}

-- Definitions of the name at `node`, nearest first, in resolve.lua's shape:
-- { {name, pos, path, import} }, `path` set when the definition is in a file
-- other than the buffer.
local definitions

-- The unit a definition was found in: the buffer, or a file read from disk.
local function unit_of(ctx, def)
  if def.path and def.path ~= ctx.unit.path then
    return disk.load(def.path)
  end
  return ctx.unit
end

-- `obj.x`: no scope binds `x`, so look it up in the class `obj` is declared
-- as. `obj` itself resolves by the same rules as any name -- through scopes, or
-- through another member access for `a.b.x` -- and `this` is the enclosing
-- class. One declared type per hop, read off the declaration: `auto`, a call's
-- return value, or a smart pointer's pointee is a type it does not see, and the
-- lookup gives up to the grep.
local function member_definitions(ctx, node, object)
  local class, from
  if object:type() == 'this' then
    class, from = members.enclosing_class(node, ctx.bufnr), ctx.unit
  else
    local named = object:type() == 'field_expression' and object:field('field')[1] or object
    local def = definitions(ctx, named)[1]
    from = def and unit_of(ctx, def)
    class = from and members.declared_type(from, def.pos)
  end
  if not class then
    return {}
  end
  return members.lookup(class, vim.treesitter.get_node_text(node, ctx.bufnr), from, disk) or {}
end

definitions = function(ctx, node)
  local object = ctx.spec.member_object and ctx.spec.member_object(node)
  if object then
    return member_definitions(ctx, node, object)
  end
  if not ctx.spec.is_reference(node) then
    return {}
  end
  local name = vim.treesitter.get_node_text(node, ctx.bufnr)

  local members_for
  if ctx.spec.out_of_line_members then
    members_for = function(fn)
      local class = members.method_class(fn, ctx.bufnr)
      return class and members.lookup(class, name, ctx.unit, disk)
    end
  end

  local scopes, defs, ref_scope = collect.collect(ctx.unit.root, ctx.bufnr, ctx.spec, node, members_for)
  local ref = { name = name, scope = ref_scope, pos = { node:start() } }
  return resolve.resolve(scopes, defs, ref, ctx.spec.rules)
end

--- Definitions of the identifier at the 0-based (row, col) of `bufnr`, nearest
--- first, as { {row, col, name, path, import} }. `path` is set only for a
--- definition in another file; `import` only for a binding an import made.
--- {} when the buffer has no supported parser, the position is not on a
--- variable or member name, or nothing in scope binds it.
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
  if not node then
    return {}
  end

  local buffer_path = vim.api.nvim_buf_get_name(bufnr)
  local ctx = {
    bufnr = bufnr,
    spec = spec,
    unit = { path = buffer_path ~= '' and buffer_path or nil, root = root, source = bufnr },
  }
  return vim.tbl_map(function(def)
    local elsewhere = def.path and def.path ~= buffer_path
    return { row = def.pos[1], col = def.pos[2], name = def.name, path = elsewhere and def.path or nil, import = def.import }
  end, definitions(ctx, node))
end

local function line_at(bufnr, def)
  if def.path then
    return vim.fn.readfile(def.path, '', def.row + 1)[def.row + 1] or ''
  end
  return vim.api.nvim_buf_get_lines(bufnr, def.row, def.row + 1, false)[1] or ''
end

--- Definitions of the word under the cursor as custom.locations entries,
--- nearest first, plus the name looked up (for a list title) and whether every
--- one is an import -- a binding that only says the definition is elsewhere.
--- An empty list when there is no local definition. Loading them anywhere is
--- the caller's job -- see custom.locations.load.
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
  local imported = #found > 0 and vim.iter(found):all(function(def)
    return def.import
  end)
  return locations, found[1] and found[1].name, imported
end

return M
