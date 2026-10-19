-- Tests for lua/custom/index_grep.lua. Run from anywhere:
--
--   nvim --headless -u NONE -l ~/dotfiles/nvim/tests/index_grep_test.lua

local config = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2))))
vim.opt.rtp:prepend(config)
vim.opt.rtp:append(vim.fn.stdpath 'data' .. '/lazy/vim-fugitive')
vim.cmd 'runtime plugin/fugitive.vim'

local index_grep = require 'custom.index_grep'

local failures, count = 0, 0

local function check(label, got, want)
  count = count + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  want %s\n  got  %s'):format(label, vim.inspect(want), vim.inspect(got)))
  end
end

-- pathspecs (pure) --------------------------------------------------------------

local globs_of_type = { cpp = { '*.cc', '*.[ch]pp' }, lua = { '*.lua' } }

check('pathspecs: an rg type is its globs, at any depth', index_grep.pathspecs({ types = { 'cpp', 'lua' } }, globs_of_type), {
  ':(glob)**/*.cc',
  ':(glob)**/*.[ch]pp',
  ':(glob)**/*.lua',
})
check('pathspecs: a ! glob excludes', index_grep.pathspecs({ globs = { '*.h', '!*.md' } }, globs_of_type), {
  ':(glob)**/*.h',
  ':(exclude,glob)**/*.md',
})
check('pathspecs: braces expand, since git globs have none', index_grep.pathspecs({ globs = { '!*.{png,jpg}' } }, globs_of_type), {
  ':(exclude,glob)**/*.png',
  ':(exclude,glob)**/*.jpg',
})
check('pathspecs: a glob with a slash is anchored as written', index_grep.pathspecs({ globs = { 'src/*.cc' } }, globs_of_type), {
  ':(glob)src/*.cc',
})
check('pathspecs: no types or globs is the whole tree', index_grep.pathspecs({}, globs_of_type), {})
check('pathspecs: an unknown rg type fails loudly', pcall(index_grep.pathspecs, { types = { 'nope' } }, globs_of_type), false)

-- search ------------------------------------------------------------------------

local function git(dir, ...)
  local result = vim.system({ 'git', '-C', dir, ... }, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end

local function search(query)
  local done, got, err = false, nil, nil
  index_grep.search(query, function(f, e)
    done, got, err = true, f, e
  end)
  vim.wait(10000, function()
    return done
  end, 20)
  return got, err
end

local repo = vim.fn.tempname()
vim.fn.mkdir(repo .. '/lib', 'p')
vim.fn.writefile({ '#pragma once', 'struct Needle {', '};' }, repo .. '/lib/defs.h')
vim.fn.writefile({ 'struct Needle* on_disk;' }, repo .. '/use.cc')
vim.fn.writefile({ 'Needle in prose' }, repo .. '/notes.md')
git(repo, 'init', '-q')
git(repo, 'add', '.')
git(repo, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'init')
local query = { pattern = [[\bNeedle\b]], dir = repo, globs = { '*.h', '*.cc' } }

check('search: a full checkout is not searched', search(query), {})

git(repo, 'update-index', '--skip-worktree', 'lib/defs.h')
vim.fn.delete(repo .. '/lib/defs.h')
local found, err = search(query)
check('search: finishes without error', err, nil)
check('search: only the hit whose file is missing from disk', found and vim.tbl_map(function(l)
  return { l.filename, l.lnum, l.col, l.text }
end, found), {
  { vim.fn.FugitiveFind(':0:lib/defs.h', vim.fn.resolve(repo) .. '/.git'), 2, 8, 'struct Needle {' },
})

vim.cmd('edit ' .. vim.fn.fnameescape(found[1].filename))
check('search: the hit opens to the indexed blob', vim.api.nvim_buf_get_lines(0, 0, -1, false), { '#pragma once', 'struct Needle {', '};' })

check('search: outside a git repo is no hits, not an error', { search { pattern = 'x', dir = vim.fn.tempname():match '^(.*)/' } }, { {} })

vim.fn.delete(repo, 'rf')
print(('%d/%d passed'):format(count - failures, count))
if failures > 0 then
  os.exit(1)
end
