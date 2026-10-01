-- Tests for lua/custom/function_motion.lua. Run from anywhere:
--
--   nvim --headless -u NONE -l ~/dotfiles/nvim/tests/function_motion_test.lua

local config = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2))))
vim.opt.rtp:prepend(config)
vim.opt.rtp:append(vim.fn.stdpath 'data' .. '/lazy/nvim-treesitter')

local motion = require 'custom.function_motion'

local failures, count = 0, 0

local function check(label, got, want)
  count = count + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  want %s\n  got  %s'):format(label, vim.inspect(want), vim.inspect(got)))
  end
end

-- Pure ------------------------------------------------------------------------

do
  -- outer [0,0 .. 10,0) holds inner [2,4 .. 5,0); last [12,0 .. 14,0)
  local fns = {
    { start = { 0, 0 }, finish = { 10, 0 } },
    { start = { 2, 4 }, finish = { 5, 0 } },
    { start = { 12, 0 }, finish = { 14, 0 } },
  }
  check('pure: [f inside inner goes to inner start', motion.target(fns, { 3, 8 }, -1), { 2, 4 })
  check('pure: [f at inner start goes to enclosing outer', motion.target(fns, { 2, 4 }, -1), { 0, 0 })
  check('pure: [f past inner, still inside outer, goes to outer', motion.target(fns, { 7, 0 }, -1), { 0, 0 })
  check('pure: [f between functions goes to the nearest start above', motion.target(fns, { 11, 0 }, -1), { 2, 4 })
  check('pure: [f before everything has nowhere to go', motion.target(fns, { 0, 0 }, -1), nil)
  check('pure: ]f goes to the next start, nested or not', motion.target(fns, { 0, 3 }, 1), { 2, 4 })
  check('pure: ]f from inside inner skips to the next start', motion.target(fns, { 3, 0 }, 1), { 12, 0 })
  check('pure: ]f after the last has nowhere to go', motion.target(fns, { 13, 0 }, 1), nil)
end

-- End to end ------------------------------------------------------------------

--- Put the cursor on the first occurrence of `from`, press the motion, and
--- report the text of the line the cursor lands on.
local function case(label, filetype, src, from, keys, want_line)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  local lines = vim.split(vim.trim(src), '\n')
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].filetype = filetype
  motion.setup()
  for row, line in ipairs(lines) do
    local col = line:find(from, 1, true)
    if col then
      vim.api.nvim_win_set_cursor(0, { row, col - 1 })
      break
    end
  end
  vim.cmd('normal ' .. vim.api.nvim_replace_termcodes(keys, true, false, true))
  local row = vim.api.nvim_win_get_cursor(0)[1]
  check(label, vim.trim(lines[row]), want_line)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local cpp = [[
namespace ns {
void Foo::Bar(int x) {
  auto lam = [&](int y) {
    use(y);
  };
  if (x) {
    use(x);
  }
}
int Free() { return 1; }
}]]

case('c++: [f from inside a lambda skips to the method', 'cpp', cpp, 'use(y)', '[f', 'void Foo::Bar(int x) {')
case('c++: [f from a nested block in an out-of-line method', 'cpp', cpp, 'use(x)', '[f', 'void Foo::Bar(int x) {')
case('c++: ]f to the next function', 'cpp', cpp, 'use(x)', ']f', 'int Free() { return 1; }')
case('c++: 2[f walks back past the start', 'cpp', cpp, 'return 1', '2[f', 'void Foo::Bar(int x) {')

local py = [[
def outer():
    def inner():
        return 1
    return inner

class K:
    def method(self):
        return 2
]]

case('python: [f to the nested def', 'python', py, 'return 1', '[f', 'def inner():')
case('python: 2[f walks out to the enclosing def', 'python', py, 'return 1', '2[f', 'def outer():')
case('python: [f to a method', 'python', py, 'return 2', '[f', 'def method(self):')
case('python: ]f from outer lands on the method', 'python', py, 'return inner', ']f', 'def method(self):')

--- Like `case`, but `keys` is an operator + motion; report what it yanked.
local function yank_case(label, filetype, src, from, keys, want)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  local lines = vim.split(vim.trim(src), '\n')
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].filetype = filetype
  motion.setup()
  for row, line in ipairs(lines) do
    local col = line:find(from, 1, true)
    if col then
      vim.api.nvim_win_set_cursor(0, { row, col - 1 })
      break
    end
  end
  vim.fn.setreg('"', '')
  vim.cmd('normal ' .. keys)
  check(label, vim.fn.getreg '"', want)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

yank_case('python: y[f yanks back to the def, exclusive', 'python', py, 'return 1', 'y[f', 'def inner():\n        ')
yank_case('python: y]f yanks forward to the next def', 'python', py, 'return inner', 'y]f', 'return inner\n\nclass K:\n    ')
yank_case('python: y2[f takes a count', 'python', py, 'return 1', 'y2[f', 'def outer():\n    def inner():\n        ')

case('unsupported filetype is a no-op', 'text', 'just\nsome text', 'some', '[f', 'some text')

print(('%d/%d passed'):format(count - failures, count))
if failures > 0 then
  os.exit(1)
end
