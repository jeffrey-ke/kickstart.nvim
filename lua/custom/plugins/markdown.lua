return {
  'MeanderingProgrammer/render-markdown.nvim',
  opts = {
    code = {
      -- ANSI-16 Solarized has no readable "block" tone: RenderMarkdownCode links to
      -- ColorColumn = base02, only one step off the background. Render fenced blocks on
      -- the normal bg instead (full syntax contrast); keep the language label + border so
      -- blocks stay identifiable. Default was { 'diff' }; widen to all languages.
      disable_background = true,
    },
  },
}
