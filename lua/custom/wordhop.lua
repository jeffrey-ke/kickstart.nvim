-- Toggleable word-hop labels: the digit you would pass to `w` or `b` to land on
-- each word, painted onto the buffer.
--
-- Why this exists: 'relativenumber' solves the *vertical* version of this problem
-- -- nobody guesses how many `j`s to press -- but vim ships no horizontal
-- analogue, so `w`/`b` counts get eyeballed and overshot. This is that analogue.
--
-- Labels are produced by *driving the motion*, never by reimplementing vim's word
-- regex: the cursor is walked with `normal! w` / `normal! b` and each landing spot
-- recorded, so a label of N is correct by construction for `Nw` / `Nb`. That comes
-- with every quirk for free -- 'iskeyword' locality (a filetype where `-` is a
-- word char labels differently), runs of punctuation counting as one word, empty
-- lines counting as a word, and the current word's own start being `1b` only when
-- the cursor is not already sitting on it.
--
-- Two render modes, both extmark-based:
--   'overlay'    digits painted over the first character of each word. Zero
--                reflow, but that character is hidden while the overlay is on.
--   'virt_lines' a virtual row beneath each real line, digits under each word
--                start. Every character stays readable; screen lines double.
--
-- The default limit of 9 is deliberate: every label stays one cell wide, so
-- 'overlay' never hides more than the single first character. Past 9 words a
-- count is the wrong tool anyway -- use `/`, `f`, or a text object.

local M = {}

M.config = {
  mode = 'overlay', -- 'overlay' | 'virt_lines'
  limit = 9, -- labels per direction; >9 makes two-cell labels
  fwd_hl = 'WordHopFwd',
  bwd_hl = 'WordHopBwd',
}

local ns = vim.api.nvim_create_namespace 'custom.wordhop'
local state = { on = false, big = false, aug = nil, busy = false }

-- Walk `motion` from the cursor, recording each landing position, and put the
-- cursor and the viewport back. Stops early on no-progress (buffer edge, since a
-- blocked motion is a silent no-op under `silent!`) or once past the region --
-- both motions are monotone, so leaving it means every later hop is further out.
local function walk(motion, top, bot)
  local out = {}
  local view = vim.fn.winsaveview()
  local prev = vim.api.nvim_win_get_cursor(0)
  for n = 1, M.config.limit do
    vim.cmd('silent! keepjumps normal! ' .. motion)
    local pos = vim.api.nvim_win_get_cursor(0)
    if pos[1] == prev[1] and pos[2] == prev[2] then
      break
    end
    if pos[1] < top or pos[1] > bot then
      break
    end
    out[#out + 1] = { lnum = pos[1], col = pos[2], n = n }
    prev = pos
  end
  vim.fn.winrestview(view)
  return out
end

-- Every label for the current window: forward counts feed `w`, backward `b`.
-- The two sets are disjoint -- `w` only ever lands after the cursor and `b`
-- only before it -- so a position carries exactly one digit.
function M.targets()
  local top, bot = vim.fn.line 'w0', vim.fn.line 'w$'
  local fwd = walk(state.big and 'W' or 'w', top, bot)
  local bwd = walk(state.big and 'B' or 'b', top, bot)
  for _, t in ipairs(fwd) do
    t.hl = M.config.fwd_hl
  end
  for _, t in ipairs(bwd) do
    t.hl = M.config.bwd_hl
  end
  return fwd, bwd
end

local function draw_overlay(buf, targets)
  for _, t in ipairs(targets) do
    vim.api.nvim_buf_set_extmark(buf, ns, t.lnum - 1, t.col, {
      virt_text = { { tostring(t.n), t.hl } },
      virt_text_pos = 'overlay',
      hl_mode = 'replace',
    })
  end
end

local function draw_virt_lines(buf, targets)
  local rows = {}
  for _, t in ipairs(targets) do
    rows[t.lnum] = rows[t.lnum] or {}
    table.insert(rows[t.lnum], t)
  end
  for lnum, ts in pairs(rows) do
    table.sort(ts, function(a, b)
      return a.col < b.col
    end)
    local line = vim.fn.getline(lnum)
    local chunks, at = {}, 0
    for _, t in ipairs(ts) do
      -- t.col is a 0-based byte offset, so the display width of everything
      -- before it is its 0-based display column -- correct through tabs and
      -- multibyte, which a byte count would not be.
      local want = vim.fn.strdisplaywidth(line:sub(1, t.col))
      local label = tostring(t.n)
      if want >= at then
        chunks[#chunks + 1] = { string.rep(' ', want - at) }
        chunks[#chunks + 1] = { label, t.hl }
        at = want + #label
      end
    end
    vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, { virt_lines = { chunks } })
  end
end

local function refresh()
  if not state.on or state.busy then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  -- Labels while typing are noise, and an overlay would hide the character you
  -- are editing. Insert mode gets a bare buffer.
  if vim.fn.mode():sub(1, 1) == 'i' then
    return
  end
  state.busy = true
  local ok, err = pcall(function()
    local fwd, bwd = M.targets()
    local all = {}
    vim.list_extend(all, fwd)
    vim.list_extend(all, bwd)
    if M.config.mode == 'virt_lines' then
      draw_virt_lines(buf, all)
    else
      draw_overlay(buf, all)
    end
  end)
  state.busy = false
  if not ok then
    vim.notify('wordhop: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

local function clear_all()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
    end
  end
end

local function disable()
  state.on = false
  if state.aug then
    vim.api.nvim_del_augroup_by_id(state.aug)
    state.aug = nil
  end
  clear_all()
end

local function enable(big)
  state.on, state.big = true, big
  state.aug = vim.api.nvim_create_augroup('CustomWordHop', { clear = true })
  vim.api.nvim_create_autocmd(
    { 'CursorMoved', 'TextChanged', 'WinScrolled', 'BufEnter', 'InsertEnter', 'InsertLeave' },
    { group = state.aug, callback = refresh }
  )
  refresh()
end

-- Same key re-pressed turns it off; the other key switches granularity in place.
function M.toggle(big)
  local was, same = state.on, state.big == big
  disable()
  if not (was and same) then
    enable(big)
  end
end

function M.setup()
  vim.api.nvim_set_hl(0, 'WordHopFwd', { link = 'DiagnosticVirtualTextHint', default = true })
  vim.api.nvim_set_hl(0, 'WordHopBwd', { link = 'DiagnosticVirtualTextWarn', default = true })

  vim.keymap.set('n', '<leader>tw', function()
    M.toggle(false)
  end, { desc = '[T]oggle [w]ord-hop counts (w/b)' })
  vim.keymap.set('n', '<leader>tW', function()
    M.toggle(true)
  end, { desc = '[T]oggle [W]ORD-hop counts (W/B)' })

  vim.api.nvim_create_user_command('WordHopMode', function(o)
    M.config.mode = o.args
    refresh()
  end, {
    nargs = 1,
    complete = function()
      return { 'overlay', 'virt_lines' }
    end,
    desc = 'Switch word-hop rendering between overlay and virt_lines',
  })
end

return M
