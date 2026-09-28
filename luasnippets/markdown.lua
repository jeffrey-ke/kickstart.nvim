local ls = require 'luasnip'
local s = ls.snippet
local t = ls.text_node
local i = ls.insert_node
local d = ls.dynamic_node
local sn = ls.snippet_node
local fmt = require('luasnip.extras.fmt').fmt
local conds = require 'luasnip.extras.conditions.expand'

-- `[text](url)`: fmt only treats `{}` as a placeholder, so the brackets and
-- parens are literal and the two tab stops are the visible label (i1) then
-- the target (i2). A snippet takes a single trigger, and its nodes can't be
-- shared between two snippets, so this builds a fresh set per trigger. `trig`
-- goes straight to `s()`, which takes either a bare string or an opts table --
-- that is how the `;url` autosnippet below reuses this with a `desc`.
local function link(trig)
  return s(trig, fmt('[{}]({})', { i(1, 'text'), i(2, 'url') }))
end

-- `[[Page]]`: SilverBullet wikilinks are absolute, resolved from the space root
-- rather than relative to the page they sit on (same fact sbnav.lua relies on),
-- so the tab stop takes a bare name or a `Folder/Page` path. Deliberately a
-- word trigger and not an autosnippet on `[[`: that sequence is also Lua's
-- long-string delimiter, which SilverBullet uses for its query blocks -- the
-- space's own index.md has four `${query[[` and Calendar.md builds wikilinks
-- with `string.format("[[%s|%d]]", ...)`. LuaSnip has no context guard
-- equivalent to SilverBullet's own `exceptContexts`, so `[[` would misfire on
-- real content.
local function wikilink(trig)
  return s(trig, fmt('[[{}]]', { i(1, 'Page') }))
end

-- Nodes for one `| a | b |` table line: `cell(c)` supplies column c's node,
-- the pipes and single-space padding are literal. These snippets only have to
-- get the *number* of pipes right: single-space padding is the narrowest legal
-- cell, and `<leader>ma` (md_table.lua's align()) is what widens the columns to
-- match once there is content to measure.
local function row(n, cell)
  local nodes = { t '| ' }
  for c = 1, n do
    if c > 1 then
      table.insert(nodes, t ' | ')
    end
    table.insert(nodes, cell(c))
  end
  table.insert(nodes, t ' |')
  return nodes
end

-- Header + delimiter + one empty body row for `tbl<N>`. N comes from the
-- trigger's regex capture, not from another node, so there's nothing to pass
-- as dynamic_node's node_references arg. Tab stops run left-to-right across
-- the header (1..n), then the body row (n+1..2n).
local function table_nodes(_, snip)
  local n = tonumber(snip.captures[1]) or 2
  local nodes = row(n, function(c)
    return i(c, 'h' .. c)
  end)
  -- A text_node's list is its lines, so the leading and trailing "" wrap the
  -- delimiter in the newlines that separate it from the two rows.
  table.insert(nodes, t { '', '|' .. (' --- |'):rep(n), '' })
  vim.list_extend(
    nodes,
    row(n, function(c)
      return i(n + c)
    end)
  )
  return sn(nil, nodes)
end

-- Column count for `trow`, read off the delimiter row of the table above the
-- expansion point. The delimiter is the authority: the markdown grammar only
-- recognises a table when the header and delimiter agree on cell count, while
-- body rows are free to be short (their missing cells render empty), so
-- counting the nearest row above would inherit any raggedness.
--
-- Scan up from the expansion point through the contiguous run of `|` lines,
-- skipping blanks first so this also works with the cursor a line below the
-- table. Cell count is (pipes - 1) for a `| a | b |` line, which a literal `|`
-- inside inline code would throw off.
local function columns_above(line_number)
  -- No line number means we aren't expanding: LuaSnip also evaluates this
  -- dynamic_node to build the snippet's docstring (the completion-menu preview
  -- blink.cmp asks for), and `env` is only populated on a real expansion, so
  -- `TM_LINE_NUMBER` is nil there. Bail out to the caller's default rather than
  -- counting pipes in whatever buffer happens to be current.
  if not line_number then
    return nil
  end

  local function line_at(n)
    return vim.trim(vim.api.nvim_buf_get_lines(0, n - 1, n, false)[1] or '')
  end

  local lnum = line_number - 1
  while lnum >= 1 and line_at(lnum) == '' do
    lnum = lnum - 1
  end

  -- Walk to the top of the `|` run, remembering the last row seen so a
  -- one-line-tall "table" (no delimiter yet) still yields a count.
  local last_row = nil
  while lnum >= 1 do
    local line = line_at(lnum)
    if line:sub(1, 1) ~= '|' or line:sub(-1) ~= '|' then
      break
    end
    last_row = line
    lnum = lnum - 1
  end
  if not last_row then
    return nil
  end

  -- lnum now sits just above the block, so its second line is the delimiter.
  local delimiter = line_at(lnum + 2)
  local row = (delimiter:match '^|[%s:%-|]+|$' and delimiter) or last_row
  local _, pipes = row:gsub('|', '')
  return pipes - 1
end

-- Cell 1 takes a placeholder where the other cells take bare tab stops. A row
-- whose every cell is blank only parses as the *first* body row of a table, and
-- `trow` by definition appends to a table that already has one: an all-empty row
-- puts the markdown grammar into an ERROR node, drops the row out of the tree,
-- and render-markdown.nvim stops rendering the whole table until something is
-- typed into it. LuaSnip pre-selects placeholder text, so the first keystroke
-- replaces the `.` and it costs nothing in the normal case; tabbing straight past
-- leaves one visible character rather than an invisibly broken table.
--
-- `.` and not `-`: a dash-only cell reads as a second delimiter row and breaks
-- the parse just the same. Verified 2026-09-01 against both nvim 0.12.4's bundled
-- markdown parser and nvim-treesitter's -- they agree, so this is the grammar and
-- not a stale parser build.
local function row_nodes(_, snip)
  local n = columns_above(tonumber(snip.env.TM_LINE_NUMBER)) or 3
  return sn(
    nil,
    row(n, function(c)
      return c == 1 and i(c, '.') or i(c)
    end)
  )
end

local snippets = {
  link 'link',
  link 'li',
  -- Same shape with the leading `!` for an inline image embed.
  s('img', fmt('![{}]({})', { i(1, 'alt'), i(2, 'url') })),
  wikilink 'wiki',
  wikilink 'wl',
  -- Plain trigger, so it gets a real label in blink.cmp's menu and can wait
  -- for an explicit expand -- unlike `tbl<N>` below.
  s({ trig = 'trow', desc = 'Table row matching the table above' }, { d(1, row_nodes, {}), i(0) }),
}

local autosnippets = {
  -- Regex-triggered snippets default their completion-menu label to the raw
  -- Lua pattern (e.g. "tbl(%d+)"), which can't fuzzy-match what you type
  -- (e.g. "tbl4") in blink.cmp's popup. Living here instead expands it via the
  -- InsertCharPre -> expand_auto() hook, the moment the trigger matches,
  -- bypassing the completion menu entirely. Same reasoning as `item(%d+)` in
  -- myvimtex's tex.lua.
  s({ trig = 'tbl(%d+)', regTrig = true }, { d(1, table_nodes, {}), t { '', '' }, i(0) }),
  -- `- [ ] ` checkbox item. render-markdown.nvim substitutes the icon from an
  -- extmark over the literal `[ ]`, so the snippet emits no icon of its own --
  -- just the marker and the space that separates it from the item text. A
  -- plain text_node, so there is no tab stop to jump out of before typing.
  --
  -- The `;` prefix is what makes a homerow trigger safe here: an autosnippet
  -- fires the instant it matches, with no menu to decline it, and no markdown
  -- line begins with a semicolon -- whereas bare `dd` would also swallow the
  -- start of any line where those really were the first two characters. It
  -- also leaves room for a `;`-prefixed family of markdown autosnippets.
  --
  -- `conds.line_begin` permits only whitespace before the trigger, which is
  -- what lets indented sub-todos expand while confining the trigger to the
  -- one position where a list marker can legally start.
  s({ trig = ';dd', desc = 'Todo checkbox item' }, t '- [ ] ', { condition = conds.line_begin }),
  -- `;url` is `link` under an autosnippet trigger: same two tab stops, expanded
  -- the moment it matches rather than waiting to be picked out of a menu, which
  -- is the whole point of a `;` trigger -- same reasoning as `;dd`. No
  -- `line_begin` condition: a link belongs mid-sentence as often as at the start
  -- of one.
  --
  -- It used to fill the target from the `+` register on the theory that the URL
  -- was already copied out of a browser. It isn't, in this setup: init.lua's OSC
  -- 52 provider can only *write* the terminal clipboard (the escape sequence has
  -- no reply), so init.lua points its paste half at the unnamed register and
  -- `getreg '+'` returns the last thing yanked inside nvim instead. The URL
  -- sniff let anything shaped like a URL through, so the failure was a wrong
  -- link silently pasted into the parens, not an empty one -- worse than typing
  -- it. Paste over the `url` tab stop when the clipboard really does hold it.
  link { trig = ';url', desc = 'Link with an empty URL to fill in' },
}

return snippets, autosnippets
