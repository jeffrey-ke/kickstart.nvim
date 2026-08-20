--[[

=====================================================================
==================== READ THIS BEFORE CONTINUING ====================
=====================================================================
========                                    .-----.          ========
========         .----------------------.   | === |          ========
========         |.-""""""""""""""""""-.|   |-----|          ========
========         ||                    ||   | === |          ========
========         ||   KICKSTART.NVIM   ||   |-----|          ========
========         ||                    ||   | === |          ========
========         ||                    ||   |-----|          ========
========         ||:Tutor              ||   |:::::|          ========
========         |'-..................-'|   |____o|          ========
========         `"")----------------(""`   ___________      ========
========        /::::::::::|  |::::::::::\  \ no mouse \     ========
========       /:::========|  |==hjkl==:::\  \ required \    ========
========      '""""""""""""'  '""""""""""""'  '""""""""""'   ========
========                                                     ========
=====================================================================
=====================================================================

What is Kickstart?

  Kickstart.nvim is *not* a distribution.

  Kickstart.nvim is a starting point for your own configuration.
    The goal is that you can read every line of code, top-to-bottom, understand
    what your configuration is doing, and modify it to suit your needs.

    Once you've done that, you can start exploring, configuring and tinkering to
    make Neovim your own! That might mean leaving Kickstart just the way it is for a while
    or immediately breaking it into modular pieces. It's up to you!

    If you don't know anything about Lua, I recommend taking some time to read through
    a guide. One possible example which will only take 10-15 minutes:
      - https://learnxinyminutes.com/docs/lua/

    After understanding a bit more about Lua, you can use `:help lua-guide` as a
    reference for how Neovim integrates Lua.
    - :help lua-guide
    - (or HTML version): https://neovim.io/doc/user/lua-guide.html

Kickstart Guide:

  TODO: The very first thing you should do is to run the command `:Tutor` in Neovim.

    If you don't know what this means, type the following:
      - <escape key>
      - :
      - Tutor
      - <enter key>

    (If you already know the Neovim basics, you can skip this step.)

  Once you've completed that, you can continue working through **AND READING** the rest
  of the kickstart init.lua.

  Next, run AND READ `:help`.
    This will open up a help window with some basic information
    about reading, navigating and searching the builtin help documentation.

    This should be the first place you go to look when you're stuck or confused
    with something. It's one of my favorite Neovim features.

    MOST IMPORTANTLY, we provide a keymap "<space>sh" to [s]earch the [h]elp documentation,
    which is very useful when you're not exactly sure of what you're looking for.

  I have left several `:help X` comments throughout the init.lua
    These are hints about where to find more information about the relevant settings,
    plugins or Neovim features used in Kickstart.

   NOTE: Look for lines like this

    Throughout the file. These are for you, the reader, to help you understand what is happening.
    Feel free to delete them once you know what you're doing, but they should serve as a guide
    for when you are first encountering a few different constructs in your Neovim config.

If you experience any errors while trying to install kickstart, run `:checkhealth` for more info.

I hope you enjoy your Neovim journey,
- TJ

P.S. You can delete this when you're done too. It's your config now! :)
--]]

-- Set <space> as the leader key
-- See `:help mapleader`
--  NOTE: Must happen before plugins are loaded (otherwise wrong leader will be used)
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

vim.opt.jumpoptions = 'stack'

-- Set to true if you have a Nerd Font installed and selected in the terminal
vim.g.have_nerd_font = true
vim.cmd.packadd 'cfilter'

-- [[ Setting options ]]
-- True color: colorscheme picks fixed RGB values directly, independent of
-- whatever palette the terminal emulator itself is configured with.
vim.o.termguicolors = true

-- [[ Wildmenu Configuration ]]
vim.o.wildmode = 'longest:full' -- Tab completes to longest common prefix and shows menu; next Tab cycles
vim.o.wildoptions = 'pum' -- Show completions in a popup menu (modern Neovim feature)
vim.o.wildignorecase = true -- Case-insensitive command-line completion

-- See `:help vim.o`
-- NOTE: You can change these options as you wish!
--  For more options, you can see `:help option-list`

-- Native tabline showing all listed buffers.
-- This config overrides no TabLine*/StatusLine*/UI group with a fixed color.
-- nvim_set_hl replaces a group rather than merging, so a cterm-only override
-- under termguicolors=true blanks out seoul256's own (correct) gui colors
-- entirely and the element renders with no color at all. The colorscheme owns
-- every group.
--
-- The one exception is the [+] modified badge, and it still hardcodes nothing:
-- it inverts each cell's own fg/bg pair. That reads on both the inactive cell
-- and the (teal) selected cell, and in light or dark, which no single accent
-- color does -- and it needs no maintenance when the colorscheme changes.
-- TabLine ships without an fg, so Normal fills in the gaps. cterm values are
-- set alongside gui ones so this survives a terminal without truecolor; the old
-- bug was being cterm-*only*, not setting cterm at all.
local function set_tabline_modified()
  local normal = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
  for badge, base_name in pairs { TabLineModified = 'TabLine', TabLineSelModified = 'TabLineSel' } do
    local base = vim.api.nvim_get_hl(0, { name = base_name, link = false })
    vim.api.nvim_set_hl(0, badge, {
      fg = base.bg or normal.bg,
      bg = base.fg or normal.fg,
      ctermfg = base.ctermbg or normal.ctermbg,
      ctermbg = base.ctermfg or normal.ctermfg,
      bold = true,
    })
  end
end
set_tabline_modified()
vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('tabline-modified-hl', { clear = true }),
  callback = set_tabline_modified,
})
vim.o.showtabline = 2
function _G.custom_tabline()
  local bufs = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].buflisted then
      local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':t')
      if name == '' then
        name = '[No Name]'
      end
      local is_current = buf == vim.api.nvim_get_current_buf()
      local hl = is_current and '%#TabLineSel#' or '%#TabLine#'
      -- Switch back to `hl` after the badge, or the cell's trailing space stays
      -- in the badge highlight and the chip looks ragged on the right.
      local modified = ''
      if vim.bo[buf].modified then
        modified = ' ' .. (is_current and '%#TabLineSelModified#' or '%#TabLineModified#') .. '[+]' .. hl
      end
      table.insert(bufs, hl .. ' ' .. name .. modified .. ' ')
    end
  end
  return table.concat(bufs) .. '%#TabLineFill#'
end
vim.o.tabline = '%!v:lua.custom_tabline()'

-- Make line numbers default
vim.o.number = true
-- You can also add relative line numbers, to help with jumping.
--  Experiment for yourself to see if you like it!
vim.o.relativenumber = true

-- Enable mouse mode, can be useful for resizing splits for example!
vim.o.mouse = 'a'

-- Don't show the mode, since it's already in the status line
vim.o.showmode = false

-- Sync clipboard between OS and Neovim.
--  Schedule the setting after `UiEnter` because it can increase startup-time.
--  Remove this option if you want your OS clipboard to remain independent.
--  See `:help 'clipboard'`
vim.schedule(function()
  vim.o.clipboard = 'unnamedplus'

  -- Detect SSH session (SSH_TTY often doesn't propagate into tmux)
  local function is_ssh_session()
    if vim.env.SSH_TTY or vim.env.SSH_CONNECTION or vim.env.SSH_CLIENT then
      return true
    end
    -- Check tmux's environment if we're in tmux
    if vim.env.TMUX then
      local handle = io.popen 'tmux show-environment SSH_TTY 2>/dev/null'
      if handle then
        local result = handle:read '*a'
        handle:close()
        return result and not result:match '^-' -- '-SSH_TTY' means unset
      end
    end
    return false
  end

  if is_ssh_session() then
    local function paste()
      return { vim.fn.split(vim.fn.getreg '', '\n'), vim.fn.getregtype '' }
    end
    vim.g.clipboard = {
      name = 'OSC 52',
      copy = {
        ['+'] = require('vim.ui.clipboard.osc52').copy '+',
        ['*'] = require('vim.ui.clipboard.osc52').copy '*',
      },
      paste = {
        ['+'] = paste,
        ['*'] = paste,
      },
    }
  else
    -- Neovim will auto-detect xsel (preferred) or xclip if available.
    -- No manual configuration needed - the clipboard provider handles this automatically.
  end
end)

-- Enable break indent
vim.o.breakindent = true

-- Save undo history
-- vim.o.undofile = true

-- Case-insensitive searching UNLESS \C or one or more capital letters in the search term
vim.o.ignorecase = true
vim.o.smartcase = true

-- Keep signcolumn on by default
vim.o.signcolumn = 'yes'

-- Decrease update time
vim.o.updatetime = 250

-- Decrease mapped sequence wait time
vim.o.timeoutlen = 300

-- Configure how new splits should be opened
vim.o.splitright = true
vim.o.splitbelow = true

-- Sets how neovim will display certain whitespace characters in the editor.
--  See `:help 'list'`
--  and `:help 'listchars'`
--
--  Notice listchars is set using `vim.opt` instead of `vim.o`.
--  It is very similar to `vim.o` but offers an interface for conveniently interacting with tables.
--   See `:help lua-options`
--   and `:help lua-options-guide`
vim.o.list = true
vim.opt.listchars = { tab = '» ', trail = '·', nbsp = '␣' }

-- Preview substitutions live, as you type!
vim.o.inccommand = 'split'

-- Show which line your cursor is on
vim.o.cursorline = true

-- Name a highlight group in every 'guicursor' mode. Stock nvim names none, and
-- with no group nvim never emits OSC 12, so the cursor keeps whatever color the
-- terminal draws it in and the colorscheme's `Cursor` group is dead code --
-- verified by capturing a whole nvim startup on a pty: zero `ESC]12;`, only
-- DECSCUSR shape changes. tmux advertises `ccolour` for a Ghostty client, so the
-- color reaches the outer terminal (and is restored on exit).
vim.o.guicursor = table.concat({
  'n-v-c-sm:block-Cursor/lCursor',
  'i-ci-ve:ver25-Cursor/lCursor',
  'r-cr-o:hor20-Cursor/lCursor',
  't:block-blinkon500-blinkoff500-TermCursor',
}, ',')

-- Minimal number of screen lines to keep above and below the cursor.
vim.o.scrolloff = 2

-- Always show status line for all windows (acts as horizontal separator)
vim.opt.laststatus = 3

-- if performing an operation that would fail due to unsaved changes in the buffer (like `:q`),
-- instead raise a dialog asking if you wish to save the current file(s)
-- See `:help 'confirm'`
vim.o.confirm = true

-- Folding configuration (treesitter-aware)
vim.opt.foldmethod = 'expr'
vim.opt.foldexpr = 'v:lua.vim.treesitter.foldexpr()'
vim.opt.foldlevelstart = 99
-- Keep syntax-highlighted (colored) text in the fold line instead of uniform grey.
-- An empty 'foldtext' is nvim's native way to do this (since 0.10): "foldtext is
-- disabled, and the line is displayed normally with highlighting and no line
-- wrapping" — see :help 'foldtext'. This replaces a hand-rolled foldtext function
-- that walked the treesitter highlights query to emit {text, group} chunks itself.
vim.opt.foldtext = ''

-- Soft wrap, breaking at word boundaries rather than mid-word.
vim.opt.wrap = true
vim.opt.linebreak = true

-- Automatically reload files changed outside of nvim
vim.o.autoread = true

-- [[ Basic Keymaps ]]
-- Keymaps are defined in a separate file for organization
require 'keymaps'

-- [[ Basic Autocommands ]]
--  See `:help lua-guide-autocommands`

-- Highlight when yanking (copying) text
--  Try it with `yap` in normal mode
--  See `:help vim.hl.on_yank()`
vim.api.nvim_create_autocmd('TextYankPost', {
  desc = 'Highlight when yanking (copying) text',
  group = vim.api.nvim_create_augroup('kickstart-highlight-yank', { clear = true }),
  callback = function()
    vim.hl.on_yank()
  end,
})

-- Disable automatic reindentation when typing ':'
vim.api.nvim_create_autocmd('FileType', {
  pattern = '*',
  callback = function()
    vim.opt_local.cinkeys:remove ':'
    vim.opt_local.indentkeys:remove ':'
  end,
})

-- Auto-reload files when changed externally
vim.api.nvim_create_autocmd({ 'FocusGained', 'BufEnter', 'CursorHold', 'CursorHoldI' }, {
  desc = 'Check for file changes when focus is gained or buffer is entered',
  group = vim.api.nvim_create_augroup('auto-reload', { clear = true }),
  callback = function()
    if vim.fn.mode() ~= 'c' then
      vim.cmd 'checktime'
    end
  end,
})

-- [[ Spell checking ]]
-- The Lua port of the .vimrc spell layer (dotfiles/.vimrc:57-86). Both editors
-- read the same repo-tracked word list, so a `zg` in either one travels between
-- machines.

-- 'en_us' is a *region* inside the bundled en.utf-8.spl (nvim ships it in
-- $VIMRUNTIME/spell/), so spellfile.vim never prompts to download anything.
-- British spellings are then flagged as SpellRare rather than SpellBad.
vim.o.spelllang = 'en_us'

-- Words added with zg go in the dotfiles repo so they are version-controlled.
-- nvim's default is the first 'runtimepath' entry -- i.e. this submodule, whose
-- .gitignore:6 ignores spell/ -- so zg words would be dropped on the floor.
-- expand() because 'spellfile' takes a comma-separated list of names, and the
-- '~' in one is not expanded when the value is set from Lua.
vim.opt.spellfile = vim.fn.expand '~/dotfiles/spell/en.utf-8.add'

-- Check camelCase/snake_case parts separately instead of reading an identifier
-- as one long typo.
vim.opt.spelloptions:append 'camel'

-- The .add list is plain text, but vim only ever reads the compiled .add.spl
-- beside it, and *.spl is gitignored (spell/.gitignore) as a binary artifact.
-- `zg` recompiles on add, but a fresh clone has no .add.spl at all, and a pull
-- that brings words in from another machine leaves the existing one stale -- in
-- both cases every tracked word is silently treated as a typo. getftime() is -1
-- for a missing file, so the same comparison covers both. Two stats at startup,
-- and the rebuild is rare; doing it here rather than lazily means the .spl is in
-- place before the first prose buffer loads it, so no reload dance is needed.
local spell_add = vim.fn.expand '~/dotfiles/spell/en.utf-8.add'
if vim.fn.filereadable(spell_add) == 1 and vim.fn.getftime(spell_add) > vim.fn.getftime(spell_add .. '.spl') then
  pcall(vim.cmd, 'silent! mkspell! ' .. vim.fn.fnameescape(spell_add))
end

-- Prose filetypes only -- a global 'spell' underlines every identifier in code.
-- tex/plaintex are the filetypes the myvimtex layer loads on.
vim.api.nvim_create_autocmd('FileType', {
  desc = 'Enable spell checking in prose buffers',
  group = vim.api.nvim_create_augroup('spell-prose', { clear = true }),
  pattern = { 'tex', 'plaintex', 'markdown', 'text', 'gitcommit', 'rst' },
  callback = function()
    vim.opt_local.spell = true
  end,
})

-- Journal entries are named by date (~/journal/aug18) with no extension, so they
-- get no filetype and the FileType rule above never fires; match on path
-- instead. The second 'spellfile' entry is what `2zg` writes to, keeping names
-- and one-off jargon in the journal while plain `zg` still files to the dotfiles
-- list. Words in either file count as good; the count only picks which file gets
-- written. 'spellfile' is buffer-local, so opt_local appends for this buffer.
vim.api.nvim_create_autocmd({ 'BufRead', 'BufNewFile' }, {
  desc = 'Spell-check journal entries, which vim gives no filetype',
  group = vim.api.nvim_create_augroup('spell-journal', { clear = true }),
  pattern = vim.fn.expand '~/journal/*',
  callback = function()
    vim.opt_local.spell = true
    vim.opt_local.spellfile:append(vim.fn.expand '~/journal/.spell.add')
  end,
})

-- [[ Quickfix Display ]]
-- Shorten paths in the quickfix and location-list windows: cwd-relative, then
-- `~`, then fish-style directory initials for whatever is still long
-- (`~/.l/s/n/l/r/l/r/core/ui.lua`). Reproduces Vim's own line format in every
-- other respect -- see lua/custom/qf_text.lua.
-- The lambda wrapper is required: this option takes a funcref or a function
-- *name*, and a bare `v:lua.require("...").format` parses as neither, so Vim
-- discards it and silently falls back to the built-in format -- no error, the
-- window just looks untouched.
vim.o.quickfixtextfunc = '{info -> v:lua.require("custom.qf_text").format(info)}'

-- [[ Make Configuration ]]
-- Configure :make to run linters per filetype, populating the quickfix list
vim.api.nvim_create_augroup('make-config', { clear = true })

-- Python: use pylint for warnings (unused vars, bad patterns) and pyright for type errors
-- Pylint with --disable=E,R,C shows only W (warnings) and F (fatal)
-- Pyright handles E-level issues (undefined variables, type mismatches)
vim.api.nvim_create_autocmd('FileType', {
  group = 'make-config',
  pattern = 'python',
  callback = function()
    vim.bo.makeprg = 'pyright %'
    vim.bo.errorformat = '%\\ %#%f:%l:%c - %trror: %m,%\\ %#%f:%l:%c - %tarning: %m,%-G%.%#'
  end,
})

-- Helper function to get all open Python buffer paths
local function get_python_buffers()
  local paths = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == 'python' then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= '' and vim.fn.filereadable(name) == 1 then
        table.insert(paths, vim.fn.shellescape(name))
      end
    end
  end
  return table.concat(paths, ' ')
end

-- Custom :Make command for Python that lints all open Python buffers
vim.api.nvim_create_user_command('Make', function()
  local python_files = get_python_buffers()
  if python_files == '' then
    vim.notify('No Python buffers open', vim.log.levels.WARN)
    return
  end
  local cmd = 'pyright ' .. python_files
  vim.opt.errorformat = '%\\ %#%f:%l:%c - %trror: %m,%\\ %#%f:%l:%c - %tarning: %m,%-G%.%#'
  vim.cmd('cexpr system("' .. cmd:gsub('"', '\\"') .. '")')
  vim.cmd 'copen'
end, { desc = 'Run pylint and pyright on all open Python buffers' })

-- C/C++: use the compiler directly (errors will populate quickfix)
-- Note: For more advanced static analysis, consider adding cppcheck or clang-tidy
vim.api.nvim_create_autocmd('FileType', {
  group = 'make-config',
  pattern = { 'c', 'cpp' },
  callback = function()
    -- Uses gcc/g++ by default; adjust if you have a Makefile
    local compiler = vim.bo.filetype == 'cpp' and 'g++' or 'gcc'
    vim.bo.makeprg = compiler .. ' -Wall -Wextra -fsyntax-only %'
    vim.bo.errorformat = '%f:%l:%c: %t%*[^:]: %m,%f:%l: %t%*[^:]: %m'
  end,
})

-- [[ Custom Commands ]]

-- Close all buffers except current (skip terminals)
vim.api.nvim_create_user_command('Bon', function(opts)
  local current_buf = vim.api.nvim_get_current_buf()
  local exclusion_patterns = opts.fargs

  local function matches_exclusion(bufname)
    for _, pattern in ipairs(exclusion_patterns) do
      if bufname:find(pattern, 1, true) then
        return true
      end
    end
    return false
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted then
      if buf ~= current_buf then
        if vim.bo[buf].buftype ~= 'terminal' then
          local bufname = vim.api.nvim_buf_get_name(buf)
          if not matches_exclusion(bufname) then
            pcall(vim.api.nvim_buf_delete, buf, { force = false })
          end
        end
      end
    end
  end
end, { nargs = '*', desc = 'Close all buffers except current and patterns (skip terminals)' })

-- [[ Install `lazy.nvim` plugin manager ]]
--    See `:help lazy.nvim.txt` or https://github.com/folke/lazy.nvim for more info
local lazypath = vim.fn.stdpath 'data' .. '/lazy/lazy.nvim'
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = 'https://github.com/folke/lazy.nvim.git'
  local out = vim.fn.system { 'git', 'clone', '--filter=blob:none', '--branch=stable', lazyrepo, lazypath }
  if vim.v.shell_error ~= 0 then
    error('Error cloning lazy.nvim:\n' .. out)
  end
end

---@type vim.Option
local rtp = vim.opt.rtp
rtp:prepend(lazypath)

-- [[ Configure and install plugins ]]
--
--  To check the current status of your plugins, run
--    :Lazy
--
--  You can press `?` in this menu for help. Use `:q` to close the window
--
--  To update plugins you can run
--    :Lazy update
--
-- NOTE: Here is where you install your plugins.
require('lazy').setup({
  -- NOTE: Plugins can be added with a link (or for a github repo: 'owner/repo' link).
  'NMAC427/guess-indent.nvim', -- Detect tabstop and shiftwidth automatically
  'tpope/vim-fugitive',
  'tpope/vim-eunuch',

  {
    'folke/persistence.nvim',
    event = 'BufReadPre',
    opts = {},
  },

  -- NOTE: Plugins can also be added by using a table,
  -- with the first argument being the link and the following
  -- keys can be used to configure plugin behavior/loading/etc.
  --
  -- Use `opts = {}` to automatically pass options to a plugin's `setup()` function, forcing the plugin to be loaded.
  --

  -- Alternatively, use `config = function() ... end` for full control over the configuration.
  -- If you prefer to call `setup` explicitly, use:
  --    {
  --        'lewis6991/gitsigns.nvim',
  --        config = function()
  --            require('gitsigns').setup({
  --                -- Your gitsigns configuration here
  --            })
  --        end,
  --    }
  --
  -- Here is a more advanced example where we pass configuration
  -- options to `gitsigns.nvim`.
  --
  -- See `:help gitsigns` to understand what the configuration keys do
  { -- Adds git related signs to the gutter, as well as utilities for managing changes
    'lewis6991/gitsigns.nvim',
    opts = {
      signs = {
        add = { text = '+' },
        change = { text = '~' },
        delete = { text = '_' },
        topdelete = { text = '‾' },
        changedelete = { text = '~' },
      },
    },
  },

  -- NOTE: Plugins can also be configured to run Lua code when they are loaded.
  --
  -- This is often very useful to both group configuration, as well as handle
  -- lazy loading plugins that don't need to be loaded immediately at startup.
  --
  -- For example, in the following configuration, we use:
  --  event = 'VimEnter'
  --
  -- which loads which-key before all the UI elements are loaded. Events can be
  -- normal autocommands events (`:help autocmd-events`).
  --
  -- Then, because we use the `opts` key (recommended), the configuration runs
  -- after the plugin has been loaded as `require(MODULE).setup(opts)`.

  { -- Useful plugin to show you pending keybinds.
    'folke/which-key.nvim',
    event = 'VimEnter', -- Sets the loading event to 'VimEnter'
    opts = {
      -- delay between pressing a key and opening which-key (milliseconds)
      -- this setting is independent of vim.o.timeoutlen
      delay = 0,
      icons = {
        -- set icon mappings to true if you have a Nerd Font
        mappings = vim.g.have_nerd_font,
        -- If you are using a Nerd Font: set icons.keys to an empty table which will use the
        -- default which-key.nvim defined Nerd Font icons, otherwise define a string table
        keys = vim.g.have_nerd_font and {} or {
          Up = '<Up> ',
          Down = '<Down> ',
          Left = '<Left> ',
          Right = '<Right> ',
          C = '<C-…> ',
          M = '<M-…> ',
          D = '<D-…> ',
          S = '<S-…> ',
          CR = '<CR> ',
          Esc = '<Esc> ',
          ScrollWheelDown = '<ScrollWheelDown> ',
          ScrollWheelUp = '<ScrollWheelUp> ',
          NL = '<NL> ',
          BS = '<BS> ',
          Space = '<Space> ',
          Tab = '<Tab> ',
          F1 = '<F1>',
          F2 = '<F2>',
          F3 = '<F3>',
          F4 = '<F4>',
          F5 = '<F5>',
          F6 = '<F6>',
          F7 = '<F7>',
          F8 = '<F8>',
          F9 = '<F9>',
          F10 = '<F10>',
          F11 = '<F11>',
          F12 = '<F12>',
        },
      },

      -- Document existing key chains
      spec = {
        { '<leader>c', group = 'Quickfix' },
        { '<leader>s', group = '[S]earch' },
        { '<leader>t', group = '[T]oggle' },
        { '<leader>h', group = 'Git [H]unk', mode = { 'n', 'v' } },
      },
    },
  },

  -- NOTE: Plugins can specify dependencies.
  --
  -- The dependencies are proper plugin specifications as well - anything
  -- you do for a plugin at the top level, you can do for a dependency.
  --
  -- Use the `dependencies` key to specify the dependencies of a particular plugin

  { -- Fuzzy Finder (files, lsp, etc)
    'nvim-telescope/telescope.nvim',
    event = 'VimEnter',
    dependencies = {
      'nvim-lua/plenary.nvim',
      { -- If encountering errors, see telescope-fzf-native README for installation instructions
        'nvim-telescope/telescope-fzf-native.nvim',

        -- `build` is used to run some command when the plugin is installed/updated.
        -- This is only run then, not every time Neovim starts up.
        build = 'make',

        -- `cond` is a condition used to determine whether this plugin should be
        -- installed and loaded.
        cond = function()
          return vim.fn.executable 'make' == 1
        end,
      },
      { 'nvim-telescope/telescope-ui-select.nvim' },

      -- Useful for getting pretty icons, but requires a Nerd Font.
      { 'nvim-tree/nvim-web-devicons', enabled = vim.g.have_nerd_font },
    },
    config = function()
      -- Telescope is a fuzzy finder that comes with a lot of different things that
      -- it can fuzzy find! It's more than just a "file finder", it can search
      -- many different aspects of Neovim, your workspace, LSP, and more!
      --
      -- The easiest way to use Telescope, is to start by doing something like:
      --  :Telescope help_tags
      --
      -- After running this command, a window will open up and you're able to
      -- type in the prompt window. You'll see a list of `help_tags` options and
      -- a corresponding preview of the help.
      --
      -- Two important keymaps to use while in Telescope are:
      --  - Insert mode: <c-/>
      --  - Normal mode: ?
      --
      -- This opens a window that shows you all of the keymaps for the current
      -- Telescope picker. This is really useful to discover what Telescope can
      -- do as well as how to actually do it!

      -- [[ Configure Telescope ]]
      -- See `:help telescope` and `:help telescope.setup()`
      require('telescope').setup {
        -- You can put your default mappings / updates / etc. in here
        --  All the info you're looking for is in `:help telescope.setup()`
        --
        defaults = {
          mappings = {
            i = { -- Insert mode mappings
              ['<C-j>'] = 'move_selection_next',
              ['<C-k>'] = 'move_selection_previous',
            },
            n = { -- Normal mode mappings
              ['<C-j>'] = 'move_selection_next',
              ['<C-k>'] = 'move_selection_previous',
            },
          },
        },
        pickers = {
          find_files = {
            hidden = true,
          },
          -- Give the quickfix picker the same paths `:copen` shows, so the two
          -- views of one list don't disagree. A function `path_display`
          -- short-circuits Telescope's own path handling, hence the shortening
          -- also does the cwd-relativizing (lua/custom/qf_text.lua).
          --
          -- Same idea for the ordering: Telescope's default
          -- `sorting_strategy = 'descending'` grows the list upward from the
          -- prompt, so with an empty prompt (all scores equal, insertion order
          -- kept) quickfix entry 1 lands at the *bottom* — `:copen` read
          -- backwards. 'ascending' puts entry 1 on the top row, and moving the
          -- prompt up with it keeps the first entry next to where you type
          -- instead of a rows-tall gap when the list is short.
          quickfix = {
            path_display = function(_, path)
              return require('custom.qf_text').shorten(path)
            end,
            sorting_strategy = 'ascending',
            layout_config = { prompt_position = 'top' },
          },
        },
        extensions = {
          ['ui-select'] = {
            require('telescope.themes').get_dropdown(),
          },
        },
      }

      -- Enable Telescope extensions if they are installed
      pcall(require('telescope').load_extension, 'fzf')
      pcall(require('telescope').load_extension, 'ui-select')

      -- See `:help telescope.builtin`
      local builtin = require 'telescope.builtin'
      vim.keymap.set('n', '<leader>sh', builtin.help_tags, { desc = '[S]earch [H]elp' })
      vim.keymap.set('n', '<leader>sk', builtin.keymaps, { desc = '[S]earch [K]eymaps' })
      vim.keymap.set('n', '<leader>sf', builtin.find_files, { desc = '[S]earch [F]iles' })
      vim.keymap.set('n', '<leader>ss', builtin.builtin, { desc = '[S]earch [S]elect Telescope' })
      vim.keymap.set('n', '<leader>sw', builtin.grep_string, { desc = '[S]earch current [W]ord' })
      vim.keymap.set('n', '<leader>sg', builtin.live_grep, { desc = '[S]earch by [G]rep' })
      vim.keymap.set('n', '<leader>sd', builtin.diagnostics, { desc = '[S]earch [D]iagnostics' })
      vim.keymap.set('n', '<leader>sr', builtin.resume, { desc = '[S]earch [R]esume' })
      vim.keymap.set('n', '<leader>s.', builtin.oldfiles, { desc = '[S]earch Recent Files ("." for repeat)' })
      -- Fuzzy-filter the current quickfix list; <leader>sQ picks an older list
      -- out of the ten-deep history (`:h quickfix-error-lists`), which is the
      -- part `:copen` alone gives no way to reach.
      vim.keymap.set('n', '<leader>sq', builtin.quickfix, { desc = '[S]earch [Q]uickfix list' })
      vim.keymap.set('n', '<leader>sQ', builtin.quickfixhistory, { desc = '[S]earch [Q]uickfix history' })
      vim.keymap.set('n', '<leader><leader>', builtin.buffers, { desc = '[ ] Find existing buffers' })

      -- Slightly advanced example of overriding default behavior and theme
      vim.keymap.set('n', '<leader>/', function()
        -- You can pass additional configuration to Telescope to change the theme, layout, etc.
        builtin.current_buffer_fuzzy_find(require('telescope.themes').get_dropdown {
          winblend = 10,
          previewer = false,
        })
      end, { desc = '[/] Fuzzily search in current buffer' })

      -- It's also possible to pass additional configuration options.
      --  See `:help telescope.builtin.live_grep()` for information about particular keys
      vim.keymap.set('n', '<leader>s/', function()
        builtin.live_grep {
          grep_open_files = true,
          prompt_title = 'Live Grep in Open Files',
        }
      end, { desc = '[S]earch [/] in Open Files' })

      -- Shortcut for searching your Neovim configuration files
      vim.keymap.set('n', '<leader>sn', function()
        builtin.find_files { cwd = vim.fn.stdpath 'config' }
      end, { desc = '[S]earch [N]eovim files' })
    end,
  },

  -- LSP Plugins
  {
    -- `lazydev` configures Lua LSP for your Neovim config, runtime and plugins
    -- used for completion, annotations and signatures of Neovim apis
    'folke/lazydev.nvim',
    ft = 'lua',
    opts = {
      library = {
        -- Load luvit types when the `vim.uv` word is found
        { path = '${3rd}/luv/library', words = { 'vim%.uv' } },
      },
    },
  },
  {
    -- Main LSP Configuration
    'neovim/nvim-lspconfig',
    dependencies = {
      -- Automatically install LSPs and related tools to stdpath for Neovim
      -- Mason must be loaded before its dependents so we need to set it up here.
      -- NOTE: `opts = {}` is the same as calling `require('mason').setup({})`
      { 'mason-org/mason.nvim', opts = {} },
      'mason-org/mason-lspconfig.nvim',
      'WhoIsSethDaniel/mason-tool-installer.nvim',

      -- Useful status updates for LSP.
      { 'j-hui/fidget.nvim', opts = {} },

      -- Allows extra capabilities provided by blink.cmp
      'saghen/blink.cmp',
    },
    config = function()
      -- Brief aside: **What is LSP?**
      --
      -- LSP is an initialism you've probably heard, but might not understand what it is.
      --
      -- LSP stands for Language Server Protocol. It's a protocol that helps editors
      -- and language tooling communicate in a standardized fashion.
      --
      -- In general, you have a "server" which is some tool built to understand a particular
      -- language (such as `gopls`, `lua_ls`, `rust_analyzer`, etc.). These Language Servers
      -- (sometimes called LSP servers, but that's kind of like ATM Machine) are standalone
      -- processes that communicate with some "client" - in this case, Neovim!
      --
      -- LSP provides Neovim with features like:
      --  - Go to definition
      --  - Find references
      --  - Autocompletion
      --  - Symbol Search
      --  - and more!
      --
      -- Thus, Language Servers are external tools that must be installed separately from
      -- Neovim. This is where `mason` and related plugins come into play.
      --
      -- If you're wondering about lsp vs treesitter, you can check out the wonderfully
      -- and elegantly composed help section, `:help lsp-vs-treesitter`

      --  This function gets run when an LSP attaches to a particular buffer.
      --    That is to say, every time a new file is opened that is associated with
      --    an lsp (for example, opening `main.rs` is associated with `rust_analyzer`) this
      --    function will be executed to configure the current buffer
      vim.api.nvim_create_autocmd('LspAttach', {
        group = vim.api.nvim_create_augroup('kickstart-lsp-attach', { clear = true }),
        callback = function(event)
          -- NOTE: Remember that Lua is a real programming language, and as such it is possible
          -- to define small helper and utility functions so you don't have to repeat yourself.
          --
          -- In this case, we create a function that lets us more easily define mappings specific
          -- for LSP related items. It sets the mode, buffer and description for us each time.
          local map = function(keys, func, desc, mode)
            mode = mode or 'n'
            vim.keymap.set(mode, keys, func, { buffer = event.buf, desc = 'LSP: ' .. desc })
          end

          -- Rename the variable under your cursor.
          --  Most Language Servers support renaming across files, etc.
          map('grn', vim.lsp.buf.rename, '[R]e[n]ame')

          -- Execute a code action, usually your cursor needs to be on top of an error
          -- or a suggestion from your LSP for this to activate.
          map('gra', vim.lsp.buf.code_action, '[G]oto Code [A]ction', { 'n', 'x' })

          map('grD', vim.lsp.buf.declaration, '[G]oto [D]eclaration')

          local has_telescope, telescope_builtin = pcall(require, 'telescope.builtin')
          if has_telescope then
            map('grr', telescope_builtin.lsp_references, '[G]oto [R]eferences')
            map('gri', telescope_builtin.lsp_implementations, '[G]oto [I]mplementation')
            map('grd', telescope_builtin.lsp_definitions, '[G]oto [D]efinition')
            map('gO', telescope_builtin.lsp_document_symbols, 'Open Document Symbols')
            map('gW', telescope_builtin.lsp_dynamic_workspace_symbols, 'Open Workspace Symbols')
            map('grt', telescope_builtin.lsp_type_definitions, '[G]oto [T]ype Definition')
          end

          -- This function resolves a difference between neovim nightly (version 0.11) and stable (version 0.10)
          ---@param client vim.lsp.Client
          ---@param method vim.lsp.protocol.Method
          ---@param bufnr? integer some lsp support methods only in specific files
          ---@return boolean
          local function client_supports_method(client, method, bufnr)
            if vim.fn.has 'nvim-0.11' == 1 then
              return client:supports_method(method, bufnr)
            else
              return client.supports_method(method, { bufnr = bufnr })
            end
          end

          -- The following two autocommands are used to highlight references of the
          -- word under your cursor when your cursor rests there for a little while.
          --    See `:help CursorHold` for information about when this is executed
          --
          -- When you move your cursor, the highlights will be cleared (the second autocommand).
          local client = vim.lsp.get_client_by_id(event.data.client_id)
          if client and client_supports_method(client, vim.lsp.protocol.Methods.textDocument_documentHighlight, event.buf) then
            local highlight_augroup = vim.api.nvim_create_augroup('kickstart-lsp-highlight', { clear = false })
            vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, {
              buffer = event.buf,
              group = highlight_augroup,
              callback = vim.lsp.buf.document_highlight,
            })

            vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
              buffer = event.buf,
              group = highlight_augroup,
              callback = vim.lsp.buf.clear_references,
            })

            vim.api.nvim_create_autocmd('LspDetach', {
              group = vim.api.nvim_create_augroup('kickstart-lsp-detach', { clear = true }),
              callback = function(event2)
                vim.lsp.buf.clear_references()
                vim.api.nvim_clear_autocmds { group = 'kickstart-lsp-highlight', buffer = event2.buf }
              end,
            })
          end

          -- The following code creates a keymap to toggle inlay hints in your
          -- code, if the language server you are using supports them
          --
          -- This may be unwanted, since they displace some of your code
          if client and client_supports_method(client, vim.lsp.protocol.Methods.textDocument_inlayHint, event.buf) then
            map('<leader>th', function()
              vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled { bufnr = event.buf })
            end, '[T]oggle Inlay [H]ints')
          end
        end,
      })

      -- Diagnostic Config
      -- See :help vim.diagnostic.Opts
      vim.diagnostic.config {
        severity_sort = true,
        float = { border = 'rounded', source = 'if_many' },
        underline = { severity = vim.diagnostic.severity.ERROR },
        signs = vim.g.have_nerd_font and {
          text = {
            [vim.diagnostic.severity.ERROR] = '󰅚 ',
            [vim.diagnostic.severity.WARN] = '󰀪 ',
            [vim.diagnostic.severity.INFO] = '󰋽 ',
            [vim.diagnostic.severity.HINT] = '󰌶 ',
          },
        } or {},
        virtual_text = {
          source = 'if_many',
          spacing = 2,
          format = function(diagnostic)
            local diagnostic_message = {
              [vim.diagnostic.severity.ERROR] = diagnostic.message,
              [vim.diagnostic.severity.WARN] = diagnostic.message,
              [vim.diagnostic.severity.INFO] = diagnostic.message,
              [vim.diagnostic.severity.HINT] = diagnostic.message,
            }
            return diagnostic_message[diagnostic.severity]
          end,
        },
      }

      -- LSP servers and clients are able to communicate to each other what features they support.
      --  By default, Neovim doesn't support everything that is in the LSP specification.
      --  When you add blink.cmp, luasnip, etc. Neovim now has *more* capabilities.
      --  So, we create new capabilities with blink.cmp, and then broadcast that to the servers.
      local capabilities = require('blink.cmp').get_lsp_capabilities()

      -- Enable the following language servers
      --  Feel free to add/remove any LSPs that you want here. They will automatically be installed.
      --
      --  Add any additional override configuration in the following tables. Available keys are:
      --  - cmd (table): Override the default command used to start the server
      --  - filetypes (table): Override the default list of associated filetypes for the server
      --  - capabilities (table): Override fields in capabilities. Can be used to disable certain LSP features.
      --  - settings (table): Override the default settings passed when initializing the server.
      --        For example, to see the options for `lua_ls`, you could go to: https://luals.github.io/wiki/settings/
      local servers = {
        clangd = {
          cmd = {
            'clangd',
            '--background-index',
            '--clang-tidy',
            '--header-insertion=iwyu',
            '--completion-style=detailed',
            '--function-arg-placeholders',
            '--fallback-style=llvm',
          },
          init_options = {
            usePlaceholders = true,
            completeUnimported = true,
            clangdFileStatus = true,
          },
          root_dir = function(fname)
            return require('lspconfig.util').root_pattern('Makefile', 'configure.in', 'configure.ac', '.git')(fname)
              or require('lspconfig.util').path.dirname(fname)
          end,
        },
        -- gopls = {},
        -- pyright = {},
        bashls = {},
        -- rust_analyzer = {},
        -- ... etc. See `:help lspconfig-all` for a list of all the pre-configured LSPs
        --
        -- Some languages (like typescript) have entire language plugins that can be useful:
        --    https://github.com/pmizio/typescript-tools.nvim
        --
        -- But for many setups, the LSP (`ts_ls`) will work just fine
        -- ts_ls = {},
        --

        lua_ls = {
          -- cmd = { ... },
          -- filetypes = { ... },
          -- capabilities = {},
          settings = {
            Lua = {
              completion = {
                callSnippet = 'Replace',
              },
              -- You can toggle below to ignore Lua_LS's noisy `missing-fields` warnings
              -- diagnostics = { disable = { 'missing-fields' } },
            },
          },
        },
      }

      -- Ensure the servers and tools above are installed
      --
      -- To check the current status of installed tools and/or manually install
      -- other tools, you can run
      --    :Mason
      --
      -- You can press `g?` for help in this menu.
      --
      -- `mason` had to be setup earlier: to configure its options see the
      -- `dependencies` table for `nvim-lspconfig` above.
      --
      -- You can add other tools here that you want Mason to install
      -- for you, so that they are available from within Neovim.
      local ensure_installed = vim.tbl_keys(servers or {})
      vim.list_extend(ensure_installed, {
        'stylua', -- Used to format Lua code
      })
      require('mason-tool-installer').setup { ensure_installed = ensure_installed }

      require('mason-lspconfig').setup {
        ensure_installed = {}, -- explicitly set to an empty table (Kickstart populates installs via mason-tool-installer)
        automatic_installation = false,
        handlers = {
          function(server_name)
            local server = servers[server_name] or {}
            -- This handles overriding only values explicitly passed
            -- by the server configuration above. Useful when disabling
            -- certain features of an LSP (for example, turning off formatting for ts_ls)
            server.capabilities = vim.tbl_deep_extend('force', {}, capabilities, server.capabilities or {})
            require('lspconfig')[server_name].setup(server)
          end,
        },
      }

      -- Safety autocommand to detach clangd from git buffers if it somehow attaches
      vim.api.nvim_create_autocmd({ 'BufEnter', 'FileType' }, {
        group = vim.api.nvim_create_augroup('git-lsp-prevention', { clear = true }),
        callback = function(event)
          local bufnr = event.buf
          local bufname = vim.api.nvim_buf_get_name(bufnr)
          local filetype = vim.bo[bufnr].filetype
          local buftype = vim.bo[bufnr].buftype

          -- Check if this is a git buffer that clangd shouldn't handle
          local is_git_buffer = bufname:match '^fugitive://'
            or vim.tbl_contains({ 'fugitive', 'fugitiveblame', 'git', 'gitcommit', 'gitrebase', 'gitconfig' }, filetype)
            or buftype ~= ''
            or bufname:match '/.git/'
            or bufname:match '%.git/MERGE_MSG'
            or bufname:match '%.git/COMMIT_EDITMSG'

          if is_git_buffer then
            local clients = vim.lsp.get_clients { bufnr = bufnr, name = 'clangd' }
            for _, client in pairs(clients) do
              vim.lsp.buf_detach_client(bufnr, client.id)
            end
          end
        end,
      })

      -- Toggle clangd LSP command
      vim.api.nvim_create_user_command('ToggleClangd', function()
        local clients = vim.lsp.get_clients { name = 'clangd' }

        if #clients > 0 then
          -- Clangd is running, stop it
          for _, client in pairs(clients) do
            vim.lsp.stop_client(client.id)
          end
          vim.notify('Clangd stopped', vim.log.levels.INFO)
        else
          -- Clangd is not running, start it
          local bufnr = vim.api.nvim_get_current_buf()
          local filetype = vim.bo[bufnr].filetype

          if filetype == 'c' or filetype == 'cpp' or filetype == 'objc' or filetype == 'objcpp' then
            require('lspconfig').clangd.setup(servers.clangd or {})
            vim.defer_fn(function()
              vim.cmd 'LspStart clangd'
            end, 100)
            vim.notify('Clangd started', vim.log.levels.INFO)
          else
            vim.notify('Not a C/C++ file', vim.log.levels.WARN)
          end
        end
      end, { desc = 'Toggle clangd LSP on/off' })
    end,
  },

  { -- Autoformat
    'stevearc/conform.nvim',
    event = { 'BufWritePre' },
    cmd = { 'ConformInfo' },
    keys = {
      {
        '<leader>f',
        function()
          require('conform').format { async = true, lsp_format = 'fallback' }
        end,
        mode = '',
        desc = '[F]ormat buffer',
      },
    },
    opts = {
      notify_on_error = false,
      format_on_save = function(bufnr)
        -- Disable "format_on_save lsp_fallback" for languages that don't
        -- have a well standardized coding style. You can add additional
        -- languages here or re-enable it for the disabled ones.
        local disable_filetypes = { c = true, cpp = true }
        if disable_filetypes[vim.bo[bufnr].filetype] then
          return nil
        else
          return {
            timeout_ms = 500,
            lsp_format = 'fallback',
          }
        end
      end,
      formatters_by_ft = {
        lua = { 'stylua' },
        -- Conform can also run multiple formatters sequentially
        -- python = { "isort", "black" },
        --
        -- You can use 'stop_after_first' to run the first available formatter from the list
        -- javascript = { "prettierd", "prettier", stop_after_first = true },
      },
    },
  },

  { -- Autocompletion
    'saghen/blink.cmp',
    event = 'VimEnter',
    version = '1.*',
    dependencies = {
      -- Snippet Engine
      {
        'L3MON4D3/LuaSnip',
        version = '2.*',
        build = (function()
          -- Build Step is needed for regex support in snippets.
          -- This step is not supported in many windows environments.
          -- Remove the below condition to re-enable on windows.
          if vim.fn.has 'win32' == 1 or vim.fn.executable 'make' == 0 then
            return
          end
          return 'make install_jsregexp'
        end)(),
        dependencies = {
          -- `friendly-snippets` contains a variety of premade snippets.
          --    See the README about individual language/framework/plugin snippets:
          --    https://github.com/rafamadriz/friendly-snippets
          -- {
          --   'rafamadriz/friendly-snippets',
          --   config = function()
          --     require('luasnip.loaders.from_vscode').lazy_load()
          --   end,
          -- },
        },
        opts = { enable_autosnippets = true },
        config = function(_, opts)
          require('luasnip').setup(opts)
          -- Given nil paths, from_lua scans the runtimepath for `luasnippets/`
          -- dirs, so this also picks up ours at the config root.
          require('luasnip.loaders.from_lua').load()
        end,
      },
      'folke/lazydev.nvim',
    },
    --- @module 'blink.cmp'
    --- @type blink.cmp.Config
    opts = {
      keymap = {
        -- 'default' (recommended) for mappings similar to built-in completions
        --   <c-y> to accept ([y]es) the completion.
        --    This will auto-import if your LSP supports it.
        --    This will expand snippets if the LSP sent a snippet.
        -- 'super-tab' for tab to accept
        -- 'enter' for enter to accept
        -- 'none' for no mappings
        --
        -- For an understanding of why the 'default' preset is recommended,
        -- you will need to read `:help ins-completion`
        --
        -- No, but seriously. Please read `:help ins-completion`, it is really good!
        --
        -- All presets have the following mappings:
        -- <tab>/<s-tab>: move to right/left of your snippet expansion
        -- <c-space>: Open menu or open docs if already open
        -- <c-n>/<c-p> or <up>/<down>: Select next/previous item
        -- <c-e>: Hide menu
        -- <c-k>: Toggle signature help
        --
        -- See :h blink-cmp-config-keymap for defining your own keymap
        preset = 'enter',

        -- Override preset mappings
        ['<C-j>'] = { 'select_next', 'fallback' },
        ['<C-k>'] = { 'select_prev', 'fallback' },
        -- For more advanced Luasnip keymaps (e.g. selecting choice nodes, expansion) see:
        --    https://github.com/L3MON4D3/LuaSnip?tab=readme-ov-file#keymaps
      },

      appearance = {
        -- 'mono' (default) for 'Nerd Font Mono' or 'normal' for 'Nerd Font'
        -- Adjusts spacing to ensure icons are aligned
        nerd_font_variant = 'mono',
      },

      completion = {
        -- By default, you may press `<c-space>` to show the documentation.
        -- Optionally, set `auto_show = true` to show the documentation after a delay.
        documentation = { auto_show = false, auto_show_delay_ms = 500 },
      },

      sources = {
        default = { 'lsp', 'path', 'snippets', 'buffer', 'lazydev' },
        providers = {
          lazydev = { module = 'lazydev.integrations.blink', score_offset = 100 },
          -- Without this, snippets keep blink.cmp's built-in -1 default while
          -- buffer is boosted to 10 below, so buffer-word matches outrank
          -- snippet triggers (e.g. typing "item" would rank the literal word
          -- "item" from elsewhere in the buffer above the itemize snippet).
          snippets = { score_offset = 15 },
          buffer = {
            score_offset = 10,
            opts = {
              get_bufnrs = function()
                return vim.tbl_filter(function(bufnr)
                  return vim.bo[bufnr].buflisted and vim.api.nvim_buf_is_loaded(bufnr)
                end, vim.api.nvim_list_bufs())
              end,
            },
          },
        },
      },

      snippets = { preset = 'luasnip' },

      -- Blink.cmp includes an optional, recommended rust fuzzy matcher,
      -- which automatically downloads a prebuilt binary when enabled.
      --
      -- By default, we use the Lua implementation instead, but you may enable
      -- the rust implementation via `'prefer_rust_with_warning'`
      --
      -- See :h blink-cmp-config-fuzzy for more information
      fuzzy = { implementation = 'lua' },

      -- Shows a signature help window while you type arguments for a function
      signature = { enabled = true },

      cmdline = {
        enabled = false, -- Use native wildmenu instead (see wildmode above)
      },
    },
  },

  { -- catppuccin, true-color mode: flavour names double as dark/light colorschemes.
    -- One plugin, unlike seoul256's two separate repos: catppuccin-latte is the
    -- light flavour, catppuccin-mocha the dark one.
    'catppuccin/nvim',
    name = 'catppuccin',
    priority = 1000, -- Make sure to load this before all the other start plugins.
    config = function()
      require('catppuccin').setup {
        -- Leave every cell's background to the terminal, which is what lets
        -- tmux's inactive-pane dimming reach nvim at all: `window-style` only
        -- recolors cells an application left at default fg/bg. Measured with a
        -- pty capture of an inactive pane -- opaque `Normal` forwarded nvim's
        -- own bg and none of tmux's dim colors; `Normal bg=NONE` emitted them
        -- throughout. Floats stay opaque (`float.transparent` defaults false),
        -- so hover and completion windows still read as raised panels.
        transparent_background = true,
        custom_highlights = function(colors)
          -- Light vs dark is read off the palette handed in, not off
          -- &background: catppuccin compiles every flavour in one pass, so a
          -- &background test would bake one answer into both flavours' cached
          -- files. The red channel of `base` separates them cleanly.
          local dark = tonumber(colors.base:sub(2, 3), 16) < 0x80
          return {
            -- Catppuccin's CursorLine is a 64% blend of surface0 back toward
            -- the base: 6/255 per channel from `Normal` in latte, so the line
            -- is enabled but invisible. An unblended surface is the contrast,
            -- and with a transparent background it is the only thing marking
            -- the cursor's row.
            CursorLine = { bg = dark and colors.surface1 or colors.surface0 },
            CursorLineNr = { fg = colors.lavender, bold = true },
            -- The terminal-cursor look: the block takes the foreground color
            -- and the character under it the background, which reads at full
            -- contrast in both flavours. Catppuccin ships rosewater here --
            -- in latte a pale salmon block under off-white text, 2.6:1.
            Cursor = { fg = colors.base, bg = colors.text },
            lCursor = { fg = colors.base, bg = colors.text },
            TermCursor = { fg = colors.base, bg = colors.text },
          }
        end,
      }
      -- Deliberately no `vim.o.background = ...` here, and deliberately the
      -- flavour-agnostic `catppuccin` colorscheme rather than a flavour name:
      -- nvim detects the terminal's background over OSC 11 at startup, but only
      -- honors the reply while 'background' has never been assigned. Measured in
      -- a pane whose OSC 11 answer is light -- `--cmd 'set background=dark'`
      -- keeps nvim dark for the session, the same pane with 'background'
      -- untouched flips to light. `:colorscheme catppuccin-latte` counts as such
      -- an assignment (its compiled chunk sets 'background' whenever it is
      -- called with a flavour), whereas plain `catppuccin` under the default
      -- `flavour = 'auto'` reads &background and leaves it alone. So the terminal
      -- decides, and :ToggleBackground still overrides by hand.
      vim.cmd.colorscheme 'catppuccin'
      vim.o.termguicolors = true -- defensive re-assert in case a later plugin flips it off

      -- Reload catppuccin whenever &background changes: absorbs nvim's async
      -- OSC-11 startup detection and drives :ToggleBackground. nested=true is
      -- required so the ColorScheme autocmds (statusline etc.) re-fire.
      local reloading = false
      vim.api.nvim_create_autocmd('OptionSet', {
        pattern = 'background',
        nested = true,
        callback = function()
          if reloading then
            return
          end
          reloading = true
          vim.cmd.colorscheme 'catppuccin' -- flavour follows &background
          reloading = false
        end,
      })
    end,
  },

  -- Highlight todo, notes, etc in comments
  { 'folke/todo-comments.nvim', event = 'VimEnter', dependencies = { 'nvim-lua/plenary.nvim' }, opts = { signs = false } },

  { -- Collection of various small independent plugins/modules
    'echasnovski/mini.nvim',
    config = function()
      -- Better Around/Inside textobjects
      --
      -- Examples:
      --  - va)  - [V]isually select [A]round [)]paren
      --  - yinq - [Y]ank [I]nside [N]ext [Q]uote
      --  - ci'  - [C]hange [I]nside [']quote
      require('mini.ai').setup { n_lines = 500 }

      -- Add/delete/replace surroundings (brackets, quotes, etc.)
      --
      -- - saiw) - [S]urround [A]dd [I]nner [W]ord [)]Paren
      -- - sd'   - [S]urround [D]elete [']quotes
      -- - sr)'  - [S]urround [R]eplace [)] [']
      require('mini.surround').setup()

      -- Simple and easy statusline.
      --  You could remove this setup call if you don't like it,
      --  and try some other statusline plugin
      local statusline = require 'mini.statusline'
      -- set use_icons to true if you have a Nerd Font
      statusline.setup { use_icons = vim.g.have_nerd_font }

      ---@diagnostic disable-next-line: duplicate-set-field
      statusline.active = function()
        local mode, mode_hl = statusline.section_mode { trunc_width = 120 }
        local git = statusline.section_git { trunc_width = 75 }
        local diagnostics = statusline.section_diagnostics { trunc_width = 75 }
        local path = vim.fn.expand '%:.'
        if path == '' then
          path = '[No Name]'
        end
        local filename = path .. (vim.bo.modified and '[+]' or '') .. (vim.bo.readonly and '[RO]' or '')
        local pwd = vim.fn.getcwd():gsub('^' .. vim.env.HOME, '~')

        -- Only the mode section is colored, by mini's own MiniStatuslineMode*
        -- groups; everything after it resets to StatusLine so the colorscheme
        -- owns the bar. The section layout is the customization here, not the hues.
        local s = '%#' .. mode_hl .. '# ' .. mode .. ' %#StatusLine#'
        if git ~= '' then
          s = s .. ' ' .. git .. ' '
        end
        if diagnostics ~= '' then
          s = s .. ' ' .. diagnostics .. ' '
        end
        s = s .. '%< ' .. pwd .. ' '
        s = s .. '%= %2l:%-2v  ' .. filename .. ' '
        return s
      end

      -- ... and there is more!
      --  Check out: https://github.com/echasnovski/mini.nvim
    end,
  },
  { -- Highlight, edit, and navigate code
    'nvim-treesitter/nvim-treesitter',
    build = ':TSUpdate',
    -- Pin the branch. nvim-treesitter's default branch is now `main`, a ground-up
    -- rewrite with no `nvim-treesitter.configs` module — so without this, lazy
    -- resolves the update target from remotes/origin/HEAD and `:Lazy update` would
    -- move this checkout onto the rewrite, breaking the `main`/`opts` block below.
    -- (`:Lazy restore` was never the risk: it checks out the lockfile's commit.)
    -- master declares "Neovim 0.10 or 0.11 (Neovim 0.12 is not supported)" and we
    -- are on 0.12.4, so this is a holding action — it works today, but the real
    -- resolutions are migrating to `main` or following upstream kickstart, which
    -- has since dropped lazy.nvim for `vim.pack` entirely.
    branch = 'master',
    -- One concrete casualty of that 0.12 mismatch, repaired before the plugin's
    -- query_predicates module registers anything: master still asks core for the
    -- `all = false` (one-node-per-capture) handler signature that 0.12 dropped.
    init = function()
      require 'custom.ts_predicate_compat'()
    end,
    main = 'nvim-treesitter.configs', -- Sets main module to use for opts
    -- [[ Configure Treesitter ]] See `:help nvim-treesitter`
    opts = {
      ensure_installed = { 'bash', 'c', 'diff', 'html', 'lua', 'luadoc', 'markdown', 'markdown_inline', 'query', 'vim', 'vimdoc' },
      -- Autoinstall languages that are not installed
      auto_install = true,
      highlight = {
        enable = true,
        -- Some languages depend on vim's regex highlighting system (such as Ruby) for indent rules.
        --  If you are experiencing weird indenting issues, add the language to
        --  the list of additional_vim_regex_highlighting and disabled languages for indent.
        additional_vim_regex_highlighting = { 'ruby' },
        -- VimTeX's own :syntax-based highlighting (and its conceal feature,
        -- e.g. \alpha -> α) only attaches if treesitter isn't already
        -- highlighting the buffer -- confirmed via vimtex's maintainer
        -- (github.com/lervag/vimtex issue #3131): disabling treesitter
        -- highlighting for latex specifically is the documented fix.
        disable = { 'latex' },
      },
      indent = { enable = true, disable = { 'ruby' } },
    },
    -- There are additional nvim-treesitter modules that you can use to interact
    -- with nvim-treesitter. You should go explore a few and see what interests you:
    --
    --    - Incremental selection: Included, see `:help nvim-treesitter-incremental-selection-mod`
    --    - Show your current context: https://github.com/nvim-treesitter/nvim-treesitter-context
    --    - Treesitter + textobjects: https://github.com/nvim-treesitter/nvim-treesitter-textobjects
  },

  -- The following comments only work if you have downloaded the kickstart repo, not just copy pasted the
  -- init.lua. If you want these files, they are in the repository, so you can just download them and
  -- place them in the correct locations.

  -- NOTE: Next step on your Neovim journey: Add/Configure additional plugins for Kickstart
  --
  --  Here are some example plugins that I've included in the Kickstart repository.
  --  Uncomment any of the lines below to enable them (you will need to restart nvim).
  --
  -- require 'kickstart.plugins.debug',
  -- require 'kickstart.plugins.indent_line',
  -- require 'kickstart.plugins.lint',
  -- require 'kickstart.plugins.autopairs',
  require 'kickstart.plugins.neo-tree',
  -- require 'kickstart.plugins.gitsigns', -- adds gitsigns recommend keymaps
  -- NOTE: The import below can automatically add your own plugins, configuration, etc from `lua/custom/plugins/*.lua`
  --    This is the easiest way to modularize your config.
  --
  --  Uncomment the following line and add your plugins to `lua/custom/plugins/*.lua` to get going.
  { import = 'custom.plugins' },
  -- myvimtex: the LaTeX layer, a dotfiles-submodule lazy plugin; every
  -- spec inside is ft = 'tex', so coding sessions never source any of it.
  -- ~/.config/nvim resolves into the dotfiles root; the submodule sits
  -- beside this config there.
  { dir = vim.fs.dirname(vim.fn.resolve(vim.fn.stdpath 'config')) .. '/myvimtex',
    import = 'latex.plugins' },
  --
  -- For additional information with loading, sourcing and examples see `:help lazy.nvim-🔌-plugin-spec`
  -- Or use telescope!
  -- In normal mode type `<space>sh` then write `lazy.nvim-plugin`
  -- you can continue same window with `<space>sr` which resumes last telescope search
}, {
  ui = {
    -- If you are using a Nerd Font: set icons to an empty table which will use the
    -- default lazy.nvim defined Nerd Font icons, otherwise define a unicode icons table
    icons = vim.g.have_nerd_font and {} or {
      cmd = '⌘',
      config = '🛠',
      event = '📅',
      ft = '📂',
      init = '⚙',
      keys = '🗝',
      plugin = '🔌',
      runtime = '💻',
      require = '🌙',
      source = '📄',
      start = '🚀',
      task = '📌',
      lazy = '💤 ',
    },
  },
})
-- Make snacks.nvim terminals transparent (Claude Code terminal).
-- Inside a ColorScheme autocmd, not a bare call: :colorscheme runs :hi clear
-- first, so a one-shot override at startup is wiped by the first
-- :ToggleBackground. Applied once here too, since seoul256 has already loaded.
local function set_snacks_transparent()
  vim.api.nvim_set_hl(0, 'SnacksNormal', { bg = 'NONE' })
  vim.api.nvim_set_hl(0, 'SnacksNormalNC', { bg = 'NONE' })
end
set_snacks_transparent()
vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('snacks-transparent', { clear = true }),
  callback = set_snacks_transparent,
})

-- Match nvim's light/dark mode to the terminal theme after flipping it.
-- The OptionSet autocmd (colorscheme spec) does the actual seoul256 reload.
local function toggle_background()
  vim.o.background = vim.o.background == 'dark' and 'light' or 'dark'
  vim.notify('Background: ' .. vim.o.background, vim.log.levels.INFO)
end
vim.api.nvim_create_user_command('ToggleBackground', toggle_background, { desc = 'Flip light/dark to match terminal theme' })
vim.keymap.set('n', '<leader>tb', toggle_background, { desc = '[T]oggle [B]ackground (light/dark)' })

-- The line beneath this is called `modeline`. See `:help modeline`
-- vim: ts=2 sts=2 sw=2 et
