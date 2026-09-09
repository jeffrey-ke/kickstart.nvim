-- [[ Basic Keymaps ]]
--  See `:help vim.keymap.set()`

vim.cmd [[cnoreabbrev vsb vert sb]]

-- Clear highlights on search when pressing <Esc> in normal mode
--  See `:help hlsearch`
vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')

-- `*` highlights every match of the word under the cursor but also jumps to the
-- next one. This is the same highlight without the jump: the pattern is written
-- straight into the `/` register instead of being searched for, so the cursor
-- stays put and `n`/`N`/`:%s//new/g` still pick it up. <Esc> above clears it.
-- Word chars get `\<...\>` boundaries like `*` does; anything else (`+++`, `->`)
-- is matched literally with `\V`, where `\<` would not apply.
vim.keymap.set('n', '<leader>*', function()
  local word = vim.fn.expand '<cword>'
  if word == '' then
    return
  end
  local pattern = word:match '^[%w_]+$' and ('\\<' .. word .. '\\>') or ('\\V' .. vim.fn.escape(word, '\\'))
  vim.fn.setreg('/', pattern)
  vim.fn.histadd('search', pattern)
  vim.opt.hlsearch = true
end, { desc = 'Highlight all matches of word under cursor (no jump)' })

-- Diagnostic keymaps
vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Open diagnostic [Q]uickfix list' })

-- Quickfix navigation under <leader>c, shaped like buffer motion: `cj`/`ck` step
-- one entry (`:cnext`/`:cprevious`, count-aware), `cgg`/`cG` jump to the ends
-- (`:cfirst`/`:clast`). Stepping off either end is an error in Vim (E553), so
-- these wrap around instead, and an empty list says so rather than raising E42.
local function qf_size()
  return vim.fn.getqflist({ size = 0 }).size
end

local function qf_step(cmd, wrap)
  return function()
    if qf_size() == 0 then
      vim.notify('Quickfix list is empty', vim.log.levels.WARN)
    elseif not pcall(vim.cmd, vim.v.count1 .. cmd) then
      vim.cmd(wrap)
    end
  end
end

local function qf_edge(cmd)
  return function()
    if qf_size() == 0 then
      vim.notify('Quickfix list is empty', vim.log.levels.WARN)
    else
      vim.cmd(cmd)
    end
  end
end

vim.keymap.set('n', '<leader>cj', qf_step('cnext', 'cfirst'), { desc = 'Quickfix next entry' })
vim.keymap.set('n', '<leader>ck', qf_step('cprevious', 'clast'), { desc = 'Quickfix previous entry' })
vim.keymap.set('n', '<leader>cgg', qf_edge 'cfirst', { desc = 'Quickfix first entry' })
vim.keymap.set('n', '<leader>cG', qf_edge 'clast', { desc = 'Quickfix last entry' })

-- Force diagnostic rendering on for every filetype. init.lua's [[ Diagnostic Config ]]
-- paints only shell buffers by default; that replaced a blanket vim.diagnostic.enable(false),
-- so diagnostics are computed everywhere now and <leader>q works without toggling first.
-- A bare vim.diagnostic.show() hides then re-shows every cached buffer, which is what makes
-- the flip reach windows already open rather than only the next buffer entered.
vim.g.diagnostic_render_all = false
vim.keymap.set('n', '<leader>td', function()
  vim.g.diagnostic_render_all = not vim.g.diagnostic_render_all
  vim.diagnostic.show()
  vim.notify('Diagnostic rendering: ' .. (vim.g.diagnostic_render_all and 'all filetypes' or 'shell only'), vim.log.levels.INFO)
end, { desc = '[T]oggle [D]iagnostic rendering' })

-- Spell checking (options and the prose autocmds live in init.lua's
-- [[ Spell checking ]] block). The .vimrc uses <Space>s for this toggle, which
-- cannot be copied over: <Space> is mapleader here and <leader>s is telescope's
-- [S]earch prefix, so a bare <leader>s map would stall all twelve <leader>s*
-- keys behind 'timeoutlen'. <leader>ts joins the [T]oggle group instead.
vim.keymap.set('n', '<leader>ts', function()
  vim.opt_local.spell = not vim.opt_local.spell:get()
  vim.notify('Spell ' .. (vim.opt_local.spell:get() and 'enabled' or 'disabled'), vim.log.levels.INFO)
end, { desc = '[T]oggle [S]pell' })

-- Fix the previous typo without leaving insert mode (castel.dev/post/lecture-notes-1):
-- [s jumps back to it, 1z= takes the first suggestion, `]a returns to where you
-- were typing. The <C-g>u breaks make the whole correction one undo step. Raises
-- E756 when 'spell' is off -- that is what <leader>ts above is for.
vim.keymap.set('i', '<C-l>', '<C-g>u<Esc>[s1z=`]a<C-g>u', { desc = 'Fix previous spelling mistake' })

-- Swap ^ and $ for easier end-of-line navigation
vim.keymap.set({ 'n', 'o', 'v' }, '^', '$')
vim.keymap.set({ 'n', 'o', 'v' }, '$', '^')

-- Fold keymaps
local function_types = { 'function_definition', 'function_declaration', 'method_definition', 'method_declaration', 'arrow_function', 'function' }

local function enclosing_function_node()
  local node = vim.treesitter.get_node()
  while node do
    for _, t in ipairs(function_types) do
      if node:type() == t then
        return node
      end
    end
    node = node:parent()
  end
end

local function jump_to_node_start(node)
  local row = node:start()
  vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
end

-- Move to the enclosing function's first line, then run a fold command there.
-- The guard matters: za/zO throw E490 "No fold found" on a line with no fold, and
-- that is exactly the case where there was no function to jump to either (a
-- top-level statement, the import block, a blank line). foldlevel > 0 means some
-- fold contains this line, so the command has something to act on.
local function fold_at_enclosing_function(keys)
  local node = enclosing_function_node()
  if node then
    jump_to_node_start(node)
  end
  if vim.fn.foldlevel(vim.fn.line '.') == 0 then
    vim.notify('No fold here', vim.log.levels.INFO)
    return
  end
  vim.cmd('normal! ' .. keys)
end

vim.keymap.set('n', 'zf', function()
  fold_at_enclosing_function 'za'
end, { desc = 'Toggle enclosing function fold' })

-- z1..z9 fold the whole buffer to a depth: z1 leaves only level-1 fold starts
-- visible (top-level markdown headings, module-level def/class), z2 one level
-- deeper, and so on. 'foldlevel' is the count of levels left *open*, so showing
-- N levels of headers means closing everything at level N -- hence N - 1.
-- These shadow built-in z{height}<CR> (resize window to {height} lines), which
-- becomes unreachable: 'z1' matches and fires before you can type the digits.
for n = 1, 9 do
  vim.keymap.set('n', 'z' .. n, function()
    vim.wo.foldlevel = n - 1
  end, { desc = ('Fold to level %d'):format(n) })
end

-- The chain of folds enclosing the cursor, outermost first, as {start, stop}
-- line pairs. No fold API reports this directly, so it is read the way vim
-- exposes it: with everything closed, foldclosed('.')/foldclosedend('.') give
-- the outermost fold over the cursor, and each zo (which opens exactly one
-- level) peels the next one into view. Leaves that whole chain open, the cursor
-- line visible, and every fold off the chain closed.
local function open_fold_chain()
  vim.cmd 'normal! zM'
  local chain = {}
  for _ = 1, vim.fn.foldlevel(vim.fn.line '.') do
    local line = vim.fn.line '.'
    local start = vim.fn.foldclosed(line)
    if start == -1 then
      break
    end
    table.insert(chain, { start = start, stop = vim.fn.foldclosedend(line) })
    vim.cmd 'normal! zo'
  end
  return chain
end

-- Where the last zF left off, so repeated presses widen instead of repeating.
local focus = { bufnr = nil, start = nil, depth = nil, press = 0 }

-- Focus the fold under the cursor; widen on repeat. Press 1 folds the whole
-- buffer except the chain down to the innermost enclosing fold, whose own
-- children stay closed -- the tightest view that still shows this fold's body.
-- Press k also opens the (k-1)'th ancestor recursively, so each press brings
-- more surrounding context (and the siblings inside that ancestor) into view.
-- Press depth+1 wraps back to the tightest view. Walking to a fold elsewhere
-- resets the cycle, since `focus` no longer matches the chain found here.
local function fold_focus()
  if vim.fn.foldlevel(vim.fn.line '.') == 0 then
    vim.notify('No fold here', vim.log.levels.INFO)
    return
  end
  local view = vim.fn.winsaveview()
  local chain = open_fold_chain()
  local depth = #chain
  if depth == 0 then
    vim.fn.winrestview(view)
    vim.notify('No fold here', vim.log.levels.INFO)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local innermost = chain[depth].start
  local continuing = focus.bufnr == bufnr and focus.start == innermost and focus.depth == depth
  local press = continuing and (focus.press % depth) + 1 or 1
  focus = { bufnr = bufnr, start = innermost, depth = depth, press = press }

  if press > 1 then
    -- Counting inward from the outermost: press 2 is the innermost's parent.
    -- ':range foldopen!' and not zO: zO opens the folds *containing* the cursor
    -- recursively, which the chain walk above already did. Widening means
    -- opening everything nested inside the ancestor, siblings included, and a
    -- ranged :foldopen! is what does that.
    local ancestor = chain[depth - press + 1]
    vim.cmd(('%d,%dfoldopen!'):format(ancestor.start, ancestor.stop))
  end
  vim.fn.winrestview(view)
  -- Not notify(): the cycle position is worth seeing, not worth a message log.
  vim.api.nvim_echo({ { ('fold focus %d/%d'):format(press, depth), 'Comment' } }, false, {})
end

vim.keymap.set('n', 'zF', fold_focus, { desc = 'Focus fold under cursor (repeat to widen)' })
-- vim.keymap.set('n', '<Tab>', 'za', { desc = 'Toggle fold under cursor' }) -- conflicts with <C-i> jumplist
vim.keymap.set('n', '<S-Tab>', 'zA', { desc = 'Toggle fold under cursor (recursive)' })

-- Append a space after the cursor without entering insert mode persistently
vim.keymap.set('n', '<leader>p', 'a<Space><Esc>', { desc = 'Append a space after cursor' })

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

vim.keymap.set('n', '<leader>yr', function()
  local file = vim.fn.expand '%:.'
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local ref = '@' .. file .. '#L' .. line
  vim.fn.setreg('+', ref)
  vim.notify('Copied: ' .. ref, vim.log.levels.INFO)
end, { desc = 'Yank Claude Code file reference (@file#Lnum)' })

vim.keymap.set('v', '<leader>yr', function()
  local file = vim.fn.expand '%:.'
  local start_line = vim.fn.line 'v'
  local end_line = vim.fn.line '.'
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end
  local ref = '@' .. file .. '#L' .. start_line .. '-' .. end_line
  vim.fn.setreg('+', ref)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
  vim.notify('Copied: ' .. ref, vim.log.levels.INFO)
end, { desc = 'Yank Claude Code file range reference (@file#Lstart-end)' })

-- A commit-pinned web link to the line(s) under the cursor -- the shareable
-- cousin of <leader>yr, for anyone who is not looking at this checkout.
-- Pinning to the commit rather than the branch is the whole point: the link
-- keeps meaning the same line after the branch moves on.
local function git_permalink(first_line, last_line)
  local path = vim.fn.expand '%:p'
  if path == '' then
    return nil, 'No file for this buffer'
  end
  local dir = vim.fn.fnamemodify(path, ':h')

  -- nil on nonzero exit, so every step below can be checked the same way.
  local function git(...)
    local out = vim.fn.systemlist { 'git', '-C', dir, ... }
    if vim.v.shell_error ~= 0 then
      return nil
    end
    return out
  end

  local head = git('rev-parse', 'HEAD')
  if not head then
    return nil, 'Not inside a git repository: ' .. dir
  end
  local sha = head[1]

  local tracked = git('ls-files', '--full-name', '--error-unmatch', '--', path)
  if not tracked or not tracked[1] then
    return nil, 'Not tracked by git: ' .. path
  end
  local relpath = tracked[1]

  -- Does the remote have this commit? Asked of the local remote-tracking refs
  -- rather than the network, so it is wrong only when the push happened in
  -- another checkout and this one has not fetched since.
  --
  -- The upstream branch answers it in milliseconds; the exhaustive scan over
  -- every refs/remotes/* takes ~1s in a repo the size of Nuro, so it is a
  -- fallback for detached HEADs and branches with no upstream, not the norm.
  local on_remote = git('merge-base', '--is-ancestor', sha, '@{upstream}') ~= nil
  if not on_remote then
    local containing = git('branch', '--remotes', '--contains', sha)
    on_remote = containing ~= nil and #containing > 0
  end
  if not on_remote then
    return nil, ('Commit %s is on no remote branch -- push (or fetch) first'):format(sha:sub(1, 12))
  end

  local origin = git('remote', 'get-url', 'origin')
  if not origin then
    return nil, 'No `origin` remote to build a URL from'
  end
  -- scp-style git@host:owner/repo.git, else a ssh:// or https:// URL -- whose
  -- authority can carry a user@ and a :port that have no place in a web link.
  local host, repo = origin[1]:match '^[%w._-]+@([^:/]+):(.+)$'
  if not host then
    local authority
    authority, repo = origin[1]:match '^%a+://([^/]+)/(.+)$'
    if authority then
      host = authority:gsub('^[^@]*@', ''):gsub(':%d+$', '')
    end
  end
  if not host then
    return nil, 'Cannot parse origin URL: ' .. origin[1]
  end
  repo = repo:gsub('%.git$', '')

  local anchor = first_line == last_line and ('#L%d'):format(first_line) or ('#L%d-L%d'):format(first_line, last_line)
  local url = ('https://%s/%s/blob/%s/%s%s'):format(host, repo, sha, relpath, anchor)

  -- Unsaved or uncommitted edits shift line numbers away from what the commit
  -- holds, so the link is still valid but points somewhere else. Worth saying.
  local stale = vim.bo.modified or git('diff', '--quiet', 'HEAD', '--', path) == nil
  return url, nil, stale
end

local function yank_git_permalink(first_line, last_line)
  local url, err, stale = git_permalink(first_line, last_line)
  if not url then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end
  vim.fn.setreg('+', url)
  if stale then
    vim.notify('Copied (buffer differs from HEAD, lines may not match):\n' .. url, vim.log.levels.WARN)
    return
  end
  vim.notify('Copied: ' .. url, vim.log.levels.INFO)
end

vim.keymap.set('n', '<leader>yg', function()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  yank_git_permalink(line, line)
end, { desc = 'Yank [G]it permalink to this line' })

vim.keymap.set('v', '<leader>yg', function()
  local start_line, end_line = vim.fn.line 'v', vim.fn.line '.'
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
  yank_git_permalink(start_line, end_line)
end, { desc = 'Yank [G]it permalink to this line range' })
vim.keymap.set('n', '<leader>yp', function()
  local path = vim.fn.expand '%:p'
  if path == '' then
    vim.notify('No file for this buffer', vim.log.levels.WARN)
    return
  end
  vim.fn.setreg('+', path)
  vim.notify('Copied: ' .. path, vim.log.levels.INFO)
end, { desc = 'Yank absolute [P]ath of current file' })

-- The RPC socket, for handing this session to an external agent that will drive it
-- with `nvim --server <socket> --remote-expr ...`.
vim.keymap.set('n', '<leader>ys', function()
  local server = vim.v.servername
  if server == '' then
    vim.notify('This session has no RPC server', vim.log.levels.WARN)
    return
  end
  vim.fn.setreg('+', server)
  vim.notify('Copied: ' .. server, vim.log.levels.INFO)
end, { desc = 'Yank nvim [S]ervername (RPC socket)' })

vim.keymap.set('n', 'g;', 'g;zz')

-- Command abbreviations
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
vim.keymap.set('n', '-:', [[:<C-U>.-<C-R>=v:count1<CR>,.s/]], {
  desc = 'Populate backward range with substitute',
})
-- Remap [count]: to use .,.+N instead of .,.+N-1
vim.keymap.set('n', ':', function()
  if vim.v.count > 0 then
    return ':<C-U>.,.+' .. vim.v.count .. 's/'
  end
  return ':'
end, { expr = true, desc = 'Range N: as .,+N substitute' })

vim.keymap.set('n', '<leader>rn', function()
  local word = vim.fn.expand '<cword>'
  local save_pos = vim.api.nvim_win_get_cursor(0)
  vim.cmd 'normal ]M'
  local end_line = vim.api.nvim_win_get_cursor(0)[1]
  vim.api.nvim_win_set_cursor(0, save_pos)
  local escaped = vim.fn.escape(word, '/')
  local offset = end_line - save_pos[1]
  local cmd = '.,+' .. offset .. 's/' .. escaped .. '/'
  vim.api.nvim_feedkeys(':' .. cmd, 'n', false)
end, { desc = '[R]e[n]ame word to end of method' })

vim.o.grepprg = 'rg --vimgrep'

local function build_definition_pattern(word)
  return '(function|def|class|local|const|let|var)\\s+' .. word
end

local function grep_and_open(pattern, dir)
  local cmd = vim.o.grepprg .. ' -g "!*.md" -g "!*.txt" -g "!*.json" -g "!*.yaml" -g "!*.yml" -g "!*.toml" -g "!*.lock" -g "!*.csv" '
    .. vim.fn.shellescape(pattern)
    .. ' '
    .. dir
  vim.fn.setqflist({}, ' ', { title = cmd, lines = vim.fn.systemlist(cmd), efm = vim.o.grepformat })
  vim.cmd 'copen'
  pcall(vim.cmd, 'cfirst')
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
  vim.cmd 'cclose'
end, { nargs = '*', desc = 'Find definition: :Def [name] [dir]' })

vim.api.nvim_create_user_command('D', function(opts)
  vim.cmd('Def ' .. opts.args)
end, { nargs = '*', desc = 'Alias for :Def' })

vim.api.nvim_create_user_command('VDef', function(opts)
  vim.cmd 'vsplit'
  vim.cmd('Def ' .. opts.args)
end, { nargs = '*', desc = 'Vsplit + :Def' })

vim.api.nvim_create_user_command('Vd', function(opts)
  vim.cmd('VDef ' .. opts.args)
end, { nargs = '*', desc = 'Alias for :VDef' })

vim.api.nvim_create_user_command('SDef', function(opts)
  vim.cmd 'split'
  vim.cmd('Def ' .. opts.args)
end, { nargs = '*', desc = 'Hsplit + :Def' })

vim.api.nvim_create_user_command('Sd', function(opts)
  vim.cmd('SDef ' .. opts.args)
end, { nargs = '*', desc = 'Alias for :SDef' })

vim.api.nvim_create_user_command('VGr', function(opts)
  vim.cmd 'vsplit'
  vim.cmd('Gr ' .. opts.args)
end, { nargs = '?', desc = 'Vsplit + :Gr' })

vim.api.nvim_create_user_command('Vg', function(opts)
  vim.cmd('VGr ' .. opts.args)
end, { nargs = '?', desc = 'Alias for :VGr' })

vim.api.nvim_create_user_command('Gr', function(opts)
  local pattern = opts.args ~= '' and opts.args or vim.fn.expand '<cword>'
  grep_and_open(pattern, '.')
end, { nargs = '?', desc = 'Grep (defaults to word under cursor)' })

vim.api.nvim_create_user_command('Su', function(opts)
  local args = vim.split(opts.args, '%s+')
  local from, to

  if #args == 1 and args[1] ~= '' then
    from = vim.fn.expand '<cword>'
    to = args[1]
  elseif #args >= 2 then
    from = args[1]
    to = args[2]
  else
    vim.notify('Usage: :Su <replacement> or :Su <from> <replacement>', vim.log.levels.ERROR)
    return
  end

  local qflist = vim.fn.getqflist()
  if #qflist == 0 then
    vim.notify('Quickfix list is empty', vim.log.levels.WARN)
    return
  end

  local files = {}
  for _, entry in ipairs(qflist) do
    if entry.bufnr and entry.bufnr > 0 then
      local fname = vim.api.nvim_buf_get_name(entry.bufnr)
      if fname ~= '' then
        files[fname] = true
      end
    end
  end

  local file_count = vim.tbl_count(files)
  if file_count == 0 then
    vim.notify('No files in quickfix list', vim.log.levels.WARN)
    return
  end

  local sub_from = vim.fn.escape(from, '/')
  local escaped_to = vim.fn.escape(to, '/\\&~')
  for fname, _ in pairs(files) do
    vim.cmd('silent! argadd ' .. vim.fn.fnameescape(fname))
  end
  vim.cmd('silent! argdo %s/' .. sub_from .. '/' .. escaped_to .. '/ge | update')
  vim.cmd 'argdelete *'

  vim.notify(string.format('Substituted "%s" -> "%s" in %d file(s)', from, to, file_count), vim.log.levels.INFO)
end, { nargs = '+', desc = 'Substitute in quickfix files: :Su <to> or :Su <from> <to>' })

-- Toggle markdown checkboxes over the cursor line, or over the visual range.
--
-- `line('v')` is the other end of the Visual area in visual mode and the cursor
-- line outside it, so one expression covers both modes and the range never has
-- to be reconstructed from the '< '> marks (which only update on leaving
-- visual, and so would lag a press behind).
--
-- Each line flips independently: a mixed selection ends up inverted rather than
-- normalised to all-checked. Nothing propagates to parents or children -- that
-- was checkmate.nvim's smart_toggle, and it went with the plugin.
--
-- The pattern accepts any of the three bullet characters and either case of x,
-- but requires the marker to be the first thing on the line, so a `[x]` written
-- inline in prose is left alone. One set_lines call for the whole range keeps
-- it to a single undo step.
local function toggle_checkbox()
  local first, last = vim.fn.line 'v', vim.fn.line '.'
  if first > last then
    first, last = last, first
  end

  local lines = vim.api.nvim_buf_get_lines(0, first - 1, last, false)
  local found = false
  for idx, line in ipairs(lines) do
    local head, state, tail = line:match '^(%s*[-*+]%s+%[)([ xX])(%].*)$'
    if head then
      lines[idx] = head .. (state == ' ' and 'x' or ' ') .. tail
      found = true
    end
  end

  if not found then
    vim.notify('no markdown checkbox here', vim.log.levels.WARN)
  else
    vim.api.nvim_buf_set_lines(0, first - 1, last, false, lines)
  end

  -- Leave visual mode either way: the selection's highlight would otherwise
  -- survive the edit and suggest the range is still live.
  if vim.fn.mode():match '[vV\22]' then
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
  end
end

-- Buffer-local, in the same `<leader>m` markdown namespace as md_table.lua's
-- `<leader>mc`. Its own augroup rather than md_table's, since checkboxes are
-- nothing to do with tables.
vim.api.nvim_create_autocmd('FileType', {
  desc = 'Markdown checkbox toggle',
  group = vim.api.nvim_create_augroup('md_checkbox', { clear = true }),
  pattern = 'markdown',
  callback = function()
    vim.keymap.set({ 'n', 'x' }, '<leader>mx', toggle_checkbox, {
      buffer = true,
      desc = '[M]arkdown: toggle checkbo[x]',
    })
  end,
})

require('custom.stage_commit').setup()
require('custom.code_pointers').setup()
require('custom.md_table').setup()
