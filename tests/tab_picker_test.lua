-- Tests for lua/custom/tab_picker's labels. Run from anywhere:
--
--   nvim --headless -u NONE -l ~/dotfiles/nvim/tests/tab_picker_test.lua
--
-- Builds a throwaway repo with a modified, an added and a deleted file, opens
-- them through fugitive's real `:Git difftool -y`, and checks the label of
-- every tab -- so the fugitive URL shapes and the missing-side signal
-- (`b:fugitive_type` unset) are pinned against the installed fugitive.

local config = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2))))
vim.opt.rtp:prepend(config)
vim.opt.rtp:append(vim.fn.stdpath 'data' .. '/lazy/vim-fugitive')
vim.cmd 'runtime plugin/fugitive.vim'

local tab_picker = require 'custom.tab_picker'

local failures, count = 0, 0

local function check(label, got, want)
  count = count + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  want %s\n  got  %s'):format(label, vim.inspect(want), vim.inspect(got)))
  end
end

local repo = vim.fn.tempname()
vim.fn.mkdir(repo .. '/sub', 'p')
local function sh(cmd)
  local out = vim.fn.system { 'sh', '-c', cmd }
  assert(vim.v.shell_error == 0, cmd .. '\n' .. out)
  return vim.trim(out)
end
sh(([[
  cd %s && git init -q && git config user.email t@t && git config user.name t &&
  printf 'a\nb\n' > sub/mod.py && printf 'gone\n' > del.py && git add . && git commit -qm 1 &&
  printf 'a\nB\n' > sub/mod.py && printf 'new\n' > add.py && git rm -q del.py && git add . && git commit -qm 2 &&
  printf 'a\nBB\n' > sub/mod.py
]]):format(repo))
local old = sh(('git -C %s rev-parse --short=7 HEAD~'):format(repo))
local new = sh(('git -C %s rev-parse --short=7 HEAD'):format(repo))
vim.cmd.cd(repo)

local function reset()
  vim.cmd 'silent! tabonly | silent! only | enew'
end

-- Commit to commit: one tab per file, revisions aligned in a column. A plain
-- tab keeps its plain label, and difftool leaves you on its first tab.
vim.cmd('edit ' .. repo .. '/add.py')
vim.cmd 'silent Git difftool -y HEAD~ HEAD'
local revs = old .. '..' .. new
check('commit..commit', tab_picker._labels(), {
  ' 1: add.py',
  '%2: A add.py      ' .. revs,
  ' 3: D del.py      ' .. revs,
  ' 4: M sub/mod.py  ' .. revs,
})

-- Commit to working tree: the right side is the plain file.
reset()
vim.cmd 'silent Git difftool -y HEAD -- sub/mod.py'
check('commit..worktree', tab_picker._labels()[2], '%2: M sub/mod.py  ' .. new .. '..worktree')

-- A split of two different files is not a diff; fugitive buffers in it read
-- as rev:path rather than as URLs.
reset()
vim.cmd('silent Gedit HEAD:sub/mod.py | vsplit ' .. repo .. '/add.py')
check('mixed split', tab_picker._labels(), { '%1: add.py, ' .. new .. ':sub/mod.py' })

vim.fn.delete(repo, 'rf')
print(('%d/%d passed'):format(count - failures, count))
os.exit(failures == 0 and 0 or 1)
