-- Tests for lua/custom/notebook_cells.lua. Run from anywhere (stdpath('data') must hold
-- nvim-treesitter's python parser):
--
--   nvim --headless -u NONE -l ~/dotfiles/nvim/tests/notebook_cells_test.lua

local config = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2))))
vim.opt.rtp:prepend(config)
vim.opt.rtp:append(vim.fn.stdpath 'data' .. '/lazy/nvim-treesitter')

local cells = require 'custom.notebook_cells'

local failures, count = 0, 0

local function check(label, got, want)
  count = count + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  want %s\n  got  %s'):format(label, vim.inspect(want), vim.inspect(got)))
  end
end

local fixture = {
  '# ---', -- 1
  '# jupyter:',
  '# ---',
  '',
  '# %% [markdown]', -- 5
  '# # Title',
  '#',
  '# Some `code` here',
  '',
  '# %%', -- 10
  'def f():',
  '    x = 1',
  '    return x',
  '',
  '# %%', -- 15
  'y = 2',
  '',
  '# %% [markdown]', -- 18
  '# ## Section',
}

-- Pure ------------------------------------------------------------------------

check('parse: cells end at their last non-blank line', cells.parse(fixture), {
  { kind = 'header', first = 1, last = 3 },
  { kind = 'markdown', first = 5, last = 8 },
  { kind = 'code', first = 10, last = 13, number = 1 },
  { kind = 'code', first = 15, last = 16, number = 2 },
  { kind = 'markdown', first = 18, last = 19 },
})
check('parse: no header when line 1 is a marker', cells.parse { '# %%', 'x' }, {
  { kind = 'code', first = 1, last = 2, number = 1 },
})
check('parse: an empty cell keeps its marker', cells.parse { '# %%', '', '# %%' }, {
  { kind = 'code', first = 1, last = 1, number = 1 },
  { kind = 'code', first = 3, last = 3, number = 2 },
})

check('ref: a code line, cells counted from 0 without the header', cells.claude_ref(fixture, 12, 12), 'cell-1 line 2: `x = 1`')
check('ref: a markdown line without its `# `', cells.claude_ref(fixture, 6, 6), 'cell-0 line 1: `# Title`')
check('ref: an empty markdown line has no text', cells.claude_ref(fixture, 7, 7), 'cell-0 line 2')
check('ref: the marker is the first line', cells.claude_ref(fixture, 10, 10), 'cell-1 line 1: `def f():`')
check('ref: the blank line after a cell is its last', cells.claude_ref(fixture, 14, 14), 'cell-1 line 3: `return x`')
check('ref: lines in one cell', cells.claude_ref(fixture, 11, 13), 'cell-1 lines 1-3')
check('ref: lines across cells', cells.claude_ref(fixture, 12, 16), 'cell-1 line 2 to cell-2 line 1')
check('ref: none in the header', cells.claude_ref(fixture, 2, 2), nil)
check('ref: long text is cut', cells.claude_ref({ '# %%', ('x'):rep(70) }, 2, 2), 'cell-0 line 1: `' .. ('x'):rep(60) .. '…`')

check('shift: number', cells.shift_level(2), '3')
check('shift: string number', cells.shift_level '0', '1')
check('shift: fold start', cells.shift_level '>1', '>2')
check('shift: fold end', cells.shift_level '<2', '<3')
check('shift: same as previous', cells.shift_level '=', '=')

-- Buffer ----------------------------------------------------------------------

local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. '.ipynb')
vim.api.nvim_buf_set_lines(buf, 0, -1, false, fixture)
vim.bo[buf].filetype = 'python'
vim.wo.foldmethod = 'expr'
vim.wo.foldexpr = "v:lua.require'custom.notebook_cells'.foldexpr()"

local levels = {}
for lnum = 1, #fixture do
  levels[lnum] = vim.fn.foldlevel(lnum)
end
-- the blank separator lines (4, 9, 14, 17) sit outside every fold
check('foldlevel per line', levels, { 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 2, 2, 2, 0, 1, 1, 0, 0, 0 })

--- The top edges, each as {row, text up to the run of '─' that fills it to '╮'}.
local function top_edges()
  local found = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces()['notebook-cells'], 0, -1, { details = true })) do
    local details = m[4]
    if details.virt_text_pos == 'overlay' then
      local text = details.virt_text[1][1]
      check('top edge ends in ╮', vim.endswith(text, '╮'), true)
      text = text:sub(1, -#'╮' - 1)
      -- '─' is three bytes, so a `─+` pattern would only repeat its last byte
      while vim.endswith(text, '─') do
        text = text:sub(1, -#'─' - 1)
      end
      table.insert(found, { m[2] + 1, text })
    end
  end
  return found
end

cells.draw(buf, nil)
check('top edges on every marker, labelled on code cells', top_edges(), {
  { 5, '╭' },
  { 10, '╭── [1] python · 3 lines ' },
  { 15, '╭── [2] python · 1 line ' },
  { 18, '╭' },
})
cells.draw(buf, 10)
check('no top edge on the cursor row', #top_edges(), 3)

local function rows_with(key)
  local rows = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces()['notebook-cells'], 0, -1, { details = true })) do
    if m[4][key] then
      rows[m[2] + 1] = m[4][key]
    end
  end
  return rows
end

cells.draw(buf, nil)
local function bottom_edges()
  local found = {}
  for row, virt_lines in pairs(rows_with 'virt_lines') do
    found[row] = #virt_lines
  end
  return found
end
-- above the separators 9, 14 and 17; the last cell has none, so its edge hangs below 19
check('bottom edges: one line each, on the separator when there is one', bottom_edges(), { [9] = 1, [14] = 1, [17] = 1, [19] = 1 })

vim.api.nvim_buf_set_lines(buf, 16, 17, false, {}) -- drop the blank line between cells 2 and 3
cells.draw(buf, nil)
check('bottom edges: a cell flush against the next one gets a margin line too', bottom_edges(), { [9] = 1, [14] = 1, [16] = 2, [18] = 1 })

-- Window options -------------------------------------------------------------

cells.setup()
local notebook = vim.fn.tempname() .. '.ipynb'
vim.fn.writefile(fixture, notebook)
vim.cmd.edit(notebook)
vim.bo.filetype = 'python'
check('notebook window gets the notebook foldexpr', vim.wo.foldexpr, "v:lua.require'custom.notebook_cells'.foldexpr()")
vim.cmd.enew()
check('the next buffer in that window does not', vim.wo.foldexpr, vim.go.foldexpr)
check('nor its conceallevel', vim.wo.conceallevel, vim.go.conceallevel)

print(('%d/%d passed'):format(count - failures, count))
if failures > 0 then
  os.exit(1)
end
