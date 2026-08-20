local ls = require 'luasnip'
local s = ls.snippet
local i = ls.insert_node
local fmt = require('luasnip.extras.fmt').fmt

local snippets = {
  s('p', fmt('print("{}")', { i(1) })),
  s('pf', fmt('print(f"{}")', { i(1) })),
  -- Python 3.8+ self-documenting f-string: `{expr=}` prints both the
  -- source text and repr(expr), so the tab stop only needs the expression.
  s('pe', fmt('print(f"{{{} = }}")', { i(1) })),
}

return snippets
