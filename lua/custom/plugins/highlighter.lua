-- vim-highlighter -- highlighter-pen marking of arbitrary regions.
--
-- Two different features share one plugin, and only the second is the one worth
-- having here:
--   * `f<CR>`  pattern highlight -- colors *every* occurrence of a word/regex.
--   * `t<CR>`  positional highlight -- colors the exact span you selected. This
--              is `nvim_buf_set_extmark` with `end_row`/`end_col` underneath, so
--              the mark rides the text: "the position is updated when inserting
--              or deleting the line above". A multiline selection is promoted to
--              positional automatically.
--
-- Persistence is manual and, out of the box, badly footgunned: `:Hi save` with
-- no name writes a single shared `_.hl`, and a saved positional highlight stores
-- only `line,col` -- no file path, no text -- so `:Hi load` replays those
-- coordinates into whichever buffer happens to be current, on whatever now sits
-- at those lines. custom/hi_store.lua replaces it: one JSON per file keyed by
-- repo root commit + relative path (so a worktree sees the same washes), with
-- custom/versions.lua keeping the file text the positions are exact for and
-- mapping them through the diff when the file changes underneath (a checkout,
-- a pull, a formatter). Loaded on BufReadPost, autosaved -- deleting the store
-- when the last wash goes, so an erased wash never comes back. Pattern
-- highlights are not persisted; `:Hi save` still does that by hand if wanted.
return {
  'azabiong/vim-highlighter',
  -- Eager: the BufReadPost restore fires for the file passed on the command
  -- line, which is earlier than VeryLazy would have loaded the plugin.
  lazy = false,
  init = function()
    -- The plugin still wants a directory for `:Hi save`; keep it out of
    -- ~/.config (the default is $HOME/.config/keywords, which is dotfiles
    -- territory) and out of any repo. hi_store's files live under it too.
    local dir = vim.fs.joinpath(vim.fn.stdpath 'data', 'highlighter')
    vim.fn.mkdir(dir, 'p')
    vim.g.HiKeywords = dir

    -- Suppress the plugin's own mappings for the three keys that *mutate*
    -- highlights; plugin/highlighter.vim skips any key whose g: override is
    -- empty, and custom/annot.lua redefines them so that setting one uses the
    -- global pen and any change is persisted on the spot. f<CR> (pattern
    -- highlight) and f<Tab> (find) are left to the plugin.
    vim.g.HiSetSL = '' -- t<CR>
    vim.g.HiErase = '' -- f<BS>
    vim.g.HiClear = '' -- f<C-L>

    vim.keymap.set('n', '<leader>Hs', function()
      require('custom.hi_store').save()
    end, { desc = '[H]ighlights: [s]ave for this file' })
    vim.keymap.set('n', '<leader>Hl', function()
      require('custom.versions').remap(0)
    end, { desc = "[H]ighlights: re[l]oad this file's marks from disk" })

    -- The autocmds that load, detach and persist -- for washes and haunt's
    -- notes alike -- live in versions.lua, since one snapshot serves both.
    require('custom.versions').setup()
    require('custom.hi_store').setup()
  end,
  config = function()
    -- After the plugin is sourced, so this mapping wins the t<CR> slot.
    require('custom.annot').use_pen_for_hi_keys()
  end,
}
