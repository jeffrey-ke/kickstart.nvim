-- Snippets active in *every* buffer. LuaSnip's get_snippet_filetypes() appends
-- "all" to the list it resolves for any buffer (util/util.lua:303), so a file
-- named `all.lua` needs no ftdetect glue -- and blink.cmp's luasnip source
-- walks that same function (sources/snippets/luasnip.lua:75), so these reach
-- the completion menu rather than only `<c-k>`-style expansion.
--
-- The content is not written here. It comes from ~/.snippet_aliases, a
-- key=value file that .bashrc also sources -- one list serving both `$key` on
-- the command line and `key<CR>` in insert mode. Same split as the pp/pl path
-- registry in .functions.sh: mechanism in a shared file, data in a sourced one.
-- The data file is read at load time, so `<leader>rs` (:ReloadSnippets) re-runs
-- this file and picks up edits; blink drops its per-ft cache on the
-- LuasnipSnippetsAdded that reload_file fires, so the menu updates too.

local ls = require 'luasnip'
local s = ls.snippet
local t = ls.text_node
local i = ls.insert_node
local d = ls.dynamic_node
local sn = ls.snippet_node

-- Read through $HOME rather than the repo, so this file does not have to know
-- where dotfiles was cloned: run.sh symlinks ~/.snippet_aliases the same way it
-- does .bash_aliases, and nvim/ is a submodule that cannot assume ~/dotfiles.
local path = vim.fn.expand '~/.snippet_aliases'

local keys, expansion = {}, {}

local fd = io.open(path, 'r')
if fd then
  for line in fd:lines() do
    -- `export ` is optional; the parenthesis keeps gsub's second return value
    -- (the substitution count) out of the assignment.
    local body = (line:gsub('^%s*export%s+', ''))
    -- Requiring an identifier as the first non-blank character is also what
    -- discards comments and blank lines -- `#` cannot start a variable name.
    -- No `%s*` around the `=`, and `%S` to open the value, because bash accepts
    -- neither: `k = v` runs `k` as a command and `k= v` assigns empty and runs
    -- `v`. Being laxer here would let a line work in nvim while silently
    -- failing in the shell, which is the one bug a shared file can hide.
    local key, value = body:match '^%s*([%a_][%w_]*)=(%S.-)%s*$'
    if key then
      -- One layer of matching quotes, so a value with spaces stays valid bash.
      local single = value:match "^'(.*)'$"
      local double = value:match '^"(.*)"$'
      if single then
        -- bash has no escape *inside* '...': a literal quote is written by
        -- closing, escaping and reopening -- `'\''` -- which is precisely what
        -- `sa` and `pp` emit. Undoing that one idiom is what makes a value like
        -- don't read the same here as it does when the file is sourced.
        value = (single:gsub([==['\'']==], "'"))
      elseif double then
        -- Taken literally, whereas bash would expand `$var` and `\t` in here.
        -- `sa` only ever writes single quotes, so this is the hand-edited path.
        value = double
      else
        -- Only an unquoted value can carry a trailing comment, which is
        -- precisely when bash would strip it too.
        value = (value:gsub('%s+#.*$', ''))
      end
      if value ~= '' then
        -- Last assignment wins, again matching what sourcing the file does.
        if not expansion[key] then
          table.insert(keys, key)
        end
        expansion[key] = value
      end
    end
  end
  fd:close()
end

local snippets = {}
for _, key in ipairs(keys) do
  local value = expansion[key]
  -- text_node, not fmt: the value is literal text with no tab stops, and fmt
  -- would read any `{}` in it as a placeholder. `desc` is what the docs window
  -- shows, since blink labels the item with the trigger alone.
  table.insert(snippets, s({ trig = key, desc = value }, t(value)))
end

-- `;_N` -> N tab stops joined by underscores: `;_3` expands to
-- `foo_foo_foo`, the skeleton of a snake_case name whose parts you replace by
-- tabbing. The count lives in the trigger, so the node list cannot be written
-- out -- trigEngine 'pattern' captures it and a dynamicNode builds the nodes
-- at expansion time. The pattern needs no `$`: match_pattern appends one
-- (nodes/util/trig_engines.lua), so it only ever matches at the cursor.
local PART = 'foo'

local function underscore_joined(_, parent)
  -- The docstring pass expands with no real trigger, and `captures` answers
  -- every index with "$CAPTURE<n>" (nodes/snippet.lua:944), so tonumber fails
  -- there; `math.max` covers the same for a literal `;_0`.
  local n = math.max(tonumber(parent.snippet.captures[1]) or 1, 1)
  local nodes = {}
  for k = 1, n do
    if k > 1 then
      table.insert(nodes, t '_')
    end
    -- The placeholder is the second argument, not a text_node beside an empty
    -- insert_node: LuaSnip selects an insert_node's own default text when you
    -- land on it, so the first `foo` is already replaced by whatever you type,
    -- and an untouched stop keeps reading `foo`.
    table.insert(nodes, i(k, PART))
  end
  return sn(nil, nodes)
end

-- Autosnippets are the loader's *second* return value; `enable_autosnippets`
-- is already set where luasnip is configured (init.lua).
local autosnippets = {
  s({
    trig = ';_(%d+)',
    trigEngine = 'pattern',
    -- Read only by the fake expansion behind the docs window, which would
    -- otherwise have no capture to work with.
    docTrig = ';_3',
    desc = 'N ' .. PART .. ' stops joined by _  (;_3 -> foo_foo_foo)',
  }, d(1, underscore_joined, {})),
}

return snippets, autosnippets
