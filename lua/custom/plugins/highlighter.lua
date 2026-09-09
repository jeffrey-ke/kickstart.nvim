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
-- only `line,col` -- no file path -- so `:Hi load` replays those coordinates
-- into whichever buffer happens to be current. The wrappers below fix that by
-- naming the save file after the buffer's own path, auto-loading it, and
-- autosaving -- deleting the store when the last highlight goes, so a deleted
-- highlight never comes back.
return {
  'azabiong/vim-highlighter',
  -- Eager: the BufWinEnter restore below fires for the file passed on the
  -- command line, which is earlier than VeryLazy would have loaded `:Hi`.
  lazy = false,
  init = function()
    -- Keep the store out of ~/.config (the default is $HOME/.config/keywords,
    -- which is dotfiles territory) and out of any repo.
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

    local annot = function()
      return require 'custom.annot'
    end

    vim.keymap.set('n', '<leader>Hs', function()
      annot().save()
    end, { desc = '[H]ighlights: [s]ave for this file' })
    vim.keymap.set('n', '<leader>Hl', function()
      annot().load(false)
    end, { desc = '[H]ighlights: [l]oad for this file' })

    local group = vim.api.nvim_create_augroup('highlighter-persist', { clear = true })

    -- Restore on open. Window-scoped like the save itself, guarded so
    -- revisiting a buffer does not stack duplicates.
    vim.api.nvim_create_autocmd('BufWinEnter', {
      group = group,
      callback = function()
        if vim.b.hi_restored then
          return
        end
        vim.b.hi_restored = true
        annot().load(true)
      end,
      desc = 'Load saved highlights for this file',
    })

    -- Autosave. Adds and deletes made through our own keys already write
    -- through; these catch the rest (`f<CR>` patterns, `:Hi` used directly).
    vim.api.nvim_create_autocmd({ 'BufWinLeave', 'BufWritePost' }, {
      group = group,
      callback = function()
        annot().autosave()
      end,
      desc = 'Save highlights for this file',
    })
    vim.api.nvim_create_autocmd('VimLeavePre', {
      group = group,
      callback = function()
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          vim.api.nvim_win_call(win, function()
            annot().autosave()
          end)
        end
      end,
      desc = 'Save highlights in every window before quitting',
    })
  end,
  config = function()
    -- After the plugin is sourced, so this mapping wins the t<CR> slot.
    require('custom.annot').use_pen_for_hi_keys()
  end,
}
