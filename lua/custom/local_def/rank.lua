-- Order grep hits for "go to definition": a function's body before its
-- declaration. rg's definition pattern cannot tell `size_t F(...);` in a
-- header from `size_t F(...) {` in the .cc -- both start at column 0 with the
-- name followed by `(` -- and it lists whichever file it reached first. The
-- syntax tree can tell them apart, so this asks it.
--
-- Pure given `load` (path -> unit | nil; see disk.lua), so tests hand it
-- in-memory sources.

local M = {}

local CPP_EXTENSIONS = { c = true, cc = true, cpp = true, cxx = true, h = true, hh = true, hpp = true, hxx = true }

-- Past this many hits the name is too common for ordering to rescue, and
-- parsing every file would stall the editor.
local MAX_RANKED = 100

local function field(node, name)
  return node:field(name)[1]
end

local type_specifiers = { class_specifier = true, struct_specifier = true, union_specifier = true, enum_specifier = true }

-- Nodes between a declared name and its declaration. Passing through anything
-- else -- a call, an argument list, a body -- means the name is used there,
-- not declared: `size_t n = F(x);` is not a declaration of F.
local signature_path = {
  destructor_name = true,
  function_declarator = true,
  init_declarator = true,
  operator_name = true,
  pointer_declarator = true,
  qualified_identifier = true,
  reference_declarator = true,
  template_function = true,
}

--- Pure. What the name `name` on 0-based `row` of `unit` is, given that row's
--- text: 'definition' (a function with a body, a class with a body),
--- 'declaration' (a prototype, a forward declaration, a member declared in a
--- class), or nil when it is neither -- a use, a comment, a macro.
function M.kind(unit, row, line, name)
  local col = line:find('%f[%w_]' .. vim.pesc(name) .. '%f[^%w_]')
  if not col then
    return nil
  end
  local node = unit.root:named_descendant_for_range(row, col - 1, row, col - 1 + #name)
  local child, up = node, node and node:parent()
  while up do
    local t = up:type()
    if t == 'function_definition' then
      -- The name must be in the signature; one in the body is just a use.
      local declarator = field(up, 'declarator')
      return declarator and child:equal(declarator) and 'definition' or nil
    end
    if t == 'declaration' or t == 'field_declaration' then
      return 'declaration'
    end
    if type_specifiers[t] then
      return field(up, 'body') and 'definition' or 'declaration'
    end
    if not signature_path[t] then
      return nil
    end
    child, up = up, up:parent()
  end
end

--- Locations (see custom.locations) reordered: definitions first, then hits
--- that are neither or are not C/C++, then declarations. Order within each
--- group is kept, and nothing is dropped -- the declaration stays one `]l`
--- away.
function M.definitions_first(locations, name, load)
  if #locations > MAX_RANKED then
    return locations
  end
  local groups = { definition = {}, other = {}, declaration = {} }
  for _, location in ipairs(locations) do
    local ext = location.filename and location.filename:match '%.(%w+)$'
    local unit = ext and CPP_EXTENSIONS[ext] and load(location.filename)
    local kind = unit and M.kind(unit, location.lnum - 1, location.text or '', name)
    table.insert(groups[kind or 'other'], location)
  end
  return vim.list_extend(vim.list_extend(groups.definition, groups.other), groups.declaration)
end

return M
