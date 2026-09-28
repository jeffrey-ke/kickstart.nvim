-- Markdown table editing: add a column, move from cell to cell, align pipes.
--
-- add_column is not a snippet: LuaSnip expands at a single point and can only
-- put tab stops in text it inserted itself, whereas a new column has to extend
-- lines that already exist -- including the delimiter row two lines up from
-- wherever you happen to be sitting.
--
-- The header and delimiter rows must agree on cell count or the markdown
-- treesitter grammar stops recognising the block as a table at all (verified:
-- header=3/delim=2 parses to zero pipe_table nodes), which would make
-- render-markdown.nvim drop the whole table mid-edit. So every line goes out in
-- one nvim_buf_set_lines call: one undo step, no unparseable intermediate.
--
-- Body rows are padded too, even though the grammar tolerates short ones
-- (missing cells just render empty). Keeping the block rectangular is what
-- keeps the `trow` snippet's column count right, since it reads the table's
-- shape back out of the buffer.
--
-- align() is the third feature and shares the same primitives: block() for the
-- extent, separators()/cells() for the split. It is bound to a key rather than
-- run on save, because the vault is also open in SilverBullet -- a formatter
-- firing on :w would rewrite rows underneath its sync.
--
-- The motions find rows with the same is_row/block helpers add_column uses,
-- rather than going to treesitter, so both features share one notion of where
-- a table starts and stops. Treesitter would additionally get tables nested in
-- blockquotes or list items right, where `^%s*|` fails on the `>` prefix --
-- worth revisiting if those ever turn up in the vault.

local M = {}

local function line_at(n)
  return vim.api.nvim_buf_get_lines(0, n - 1, n, false)[1]
end

local function is_row(line)
  return line ~= nil and line:match '^%s*|' ~= nil
end

-- Contiguous run of `|` lines containing `lnum`, as 1-indexed first,last.
-- Returns nil when the cursor isn't in a table, or when the run is too short to
-- have both a header and a delimiter.
local function block(lnum)
  if not is_row(line_at(lnum)) then
    return nil
  end
  local first, last = lnum, lnum
  while first > 1 and is_row(line_at(first - 1)) do
    first = first - 1
  end
  local total = vim.api.nvim_buf_line_count(0)
  while last < total and is_row(line_at(last + 1)) do
    last = last + 1
  end
  if last - first < 1 then
    return nil
  end
  return first, last
end

-- Append one cell to a row: `| a | b |` -> `| a | b |  |`. Trailing whitespace
-- after the final pipe would otherwise end up mid-row, so it's dropped first.
local function extend(line, cell)
  return (line:gsub('%s*$', '')) .. ' ' .. cell .. ' |'
end

function M.add_column()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local first, last = block(cursor[1])
  if not first then
    vim.notify('not inside a markdown table', vim.log.levels.WARN)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(0, first - 1, last, false)
  for idx, line in ipairs(lines) do
    -- The delimiter is always the second line of the block; only it takes the
    -- dashes, every other row takes an empty cell.
    lines[idx] = extend(line, idx == 2 and '---' or '')
  end
  vim.api.nvim_buf_set_lines(0, first - 1, last, false, lines)

  -- Land in the new header cell, between the two spaces that extend() added, so
  -- the column name can be typed straight away.
  vim.api.nvim_win_set_cursor(0, { first, #lines[1] - 2 })
  vim.cmd 'startinsert'
end

-- Cell separators are unescaped `|` only: GFM reads `\|` as a literal pipe, so
-- a cell can legitimately hold one. An odd run of backslashes in front escapes
-- the pipe; an even run is escaped backslashes and leaves it separating.
local function separators(line)
  local out = {}
  local at = line:find('|', 1, true)
  while at do
    local slashes, scan = 0, at - 1
    while scan >= 1 and line:sub(scan, scan) == '\\' do
      slashes, scan = slashes + 1, scan - 1
    end
    if slashes % 2 == 0 then
      out[#out + 1] = at
    end
    at = line:find('|', at + 1, true)
  end
  return out
end

-- Cells of a row as 1-indexed {from,to} byte spans over the content between
-- separators, padding included. A row doesn't have to close with a `|` -- GFM
-- takes `| a | b`, even though extend() always writes the closer -- so a
-- non-blank tail past the last separator counts as one more cell.
local function cells(line)
  local bars = separators(line)
  if #bars == 0 then
    return {}
  end
  local out = {}
  for n = 1, #bars - 1 do
    out[n] = { bars[n] + 1, bars[n + 1] - 1 }
  end
  if line:sub(bars[#bars] + 1):match '%S' then
    out[#out + 1] = { bars[#bars] + 1, #line }
  end
  return out
end

-- Which cell holds `col` (1-indexed). A cursor on a separator belongs to the
-- cell to its right, which is also what puts the leading `|` in cell 1.
local function cell_at(line, col)
  local spans = cells(line)
  for n, span in ipairs(spans) do
    if col <= span[2] then
      return n, spans
    end
  end
  return #spans, spans
end

-- Where in a cell to leave the cursor: its first non-blank, or -- for an empty
-- cell -- the gap between the two padding spaces, which is the same spot
-- add_column drops you in a freshly added header cell.
local function landing(line, span)
  local offset = line:sub(span[1], span[2]):find '%S'
  if offset then
    return span[1] + offset - 1
  end
  return math.min(span[1] + 1, math.max(span[1], span[2]))
end

-- Trimmed contents of a row's cells. Alignment works on the text, so the
-- padding a previous align() wrote is thrown away here and recomputed below --
-- that is what makes running it twice a no-op.
local function contents(line)
  local out = {}
  for _, span in ipairs(cells(line)) do
    out[#out + 1] = vim.trim(line:sub(span[1], span[2]))
  end
  return out
end

-- How a delimiter cell says its column is aligned. nil means the cell is not a
-- delimiter at all, which is align()'s cue to leave the block alone: the second
-- line of a `|` run is normally the delimiter, but if it is really a body row
-- (a header typed with no delimiter yet) then rewriting it as dashes would
-- delete what is in it.
local function marker(cell)
  if not cell:match '^:?%-+:?$' then
    return nil
  end
  local left, right = cell:sub(1, 1) == ':', cell:sub(-1) == ':'
  if left and right then
    return 'center'
  end
  return (left and 'left') or (right and 'right') or 'none'
end

-- Display cells, not bytes: a UTF-8 name or a tab is what the reader sees line
-- up, and `#` would count its bytes. (An escaped `\|` inside a cell still
-- measures one column wide, so a column holding one ends up a column narrow --
-- the alternative is teaching this the whole of GFM's inline escaping.)
local function width(text)
  return vim.fn.strdisplaywidth(text)
end

-- Pad to `w` columns on the side the delimiter asked for. Content wider than
-- the column is returned untouched rather than truncated: widths are computed
-- from the content, so this only happens for the delimiter's own 3-column floor.
local function pad(text, w, align)
  local slack = w - width(text)
  if slack <= 0 then
    return text
  end
  if align == 'right' then
    return (' '):rep(slack) .. text
  end
  if align == 'center' then
    local half = math.floor(slack / 2)
    return (' '):rep(half) .. text .. (' '):rep(slack - half)
  end
  return text .. (' '):rep(slack)
end

-- The delimiter cell for a `w`-wide column, keeping whichever colons were there
-- before. Every branch is exactly `w` characters, so the delimiter comes out the
-- same width as the column it describes.
local function dashes(w, align)
  if align == 'center' then
    return ':' .. ('-'):rep(w - 2) .. ':'
  end
  if align == 'left' then
    return ':' .. ('-'):rep(w - 1)
  end
  if align == 'right' then
    return ('-'):rep(w - 1) .. ':'
  end
  return ('-'):rep(w)
end

-- Rewrite the table under the cursor with its pipes lined up in the source
-- bytes. render-markdown.nvim already pads the columns with virtual text, so
-- this is for every other reader of the file: SilverBullet's own editor, the
-- GitHub blob view, `git diff`, and nvim itself with conceal off.
--
-- Explicitly invoked, not fired on `|` or on save. Realigning as you type is
-- what vim-table-mode does, and it would move the byte offsets under the cursor
-- mid-insert -- which is exactly what M.move's insert-mode cell motions have
-- just finished computing. One command means the two features never disagree
-- about when the buffer is allowed to change.
--
-- Same single nvim_buf_set_lines as add_column, for the same reason: one undo
-- step, and no intermediate state where the header and delimiter disagree on
-- cell count and the treesitter grammar stops seeing a table.
function M.align()
  local pos = vim.api.nvim_win_get_cursor(0)
  local lnum, col = pos[1], pos[2] + 1
  local first, last = block(lnum)
  if not first then
    vim.notify('not inside a markdown table', vim.log.levels.WARN)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(0, first - 1, last, false)
  local rows = {}
  for idx, line in ipairs(lines) do
    rows[idx] = contents(line)
  end

  local aligns = {}
  for n, cell in ipairs(rows[2]) do
    aligns[n] = marker(cell)
    if not aligns[n] then
      vim.notify('no delimiter row: not aligning', vim.log.levels.WARN)
      return
    end
  end

  -- The widest row sets the column count, so a body row running past the
  -- delimiter keeps its cells. The grammar ignores those extras and nothing
  -- renders them, but they are still text someone typed, and dropping text is a
  -- worse failure than a table that is one column too wide.
  local columns = 0
  for _, row in ipairs(rows) do
    columns = math.max(columns, #row)
  end

  -- Floor of 3, the narrowest a delimiter cell can be and still carry `:-:`.
  -- The delimiter row is skipped when measuring: its dashes are output, not input.
  local widths = {}
  for n = 1, columns do
    widths[n] = 3
    for idx, row in ipairs(rows) do
      if idx ~= 2 then
        widths[n] = math.max(widths[n], width(row[n] or ''))
      end
    end
  end

  -- Cell the cursor is in, read before the rewrite; the same cell is where it
  -- goes afterwards, since the whole point is that nothing moved but the padding.
  local index = math.max(cell_at(lines[lnum - first + 1], col), 1)

  local indent = lines[1]:match '^%s*'
  local out = {}
  for idx = 1, #rows do
    local pieces = {}
    for n = 1, columns do
      local align = aligns[n] or 'none'
      pieces[n] = idx == 2 and dashes(widths[n], align) or pad(rows[idx][n] or '', widths[n], align)
    end
    out[idx] = indent .. '| ' .. table.concat(pieces, ' | ') .. ' |'
  end
  vim.api.nvim_buf_set_lines(0, first - 1, last, false, out)

  local landed = out[lnum - first + 1]
  local span = cells(landed)[math.min(index, columns)]
  vim.api.nvim_win_set_cursor(0, { lnum, span and landing(landed, span) - 1 or 0 })
end

-- One row up or down inside the block, hopping the delimiter (always the second
-- line) and stopping at the block's edges instead of leaving it.
local function step_row(first, last, lnum, delta)
  local n = lnum + delta
  if n == first + 1 then
    n = n + delta
  end
  if n < first or n > last then
    return nil
  end
  return n
end

-- Move one cell. Returns false when there's nowhere to go -- not in a table, or
-- already at an edge -- which is the caller's cue to let the key do whatever it
-- would have done.
--
-- h/l wrap across rows, since filling a table in is the common case and the
-- wrap is what turns them into a single "next field" motion. j/k hold the
-- column index and clamp at the block's edges: sliding out of a table
-- vertically would be surprising, and `}` already does that.
function M.move(direction)
  local pos = vim.api.nvim_win_get_cursor(0)
  local lnum, col = pos[1], pos[2] + 1
  local first, last = block(lnum)
  if not first then
    return false
  end

  local index, spans = cell_at(line_at(lnum), col)
  if index == 0 then
    return false
  end

  local target_row, target_index
  if direction == 'h' or direction == 'l' then
    local delta = direction == 'l' and 1 or -1
    target_row, target_index = lnum, index + delta
    if target_index < 1 or target_index > #spans then
      target_row = step_row(first, last, lnum, delta)
      if not target_row then
        return false
      end
      local count = #cells(line_at(target_row))
      if count == 0 then
        return false
      end
      target_index = delta == 1 and 1 or count
    end
  else
    target_row = step_row(first, last, lnum, direction == 'j' and 1 or -1)
    if not target_row then
      return false
    end
    local count = #cells(line_at(target_row))
    if count == 0 then
      return false
    end
    target_index = math.min(index, count)
  end

  local target_line = line_at(target_row)
  vim.api.nvim_win_set_cursor(0, { target_row, landing(target_line, cells(target_line)[target_index]) - 1 })
  return true
end

-- Do whatever `key` would have done in `mode` if this buffer-local map weren't
-- in the way. nvim_get_keymap lists *global* maps only, so the lookup can't
-- rediscover the buffer-local map that called it -- that is what stops this
-- recursing. (blink.cmp resolves its own `fallback` command the same way.)
--
-- Routing through the global map rather than feeding the raw key is what keeps
-- the insert-mode `<C-j>`/`<C-k>` LuaSnip choice cycling from init.lua working
-- inside markdown buffers, without this file having to repeat its rhs.
local function fallback(mode, key)
  local wanted = vim.api.nvim_replace_termcodes(key, true, true, true)
  for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
    if vim.api.nvim_replace_termcodes(map.lhs, true, true, true) == wanted then
      if map.callback then
        local produced = map.callback()
        if map.expr == 1 and type(produced) == 'string' then
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(produced, true, true, true), 'n', true)
        end
      elseif map.rhs then
        -- 'n', so a self-referential rhs can't route back through this map;
        -- insert=true to put it at the *front* of the typeahead, ahead of
        -- whatever is already queued, rather than after it.
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(map.rhs, true, true, true), 'n', true)
      end
      return
    end
  end
  vim.api.nvim_feedkeys(wanted, 'n', true)
end

-- Buffer-local so the fallbacks above are the only thing the rest of the config
-- ever notices. Insert-mode <C-j>/<C-k> arrive here by way of blink.cmp, which
-- re-applies its own buffer-local maps on InsertEnter and captures ours as the
-- `fallback` its config already lists: the completion menu keeps those keys
-- while it is open, cells get them while it isn't.
local motions = {
  ['<C-h>'] = { 'h', 'left' },
  ['<C-j>'] = { 'j', 'down' },
  ['<C-k>'] = { 'k', 'up' },
  ['<C-l>'] = { 'l', 'right' },
}

-- Write the table out as CSV, for importing into a spreadsheet, via bin/md2csv.
--
-- Range semantics follow however the range got typed: `:'<,'>MdTableCsv` from a
-- visual selection, `:'a,'bMdTableCsv` from marks, `:15,40MdTableCsv` by number.
-- With no range at all it falls back to block(), so `:MdTableCsv` with the cursor
-- anywhere in the table works the same way align() does.
--
-- The rows go to md2csv on stdin rather than by filename, so an unsaved buffer
-- exports what is on screen instead of what was last written to disk. The cost is
-- that md2csv then cannot see anything outside the range, and a selection that
-- starts at the first *body* row is not a table at all -- its find_tables wants a
-- header plus a delimiter -- so a failure retries once with block()'s extent,
-- which is where the header is. md2csv stays the only thing here that decides
-- what counts as a table; this does not re-implement that test in Lua.
local function md2csv(lines, flags)
  local exe = vim.fn.exepath 'md2csv'
  if exe == '' then
    return nil, 'md2csv not on $PATH'
  end
  local cmd = { exe }
  vim.list_extend(cmd, flags)
  -- One string, not a list: md2csv reads a text stream, and a trailing newline
  -- keeps the last row a row.
  local stdin = table.concat(lines, '\n') .. '\n'
  local done = vim.system(cmd, { stdin = stdin, text = true }):wait()
  local stderr = vim.trim(done.stderr or '')
  if done.code ~= 0 then
    -- md2csv replays its stdin to stdout on failure (so that a misuse as a range
    -- filter is a no-op rather than data loss), which means stdout here is the
    -- markdown back again, not CSV. Never write it.
    return nil, stderr
  end
  return done.stdout, stderr
end

-- `~` rather than the cwd: the cwd is usually the vault, SilverBullet watches it,
-- and a stray .csv there gets picked up as a space file. md2csv's own examples
-- write to `~/aev.csv` for the same reason.
local function default_target(first)
  local stem = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':t:r')
  if stem == '' then
    stem = 'table'
  end
  stem = (stem:lower():gsub('[^%w]+', '-'):gsub('^%-+', ''):gsub('%-+$', ''))
  return ('%s/%s-L%d.csv'):format(vim.fn.expand '~', stem, first)
end

function M.to_csv(opts)
  opts = opts or {}

  local first, last
  if (opts.range or 0) > 0 then
    first, last = opts.line1, opts.line2
  else
    first, last = block(vim.api.nvim_win_get_cursor(0)[1])
    if not first then
      vim.notify('not inside a markdown table', vim.log.levels.WARN)
      return
    end
  end

  -- Anything that is not a flag is the target path, so `:MdTableCsv ~/x.csv` and
  -- `:MdTableCsv --tsv ~/x.tsv` both work and neither one prompts.
  local flags, target = {}, nil
  for _, arg in ipairs(opts.fargs or {}) do
    local mode = arg:match '^%-%-links=(.+)$'
    if mode then
      vim.list_extend(flags, { '--links', mode })
    elseif arg == '--tsv' then
      flags[#flags + 1] = '--tsv'
    else
      target = arg
    end
  end

  local csv, err = md2csv(vim.api.nvim_buf_get_lines(0, first - 1, last, false), flags)
  if not csv then
    local wide_first, wide_last = block(first)
    if wide_first and (wide_first < first or wide_last > last) then
      csv, err = md2csv(vim.api.nvim_buf_get_lines(0, wide_first - 1, wide_last, false), flags)
      if csv then
        vim.notify(('widened to the whole table, lines %d-%d'):format(wide_first, wide_last), vim.log.levels.INFO)
      end
    end
  end
  if not csv then
    vim.notify(err ~= '' and err or 'md2csv failed', vim.log.levels.ERROR)
    return
  end

  -- md2csv terminates every row, and writefile() terminates every line it is
  -- given, so the empty final element has to go or the file ends in a blank row.
  local rows = vim.split(csv, '\n')
  if rows[#rows] == '' then
    table.remove(rows)
  end

  local function write(path)
    local resolved = vim.fn.fnamemodify(vim.fn.expand(path), ':p')
    -- A directory, or a path typed with a trailing slash, means "here, named for me".
    if resolved:sub(-1) == '/' or vim.fn.isdirectory(resolved) == 1 then
      resolved = resolved:gsub('/$', '') .. '/' .. vim.fn.fnamemodify(default_target(first), ':t')
    end
    local dir = vim.fn.fnamemodify(resolved, ':h')
    if vim.fn.isdirectory(dir) == 0 then
      vim.notify('no such directory: ' .. dir, vim.log.levels.ERROR)
      return
    end
    if vim.fn.filereadable(resolved) == 1 and vim.fn.confirm(resolved .. ' exists. Overwrite?', '&Yes\n&No', 2) ~= 1 then
      return
    end
    if vim.fn.writefile(rows, resolved) ~= 0 then
      vim.notify('could not write ' .. resolved, vim.log.levels.ERROR)
      return
    end
    vim.notify(('%d row(s) -> %s'):format(#rows, resolved), vim.log.levels.INFO)
    -- Ragged rows mean the CSV and the markdown disagree; `<leader>ma` is the fix.
    if err ~= '' then
      vim.notify(err, vim.log.levels.WARN)
    end
  end

  if target then
    write(target)
    return
  end
  vim.ui.input({ prompt = 'CSV path: ', default = default_target(first), completion = 'file' }, function(input)
    if input and vim.trim(input) ~= '' then
      write(vim.trim(input))
    end
  end)
end

function M.setup()
  vim.api.nvim_create_user_command('MdTableAddColumn', M.add_column, {
    desc = 'Add a column to the markdown table under the cursor',
  })
  vim.api.nvim_create_user_command('MdTableAlign', M.align, {
    desc = 'Line up the pipes of the markdown table under the cursor',
  })
  -- One spec, two names: `:MdTableCsv` is what shows up under `:MdTable<Tab>`
  -- next to Align and AddColumn, `:M2c` is for when typing that has got old.
  local csv_spec = {
    range = true,
    nargs = '*',
    complete = 'file',
    desc = 'Write the markdown table (or the given range) to a CSV file',
  }
  vim.api.nvim_create_user_command('MdTableCsv', M.to_csv, csv_spec)
  vim.api.nvim_create_user_command('M2c', M.to_csv, csv_spec)

  -- ...and `:mtc` in lowercase, which cannot be a command at all -- Vim reserves
  -- lowercase command names for builtins -- so it is a cmdline abbreviation.
  --
  -- `mtc`, not the `m2c` that was asked for, and the reason is worth keeping:
  -- an abbreviation only fires when Vim sees it as a word, which it does not
  -- after a digit. So `:5,8m2c` never expands, and what is left runs as
  -- `:5,8move 2` -- a valid address, silently mangling the buffer ("4 lines
  -- moved", verified). Any `m` + digit spelling has that trap. `:5,8mtc` cannot
  -- parse as an address, so the same miss is a loud `E492: Not an editor
  -- command` and the buffer is untouched. Use `:M2c` when the range is numeric.
  --
  -- The guard is the other half. An unguarded `cnoreabbrev` fires on those three
  -- letters anywhere: in a search (`/mtc`), in a filename argument
  -- (`:M2c ~/mtc.csv`), inside `:normal mtc`. So it expands only when what sits
  -- in front is a *range*, which is the one place a command name can go. Marks
  -- are stripped before the test rather than matched in it, because `'a,'b`
  -- carries letters a character class would then have to admit everywhere, and
  -- admitting letters is what makes `:normal mtc` expand.
  vim.keymap.set('ca', 'mtc', function()
    local line = vim.fn.getcmdline()
    if vim.fn.getcmdtype() ~= ':' or line:sub(-3) ~= 'mtc' then
      return 'mtc'
    end
    local head = line:sub(1, -4):gsub("'[%a<>]", '')
    if head:match "^[%s%d.$%%,;+%-/?\\]*$" then
      return 'MdTableCsv'
    end
    return 'mtc'
  end, { expr = true, desc = 'Expand :mtc to :MdTableCsv' })
  vim.api.nvim_create_autocmd('FileType', {
    desc = 'Markdown table editing maps',
    group = vim.api.nvim_create_augroup('md_table', { clear = true }),
    pattern = 'markdown',
    callback = function()
      vim.keymap.set('n', '<leader>mc', M.add_column, {
        buffer = true,
        desc = '[M]arkdown table: add [c]olumn',
      })
      vim.keymap.set('n', '<leader>ma', M.align, {
        buffer = true,
        desc = '[M]arkdown table: [a]lign pipes',
      })
      vim.keymap.set('n', '<leader>ms', '<cmd>MdTableCsv<cr>', {
        buffer = true,
        desc = '[M]arkdown table: to c[s]v',
      })
      -- `:` in visual mode types the `'<,'>` itself, which is the whole point of
      -- the x-mode map: the selection becomes the range without naming it.
      vim.keymap.set('x', '<leader>ms', ':MdTableCsv<cr>', {
        buffer = true,
        desc = '[M]arkdown table: selection to c[s]v',
      })
      for key, motion in pairs(motions) do
        local direction, label = motion[1], motion[2]
        for _, mode in ipairs { 'n', 'i' } do
          vim.keymap.set(mode, key, function()
            if not M.move(direction) then
              fallback(mode, key)
            end
          end, { buffer = true, desc = 'Markdown table: cell ' .. label })
        end
      end
    end,
  })
end

return M
