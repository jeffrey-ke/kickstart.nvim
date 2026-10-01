-- `[f` / `]f`: jump to the start of the enclosing / next function definition.
--
-- Vim's own motions miss in Google-style C++: `[m` wants methods nested inside
-- class braces, `[[` wants a `{` in column 0, and `[{` stops at the innermost
-- block. The syntax tree knows where functions are regardless of brace style,
-- so this asks it. Lambdas are skipped on purpose -- the point is to land on
-- the definition the code belongs to, not the callback it is inside.
--
-- `[f` inside a function goes to its start; from the start, to the start of the
-- enclosing function (a nested Python def); outside every function, to the
-- nearest function start above -- nested or not, mirroring `]f`, which goes to
-- the nearest start below. So repeating `[f` walks outward, then backward.
-- Both take a count and leave a jumplist entry, and work after an operator
-- (`y[f`, `d]f`) as exclusive charwise motions.

local M = {}

local function_nodes = {
  c = { 'function_definition' },
  cpp = { 'function_definition' },
  lua = { 'function_declaration' },
  python = { 'function_definition' },
}

local function before(a, b)
  return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
end

local function inside(fn, pos)
  return not before(pos, fn.start) and before(pos, fn.finish)
end

--- Pure. `functions` is a list of { start = {row, col}, finish = {row, col} }
--- in any order; returns the position `[f` (direction -1) or `]f` (+1) moves
--- to from `pos`, or nil when there is nowhere to go.
function M.target(functions, pos, direction)
  local best
  for _, fn in ipairs(functions) do
    if direction > 0 then
      if before(pos, fn.start) and (not best or before(fn.start, best.start)) then
        best = fn
      end
    elseif before(fn.start, pos) then
      -- Prefer the innermost function around the cursor; among functions that
      -- merely precede it, the latest one.
      local rank = inside(fn, pos) and 1 or 0
      local best_rank = best and (inside(best, pos) and 1 or 0)
      if not best or rank > best_rank or (rank == best_rank and before(best.start, fn.start)) then
        best = fn
      end
    end
  end
  return best and best.start
end

local queries = {}

local function query_for(lang)
  if queries[lang] == nil then
    local types = function_nodes[lang]
    local ok, query = false, nil
    if types then
      local patterns = vim.tbl_map(function(t)
        return '(' .. t .. ')'
      end, types)
      ok, query = pcall(vim.treesitter.query.parse, lang, '[' .. table.concat(patterns, ' ') .. '] @function')
    end
    queries[lang] = ok and query or false
  end
  return queries[lang] or nil
end

--- The functions in `bufnr`, for M.target; nil when the buffer has no parser
--- or no function node types are known for its language.
function M.functions(bufnr)
  local lang = vim.treesitter.language.get_lang(vim.bo[bufnr].filetype)
  local query = lang and query_for(lang)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
  if not query or not ok or not parser then
    return nil
  end
  local out = {}
  for _, node in query:iter_captures(parser:parse()[1]:root(), bufnr, 0, -1) do
    local srow, scol, erow, ecol = node:range()
    out[#out + 1] = { start = { srow, scol }, finish = { erow, ecol } }
  end
  return out
end

function M.jump(direction)
  local functions = M.functions(vim.api.nvim_get_current_buf())
  if not functions then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local pos = { cursor[1] - 1, cursor[2] }
  for _ = 1, vim.v.count1 do
    local next_pos = M.target(functions, pos, direction)
    if not next_pos then
      break
    end
    pos = next_pos
  end
  if pos[1] ~= cursor[1] - 1 or pos[2] ~= cursor[2] then
    vim.cmd "normal! m'"
    vim.api.nvim_win_set_cursor(0, { pos[1] + 1, pos[2] })
  end
end

function M.setup()
  vim.keymap.set({ 'n', 'x', 'o' }, '[f', function()
    M.jump(-1)
  end, { desc = 'Start of enclosing / previous function definition' })
  vim.keymap.set({ 'n', 'x', 'o' }, ']f', function()
    M.jump(1)
  end, { desc = 'Start of next function definition' })
end

return M
