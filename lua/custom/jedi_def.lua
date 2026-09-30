-- Python go-to-definition from jedi, one process per lookup: no language
-- server, nothing attached to the buffer, nothing pushed. It is the one part of
-- a language server `gD` wants -- following `from pkg.mod import name` to the
-- file that defines `name`, and `obj.method` to its class -- without the
-- diagnostics that fire on half-written code and imports it cannot find.
--
-- jedi comes from `uvx --with jedi`, so nothing is installed: uv caches the
-- env, and a lookup costs ~0.35 s, most of it interpreter startup. The query
-- itself is jedi_def.py beside this file.

local locations = require 'custom.locations'

local M = {}

local script = vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2)):gsub('%.lua$', '.py')

-- A first run downloads jedi; offline, uv may wait on the index instead.
local timeout_ms = 5000

-- The Python whose packages the code under the cursor imports: the active
-- virtualenv, else whatever `python3` the shell would run.
local function environment()
  if vim.env.VIRTUAL_ENV then
    return vim.env.VIRTUAL_ENV
  end
  local python = vim.fn.exepath 'python3'
  return python ~= '' and python or nil
end

--- Whether a lookup can run for `bufnr` at all: a named Python buffer, and
--- uvx on PATH.
function M.available(bufnr)
  return vim.bo[bufnr].filetype == 'python' and vim.api.nvim_buf_get_name(bufnr) ~= '' and vim.fn.executable 'uvx' == 1
end

--- Resolves the name at the 0-based byte (row, col) of `bufnr` off the event
--- loop and calls `on_done(found)` on the main loop, `found` a list of
--- custom.locations entries. It is {} whenever jedi has no answer -- an
--- unresolvable name, a timeout, a failed uvx -- so the caller's fallback
--- needs no second error path.
function M.find(bufnr, row, col, on_done)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
  local argv = { 'uvx', '--quiet', '--with', 'jedi', 'python', script }
  vim.list_extend(argv, { vim.api.nvim_buf_get_name(bufnr), tostring(row + 1), tostring(vim.fn.strchars(line:sub(1, col))) })
  table.insert(argv, environment())
  local source = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n') .. '\n'
  vim.system(argv, { text = true, stdin = source, timeout = timeout_ms }, function(result)
    vim.schedule(function()
      local ok = result.code == 0 and result.signal == 0
      on_done(ok and locations.from_vimgrep(vim.split(result.stdout or '', '\n', { trimempty = true })) or {})
    end)
  end)
end

return M
