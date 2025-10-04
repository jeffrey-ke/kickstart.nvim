return {
  {
    'akinsho/toggleterm.nvim',
    version = '*',
    lazy = true,
    opts = {
      -- size can be a number or a function
      size = function(term)
        if term.direction == 'horizontal' then
          return 15
        elseif term.direction == 'vertical' then
          return math.floor(vim.o.columns * 0.35)
        end
        return 20
      end,
      -- open_mapping = [[<C-\>]], -- global toggle (works in normal/insert/term)
      shade_terminals = true,
      start_in_insert = true,
      persist_size = true,
      persist_mode = true,
      direction = 'float', -- default; we’ll bind keys for others below
      float_opts = { border = 'curved' },
      close_on_exit = true,
      shell = vim.o.shell,
    },
    keys = {
      -- quick open by direction
      { '<leader>tt', '<cmd>ToggleTerm direction=float<cr>', desc = 'Terminal (float)' },
      { '<leader>tl', '<cmd>ToggleTerm direction=horizontal<cr>', desc = 'Terminal (horizontal)' },
      { '<leader>tv', '<cmd>ToggleTerm direction=vertical<cr>', desc = 'Terminal (vertical)' },
      { '<leader>tp', '<cmd>ToggleTerm direction=tab<cr>', desc = 'Terminal (tab)' },

      -- open by id (1..n). these persist, so you get “named” terminals
      { '<leader>t1', '<cmd>1ToggleTerm<cr>', desc = 'Terminal #1' },
      { '<leader>t2', '<cmd>2ToggleTerm<cr>', desc = 'Terminal #2' },

      -- run a one-off command in a float (examples)
    },
    cmd = { 'ToggleTerm', 'TermExec' },
  },
}
