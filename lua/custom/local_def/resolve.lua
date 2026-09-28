-- Scope resolution for `:Def` on local names. Pure: plain tables in, plain
-- tables out, no nvim API -- so every rule can be tested from hand-written
-- tables without parsing anything.
--
-- A local name is always defined in the file being read, so finding one is not
-- a search problem but a scoping one: which enclosing scope owns the binding
-- the reference sees. A definition counts only if a scope enclosing the
-- reference owns it; a same-named binding in a sibling function is never a
-- candidate, however it is spelled. That ownership test is what a text grep
-- cannot express.
--
-- Shapes (positions are 0-based {row, col} of the identifier's first char):
--
--   scope = { id, parent, kind }     kind: module|block|function|class|comprehension
--   def   = { name, scope, pos, kind }   kind: bind|global|nonlocal
--   ref   = { name, scope, pos }
--   rules = {
--     ordered            = bool,  -- a binding must start at or before the reference
--     unordered_kinds    = set,   -- scope kinds exempt from `ordered`
--     nested_skips_class = bool,  -- code in a function cannot see an enclosing class body
--   }

local M = {}

local function at_or_before(a, b)
  return a[1] < b[1] or (a[1] == b[1] and a[2] <= b[2])
end

-- Row-major distance, only ever compared against other distances.
local function distance(a, b)
  local rows = math.abs(a[1] - b[1])
  return rows * 1e6 + (rows == 0 and math.abs(a[2] - b[2]) or 0)
end

--- Bindings preceding `pos`, nearest first, then the ones after it, nearest
--- first. When one scope binds a name several times (Python), the binding the
--- reader most likely means is the last one executed before the reference.
function M.nearest_first(defs, pos)
  local sorted = vim.deepcopy(defs)
  table.sort(sorted, function(a, b)
    local a_before, b_before = at_or_before(a.pos, pos), at_or_before(b.pos, pos)
    if a_before ~= b_before then
      return a_before
    end
    return distance(a.pos, pos) < distance(b.pos, pos)
  end)
  return sorted
end

local function root_of(scopes)
  for id, scope in pairs(scopes) do
    if scope.parent == nil then
      return id
    end
  end
end

local function owned_by(defs, name)
  local by_scope = {}
  for _, def in ipairs(defs) do
    if def.name == name then
      by_scope[def.scope] = by_scope[def.scope] or {}
      table.insert(by_scope[def.scope], def)
    end
  end
  return by_scope
end

local function bindings(defs)
  return vim.tbl_filter(function(def)
    return def.kind == 'bind'
  end, defs)
end

local function redirect(defs)
  for _, def in ipairs(defs) do
    if def.kind == 'global' or def.kind == 'nonlocal' then
      return def.kind
    end
  end
end

--- The definitions `ref` resolves to, nearest first; {} when no enclosing
--- scope binds the name (it is a global, a member, or lives in another file).
function M.resolve(scopes, defs, ref, rules)
  local by_scope = owned_by(defs, ref.name)
  local scope_id = ref.scope
  local left_function = false

  while scope_id do
    local scope = scopes[scope_id]
    local visible = not (left_function and scope.kind == 'class' and rules.nested_skips_class)
    local here = by_scope[scope_id] or {}

    if visible then
      local kind = redirect(here)
      if kind == 'global' then
        -- Python: assignments here now bind the module name, so both are
        -- definitions of the same variable.
        local root = root_of(scopes)
        local merged = vim.list_extend(bindings(by_scope[root] or {}), root == scope_id and {} or bindings(here))
        return M.nearest_first(merged, ref.pos)
      end
      -- `nonlocal`: the bindings here rebind an outer variable; keep walking
      -- to the scope that introduced it.
      if kind ~= 'nonlocal' then
        local exempt = rules.unordered_kinds[scope.kind]
        local seen = vim.tbl_filter(function(def)
          return not rules.ordered or exempt or at_or_before(def.pos, ref.pos)
        end, bindings(here))
        if #seen > 0 then
          -- An exempt scope (a C++ class body) has no meaningful distance: its
          -- members may come from other files, already ordered by whoever
          -- found them -- a method's definition ahead of its declaration.
          return exempt and seen or M.nearest_first(seen, ref.pos)
        end
      end
    end

    if scope.kind == 'function' or scope.kind == 'comprehension' then
      left_function = true
    end
    scope_id = scope.parent
  end
  return {}
end

return M
