-- <leader>g: stage and commit with direct, async git calls (no fugitive).
--   gs   stage the hunk at the cursor, or the selected lines; on a staged hunk, unstage it
--   gS   stage the current file          gU  unstage the current file
--   gc   commit staged, one-line message  gm  commit staged, multi-line popup
--   gC   stage and commit only the current file, leaving other staged files staged
--   gw   checkpoint: stage tracked changes + this file, commit "wip: HH:MM"
--   gu   undo the last commit, keeping its changes staged; refuses once pushed
--   gd   :Gvdiffsplit on the command line, waiting for a revision
--   gq   toggle diff mode in every window of the tab, flipping the current window's state

local M = {}

local ERROR = vim.log.levels.ERROR

M.popup = { buf = nil, win = nil, msg_tempfile = nil, cwd = nil }

local function notify(msg, level)
  vim.schedule(function()
    vim.notify(msg, level or vim.log.levels.INFO)
  end)
end

-- The current buffer's file, or nil for a scratch, help, terminal or other non-file buffer.
local function buf_path()
  if vim.bo.buftype ~= '' then
    return nil
  end
  local p = vim.fn.expand '%:p'
  if p == '' then
    return nil
  end
  return vim.fn.resolve(p)
end

local function repo_cwd(path)
  return path and vim.fn.fnamemodify(path, ':h') or vim.fn.getcwd()
end

-- Async git; on_ok(result) runs on the main loop. A failure notifies git's output instead.
local function git(args, cwd, on_ok)
  vim.system(vim.list_extend({ 'git' }, args), { text = true, cwd = cwd }, function(r)
    if r.code ~= 0 then
      local out = vim.trim(r.stderr ~= '' and r.stderr or r.stdout)
      notify(out ~= '' and out or ('git ' .. args[1] .. ' failed'), ERROR)
      return
    end
    if on_ok then
      vim.schedule(function()
        on_ok(r)
      end)
    end
  end)
end

local function notify_committed(msg)
  return function(r)
    notify('committed: ' .. msg)
    -- The pre-commit hook's comment nudge, which never blocks.
    if vim.trim(r.stderr) ~= '' then
      notify(vim.trim(r.stderr), vim.log.levels.WARN)
    end
  end
end

local function ask_message(prompt, on_msg)
  vim.ui.input({ prompt = prompt }, function(msg)
    if not msg or vim.trim(msg) == '' then
      notify 'commit cancelled'
      return
    end
    on_msg(msg)
  end)
end

local function need_file()
  local path = buf_path()
  if not path then
    notify('not a file buffer', ERROR)
  end
  return path
end

function M.stage_hunk(range)
  require('gitsigns').stage_hunk(range)
end

function M.stage_file()
  local path = need_file()
  if not path then
    return
  end
  vim.cmd 'silent update'
  git({ 'add', '--', path }, repo_cwd(path), function()
    notify('staged ' .. vim.fn.fnamemodify(path, ':.'))
  end)
end

function M.unstage_file()
  local path = need_file()
  if not path then
    return
  end
  git({ 'restore', '--staged', '--', path }, repo_cwd(path), function()
    notify('unstaged ' .. vim.fn.fnamemodify(path, ':.'))
  end)
end

function M.commit_staged()
  local cwd = repo_cwd(buf_path())
  ask_message('commit: ', function(msg)
    git({ 'commit', '-m', msg }, cwd, notify_committed(msg))
  end)
end

function M.commit_file()
  local path = need_file()
  if not path then
    return
  end
  vim.cmd 'silent update'
  local cwd = repo_cwd(path)
  ask_message('commit ' .. vim.fn.fnamemodify(path, ':t') .. ': ', function(msg)
    -- Once the whole file is staged its working copy is what's committed, so naming it
    -- commits it alone and leaves other staged files staged.
    git({ 'add', '--', path }, cwd, function()
      git({ 'commit', '-m', msg, '--', path }, cwd, notify_committed(msg))
    end)
  end)
end

function M.checkpoint()
  local path = buf_path()
  local cwd = repo_cwd(path)
  vim.cmd 'silent! wall'
  local msg = 'wip: ' .. os.date '%H:%M'
  local function commit()
    git({ 'commit', '-m', msg }, cwd, notify_committed(msg))
  end
  git({ 'add', '-u' }, cwd, function()
    if path then
      git({ 'add', '--', path }, cwd, commit)
    else
      commit()
    end
  end)
end

function M.uncommit()
  local cwd = repo_cwd(buf_path())
  git({ 'log', '-1', '--format=%s' }, cwd, function(log)
    local subject = vim.trim(log.stdout)
    -- Exit 0: HEAD is already on the upstream. 1: it isn't. 128: no upstream at all.
    vim.system({ 'git', 'merge-base', '--is-ancestor', 'HEAD', '@{u}' }, { cwd = cwd }, function(r)
      if r.code == 0 then
        notify('HEAD is pushed; not undoing "' .. subject .. '"', ERROR)
        return
      end
      git({ 'reset', '--soft', 'HEAD~1' }, cwd, function()
        notify('undid "' .. subject .. '"; its changes are staged')
      end)
    end)
  end)
end

-- The current window decides the direction; every window in the tab follows it, whatever
-- mix of diff states they were in.
function M.toggle_diff()
  if vim.wo.diff then
    vim.cmd 'diffoff!'
    return
  end
  local win = vim.api.nvim_get_current_win()
  vim.cmd 'windo diffthis'
  vim.api.nvim_set_current_win(win)
end

-- ---- gm: the multi-line popup. Synchronous, so :wq quits only after git commit succeeds. ----

local function run_git(args, cwd)
  local result = vim.system(vim.list_extend({ 'git' }, args), { text = true, cwd = cwd }):wait()
  return result.code, result.stdout or '', result.stderr or ''
end

local function staged_name_status(cwd)
  local code, out, _ = run_git({ 'diff', '--cached', '--name-status' }, cwd)
  if code ~= 0 then
    return {}
  end
  local lines = {}
  for line in out:gmatch '[^\n]+' do
    table.insert(lines, line)
  end
  return lines
end

local function current_branch(cwd)
  local code, out, _ = run_git({ 'rev-parse', '--abbrev-ref', 'HEAD' }, cwd)
  if code ~= 0 then
    return '?'
  end
  return (out:gsub('\n', ''))
end

local function reset_state()
  if M.popup.msg_tempfile then
    os.remove(M.popup.msg_tempfile)
  end
  M.popup = { buf = nil, win = nil, msg_tempfile = nil, cwd = nil }
end

local function strip_comments_and_blanks(lines)
  local out = {}
  for _, line in ipairs(lines) do
    local trimmed = line:gsub('^%s+', ''):gsub('%s+$', '')
    if trimmed ~= '' and not trimmed:match '^#' then
      table.insert(out, line)
    end
  end
  return out
end

local function on_write()
  local buf = M.popup.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local stripped = strip_comments_and_blanks(lines)
  if #stripped == 0 then
    vim.notify('empty commit message', ERROR)
    return
  end

  local tempfile = vim.fn.tempname()
  local fd = io.open(tempfile, 'w')
  if not fd then
    vim.notify('failed to write temp commit file', ERROR)
    return
  end
  fd:write(table.concat(lines, '\n'))
  fd:write '\n'
  fd:close()
  M.popup.msg_tempfile = tempfile

  local code, _, err = run_git({ 'commit', '-F', tempfile }, M.popup.cwd)
  if code == 0 then
    vim.bo[buf].modified = false
    vim.notify('committed: ' .. stripped[1], vim.log.levels.INFO)
  else
    vim.notify(err ~= '' and err or 'git commit failed', ERROR)
    -- leave modified=true so :wq blocks; user can edit and retry, or :q!
  end
end

function M.commit_popup()
  local cwd = repo_cwd(buf_path())

  if #staged_name_status(cwd) == 0 then
    vim.notify('nothing staged', vim.log.levels.WARN)
    return
  end

  if M.popup.win and vim.api.nvim_win_is_valid(M.popup.win) then
    vim.api.nvim_set_current_win(M.popup.win)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, vim.fn.tempname() .. '/COMMIT_EDITMSG')
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'gitcommit'

  local body = { '', '' }
  table.insert(body, '# branch: ' .. current_branch(cwd))
  table.insert(body, '# files to commit:')
  for _, line in ipairs(staged_name_status(cwd)) do
    table.insert(body, '# ' .. line)
  end
  table.insert(body, '#')
  table.insert(body, '# Save and quit (:wq) to commit, or quit without saving (:q!) to cancel.')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, body)
  vim.bo[buf].modified = false

  local width = math.min(80, math.floor(vim.o.columns * 0.8))
  local height = math.min(15, math.max(8, math.floor(vim.o.lines * 0.5)))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = 'rounded',
    title = ' commit ',
    style = 'minimal',
  })

  M.popup.buf = buf
  M.popup.win = win
  M.popup.msg_tempfile = nil
  M.popup.cwd = cwd

  vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = on_write })
  vim.api.nvim_create_autocmd('BufWipeout', { buffer = buf, callback = reset_state })

  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.cmd 'startinsert'
end

function M.setup()
  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { desc = desc })
  end
  map('n', '<leader>gs', function()
    M.stage_hunk()
  end, 'Git stage/unstage hunk')
  map('x', '<leader>gs', function()
    M.stage_hunk { vim.fn.line '.', vim.fn.line 'v' }
  end, 'Git stage selected lines')
  map('n', '<leader>gS', M.stage_file, 'Git stage file')
  map('n', '<leader>gU', M.unstage_file, 'Git unstage file')
  map('n', '<leader>gc', M.commit_staged, 'Git commit staged (one line)')
  map('n', '<leader>gm', M.commit_popup, 'Git commit staged (message popup)')
  map('n', '<leader>gC', M.commit_file, 'Git commit this file only')
  map('n', '<leader>gw', M.checkpoint, 'Git wip checkpoint')
  map('n', '<leader>gu', M.uncommit, 'Git undo last commit, keep changes')
  -- Left on the command line: type a revision, or <CR> alone to diff against the index.
  map('n', '<leader>gd', ':Gvdiffsplit ', 'Git vdiff against a revision')
  map('n', '<leader>gq', M.toggle_diff, 'Diff mode toggle for every window of the tab')
end

return M
