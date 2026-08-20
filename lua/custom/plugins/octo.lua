return {
  'pwntester/octo.nvim',
  cmd = 'Octo',
  dependencies = {
    'nvim-lua/plenary.nvim',
    'nvim-telescope/telescope.nvim',
    'nvim-tree/nvim-web-devicons',
  },
  keys = {
    -- The picker over every Octo verb. Bare `:Octo` reaches the same picker,
    -- but only because enable_builtin is on below; `Octo actions` says it
    -- outright.
    { '<leader>oo', '<cmd>Octo actions<cr>', desc = '[O]ct[o] actions' },
  },
  opts = {
    picker = 'telescope',
    enable_builtin = true,
  },
  config = function(_, opts)
    require('octo').setup(opts)
    -- Octo's editable regions default to a filled background, which fights
    -- catppuccin-latte.
    vim.cmd 'hi OctoEditable guibg=NONE'
  end,
}
