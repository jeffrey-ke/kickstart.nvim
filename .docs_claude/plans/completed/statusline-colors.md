# Statusline overhaul — colors, path, splits

Changes made to `init.lua` (mini.statusline config block + the `ColorScheme` autocmd near line 113).

## What was done

| Change | Detail |
|---|---|
| Relative path in filename section | `vim.fn.expand('%:.')` — path relative to nvim's cwd, same dir shown on far right |
| Removed filetype + encoding | Dropped `section_fileinfo` (was showing "python", "utf-8", etc.) |
| Single global statusline | `laststatus=3` — one bar shared across all splits |
| Per-section colors | filename: lavender (189), git/diag: green (114), location: gold (179), cwd: cyan (117 bold) |

The active function is overridden directly on the module table (`statusline.active = function() ... end`), which is the same table exposed as `_G.MiniStatusline`. The statusline format string (`v:lua.MiniStatusline.active()`) calls through the table, so the override takes effect immediately.

## Bug: highlights wiped by colorscheme load

**Symptom:** `vim.cmd 'hi StatusLineFile ctermfg=189 ...'` inside mini.nvim's `config = function()` had no effect — no colors appeared despite the correct format codes in the statusline string.

**Cause:** mini.nvim's plugin `config` runs during lazy.nvim setup. `vim.cmd [[colorscheme vim]]` at line ~1274 fires the `ColorScheme` event *after* plugin setup completes. `:colorscheme` does `:hi clear` first, wiping every highlight not defined inside a `ColorScheme` autocmd. Our groups were defined once during plugin config and then silently cleared.

**Fix:** Moved all four `StatusLine*` highlight definitions into the existing `ColorScheme` autocmd near line 113 (where `TabLineSel` / `TabLineModified` are already defined for the same reason). They now survive every colorscheme reload.

## Pattern worth remembering

Any highlight group that must survive a `:colorscheme` call must be set inside a `ColorScheme` autocmd, not at plugin-config time or at module load time. Plugin `config` functions run before `colorscheme vim` fires `ColorScheme`, so groups set there get wiped. The canonical place in this config is the autocmd around line 113.

Also: with `termguicolors = false`, `fg = '#hexcolor'` in `nvim_set_hl` is silently ignored. Use `ctermfg = <number>` or `vim.cmd 'hi Group ctermfg=N'`.
