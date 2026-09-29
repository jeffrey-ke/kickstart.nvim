-- Headless check of lua/custom/anchor.lua:
--   nvim --headless -u NONE -l tests/anchor_spec.lua
-- from the config root. Exits non-zero on the first failure.
package.path = 'lua/?.lua;' .. package.path
local anchor = require 'custom.anchor'

local function eq(got, want, label)
  if got ~= want then
    io.stderr:write(('FAIL %s: got %s, want %s\n'):format(label, vim.inspect(got), vim.inspect(want)))
    os.exit(1)
  end
  io.write('ok   ' .. label .. '\n')
end

local before = {
  'def a():', -- 1
  '    x = 1', -- 2
  '    return nil', -- 3
  '', -- 4
  'def b():', -- 5
  '    y = 2', -- 6
  '    return nil', -- 7
  '', -- 8
  'class C:', -- 9
  '    pass', -- 10
  '}', -- 11
}

-- Ten lines prepended, `b` moved below `C`, `a` re-indented, the `pass` line gone.
local after = {}
for i = 1, 10 do
  after[#after + 1] = '# header ' .. i
end
vim.list_extend(after, {
  'def a():', -- 11
  '  x = 1', -- 12
  '  return nil', -- 13
  '', -- 14
  'class C:', -- 15
  '}', -- 16
  '', -- 17
  'def b():', -- 18
  '    y = 2', -- 19
  '    return nil', -- 20
})

local a3 = anchor.capture(before, 3)
eq(a3.text, 'returnnil', 'capture normalizes whitespace')
eq(a3.above[1], 'x=1', 'context is the nearest non-blank line')
eq(a3.above[2], 'defa():', 'context keeps two lines per side')
eq(anchor.capture(before, 4).below[1], 'defb():', 'context skips blank lines')

eq(anchor.resolve(after, anchor.capture(before, 2), 2), 12, 're-indented line still matches')
eq(anchor.resolve(after, anchor.capture(before, 3), 3), 13, 'duplicate line: context picks a()')
eq(anchor.resolve(after, anchor.capture(before, 7), 7), 20, 'duplicate line: context picks moved b()')
eq(anchor.resolve(after, anchor.capture(before, 5), 5), 18, 'moved block beats distance')
eq(anchor.resolve(after, anchor.capture(before, 11), 11), 16, 'trivial `}` found through its neighbour')
eq(anchor.resolve(after, anchor.capture(before, 10), 10), nil, 'deleted line is an orphan')
eq(anchor.resolve(after, anchor.capture(before, 4), 4), 14, 'blank line found through its neighbours')

-- Trivial text with no agreeing neighbour must not match some other `}`.
eq(anchor.resolve({ 'x', '}', 'y', '}' }, { text = '}', above = { 'zzz' }, below = { 'qqq' } }, 2), nil, 'trivial text needs context')

local s, e, exact = anchor.resolve_span(after, anchor.capture(before, 5), anchor.capture(before, 7), 5, 7)
eq(s, 18, 'span start')
eq(e, 20, 'span end')
eq(exact, true, 'span exact')

s, e, exact = anchor.resolve_span(after, anchor.capture(before, 9), anchor.capture(before, 10), 9, 10)
eq(s, 15, 'span with lost end keeps its start')
eq(e, 16, 'span with lost end keeps its length')
eq(exact, false, 'span with lost end is inexact')

-- Lower bound: the end is never found above the start.
eq(anchor.resolve(after, anchor.capture(before, 3), 3, 14), 20, 'lower bound skips earlier matches')

io.write 'all anchor checks passed\n'
