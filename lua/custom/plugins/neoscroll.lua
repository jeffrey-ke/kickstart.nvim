return {
  'karb94/neoscroll.nvim',
  event = 'VeryLazy',
  config = function()
    local neoscroll = require 'neoscroll'

    neoscroll.setup {}

    -- Set up keymaps
    local keymap = vim.keymap.set
    keymap('n', '<leader>u', function()
      neoscroll.ctrl_u { duration = 250 }
    end, { desc = 'Scroll up' })
    keymap('n', '<leader>d', function()
      neoscroll.ctrl_d { duration = 250 }
    end, { desc = 'Scroll down' })
  end,
}
