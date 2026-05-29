-- :St / :St! / :Com -- stage visual ranges and commit via a floating buffer.
-- :St[range]        stage the lines in {range} (or the current hunk).
-- :St![range]       stage, then open commit popup restricted to current file.
-- :Com              open commit popup for whatever is staged repo-wide.

local M = {}

M.popup = { buf = nil, win = nil, restrict_path = nil, msg_tempfile = nil, cwd = nil }

local function run_git(args, cwd)
  local cmd = { 'git' }
  vim.list_extend(cmd, args)
  local opts = { text = true }
  if cwd and cwd ~= '' then
    opts.cwd = cwd
  end
  local result = vim.system(cmd, opts):wait()
  return result.code, result.stdout or '', result.stderr or ''
end

local function buf_path()
  local p = vim.fn.expand '%:p'
  if p == '' then
    return nil
  end
  return vim.fn.resolve(p)
end

local function path_dir(path)
  if not path or path == '' then
    return nil
  end
  return vim.fn.fnamemodify(path, ':h')
end

local function staged_name_status(path, cwd)
  local args = { 'diff', '--cached', '--name-status' }
  if path and path ~= '' then
    table.insert(args, '--')
    table.insert(args, path)
  end
  local code, out, _ = run_git(args, cwd)
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

local function staged_diff(path, cwd)
  local args = { 'diff', '--cached' }
  if path and path ~= '' then
    table.insert(args, '--')
    table.insert(args, path)
  end
  local _, out, _ = run_git(args, cwd)
  return out
end

local function stage_range(line1, line2, has_range)
  local ok, gitsigns = pcall(require, 'gitsigns')
  if not ok then
    vim.notify('gitsigns not available', vim.log.levels.ERROR)
    return false
  end
  local cwd = path_dir(buf_path())
  local before = staged_diff(nil, cwd)
  if has_range then
    gitsigns.stage_hunk { line1, line2 }
  else
    gitsigns.stage_hunk()
  end
  -- gitsigns.stage_hunk is async; block briefly until the index actually changes.
  return vim.wait(2000, function()
    return staged_diff(nil, cwd) ~= before
  end, 30)
end

local function reset_state()
  if M.popup.msg_tempfile then
    os.remove(M.popup.msg_tempfile)
  end
  M.popup = { buf = nil, win = nil, restrict_path = nil, msg_tempfile = nil, cwd = nil }
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
    vim.notify('empty commit message', vim.log.levels.ERROR)
    return
  end

  local tempfile = vim.fn.tempname()
  local fd = io.open(tempfile, 'w')
  if not fd then
    vim.notify('failed to write temp commit file', vim.log.levels.ERROR)
    return
  end
  fd:write(table.concat(lines, '\n'))
  fd:write '\n'
  fd:close()
  M.popup.msg_tempfile = tempfile

  local args = { 'commit', '-F', tempfile }
  local code, _, err = run_git(args, M.popup.cwd)
  if code == 0 then
    vim.bo[buf].modified = false
    vim.notify('committed: ' .. stripped[1], vim.log.levels.INFO)
  else
    local msg = err ~= '' and err or 'git commit failed'
    vim.notify(msg, vim.log.levels.ERROR)
    -- leave modified=true so :wq blocks; user can edit and retry, or :q!
  end
end

local function open_commit_popup(opts)
  opts = opts or {}
  local path = opts.path
  local cwd = path_dir(path) or vim.fn.getcwd()

  if #staged_name_status(path, cwd) == 0 then
    local suffix = path and (' for ' .. vim.fn.fnamemodify(path, ':t')) or ''
    vim.notify('nothing staged' .. suffix, vim.log.levels.WARN)
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
  if path then
    table.insert(body, '# committing only changes to: ' .. vim.fn.fnamemodify(path, ':.'))
  end
  table.insert(body, '# files to commit:')
  for _, line in ipairs(staged_name_status(path, cwd)) do
    table.insert(body, '# ' .. line)
  end
  table.insert(body, '#')
  table.insert(body, '# Save and quit (:wq) to commit, or quit without saving (:q!) to cancel.')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, body)
  vim.bo[buf].modified = false

  local width = math.min(80, math.floor(vim.o.columns * 0.8))
  local height = math.min(15, math.max(8, math.floor(vim.o.lines * 0.5)))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    border = 'rounded',
    title = ' commit ',
    style = 'minimal',
  })

  M.popup.buf = buf
  M.popup.win = win
  M.popup.restrict_path = path
  M.popup.msg_tempfile = nil
  M.popup.cwd = cwd

  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = on_write,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    callback = reset_state,
  })

  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.cmd 'startinsert'
end

function M.setup()
  vim.api.nvim_create_user_command('St', function(opts)
    local staged = stage_range(opts.line1, opts.line2, opts.range > 0)
    if opts.bang then
      if not staged then
        vim.notify('staging did not take effect within timeout', vim.log.levels.WARN)
        return
      end
      open_commit_popup { path = buf_path() }
    end
  end, {
    range = true,
    bang = true,
    desc = 'Stage hunk(s); ! also commits, path-restricted to current file',
  })

  vim.api.nvim_create_user_command('Com', function()
    open_commit_popup { path = nil }
  end, { desc = 'Open commit message popup for staged changes' })
end

return M
