-- Quickfix/location-list display: paths relative to the cwd.
--
-- The built-in display prints each entry's buffer name verbatim, so an entry's
-- path is as long as whatever created it happened to pass. Anything that feeds
-- `setqflist` from `nvim_buf_get_name` hands over an absolute path -- `:Make`
-- (init.lua's pyright command), LSP handlers, and Claude pushing a list of code
-- pointers -- and then every line of the window is 40 columns of
-- `/home/jke/...` before the part worth reading. `gD`/`:Def` escape it only
-- because rg is given a relative search path.
--
-- `quickfixtextfunc` is the supported hook (`:h quickfix-window-function`). It
-- owns the *whole* line, not just the path, so the rest of this reproduces
-- Vim's own format exactly -- `qf_fill_buffer` and `qf_types` in quickfix.c,
-- cross-checked against the built-in output entry shape by entry shape:
--
--   init.lua|10 col 5| under cwd            plain
--   init.lua|10-12 col 5-9| range           end_lnum/end_col
--   init.lua|1 col 1 error   7| ...         type + nr, nr right-aligned to 3
--   MyModule|2 col 1| ...                   module wins over the filename
--   init.lua|| ...                          lnum 0: no position, no type
--   || no file at all                       no buffer
--
-- Keeping that shape matters beyond looks: the `qf` syntax file highlights on
-- the two `|` separators, and `:cc`/`<CR>` still navigate by list index rather
-- than by parsing the line, so a wrong format would only ever look wrong.
--
-- Only the path differs, in two steps. `:~:.` prefers a cwd-relative path and
-- falls back to `~/...` -- resolved at display time, so entries re-render
-- against the current cwd after a `:cd`. Then anything still over
-- `PATH_BUDGET` has its directories collapsed to initials from the left.
--
-- Worth knowing: nvim's *default* display is already cwd-relative -- it
-- re-shortens each buffer name against the current cwd, even for entries built
-- from an absolute path or a bare bufnr. So the paths this actually changes are
-- the ones reaching outside the cwd, which is where the long paths were.
--
-- Abbreviating the display is safe because nothing downstream parses the line:
-- `<CR>`/`:cc` navigate by list index, and `:Cfilter` matches
-- `bufname(item.bufnr)` -- the real path -- so `:Cfilter render-markdown` still
-- selects an entry rendered as `~/.l/s/n/l/r/l/r/core/ui.lua`. Both verified.

local M = {}

--- Vim's qf_types(): the ` error`/` warning`/... tag plus a right-aligned nr.
---@param type string
---@param nr integer
---@return string
local function type_and_nr(type, nr)
  local tag
  local c = type:lower()
  if c == 'w' then
    tag = ' warning'
  elseif c == 'i' then
    tag = ' info'
  elseif c == 'n' then
    tag = ' note'
  elseif c == 'e' or (type == '' and nr > 0) then
    tag = ' error'
  elseif type == '' then
    tag = ''
  else
    tag = ' ' .. type -- an unrecognized type is shown as its bare letter
  end
  return nr > 0 and ('%s %3d'):format(tag, nr) or tag
end

--- lnum[-end_lnum][ col col[-end_col]], or the search pattern when lnum is 0.
---@param item table
---@return string
local function position(item)
  if item.lnum == 0 then
    return item.pattern or ''
  end
  local pos = tostring(item.lnum)
  if item.end_lnum > item.lnum then
    pos = pos .. '-' .. item.end_lnum
  end
  if item.col > 0 then
    pos = pos .. ' col ' .. item.col
    if item.end_col > item.col then
      pos = pos .. '-' .. item.end_col
    end
  end
  return pos .. type_and_nr(item.type, item.nr)
end

-- Widest path shown in full. Past it, directory components collapse to their
-- initial -- the trick fish's prompt_pwd and bash-git-prompt use -- until the
-- path fits. The one knob here; raise it for wider windows.
local PATH_BUDGET = 40

--- A directory component as its initial, keeping any leading dots so `.local`
--- collapses to `.l` rather than to a bare `.` that reads as "this directory".
--- Falls out nicely for the components that must not be touched: `~`, `.`, `..`,
--- and the empty leading component of an absolute path all map to themselves.
---@param component string
---@return string
local function initial(component)
  local dots, rest = component:match '^(%.*)(.*)$'
  return dots .. rest:sub(1, 1)
end

--- Collapse directory components from the left until the path fits the budget.
--- Left to right because the rightmost components are the identifying ones: the
--- filename is never touched, and its nearest directories are given up last, so
--- what survives in full is what tells two same-named files apart.
---@param path string
---@return string
local function abbreviate(path)
  if #path <= PATH_BUDGET then
    return path
  end
  local parts = vim.split(path, '/')
  local len = #path
  for i = 1, #parts - 1 do
    if len <= PATH_BUDGET then
      break
    end
    local short = initial(parts[i])
    len = len - (#parts[i] - #short)
    parts[i] = short
  end
  return table.concat(parts, '/')
end

--- The whole path pipeline: cwd-relative, else `~`, then directory initials for
--- whatever is still over budget. Public so the Telescope quickfix picker can
--- render a path the same way this window does -- Telescope formats paths itself
--- and would otherwise disagree with the `:copen` view of the same list.
---@param path string
---@return string
function M.shorten(path)
  if path == '' then
    return ''
  end
  return abbreviate(vim.fn.fnamemodify(path, ':~:.'))
end

--- @param item table
--- @return string
local function display_path(item)
  -- `module` is a caller-supplied label, not a path; never rewrite it.
  if item.module ~= '' then
    return item.module
  end
  if item.bufnr == 0 then
    return ''
  end
  return M.shorten(vim.fn.bufname(item.bufnr))
end

--- `quickfixtextfunc`. See `:h quickfix-window-function` for the info dict.
---@param info table
---@return string[]
function M.format(info)
  local what = { id = info.id, items = 0 }
  local list = info.quickfix == 1 and vim.fn.getqflist(what) or vim.fn.getloclist(info.winid, what)

  local lines = {}
  for i = info.start_idx, info.end_idx do
    local item = list.items[i]
    -- Text is one line: an embedded newline would silently split the entry off
    -- from its index, and leading indentation just pushes the message right.
    local text = item.text:gsub('%s*\n%s*', ' '):gsub('^%s+', '')
    table.insert(lines, ('%s|%s| %s'):format(display_path(item), position(item), text))
  end
  return lines
end

return M
