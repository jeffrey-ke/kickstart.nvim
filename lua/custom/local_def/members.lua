-- C++ members seen from an out-of-line method: in `void Foo::bar() { use(x_); }`
-- the class body of `Foo` encloses the method body for name lookup, even though
-- the body is written somewhere else -- usually the header the .cc includes.
--
-- This finds that class by scope, not by spelling: the class is the one named
-- in `Foo::`, found in this file or a file it includes, then its bases the same
-- way. Only members of that class chain are ever offered, which a text pattern
-- for member declarations could not promise -- `const auto& x_ = ...;` in some
-- other function looks exactly like a member with an initializer.
--
-- Pure given its `io`: reading files is injected, so tests hand it in-memory
-- sources.
--
--   unit = { path, root, source }      a parsed file; source is a bufnr or string
--   io   = { load(path) -> unit|nil, include_path(from_path, include) -> path|nil }

local languages = require 'custom.local_def.languages'

local M = {}

-- Base classes, bases of bases, and so on. Deeper chains than this are rare
-- enough that stopping costs less than the extra parsing.
local MAX_BASE_DEPTH = 4

local function field(node, name)
  return node:field(name)[1]
end

local function text(node, source)
  return vim.treesitter.get_node_text(node, source)
end

-- `Bar<T>` names `Bar`; `base::Base<int>` names `Base`.
local function type_name(node, source)
  local t = node:type()
  if t == 'template_type' then
    return type_name(field(node, 'name'), source)
  end
  if t == 'qualified_identifier' then
    return type_name(field(node, 'name'), source)
  end
  if t == 'type_identifier' or t == 'namespace_identifier' then
    return text(node, source)
  end
end

--- For an out-of-line method definition, its class name and the node naming
--- the method -- `Foo` and `get` in `a::Foo::get()`, `Bar` and `g` in
--- `Bar<T>::g()` -- or nil for anything else.
local function qualified_method(node, source)
  if node:type() ~= 'function_definition' then
    return nil
  end
  -- Unwrap the return type's shape: `const int& Foo::get()`.
  local declarator = field(node, 'declarator')
  while declarator and declarator:type() ~= 'function_declarator' do
    declarator = field(declarator, 'declarator') or declarator:named_child(0)
  end
  local name = declarator and field(declarator, 'declarator')
  if not name or name:type() ~= 'qualified_identifier' then
    return nil
  end
  -- `a::Foo::get` nests as a::(Foo::get); the class is the innermost scope.
  while field(name, 'name'):type() == 'qualified_identifier' do
    name = field(name, 'name')
  end
  return type_name(field(name, 'scope'), source), field(name, 'name')
end

--- The class an out-of-line method definition belongs to, or nil.
function M.method_class(node, source)
  return (qualified_method(node, source))
end

local class_query = vim.treesitter.query.parse(
  'cpp',
  [[
  [(class_specifier name: (type_identifier) @name body: (field_declaration_list))
   (struct_specifier name: (type_identifier) @name body: (field_declaration_list))] @class
]]
)

local include_query = vim.treesitter.query.parse('cpp', [[(preproc_include path: (string_literal (string_content) @path))]])

local function_query = vim.treesitter.query.parse('cpp', '(function_definition) @function')

-- iter_matches yields a node per capture on older nvim, a list on newer.
local function first(nodes)
  return type(nodes) == 'table' and nodes[1] or nodes
end

local function find_class(unit, name)
  for _, match in class_query:iter_matches(unit.root, unit.source, 0, -1) do
    local captured = {}
    for id, nodes in pairs(match) do
      captured[class_query.captures[id]] = first(nodes)
    end
    if text(captured.name, unit.source) == name then
      return captured.class
    end
  end
end

local function includes(unit)
  local out = {}
  for _, node in include_query:iter_captures(unit.root, unit.source, 0, -1) do
    out[#out + 1] = text(node, unit.source)
  end
  return out
end

--- This file first, then the files it includes directly. The class of an
--- out-of-line method is almost always in its own .cc or its paired .h, and a
--- base class in a header the class's header includes.
local function find_class_near(unit, name, io)
  local class = find_class(unit, name)
  if class then
    return class, unit
  end
  if not unit.path then
    return nil
  end
  for _, include in ipairs(includes(unit)) do
    local path = io.include_path(unit.path, include)
    local included = path and io.load(path)
    if included then
      class = find_class(included, name)
      if class then
        return class, included
      end
    end
  end
end

-- Inside a field declaration, a name under a function_declarator is a method
-- (`void g(int r);`); anything else is a data member.
local function names_method(identifier, declaration)
  local up = identifier:parent()
  while up and not up:equal(declaration) do
    if up:type() == 'function_declarator' then
      return true
    end
    up = up:parent()
  end
  return false
end

local function members_named(class, unit, member)
  local found = {}
  local declare = languages.cpp.extractors.field_declaration
  local body = field(class, 'body')
  for i = 0, body:named_child_count() - 1 do
    local child = body:named_child(i)
    if child:type() == 'field_declaration' then
      declare(child, function(identifier)
        if text(identifier, unit.source) == member then
          found[#found + 1] = {
            name = member,
            pos = { identifier:start() },
            path = unit.path,
            method = names_method(identifier, child),
          }
        end
      end)
    end
  end
  return found
end

-- `Foo::name(...) { ... }` definitions in `unit`.
local function out_of_line_definitions(unit, class_name, member)
  local found = {}
  for _, node in function_query:iter_captures(unit.root, unit.source, 0, -1) do
    local class, name = qualified_method(node, unit.source)
    if class == class_name and text(name, unit.source) == member then
      found[#found + 1] = { name = member, pos = { name:start() }, path = unit.path }
    end
  end
  return found
end

-- Where a class's methods are implemented: the file being read (a method
-- calling a sibling), the class's own file (class and methods in one .cc), and
-- the source paired with the class's header (foo.h -> foo.cc).
local SOURCE_EXTENSIONS = { 'cc', 'cpp', 'cxx' }

local function implementation_units(from, class_unit, io)
  local units, seen = {}, {}
  local function add(unit)
    local key = unit and (unit.path or '\0buffer')
    if unit and not seen[key] then
      seen[key] = true
      units[#units + 1] = unit
    end
  end
  add(from)
  add(class_unit)
  if class_unit.path then
    local stem = class_unit.path:gsub('%.[^./]+$', '')
    for _, ext in ipairs(SOURCE_EXTENSIONS) do
      local path = stem .. '.' .. ext
      if path ~= class_unit.path then
        add(io.load(path))
      end
    end
  end
  return units
end

-- A method's declaration in the class body is where it is announced, not
-- where it is written. Put its out-of-line definitions first; keep the
-- declaration after them, and on its own when no definition is found (an
-- inline, defaulted, or pure virtual method, or one implemented elsewhere).
local function definitions_first(found, from, class_unit, class_name, member, io)
  local any_method = vim.iter(found):any(function(def)
    return def.method
  end)
  if not any_method then
    return found
  end
  local out = {}
  for _, unit in ipairs(implementation_units(from, class_unit, io)) do
    vim.list_extend(out, out_of_line_definitions(unit, class_name, member))
  end
  return vim.list_extend(out, found)
end

local function bases(class, unit)
  local out = {}
  for i = 0, class:named_child_count() - 1 do
    local clause = class:named_child(i)
    if clause:type() == 'base_class_clause' then
      for j = 0, clause:named_child_count() - 1 do
        local name = type_name(clause:named_child(j), unit.source)
        if name then
          out[#out + 1] = name
        end
      end
    end
  end
  return out
end

--- Declarations of `member` in class `class_name` or its bases, looked up from
--- `unit`, as { {name, pos, path} }; nil when the class cannot be found, so the
--- caller knows no class scope applies. For a method, its out-of-line
--- definitions come first, then the declaration.
function M.lookup(class_name, member, unit, io)
  local seen = {}
  local function search(name, from, depth)
    local key = name .. '\0' .. (from.path or '')
    if seen[key] or depth > MAX_BASE_DEPTH then
      return nil
    end
    seen[key] = true
    local class, class_unit = find_class_near(from, name, io)
    if not class then
      return nil
    end
    local found = members_named(class, class_unit, member)
    if #found > 0 then
      return definitions_first(found, from, class_unit, name, member, io)
    end
    for _, base in ipairs(bases(class, class_unit)) do
      local inherited = search(base, class_unit, depth + 1)
      if inherited and #inherited > 0 then
        return inherited
      end
    end
    return found
  end
  return search(class_name, unit, 0)
end

return M
