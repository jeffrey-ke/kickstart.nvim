-- Syntax tree -> the plain tables resolve.lua consumes. Pure over its inputs:
-- it reads a parsed tree and the source text and touches no editor state, so a
-- test can hand it a string parser in place of a buffer.
--
-- Only scopes enclosing the reference can own a binding it sees, so the walk
-- never descends into a scope that does not contain the reference. A scope
-- node's own extractor still runs before the cut, because some bindings belong
-- to the scope *outside* the node -- a nested Python `def` binds its name in
-- the enclosing function. Scope kinds listed in `spec.leaky_kinds` are always
-- descended, for bindings that escape from deeper inside (a walrus in a
-- comprehension). The cut keeps a lookup in a 2000-line file to the handful of
-- scopes actually on the path to the cursor.

local M = {}

local function contains(node, pos)
  local srow, scol, erow, ecol = node:range()
  local row, col = pos[1], pos[2]
  local after_start = row > srow or (row == srow and col >= scol)
  local before_end = row < erow or (row == erow and col < ecol)
  return after_start and before_end
end

--- spec   = { scope_kinds = {node_type = kind}, extractors = {node_type = fn(node, emit)},
---            leaky_kinds = set of scope kinds (optional) }
--- ref    = the identifier node under the cursor
--- source = bufnr or string, whatever the tree was parsed from
---
--- An extractor calls `emit(identifier_node, opts)` for each name its node
--- binds. `opts.owner` picks the owning scope: 'current' (default) is the
--- innermost scope open at the node -- the node's own, if it opens one --
--- 'outer' is that scope's parent, and 'function' is the innermost scope that
--- is not a comprehension (a Python walrus binds past its comprehension).
--- `opts.kind` defaults to 'bind'.
---
--- `members_for(function_node)`, optional, supplies bindings for a class body
--- that encloses a function without containing it in the tree -- a C++ method
--- defined outside its class. It returns { {name, pos, path} } or nil, and is
--- asked only about functions on the path to the reference. The members get a
--- class scope of their own between the function and its parent, so a local
--- still shadows a member and a member still shadows a global.
---
--- Returns scopes (keyed by id), defs, and the id of the reference's scope.
function M.collect(root, source, spec, ref, members_for)
  local scopes, defs, stack = {}, {}, {}
  local ref_pos = { ref:start() }
  local ref_id = ref:id()
  local ref_scope
  local leaky = spec.leaky_kinds or {}

  local function owner(mode)
    local top = stack[#stack]
    if mode == 'outer' then
      return scopes[top].parent or top
    end
    if mode == 'function' then
      for i = #stack, 1, -1 do
        if scopes[stack[i]].kind ~= 'comprehension' then
          return stack[i]
        end
      end
    end
    return top
  end

  local function emit(identifier, opts)
    opts = opts or {}
    table.insert(defs, {
      name = vim.treesitter.get_node_text(identifier, source),
      scope = owner(opts.owner),
      pos = { identifier:start() },
      kind = opts.kind or 'bind',
    })
  end

  local function open(kind)
    local id = #scopes + 1
    scopes[id] = { id = id, parent = stack[#stack], kind = kind }
    table.insert(stack, id)
    return id
  end

  local function walk(node)
    local kind = spec.scope_kinds[node:type()]
    local opened = 0
    if kind == 'function' and members_for and contains(node, ref_pos) then
      local members = members_for(node)
      if members then
        local class = open 'class'
        opened = opened + 1
        for _, member in ipairs(members) do
          table.insert(defs, { name = member.name, scope = class, pos = member.pos, kind = 'bind', path = member.path })
        end
      end
    end
    if kind then
      open(kind)
      opened = opened + 1
    end

    local extract = spec.extractors[node:type()]
    if extract then
      extract(node, emit)
    end
    if node:id() == ref_id then
      ref_scope = stack[#stack]
    end

    if not kind or leaky[kind] or contains(node, ref_pos) then
      for i = 0, node:named_child_count() - 1 do
        walk(node:named_child(i))
      end
    end

    for _ = 1, opened do
      table.remove(stack)
    end
  end

  walk(root)
  return scopes, defs, ref_scope
end

return M
