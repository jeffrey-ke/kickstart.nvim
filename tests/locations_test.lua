-- Tests for lua/custom/locations.lua and lua/custom/rg.lua. Run from anywhere:
--
--   nvim --headless -u NONE -l ~/dotfiles/nvim/tests/locations_test.lua

local config = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2))))
vim.opt.rtp:prepend(config)

local locations = require 'custom.locations'
local rg = require 'custom.rg'

local failures, count = 0, 0

local function check(label, got, want)
  count = count + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  want %s\n  got  %s'):format(label, vim.inspect(want), vim.inspect(got)))
  end
end

-- from_vimgrep (pure) ---------------------------------------------------------

check('vimgrep: path, line, column, and text that itself has colons', locations.from_vimgrep {
  './a/b.cc:12:3:  x = y ? a : b;',
  'c.py:1:1:def f():',
}, {
  { filename = './a/b.cc', lnum = 12, col = 3, text = '  x = y ? a : b;' },
  { filename = 'c.py', lnum = 1, col = 1, text = 'def f():' },
})
check('vimgrep: lines that are not matches are dropped', locations.from_vimgrep { 'rg: warning', '' }, {})

-- load --------------------------------------------------------------------------

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local file_a, file_b = dir .. '/a.txt', dir .. '/b.txt'
vim.fn.writefile({ 'one', 'two needle', 'three' }, file_a)
vim.fn.writefile({ 'needle four' }, file_b)
local found = {
  { filename = file_a, lnum = 2, col = 5, text = 'first' },
  { filename = file_b, lnum = 1, col = 1, text = 'second' },
}

local sentinel = { { filename = 'SENTINEL', lnum = 1, col = 1, text = 'loaded by the pointer skill' } }
local function reset()
  vim.cmd 'silent! only'
  vim.cmd 'enew!'
  vim.fn.setqflist({}, ' ', { title = 'pointers', items = sentinel })
  vim.fn.setloclist(0, {}, 'f')
end

local function here()
  return { vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':t'), vim.api.nvim_win_get_cursor(0)[1] }
end

reset()
local code_win = vim.api.nvim_get_current_win()
check('load: returns true for a non-empty list', locations.load(found, { title = 'hits' }), true)
check('load: fills the location list', vim.fn.getloclist(code_win, { title = 1, size = 0 }), { title = 'hits', size = 2 })
check('load: leaves the quickfix list alone', vim.fn.getqflist({ title = 1 }).title, 'pointers')
check('load: jumps to the first entry', here(), { 'a.txt', 2 })

reset()
locations.load(found, { title = 'hits', target = 'quickfix' })
check("load: target 'quickfix' fills the quickfix list", vim.fn.getqflist({ title = 1, size = 0 }), { title = 'hits', size = 2 })
check("load: target 'quickfix' leaves the location list alone", vim.fn.getloclist(0, { size = 0 }).size, 0)

reset()
check('load: an empty list returns false', locations.load({}, { title = 'nothing' }), false)
check('load: an empty list touches neither list', { vim.fn.getqflist({ title = 1 }).title, vim.fn.getloclist(0, { size = 0 }).size }, { 'pointers', 0 })

reset()
code_win = vim.api.nvim_get_current_win()
locations.load(found, { title = 'hits', open = true })
local list_open = vim.iter(vim.api.nvim_tabpage_list_wins(0)):any(function(w)
  return vim.fn.getwininfo(w)[1].loclist == 1
end)
check('load: open shows the location list window', list_open, true)
check('load: open keeps focus on the code window', vim.api.nvim_get_current_win() == code_win, true)

reset()
local split = vim.api.nvim_get_current_win()
vim.cmd 'vsplit'
local other = vim.api.nvim_get_current_win()
locations.load(found, { title = 'for the first window', win = split, jump = false })
check('load: win targets that window', vim.fn.getloclist(split, { title = 1 }).title, 'for the first window')
check('load: other windows keep their lists', vim.fn.getloclist(other, { size = 0 }).size, 0)

-- rg.search ---------------------------------------------------------------------

local done, got, err = false, nil, nil
rg.search({ 'rg', '--vimgrep', '--sort', 'path', 'needle', dir }, function(f, e)
  done, got, err = true, f, e
end)
vim.wait(5000, function()
  return done
end, 20)
check('rg: search finishes without error', { done, err }, { true, nil })
check('rg: matches as locations', got and vim.tbl_map(function(l)
  return { vim.fs.basename(l.filename), l.lnum, l.col, l.text }
end, got), { { 'a.txt', 2, 5, 'two needle' }, { 'b.txt', 1, 1, 'needle four' } })

done = false
rg.search({ 'rg', '--vimgrep', 'absent_word_zz', dir }, function(f, e)
  done, got, err = true, f, e
end)
vim.wait(5000, function()
  return done
end, 20)
check('rg: no matches is an empty list, not an error', { got, err }, { {}, nil })

vim.fn.delete(dir, 'rf')
print(('%d/%d passed'):format(count - failures, count))
if failures > 0 then
  os.exit(1)
end
