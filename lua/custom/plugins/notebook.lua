-- Jupyter notebooks without Jupyter's UI: jupytext.nvim opens a .ipynb as a `# %%` script,
-- NotebookNavigator moves between cells and sends them, molten runs them in a kernel and
-- draws each cell's output (plots via image.nvim) in a float under the cell.
-- custom/notebook_cells.lua draws and folds the cells themselves.
--
-- Out-of-editor prerequisites:
--   * molten's Python host, a venv at stdpath('data')/molten-venv:
--       uv venv --python 3.12 <venv>
--       uv pip install --python <venv>/bin/python pynvim jupyter_client nbformat jupytext \
--         pillow requests websocket-client
--     then `:UpdateRemotePlugins` once. The venv's bin/ also supplies the `jupytext` CLI.
--   * a Jupyter server to make the kernel. Monorepo kernels have to come from a Bazel
--     `notebook_server_local` binary, so molten asks a server for one instead of using a
--     kernelspec. molten POSTs /api/kernels without an _xsrf token (jupyter_server_api.py),
--     so the server must run with XSRF checks off; notebook_server.py forwards no extra flags,
--     so that goes in through a private config dir rather than the global ~/.jupyter:
--       JUPYTER_CONFIG_DIR=<data>/jupyter-config \
--         bazel run --config cloudbench -c opt //learning/behavior/tools/notebooks:joint_ilp_mh_notebook -- \
--         --ip=127.0.0.1 --port=8899 --notebook_dir=$PWD/learning/behavior/tools/notebooks
--     and `<leader>ei` attaches to it; NOTEBOOK_SERVER_URL points it at another port.
--     where <data>/jupyter-config/jupyter_server_config.json is
--       {"ServerApp": {"disable_check_xsrf": true}}

local data = vim.fn.stdpath 'data'
local venv = data .. '/molten-venv'
local server_url = vim.env.NOTEBOOK_SERVER_URL or 'http://127.0.0.1:8899'

return {
  {
    'GCBallesteros/jupytext.nvim',
    -- has to be loaded before the first .ipynb is read: it works through BufReadCmd
    lazy = false,
    init = function()
      vim.env.PATH = venv .. '/bin:' .. vim.env.PATH
    end,
    config = function()
      require('jupytext').setup { style = 'hydrogen' }
      require('custom.notebook_cells').setup()
    end,
  },
  {
    'benlubas/molten-nvim',
    version = '^1.0.0',
    dependencies = { '3rd/image.nvim' },
    build = ':UpdateRemotePlugins',
    lazy = false,
    init = function()
      vim.g.python3_host_prog = venv .. '/bin/python'
      vim.g.molten_image_provider = 'image.nvim'
      -- floats redraw images more cleanly than virtual text does while scrolling
      vim.g.molten_image_location = 'float'
      vim.g.molten_output_win_max_height = 30
      vim.g.molten_wrap_output = true
      vim.g.molten_auto_open_output = true

      -- With `allow-passthrough on`, tmux 3.4 drops passthrough from a pane that is waiting to
      -- be redrawn, so images go missing at random; `all` doesn't.
      if vim.env.TMUX and vim.env.TMUX_PANE then
        vim.system { 'tmux', 'set', '-p', '-t', vim.env.TMUX_PANE, 'allow-passthrough', 'all' }
      end
    end,
    keys = {
      { '<leader>ei', '<cmd>MoltenInit ' .. server_url .. '<cr>', desc = 'Notebook: start kernel on the server' },
      { '<leader>eo', '<cmd>noautocmd MoltenEnterOutput<cr>', desc = 'Notebook: enter output window' },
      { '<leader>eh', '<cmd>MoltenHideOutput<cr>', desc = 'Notebook: hide output' },
      { '<leader>ed', '<cmd>MoltenDelete<cr>', desc = 'Notebook: delete cell output' },
      { '<leader>ex', '<cmd>MoltenInterrupt<cr>', desc = 'Notebook: interrupt kernel' },
      { '<leader>er', '<cmd>MoltenRestart!<cr>', desc = 'Notebook: restart kernel, clear outputs' },
    },
  },
  {
    'GCBallesteros/NotebookNavigator.nvim',
    dependencies = { 'echasnovski/mini.nvim', 'benlubas/molten-nvim' },
    ft = 'python',
    config = function()
      -- NotebookNavigator comments cells through mini.comment or Comment.nvim, not the
      -- built-in gc
      require('mini.comment').setup()

      local nn = require 'notebook-navigator'
      nn.setup { repl_provider = 'molten' }

      local function move_cells(direction)
        return function()
          for _ = 1, vim.v.count1 do
            nn.move_cell(direction)
          end
          -- not as the motion of a pending operator, where the view is the operator's to leave
          if vim.api.nvim_get_mode().mode:sub(1, 2) ~= 'no' then
            vim.cmd 'normal! zz'
          end
        end
      end

      local function setup_buffer(buf)
        vim.b[buf].miniai_config = { custom_textobjects = { h = nn.miniai_spec } }
        -- Motions (normal, visual, operator-pending), where <C-n>/<C-p> only repeat j/k;
        -- insert mode keeps completion. From a `# %%` line, d<C-n> deletes the whole cell:
        -- an exclusive motion that ends in column 1 turns linewise (:h exclusive-linewise).
        if require('custom.notebook_cells').is_notebook(buf) then
          vim.keymap.set({ 'n', 'x', 'o' }, '<C-n>', move_cells 'd', { buffer = buf, desc = 'Notebook: next cell' })
          vim.keymap.set({ 'n', 'x', 'o' }, '<C-p>', move_cells 'u', { buffer = buf, desc = 'Notebook: previous cell' })
        end
      end
      vim.api.nvim_create_autocmd('FileType', {
        group = vim.api.nvim_create_augroup('notebook-buffer', { clear = true }),
        pattern = 'python',
        callback = function(event) setup_buffer(event.buf) end,
      })
      -- this config runs on the FileType that loaded the plugin, after that event's autocmds
      setup_buffer(vim.api.nvim_get_current_buf())
    end,
    keys = {
      { ']h', function() require('notebook-navigator').move_cell 'd' end, ft = 'python', desc = 'Notebook: next cell' },
      { '[h', function() require('notebook-navigator').move_cell 'u' end, ft = 'python', desc = 'Notebook: previous cell' },
      { '<leader>x', function() require('notebook-navigator').run_and_move() end, ft = 'python', desc = 'Notebook: run cell, go to next' },
      { '<leader>X', function() require('notebook-navigator').run_cell() end, ft = 'python', desc = 'Notebook: run cell' },
      { '<leader>ea', function() require('notebook-navigator').run_all_cells() end, ft = 'python', desc = 'Notebook: run all cells' },
      { '<leader>eb', function() require('notebook-navigator').run_cells_below() end, ft = 'python', desc = 'Notebook: run this cell and below' },
    },
  },
}
