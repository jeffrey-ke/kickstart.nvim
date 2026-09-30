-- Tests for lua/custom/jedi_def: the real uvx + jedi round trip on a scratch
-- package. Run from anywhere:
--
--   nvim --headless -u NONE -l ~/dotfiles/nvim/tests/jedi_def_test.lua
--
-- Skips, passing, when uvx is not on PATH. The first run may download jedi.

local config = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2))))
vim.opt.rtp:prepend(config)

if vim.fn.executable 'uvx' == 0 then
  print 'SKIP: no uvx on PATH'
  return
end

local jedi_def = require 'custom.jedi_def'

local failures, count = 0, 0

local function check(label, got, want)
  count = count + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  want %s\n  got  %s'):format(label, vim.inspect(want), vim.inspect(got)))
  end
end

-- A package jedi finds by the project root, as in the monorepo: `.git` marks it.
local root = vim.fn.tempname()
local function write(rel, text)
  local path = root .. '/' .. rel
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(vim.split(vim.trim(text), '\n'), path)
  return path
end
vim.fn.mkdir(root .. '/.git', 'p')
write('pkg/__init__.py', '')
write('pkg/lib.py', [[
class Foo:
    def bar(self):
        return 1

def helper(x):
    return x
]])
local main = write('main.py', [[
from pkg.lib import Foo, helper
from nowhere.mod import ghost

obj = Foo()
obj.bar()
helper(1)
ghost()
]])

local bufnr = vim.fn.bufadd(main)
vim.fn.bufload(bufnr)
vim.bo[bufnr].filetype = 'python'

--- `found` as { basename, lnum, col } for the definition of the Nth whole-word
--- `name` in the buffer.
local function lookup(name, n)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local seen = 0
  for row, line in ipairs(lines) do
    local from = 1
    while true do
      local col = line:find('%f[%w_]' .. vim.pesc(name) .. '%f[^%w_]', from)
      if not col then
        break
      end
      seen = seen + 1
      if seen == n then
        local result
        jedi_def.find(bufnr, row - 1, col - 1, function(found)
          result = found
        end)
        vim.wait(10000, function()
          return result ~= nil
        end)
        return vim.tbl_map(function(l)
          return { vim.fs.basename(l.filename), l.lnum, l.col }
        end, result or {})
      end
      from = col + 1
    end
  end
  error(('occurrence %d of %q not found'):format(n, name))
end

check('available for a named python buffer', jedi_def.available(bufnr), true)
check('follows a from-import to the function', lookup('helper', 2), { { 'lib.py', 5, 5 } })
check('the imported name itself resolves too', lookup('helper', 1), { { 'lib.py', 5, 5 } })
check('follows an attribute to its method', lookup('bar', 1), { { 'lib.py', 2, 9 } })
check('an import it cannot follow is no answer', lookup('ghost', 2), {})

-- The buffer, not the file on disk: an unsaved local definition wins.
vim.api.nvim_buf_set_lines(bufnr, 5, 6, false, { 'def helper(y): return y', 'helper(1)' })
check('reads the unsaved buffer', lookup('helper', 3), { { 'main.py', 6, 5 } })

vim.fn.delete(root, 'rf')
print(('%d/%d passed'):format(count - failures, count))
if failures > 0 then
  os.exit(1)
end
