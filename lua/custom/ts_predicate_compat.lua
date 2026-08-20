-- Restores the `all = false` predicate/directive shim that Neovim 0.12 removed.
--
-- nvim-treesitter's master branch registers every custom predicate and directive
-- with `{ force = true, all = false }` (query_predicates.lua:19). Through 0.11,
-- `all = false` asked core to hand the handler one TSNode per capture. 0.12
-- dropped that wrapper: `add_predicate`/`add_directive` accept only `force` now,
-- so `all` is silently ignored and legacy handlers receive what core always had
-- internally -- `table<integer, TSNode[]>`, a *list* per capture. The handlers
-- index it as a node, so the first matching query throws
--
--   vim/treesitter.lua:197: attempt to call method 'range' (a nil value)
--
-- from inside `get_node_text`, on every parse.
--
-- Markdown is the loud case. A fenced block carrying a language (```vim) matches
-- `(#set-lang-from-info-string! @_lang)` in the plugin's markdown/injections.scm,
-- which shadows the runtime query that would have read `@injection.language`
-- directly -- so the traceback repeats for every reparse of the buffer, from
-- render-markdown, the highlighter, and foldexpr alike. The bash, html_tags,
-- hcl, ruby, and php_only queries reach `#downcase!` / `#nth?` the same way.
--
-- The repair goes at the registration boundary rather than in the six handlers,
-- so it also covers whatever else on master (or any other stale plugin) still
-- passes `all = false`. Core's own shim mutated the match table in place; this
-- copies instead, leaving the captures table that `iter_matches` hands back to
-- its caller untouched.
--
-- Drop this when nvim-treesitter moves to the `main` branch -- see
-- ../../../.docs_claude/notes/nvim-kickstart-upstream-divergence.md, avenue (2).

local query = require 'vim.treesitter.query'

--- Present each capture to a legacy handler as a single node, as pre-0.12 did.
---@param handler function
---@return function
local function unwrap_captures(handler)
  return function(match, pattern, source, predicate, metadata)
    local single = {}
    for id, nodes in pairs(match) do
      -- Defensive on the value shape: a caller that already passes bare nodes
      -- (or a future core that goes back to them) is left alone.
      single[id] = type(nodes) == 'table' and nodes[#nodes] or nodes
    end
    return handler(single, pattern, source, predicate, metadata)
  end
end

---@param fn_name 'add_predicate'|'add_directive'
local function patch(fn_name)
  local original = query[fn_name]
  query[fn_name] = function(name, handler, opts)
    if type(opts) == 'table' and opts.all == false then
      handler = unwrap_captures(handler)
    end
    return original(name, handler, opts)
  end
end

return function()
  -- 0.10/0.11 still honor `all` themselves; wrapping there would unwrap twice.
  if vim.fn.has 'nvim-0.12' == 0 or vim.g.ts_predicate_compat_installed then
    return
  end
  vim.g.ts_predicate_compat_installed = true
  patch 'add_predicate'
  patch 'add_directive'
end
