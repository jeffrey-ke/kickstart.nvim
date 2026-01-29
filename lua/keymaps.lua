-- [[ Basic Keymaps ]]
--  See `:help vim.keymap.set()`

-- Clear highlights on search when pressing <Esc> in normal mode
--  See `:help hlsearch`
vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')

-- Diagnostic keymaps
vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Open diagnostic [Q]uickfix list' })

-- Diagnostics disabled by default - use :make or :Make to check errors
-- Toggle diagnostics on/off
local diagnostics_active = false
vim.diagnostic.enable(false)
local function toggle_diagnostics()
  diagnostics_active = not diagnostics_active
  vim.diagnostic.enable(diagnostics_active)
  if diagnostics_active then
    vim.notify('Diagnostics enabled', vim.log.levels.INFO)
  else
    vim.notify('Diagnostics disabled', vim.log.levels.INFO)
  end
end
vim.keymap.set('n', '<leader>td', toggle_diagnostics, { desc = '[T]oggle [D]iagnostics' })

-- Swap ^ and $ for easier end-of-line navigation
vim.keymap.set({ 'n', 'o', 'v' }, '^', '$')
vim.keymap.set({ 'n', 'o', 'v' }, '$', '^')

-- Select pasted text
vim.keymap.set('n', '<leader>p', '`[v`]', { desc = 'Select [P]asted text' })

-- Insert TODO comment on new line
vim.keymap.set('n', '<leader>to', 'o#TODO: <Esc>', { desc = 'Add [TO]DO comment' })

-- Exit terminal mode in the builtin terminal with a shortcut that is a bit easier
-- for people to discover. Otherwise, you normally need to press <C-\><C-n>, which
-- is not what someone will guess without a bit more experience.
--
-- NOTE: Using 'jk' instead of <Esc><Esc> to avoid conflicts with Claude Code
-- which uses <Esc><Esc> for its rewind menu. You can still use <C-\><C-n> directly.
vim.keymap.set('t', 'jk', '<C-\\><C-n>', { desc = 'Exit terminal mode' })

-- TIP: Disable arrow keys in normal mode
-- vim.keymap.set('n', '<left>', '<cmd>echo "Use h to move!!"<CR>')
-- vim.keymap.set('n', '<right>', '<cmd>echo "Use l to move!!"<CR>')
-- vim.keymap.set('n', '<up>', '<cmd>echo "Use k to move!!"<CR>')
-- vim.keymap.set('n', '<down>', '<cmd>echo "Use j to move!!"<CR>')

-- Keybinds to make split navigation easier.
--  Use CTRL+<hjkl> to switch between windows
--
--  See `:help wincmd` for a list of all window commands
vim.keymap.set('n', '<leader>h', '<C-w><C-h>', { desc = 'Move focus to the left window' })
vim.keymap.set('n', '<leader>l', '<C-w><C-l>', { desc = 'Move focus to the right window' })
vim.keymap.set('n', '<leader>j', '<C-w><C-j>', { desc = 'Move focus to the lower window' })
vim.keymap.set('n', '<leader>k', '<C-w><C-k>', { desc = 'Move focus to the upper window' })

-- NOTE: Some terminals have colliding keymaps or are not able to send distinct keycodes
-- vim.keymap.set("n", "<C-S-h>", "<C-w>H", { desc = "Move window to the left" })
-- vim.keymap.set("n", "<C-S-l>", "<C-w>L", { desc = "Move window to the right" })
-- vim.keymap.set("n", "<C-S-j>", "<C-w>J", { desc = "Move window to the lower" })
-- vim.keymap.set("n", "<C-S-k>", "<C-w>K", { desc = "Move window to the upper" })
--

vim.keymap.set('n', '<leader>ti', '$a#type: ignore<Esc>', { desc = 'Insert #type: ignore on the line' })

vim.keymap.set('n', 'g;', 'g;zz')

-- Diff command abbreviations
vim.cmd 'cnoreabbrev dp diffput'
vim.cmd 'cnoreabbrev dg diffget'
vim.cmd 'cnoreabbrev D Def'

vim.api.nvim_create_user_command('Ghis', function()
  vim.cmd 'G log --oneline --graph --decorate --all'
end, { desc = 'Git history graph' })

-- Session management with persistence.nvim
vim.keymap.set('n', '<leader>qs', function()
  require('persistence').load()
end, { desc = 'Restore session for current directory' })
vim.keymap.set('n', '<leader>qS', function()
  require('persistence').select()
end, { desc = 'Select a session to load' })
vim.keymap.set('n', '<leader>ql', function()
  require('persistence').load { last = true }
end, { desc = 'Restore last session' })
vim.keymap.set('n', '<leader>qd', function()
  require('persistence').stop()
end, { desc = 'Stop session recording' })

-- Maps [count]_: to populate a backward range ending at the current line
vim.keymap.set('n', '-:', [[:<C-U>.-<C-R>=v:count1<CR>,.]], {
  desc = 'Populate backward range based on count',
})
-- Remap [count]: to use .,.+N instead of .,.+N-1
vim.keymap.set('n', ':', function()
  if vim.v.count > 0 then
    -- The <C-U> clears the default range Vim tried to insert
    return ':<C-U>.,.+' .. vim.v.count
  end
  return ':'
end, { expr = true, desc = 'Range N: as .,+N instead of +N-1' })

vim.o.grepprg = 'rg --vimgrep'

local function build_definition_pattern(word)
  return '(function|def|class|local|const|let|var)\\s+' .. word
end

local function grep_and_open(pattern, dir)
  vim.cmd { cmd = 'grep', args = { vim.fn.shellescape(pattern), dir }, bang = true }
  vim.cmd 'copen'
end

vim.keymap.set('n', 'gD', function()
  local word = vim.fn.expand '<cword>'
  grep_and_open(build_definition_pattern(word), '.')
end, { desc = 'Grep definition of word under cursor' })

vim.api.nvim_create_user_command('Def', function(opts)
  local args = vim.split(opts.args, '%s+')
  local word = args[1] ~= '' and args[1] or vim.fn.expand '<cword>'
  local dir = args[2] or '.'
  grep_and_open(build_definition_pattern(word), dir)
end, { nargs = '*', desc = 'Find definition: :Def [name] [dir]' })
