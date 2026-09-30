-- Headless check of the position mapping in lua/custom/versions.lua:
--   nvim --headless -u NONE -l tests/versions_spec.lua
-- from the config root. Exits non-zero on the first failure.
package.path = 'lua/?.lua;' .. package.path
local versions = require 'custom.versions'

local function eq(got, want, label)
  if not vim.deep_equal(got, want) then
    io.stderr:write(('FAIL %s: got %s, want %s\n'):format(label, vim.inspect(got), vim.inspect(want)))
    os.exit(1)
  end
  io.write('ok   ' .. label .. '\n')
end

local old = { 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h' }

local m = versions.mapper(old, old)
eq(m.identity, true, 'same text: identity')
eq({ m.line(3) }, { 3, 'exact' }, 'same text: line maps to itself')

m = versions.mapper(old, { 'X', 'Y', 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h' })
eq({ m.line(1) }, { 3, 'exact' }, 'insert at top shifts the first line')
eq({ m.line(8) }, { 10, 'exact' }, 'insert at top shifts the last line')

m = versions.mapper(old, { 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j' })
eq({ m.line(8) }, { 8, 'exact' }, 'append after the end leaves the last line alone')

m = versions.mapper(old, { 'a', 'b', 'e', 'f', 'g', 'h' })
eq({ m.line(2) }, { 2, 'exact' }, 'line before a deletion')
eq({ m.line(5) }, { 3, 'exact' }, 'line after a deletion shifts up')
eq({ m.line(3) }, { 3, 'deleted' }, 'deleted line: a start parks on the line after the gap')
eq({ m.line(4, true) }, { 2, 'deleted' }, 'deleted line: an end parks on the line before the gap')

m = versions.mapper(old, { 'c', 'd', 'e', 'f', 'g', 'h' })
eq({ m.line(1) }, { 1, 'deleted' }, 'deletion at the top parks a start on line 1')
eq({ m.line(2, true) }, { 1, 'deleted' }, 'deletion at the top parks an end on line 1, not 0')

m = versions.mapper(old, { 'a', 'b', 'c' })
eq({ m.line(7) }, { 3, 'deleted' }, 'deletion at the end parks within the file')

m = versions.mapper(old, { 'a', 'b', 'C', 'd', 'e', 'f', 'g', 'h' })
eq({ m.line(3) }, { 3, 'modified' }, 'a rewritten line maps onto its rewrite')
eq({ m.line(4) }, { 4, 'exact' }, 'the line after a rewrite is exact')

-- xdiff + linematch read "c -> c1 c2 c3" as two lines inserted before a
-- rewrite of c into c3, so the mark follows c onto c3; the diff's reading is
-- the contract, not a guess at intent.
m = versions.mapper(old, { 'a', 'b', 'c1', 'c2', 'c3', 'd', 'e', 'f', 'g', 'h' })
eq(m.hunks, { { 2, 0, 3, 2 }, { 3, 1, 5, 1 } }, 'one line became three: insert + rewrite')
eq({ m.line(3) }, { 5, 'modified' }, 'one line became three: follows its rewrite')
eq({ m.line(4) }, { 6, 'exact' }, 'and the next line shifted by two')

-- Likewise "c d -> C" is read as c deleted and d rewritten into C.
m = versions.mapper(old, { 'a', 'b', 'C', 'e', 'f', 'g', 'h' })
eq({ m.line(3) }, { 3, 'deleted' }, 'two lines became one: the first is gone')
eq({ m.line(4, true) }, { 3, 'modified' }, 'two lines became one: the second follows its rewrite')

-- An unrelated 4 -> 7 block: linematch pairs four lines one-to-one and
-- calls the rest insertions, so a range over the old block lands on the
-- paired lines. Proportional mapping only sees hunks linematch leaves N -> M.
m = versions.mapper(
  { 'head', 'local alpha = 1', 'local beta = 2', 'local gamma = 3', 'local delta = 4', 'tail' },
  { 'head', 'return {', '  one = true,', '  two = true,', '  three = true,', '  four = true,', '  five = true,', '}', 'tail' }
)
eq(m.hunks, { { 1, 0, 2, 2 }, { 2, 4, 4, 4 }, { 5, 0, 8, 1 } }, 'unrelated block: insert, 4 -> 4, insert')
eq({ m.line(2) }, { 4, 'modified' }, 'block start on its paired line')
eq({ m.line(5, true) }, { 7, 'modified' }, 'block end on its paired line')
eq({ m.line(6) }, { 9, 'exact' }, 'line after the block shifted by three')

-- Whitespace: the diff ignores it, the column mapping does not.
m = versions.mapper({ 'x = 1', 'y' }, { '    x = 1', 'y' })
eq({ m.line(1) }, { 1, 'exact' }, 're-indented line is exact for the diff')
eq({ m.pos(1, 0, false) }, { 1, 4, 'exact' }, 'start column moves past the new indent')
eq({ m.pos(1, 5, true) }, { 1, 9, 'exact' }, 'end column moves with it')

-- Columns through a rewrite: prefix/suffix.
m = versions.mapper({ 'vim.op.number = true' }, { 'vim.o.number = true' })
eq({ m.pos(1, 0, false) }, { 1, 0, 'modified' }, 'start before the change stays')
eq({ m.pos(1, 20, true) }, { 1, 19, 'modified' }, 'end after the change shifts with the length')
eq({ m.pos(1, 5, false) }, { 1, 5, 'modified' }, 'start inside the change moves to its front')
eq({ m.pos(1, 6, true) }, { 1, 5, 'modified' }, 'end inside the change moves to its back')

m = versions.mapper({ 'abc' }, { 'XXabc' })
eq({ m.pos(1, 0, false) }, { 1, 2, 'modified' }, 'insert at the front: a start clings to the text after it')
m = versions.mapper({ 'abc' }, { 'abcXX' })
eq({ m.pos(1, 3, true) }, { 1, 3, 'modified' }, 'insert at the back: an end clings to the text before it')

-- Deleted position answers the column too.
m = versions.mapper(old, { 'a', 'b', 'e', 'f', 'g', 'h' })
eq({ m.pos(3, 0, false) }, { 3, 0, 'deleted' }, 'deleted start: column 0 of the parking line')
eq({ m.pos(4, 1, true) }, { 2, 1, 'deleted' }, 'deleted end: end of the parking line')

io.write 'all versions checks passed\n'
