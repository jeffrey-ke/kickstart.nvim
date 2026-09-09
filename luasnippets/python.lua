local ls = require 'luasnip'
local s = ls.snippet
local t = ls.text_node
local i = ls.insert_node
local f = ls.function_node
local fmt = require('luasnip.extras.fmt').fmt

local snippets = {
  s('p', fmt('print("{}")', { i(1) })),
  s('pf', fmt('print(f"{}")', { i(1) })),
  -- Python 3.8+ self-documenting f-string: `{expr=}` prints both the
  -- source text and repr(expr), so the tab stop only needs the expression.
  s('pe', fmt('print(f"{{{} = }}")', { i(1) })),
}

-- One level of indentation for a body line, read off the buffer rather than
-- hardcoded. init.lua sets expandtab/shiftwidth=4 globally (init.lua:254), but
-- guess-indent.nvim rewrites both per buffer on read, so a file that actually
-- uses tabs or two spaces would otherwise get four literal spaces. The
-- shiftwidth() *function* (not the option) already falls back to 'tabstop'
-- when 'shiftwidth' is 0.
local function one_indent()
  return vim.bo.expandtab and string.rep(' ', vim.fn.shiftwidth()) or '\t'
end

local autosnippets = {
  -- `def <name>(<args>):` with the body on its own line. The `;` prefix is
  -- what makes an autosnippet on a real word safe -- same reasoning as
  -- markdown.lua's `;dd`: a bare `def` trigger would fire mid-word in
  -- `default` or `defaultdict`, whereas `;def` cannot occur in Python source
  -- by accident. It also keeps the trigger out of blink.cmp's menu, where a
  -- snippet you never have to select does not need a row.
  --
  -- The newline is a text_node (`t { '):', '' }`) rather than a `\n` inside an
  -- fmt string so that the indent function_node lands *after* LuaSnip's own
  -- indent insertion: every line after the first is prefixed with the
  -- indentation the trigger sat at, so a def typed inside a class body comes
  -- out nested one level deeper, not flattened to the margin.
  s({ trig = ';def', desc = 'def name(args): with a body stop' }, {
    t 'def ',
    i(1, 'name'),
    t '(',
    i(2, 'args'),
    t { '):', '' },
    f(one_indent, {}),
    i(3, 'pass'),
  }),
}

return snippets, autosnippets
