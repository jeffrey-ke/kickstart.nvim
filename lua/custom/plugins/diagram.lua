-- Renders ```mermaid fences in markdown to inline PNGs, via image.nvim.
--
-- The chain is: diagram.nvim finds the fence -> shells out to `mmdc` -> image.nvim
-- hands the PNG to the terminal. Every link has an out-of-editor prerequisite:
--   * `mmdc`        -- ~/.local/bin/mmdc, a shim over ~/.local/lib/mermaid-cli that
--                      points puppeteer at the system Chrome (install-tools.sh).
--   * ImageMagick   -- image.nvim's magick_cli processor needs `convert`+`identify`
--                      (v6 is fine) purely to read the PNG's dimensions.
--   * a terminal    -- kitty graphics protocol. Ghostty/kitty/WezTerm yes,
--                      gnome-terminal no. Inside tmux this also needs
--                      `allow-passthrough on`, already set in .tmux.conf.
-- Any one missing degrades to a plain code block, not an error.
--
-- Note this does NOT need the `mermaid` treesitter parser: the markdown integration
-- queries the *markdown* parser for `(fenced_code_block (info_string) @info ...)` and
-- matches the info string as a plain word. The mermaid parser only buys highlighting
-- inside the fence while you type.
return {
  '3rd/diagram.nvim',
  dependencies = { '3rd/image.nvim' },
  ft = 'markdown',
  opts = {
    renderer_options = {
      mermaid = {
        -- Matches catppuccin's transparent_background, so a diagram sits on the
        -- normal buffer bg like render-markdown's code blocks do.
        background = 'transparent',
        -- Read once, at load. mermaid bakes text colour into the PNG, and the cache
        -- key is sha256 of the *source* alone (renderers/mermaid.lua:24), so a later
        -- :ToggleBackground will not re-render what is already cached -- clear
        -- ~/.cache/nvim/diagram-cache to pick up a flip.
        theme = vim.o.background == 'light' and 'default' or 'dark',
        scale = 2,
      },
    },
  },
  keys = {
    { '<leader>md', function() require('diagram').render() end, ft = 'markdown', desc = '[M]arkdown re-render [D]iagrams' },
    { '<leader>mD', function() require('diagram').clear() end, ft = 'markdown', desc = '[M]arkdown clear [D]iagrams' },
  },
}
