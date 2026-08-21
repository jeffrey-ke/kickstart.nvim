-- Follow SilverBullet [[wikilinks]] with gf.
--
-- The space (~/worklog by default) is plain markdown on disk, so page finding and
-- full-text search need nothing from this file: `sbj` opens nvim with cwd set to
-- the space, which makes kickstart's own <leader>sf and <leader>sg the page
-- picker and the grep. Only link following is missing, because 'isfname' splits a
-- target at its spaces -- a page named "vim dump aug20" makes plain gf report
-- E447 for "dump" -- and because the .md extension is implicit in a wikilink.
--
-- Link syntax per silverbullet.md/.fs/Link.md: wikilinks are ABSOLUTE, resolved
-- from the space root rather than relative to the page they sit on, so a link on
-- Journal/2026-08-20.md reaches a root page by bare name.

local M = {}

M.root = vim.fn.expand '~/worklog'

-- Every [[...]] span on the line with 1-indexed bounds, so the cursor can be
-- tested against each: one line may carry several links.
local function links(line)
  local out, init = {}, 1
  while true do
    local s, e, inner = line:find('%[%[(.-)%]%]', init)
    if not s then
      return out
    end
    out[#out + 1] = { s = s, e = e, inner = inner }
    init = e + 1
  end
end

-- [[^core#header]] / [[core@L2c3|alias]] -> core, anchor, pos.
-- Alias first, since anything may follow the '|'. Then the caret meta-page
-- marker, which is semantically transparent ([[^X]] and [[X]] are one page).
-- The core ends at the FIRST '#' or '@' -- a header may itself contain '#'.
local function parse(inner)
  local ref = inner:gsub('|.*$', ''):gsub('^%^', '')
  return ref:gsub('[#@].*$', ''), ref:match '#(.*)$', ref:match '@(.*)$'
end

local function jump(anchor, pos)
  if anchor and anchor ~= '' then
    vim.fn.search('\\v^#+\\s*' .. vim.fn.escape(anchor, '\\/.*$^~[]') .. '\\s*$', 'w')
  elseif pos then
    local l, c = pos:match '^[Ll](%d+)[Cc](%d+)$'
    l = l or pos:match '^[Ll](%d+)$'
    if l then
      pcall(vim.api.nvim_win_set_cursor, 0, { tonumber(l), (tonumber(c) or 1) - 1 })
    else
      -- @N is a 0-based character offset into the page; :goto is 1-based.
      vim.cmd('silent! goto ' .. (tonumber(pos) or 0) + 1)
    end
  end
end

function M.at_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  for _, l in ipairs(links(line)) do
    if col >= l.s and col <= l.e then
      return l
    end
  end
end

function M.follow()
  local l = M.at_cursor()
  if not l then
    return
  end
  local core, anchor, pos = parse(l.inner)
  if core ~= '' then
    -- A dangling link lands in an empty buffer whose :w creates the page, which
    -- is what clicking one in SilverBullet does.
    vim.cmd('edit ' .. vim.fn.fnameescape(M.root .. '/' .. core .. '.md'))
  end
  jump(anchor, pos)
end

-- Buffer-local so gf keeps its meaning everywhere else, and an expr map so it
-- keeps its meaning *here* too whenever the cursor is not on a wikilink.
local function attach()
  vim.keymap.set('n', 'gf', function()
    return M.at_cursor() and '<cmd>lua require("custom.sbnav").follow()<CR>' or 'gf'
  end, { expr = true, remap = true, buffer = true, desc = 'Follow SilverBullet wikilink' })
end

function M.setup(opts)
  M.root = vim.fn.expand((opts or {}).root or M.root)
  vim.api.nvim_create_autocmd('FileType', {
    desc = 'SilverBullet wikilink following inside the space',
    group = vim.api.nvim_create_augroup('sbnav', { clear = true }),
    pattern = 'markdown',
    callback = function(a)
      -- Only inside the space: these maps are meaningless in an unrelated
      -- README, and the machine without a worklog never matches at all.
      if vim.startswith(vim.api.nvim_buf_get_name(a.buf), M.root .. '/') then
        attach()
      end
    end,
  })
end

return M
