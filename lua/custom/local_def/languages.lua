-- Per-language knowledge for local-definition lookup, as data: which syntax
-- nodes open a scope, which nodes bind names and where the names sit inside
-- them, which identifiers can be looked up at all, and the scoping rules
-- resolve.lua applies. Adding a binding form is adding an entry, not a branch.
--
-- Node and field names are tree-sitter-cpp's and tree-sitter-python's.

local M = {}

local function named_children(node)
  local out = {}
  for i = 0, node:named_child_count() - 1 do
    out[#out + 1] = node:named_child(i)
  end
  return out
end

local function field(node, name)
  return node:field(name)[1]
end

-- C / C++ ---------------------------------------------------------------------

-- Declarators wrap the declared name in the shape of its type: `const auto&
-- [a, b]`, `int* p`, `int a[3]`. Unwrapping them yields the name.
local cpp_wrappers = {
  array_declarator = true,
  attributed_declarator = true,
  function_declarator = true,
  init_declarator = true,
  parenthesized_declarator = true,
  pointer_declarator = true,
  reference_declarator = true,
  variadic_declarator = true,
}

local function declared_names(node, emit)
  local t = node:type()
  if t == 'identifier' or t == 'field_identifier' then
    emit(node)
  elseif t == 'structured_binding_declarator' then
    for _, child in ipairs(named_children(node)) do
      declared_names(child, emit)
    end
  elseif cpp_wrappers[t] then
    -- reference_declarator and variadic_declarator hold the name positionally.
    local inner = field(node, 'declarator') or named_children(node)[1]
    if inner then
      declared_names(inner, emit)
    end
  end
  -- qualified_identifier (`int Foo::x = 1;`) defines something declared
  -- elsewhere, so it is not a local binding.
end

local function each_declarator(node, emit)
  for _, declarator in ipairs(node:field('declarator')) do
    declared_names(declarator, emit)
  end
end

-- `void proto(int q);` inside a body declares a function, and `q` binds
-- nothing. A parameter binds a name only in a function definition's signature,
-- a lambda's, or a catch clause.
local function is_bound_parameter(node)
  local owner = node:parent() and node:parent():parent()
  if not owner then
    return false
  end
  local t = owner:type()
  if t == 'lambda_declarator' or t == 'catch_clause' then
    return true
  end
  if t ~= 'function_declarator' then
    return false
  end
  local up = owner:parent()
  while up and cpp_wrappers[up:type()] do
    up = up:parent()
  end
  return up ~= nil and up:type() == 'function_definition'
end

local function parameter(node, emit)
  if is_bound_parameter(node) then
    each_declarator(node, emit)
  end
end

local cpp = {
  scope_kinds = {
    translation_unit = 'module',
    namespace_definition = 'block',
    function_definition = 'function',
    lambda_expression = 'function',
    class_specifier = 'class',
    struct_specifier = 'class',
    union_specifier = 'class',
    compound_statement = 'block',
    for_statement = 'block',
    for_range_loop = 'block',
    if_statement = 'block',
    while_statement = 'block',
    do_statement = 'block',
    switch_statement = 'block',
    catch_clause = 'block',
  },
  extractors = {
    declaration = each_declarator,
    field_declaration = each_declarator,
    for_range_loop = each_declarator,
    parameter_declaration = parameter,
    optional_parameter_declaration = parameter,
    variadic_parameter_declaration = parameter,
    lambda_capture_initializer = function(node, emit)
      emit(field(node, 'left'))
    end,
  },
  -- `obj.x` and `obj->x` name a member of some other object's type, which no
  -- enclosing scope binds; `ns::x` names something in another namespace.
  is_reference = function(node)
    local t, parent = node:type(), node:parent()
    if t == 'field_identifier' then
      return parent ~= nil and parent:type() ~= 'field_expression'
    end
    if t ~= 'identifier' then
      return false
    end
    return not (parent and parent:type() == 'qualified_identifier')
  end,
  -- Block scoped, and a name is visible only after its declaration -- except
  -- inside a class body, where members are visible throughout.
  rules = { ordered = true, unordered_kinds = { class = true }, nested_skips_class = false },
  -- `Foo::bar() { ... }` sees Foo's members though written outside the class;
  -- members.lua finds them.
  out_of_line_members = true,
}

-- Python ----------------------------------------------------------------------

-- Assignment targets: `a`, `a, (b, *rest)`, `[x, y]`. `obj.attr = 1` and
-- `arr[0] = 2` mutate an object and bind no name, so attribute and subscript
-- targets yield nothing.
local py_target_groups = {
  list = true,
  list_pattern = true,
  list_splat = true,
  list_splat_pattern = true,
  parenthesized_expression = true,
  pattern_list = true,
  tuple = true,
  tuple_pattern = true,
}

local function targets(node, emit, opts)
  local t = node:type()
  if t == 'identifier' then
    emit(node, opts)
  elseif py_target_groups[t] then
    for _, child in ipairs(named_children(node)) do
      targets(child, emit, opts)
    end
  end
end

local function left_targets(node, emit)
  targets(field(node, 'left'), emit)
end

local function outer_name(node, emit)
  emit(field(node, 'name'), { owner = 'outer' })
end

-- `import os.path` binds `os`; `import numpy as np` binds `np`. Marked as
-- imports: the binding is real, but the definition lives in another file.
local function imported_names(node, emit)
  for _, name in ipairs(node:field('name')) do
    if name:type() == 'aliased_import' then
      emit(field(name, 'alias'), { import = true })
    elseif name:type() == 'dotted_name' then
      emit(named_children(name)[1], { import = true })
    end
  end
end

local function parameters(node, emit)
  for _, param in ipairs(named_children(node)) do
    local t = param:type()
    if t == 'identifier' then
      emit(param)
    elseif t == 'default_parameter' or t == 'typed_default_parameter' then
      emit(field(param, 'name'))
    elseif t == 'typed_parameter' or t == 'list_splat_pattern' or t == 'dictionary_splat_pattern' then
      targets(named_children(param)[1], emit)
    end
  end
end

local function declared(kind)
  return function(node, emit)
    for _, name in ipairs(named_children(node)) do
      emit(name, { kind = kind })
    end
  end
end

local python = {
  scope_kinds = {
    module = 'module',
    function_definition = 'function',
    lambda = 'function',
    class_definition = 'class',
    list_comprehension = 'comprehension',
    set_comprehension = 'comprehension',
    dictionary_comprehension = 'comprehension',
    generator_expression = 'comprehension',
  },
  -- A walrus inside a comprehension binds in the enclosing function, so a
  -- comprehension must be searched even when the reference is outside it.
  leaky_kinds = { comprehension = true },
  extractors = {
    function_definition = outer_name,
    class_definition = outer_name,
    parameters = parameters,
    lambda_parameters = parameters,
    assignment = left_targets,
    augmented_assignment = left_targets,
    for_statement = left_targets,
    for_in_clause = left_targets,
    -- `with f() as x` and `except E as e`
    as_pattern_target = function(node, emit)
      targets(named_children(node)[1], emit)
    end,
    named_expression = function(node, emit)
      emit(field(node, 'name'), { owner = 'function' })
    end,
    import_statement = imported_names,
    import_from_statement = imported_names,
    global_statement = declared 'global',
    nonlocal_statement = declared 'nonlocal',
  },
  -- `obj.attr` names an attribute and `f(key=1)` a keyword parameter of
  -- another function; neither is a variable in scope.
  is_reference = function(node)
    if node:type() ~= 'identifier' then
      return false
    end
    local parent = node:parent()
    if not parent then
      return true
    end
    local t = parent:type()
    if t == 'attribute' then
      return not field(parent, 'attribute'):equal(node)
    end
    if t == 'keyword_argument' then
      return not field(parent, 'name'):equal(node)
    end
    return true
  end,
  -- Function scoped: one assignment anywhere in a function makes the name local
  -- to all of it, so order picks among bindings but never excludes one. A
  -- class body is not an enclosing scope for the functions inside it.
  rules = { ordered = false, unordered_kinds = {}, nested_skips_class = true },
}

M.c = cpp
M.cpp = cpp
M.python = python

return M
