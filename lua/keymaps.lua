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
