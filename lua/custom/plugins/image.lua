return {
  '3rd/image.nvim',
  build = false, -- so that it doesn't build the rock https://github.com/3rd/image.nvim/issues/91#issuecomment-2453430239
  opts = {
    processor = 'magick_cli',
    tmux_show_only_in_active_window = true,
    max_width_window_percentage = 100,
    max_height_window_percentage = 100,
  },
  config = function(_, opts)
    require('image').setup(opts)
    vim.api.nvim_create_autocmd('VimLeavePre', {
      callback = function()
        require('image').clear()
      end,
    })
  end,
}
