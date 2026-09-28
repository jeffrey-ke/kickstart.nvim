-- Run an rg `--vimgrep` search off the event loop and hand back the matches as
-- custom.locations entries. Where they go is the caller's business -- see
-- custom.locations.load.

local locations = require 'custom.locations'

local M = {}

--- Calls `on_done(found, err)` on the main loop once rg exits. `found` is a
--- list of locations (possibly empty); `err` is set only when rg itself failed
--- (exit code 2+; exit 1 just means no matches).
function M.search(argv, on_done)
  vim.system(argv, { text = true }, function(result)
    vim.schedule(function()
      if result.code > 1 then
        on_done({}, result.stderr ~= '' and result.stderr or ('rg exited ' .. result.code))
        return
      end
      on_done(locations.from_vimgrep(vim.split(result.stdout or '', '\n', { trimempty = true })))
    end)
  end)
end

return M
