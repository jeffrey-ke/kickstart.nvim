local ls = require 'luasnip'
local s = ls.snippet
local t = ls.text_node
local i = ls.insert_node
local f = ls.function_node
local fmt = require('luasnip.extras.fmt').fmt
local postfix = require('luasnip.extras.postfix').postfix
local events = require 'luasnip.util.events'

-- Every trigger starts with `;`, the same prefix as python.lua and markdown.lua,
-- so the short triggers below can be autosnippets without firing inside
-- ordinary identifiers (`so` in `sort`, `st` in `start`). In C++ a `;` followed
-- directly by a letter mostly shows up in unspaced for-loop headers
-- (`i = 0;start < n`), where the `;` follows a word character; LuaSnip's
-- default wordTrig refuses a trigger preceded by one, so those don't fire.
--
-- Triggers must stay prefix-free: an autosnippet fires the moment its trigger
-- matches, so adding `sva` next to `sv` would make `sva` unreachable. That is
-- why namespace-only expansions end in `:` and variant is `sx`. Where one
-- expansion really should extend another (`;ca` / `;car`), use `tree` below.
local P = ';'

-- Skip comments and strings, where `;so` is prose rather than a request for a
-- snippet. Checks the syntax node under the last typed character; buffers
-- without a cpp parser fall through to expanding.
local blocked_nodes = {
  comment = true,
  string_literal = true,
  raw_string_literal = true,
  char_literal = true,
  system_lib_string = true,
}
local function in_code()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local ok, node = pcall(vim.treesitter.get_node, { pos = { row - 1, math.max(col - 1, 0) } })
  if not ok then
    return true
  end
  while node do
    if blocked_nodes[node:type()] then
      return false
    end
    node = node:parent()
  end
  return true
end

local function auto(trig, nodes, desc)
  return s({ trig = P .. trig, condition = in_code, desc = desc }, nodes)
end

local function lambda(fn)
  return fmt(fn .. '([&](const auto& {}) {{ return {}; }})', { i(1, 'x'), i(2) })
end

-- `[%w_:<>%.%-]` rather than LuaSnip's default class so a qualified type
-- (`std::string`) or a member access (`a->b`) is captured whole.
local function wrap(trig, pre, post)
  return postfix({ trig = P .. P .. trig, match_pattern = '[%w_:<>%.%-]+$', condition = in_code }, {
    f(function(_, parent)
      return pre .. parent.snippet.env.POSTFIX_MATCH .. post
    end, {}),
  })
end

-- A prefix tree of autosnippets. `;ca` and `;car` cannot both be triggers,
-- since `;ca` fires before the `r` arrives. Instead `;ca` expands to
-- `const auto` and records where that text ends; the child keyed `r` has the
-- trigger `const autor` and fires only when the `r` was typed right at that
-- spot. So `;car` gives `const auto&`, while `const author` typed by hand,
-- or an `r` typed after moving away and back, is left alone.
-- `children` maps a key to `{ text, children }`, so trees nest.
local tip -- { buf, row, col } just past the last tree expansion, 0-indexed
local function tree(trig, condition, text, children)
  local function record_tip(_, args)
    local row, col = unpack(args.expand_pos)
    tip = { buf = vim.api.nvim_get_current_buf(), row = row, col = col + #text }
  end
  local snips = {
    s({ trig = trig, condition = condition, desc = text }, t(text), { callbacks = { [-1] = { [events.pre_expand] = record_tip } } }),
  }
  for key, child in pairs(children or {}) do
    local function at_tip(line_to_cursor)
      return tip ~= nil
        and tip.buf == vim.api.nvim_get_current_buf()
        and tip.row == vim.api.nvim_win_get_cursor(0)[1] - 1
        and #line_to_cursor == tip.col + #key
    end
    vim.list_extend(snips, tree(text .. key, at_tip, child[1], child[2]))
  end
  return snips
end

local autosnippets = {
  -- Namespace prefixes.
  auto('s:', t 'std::'),
  auto('r:', t 'std::ranges::'),
  auto('v:', t 'std::views::'),
  auto('a:', t 'absl::'),

  -- Core language. `const auto` / `const auto&` are the tree after this table.
  auto('l', fmt('[{}]({}) {{ {}; }}', { i(1), i(2), i(3) }), 'lambda'),

  -- std types and helpers.
  auto('so', fmt('std::optional<{}>', { i(1) })),
  auto('sv', fmt('std::vector<{}>', { i(1) })),
  auto('sa', fmt('std::array<{}, {}>', { i(1, 'T'), i(2, 'N') })),
  auto('sp', fmt('std::pair<{}, {}>', { i(1), i(2) })),
  auto('st', fmt('std::tuple<{}>', { i(1) })),
  auto('sx', fmt('std::variant<{}>', { i(1) }), 'std::variant'),
  auto('sst', t 'std::string'),
  auto('ssv', t 'std::string_view'),
  auto('sup', fmt('std::unique_ptr<{}>', { i(1) })),
  auto('ssp', fmt('std::shared_ptr<{}>', { i(1) })),
  auto('smu', fmt('std::make_unique<{}>({})', { i(1, 'T'), i(2) })),
  auto('sms', fmt('std::make_shared<{}>({})', { i(1, 'T'), i(2) })),
  auto('smv', fmt('std::move({})', { i(1) })),

  -- std::ranges algorithms.
  auto('rme', fmt('std::ranges::min_element({}, {{}}, {})', { i(1, 'range'), i(2, 'proj') })),
  auto('rmx', fmt('std::ranges::max_element({}, {{}}, {})', { i(1, 'range'), i(2, 'proj') })),
  auto('rso', fmt('std::ranges::sort({})', { i(1, 'range') })),
  auto('rfi', lambda 'std::ranges::find_if'),
  auto('rao', lambda 'std::ranges::any_of'),
  auto('rto', t 'std::ranges::to<std::vector>()'),

  -- std::views adaptors.
  auto('vt', lambda 'std::views::transform'),
  auto('vf', lambda 'std::views::filter'),
  auto('ve', t 'std::views::enumerate'),
  auto('vz', fmt('std::views::zip({}, {})', { i(1), i(2) })),
  auto('vk', t 'std::views::keys'),
  auto('vvs', t 'std::views::values'),
  auto('vr', t 'std::views::reverse'),
  auto('vio', fmt('std::views::iota({}, {})', { i(1, '0'), i(2, 'n') })),

  -- absl.
  auto('afm', fmt('absl::flat_hash_map<{}, {}>', { i(1), i(2) })),
  auto('afs', fmt('absl::flat_hash_set<{}>', { i(1) })),
  auto('asc', fmt('absl::StrCat({})', { i(1) })),

  -- Nuro status / check macros.
  auto('nck', fmt('NURO_CHECK({})', { i(1) })),
  auto('nri', fmt('NURO_RETURN_IF_ERROR({});', { i(1) })),
  auto('nao', fmt('NURO_ASSIGN_OR_RETURN({}, {});', { i(1, 'lhs'), i(2, 'rhs') })),

  -- Postfix wraps, double prefix: `int;;o` -> `std::optional<int>`.
  wrap('o', 'std::optional<', '>'),
  wrap('v', 'std::vector<', '>'),
  wrap('m', 'std::move(', ')'),
}

vim.list_extend(autosnippets, tree(P .. 'ca', in_code, 'const auto', { r = { 'const auto&' } }))

return {}, autosnippets
