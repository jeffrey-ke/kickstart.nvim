-- A C++-only color layer over the colorscheme, so a signature like
--
--   onboard::learning::DataGenieSignalMap ObjectTracksProducer::ProcessInputTracks(
--       const onboard::behavior::InputTracks& input_tracks)
--
-- reads as namespace / return type / class / function / parameter at a glance.
-- Stock catppuccin paints @module, @type and @constructor all yellow, and the
-- cpp query calls every capitalized function a @constructor -- which, under a
-- CamelCase-methods style, is every function -- so the whole line was one color.
--
-- Every group carries the `.cpp` suffix, so no other language is touched, and
-- each role lists its tree-sitter capture and clangd's semantic token together:
-- with clangd attached the token (priority 125) wins over tree-sitter (100), so
-- coloring only one of the two would change with LSP state. The two roles with
-- no stock capture come from after/queries/cpp/highlights.scm.
local M = {}

-- role -> palette color + style, and every group that should render as it.
local roles = {
  namespace = { fg = 'overlay1', italic = true, groups = { '@module', '@lsp.type.namespace' } },
  type = { fg = 'yellow', groups = { '@type', '@lsp.type.class', '@lsp.type.struct', '@lsp.type.enum', '@lsp.type.typeParameter' } },
  return_type = { fg = 'peach', bold = true, groups = { '@type.return' } },
  func_def = { fg = 'blue', bold = true, groups = { '@function.definition' } },
  func_call = {
    fg = 'blue',
    -- @constructor is the capitalized-call misfire above; real constructor calls
    -- still get @lsp.type.class from clangd.
    groups = { '@function', '@function.call', '@function.method', '@function.method.call', '@constructor', '@lsp.type.function', '@lsp.type.method' },
  },
  parameter = { fg = 'maroon', italic = true, groups = { '@variable.parameter', '@lsp.type.parameter' } },
  member = { fg = 'teal', groups = { '@variable.member', '@property', '@lsp.type.property' } },
  variable = { fg = 'text', groups = { '@variable', '@lsp.type.variable' } },
}

function M.apply()
  local ok, palettes = pcall(require, 'catppuccin.palettes')
  if not ok then
    return
  end
  local c = palettes.get_palette()
  for _, role in pairs(roles) do
    local spec = { fg = c[role.fg], bold = role.bold, italic = role.italic }
    for _, group in ipairs(role.groups) do
      vim.api.nvim_set_hl(0, group .. '.cpp', spec)
    end
  end
end

-- On ColorScheme, not once: :colorscheme runs :hi clear, so :ToggleBackground
-- would otherwise drop the layer (and the palette changes with the flavour).
function M.setup()
  M.apply()
  vim.api.nvim_create_autocmd('ColorScheme', {
    desc = 'Re-apply the C++ role colors over the colorscheme',
    group = vim.api.nvim_create_augroup('cpp-hl', { clear = true }),
    callback = M.apply,
  })
end

return M
