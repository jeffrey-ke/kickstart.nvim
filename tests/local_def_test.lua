-- Tests for lua/custom/local_def. Run from anywhere:
--
--   nvim --headless -u NONE -l ~/dotfiles/nvim/tests/local_def_test.lua
--
-- The first cases feed resolve.lua hand-written tables; the rest parse real
-- C++ and Python snippets, so they also pin the tree-sitter node shapes the
-- extractors depend on. A case names positions by the Nth whole-word
-- occurrence of a name, which keeps the snippets free of markers.

local config = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2))))
vim.opt.rtp:prepend(config)
-- Parsers live in nvim-treesitter's install directory.
vim.opt.rtp:append(vim.fn.stdpath 'data' .. '/lazy/nvim-treesitter')

local local_def = require 'custom.local_def'
local resolve = require 'custom.local_def.resolve'
local languages = require 'custom.local_def.languages'

local failures, count = 0, 0

local function check(label, got, want)
  count = count + 1
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  want %s\n  got  %s'):format(label, vim.inspect(want), vim.inspect(got)))
  end
end

-- Pure resolve ----------------------------------------------------------------

do
  -- module v, class K { v }, method using v.
  local scopes = {
    { id = 1, kind = 'module' },
    { id = 2, parent = 1, kind = 'class' },
    { id = 3, parent = 2, kind = 'function' },
  }
  local defs = {
    { name = 'v', scope = 1, pos = { 0, 0 }, kind = 'bind' },
    { name = 'v', scope = 2, pos = { 2, 4 }, kind = 'bind' },
  }
  local ref = { name = 'v', scope = 3, pos = { 4, 8 } }
  local function rows(found)
    return vim.tbl_map(function(def)
      return def.pos[1]
    end, found)
  end
  check('pure: python method skips the class body', rows(resolve.resolve(scopes, defs, ref, languages.python.rules)), { 0 })
  check('pure: c++ method sees the class body', rows(resolve.resolve(scopes, defs, ref, languages.cpp.rules)), { 2 })
  check('pure: unbound name', resolve.resolve(scopes, defs, { name = 'w', scope = 3, pos = { 4, 8 } }, languages.python.rules), {})
end

-- End to end ------------------------------------------------------------------

local function at(lines, name, n)
  local seen = 0
  local pattern = '%f[%w_]' .. vim.pesc(name) .. '%f[^%w_]'
  for row, line in ipairs(lines) do
    local from = 1
    while true do
      local col = line:find(pattern, from)
      if not col then
        break
      end
      seen = seen + 1
      if seen == n then
        return { row - 1, col - 1 }
      end
      from = col + 1
    end
  end
  error(('occurrence %d of %q not found'):format(n, name))
end

--- `ref` is { name, n }; `want` lists { name, n } of the expected definitions,
--- nearest first.
local function case(label, filetype, src, ref, want)
  local lines = vim.split(vim.trim(src), '\n')
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].filetype = filetype
  local pos = at(lines, ref[1], ref[2])
  local got = vim.tbl_map(function(def)
    return { def.row, def.col }
  end, local_def.find(bufnr, pos[1], pos[2]))
  local expected = vim.tbl_map(function(w)
    return at(lines, w[1], w[2])
  end, want)
  check(label, got, expected)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- C++

case('c++: inner declaration shadows outer', 'cpp', [[
void f() {
  int x = 1;
  {
    int x = 2;
    use(x);
  }
}]], { 'x', 3 }, { { 'x', 2 } })

case('c++: a later inner declaration does not capture an earlier use', 'cpp', [[
void f() {
  int x = 1;
  {
    use(x);
    int x = 2;
  }
}]], { 'x', 2 }, { { 'x', 1 } })

case('c++: structured binding in a range-for', 'cpp', [[
void f(const M& tracks) {
  for (const auto& [track_id, track] : tracks) {
    use(track);
  }
}]], { 'track', 2 }, { { 'track', 1 } })

case('c++: range-for iterable resolves to the parameter', 'cpp', [[
void f(const M& tracks) {
  for (const auto& [track_id, track] : tracks) {
    use(track);
  }
}]], { 'tracks', 2 }, { { 'tracks', 1 } })

case('c++: function parameter', 'cpp', [[
int f(int n) {
  return n;
}]], { 'n', 2 }, { { 'n', 1 } })

case('c++: a local prototype parameter binds nothing', 'cpp', [[
int f() {
  void proto(int q);
  return q;
}]], { 'q', 2 }, {})

case('c++: same name in a sibling function is not a definition', 'cpp', [[
void a() { int k = 1; }
void b() { use(k); }
]], { 'k', 2 }, {})

case('c++: lambda parameter', 'cpp', [[
void f() {
  auto lam = [&, z = 1](int w) { return w + z; };
  lam(2);
}]], { 'w', 2 }, { { 'w', 1 } })

case('c++: lambda init capture', 'cpp', [[
void f() {
  auto lam = [&, z = 1](int w) { return w + z; };
  lam(2);
}]], { 'z', 2 }, { { 'z', 1 } })

case('c++: variable holding a lambda', 'cpp', [[
void f() {
  auto lam = [&, z = 1](int w) { return w + z; };
  lam(2);
}]], { 'lam', 2 }, { { 'lam', 1 } })

case('c++: class member used before its declaration', 'cpp', [[
struct S {
  void g() { use(m_); }
  int m_;
};]], { 'm_', 1 }, { { 'm_', 2 } })

case('c++: if-statement initializer', 'cpp', [[
void f() {
  if (auto it = find(); it) { use(it); }
}]], { 'it', 3 }, { { 'it', 1 } })

case('c++: member access is not a local', 'cpp', [[
void f(S s) { use(s.m_); }
]], { 'm_', 1 }, {})

case('c++: most vexing parse still declares a variable', 'cpp', [[
void f() {
  Foo foo(bar);
  use(foo);
}]], { 'foo', 2 }, { { 'foo', 1 } })

case('c++: second declarator in a declaration', 'cpp', [[
void f() {
  int* p = nullptr, arr[3];
  use(p, arr);
}]], { 'arr', 2 }, { { 'arr', 1 } })

case('c++: catch parameter', 'cpp', [[
void f() {
  try {} catch (const E& err) { use(err); }
}]], { 'err', 2 }, { { 'err', 1 } })

case('c++: cursor on the declaration resolves to itself', 'cpp', [[
void f() {
  int x = 1;
}]], { 'x', 1 }, { { 'x', 1 } })

-- Python

case('python: blocks do not open scopes', 'python', [[
def f(c):
    if c:
        y = 1
    return y
]], { 'y', 2 }, { { 'y', 1 } })

case('python: a later assignment makes the name local to the whole function', 'python', [[
x = 0
def f():
    print(x)
    x = 1
]], { 'x', 2 }, { { 'x', 3 } })

case('python: a method does not see its class body', 'python', [[
cattr = 0
class K:
    cattr = 1
    def m(self):
        return cattr
]], { 'cattr', 3 }, { { 'cattr', 1 } })

case('python: the class body itself sees its own names', 'python', [[
cattr = 0
class K:
    cattr = 1
    other = cattr
]], { 'cattr', 3 }, { { 'cattr', 2 } })

case('python: global redirects to the module binding', 'python', [[
G = 1
def f():
    global G
    G = 2
    return G
]], { 'G', 4 }, { { 'G', 3 }, { 'G', 1 } })

case('python: nonlocal skips to the enclosing function', 'python', [[
def outer():
    a = 1
    def inner():
        nonlocal a
        a = 2
        return a
]], { 'a', 4 }, { { 'a', 1 } })

case('python: a comprehension variable does not leak', 'python', [[
k = 0
ys = [k for k in xs]
print(k)
]], { 'k', 4 }, { { 'k', 1 } })

case('python: inside the comprehension, its own variable', 'python', [[
k = 0
ys = [k for k in xs]
print(k)
]], { 'k', 2 }, { { 'k', 3 } })

case('python: walrus binds past its comprehension', 'python', [[
def f(xs):
    [y := v for v in xs]
    return y
]], { 'y', 2 }, { { 'y', 1 } })

local forms = [[
import numpy as np
from os import path
def f():
    with open(p) as fh:
        pass
    try:
        pass
    except E as err:
        pass
    for i, j in pairs:
        pass
    return np, path, fh, err, j
]]
for _, name in ipairs { 'np', 'path', 'fh', 'err', 'j' } do
  case('python: binding form for ' .. name, 'python', forms, { name, 2 }, { { name, 1 } })
end

local params = [[
def f(x, y: int, z=1, w: int = 2, *args, **kw):
    return x, y, z, w, args, kw
]]
for _, name in ipairs { 'x', 'y', 'z', 'w', 'args', 'kw' } do
  case('python: parameter ' .. name, 'python', params, { name, 2 }, { { name, 1 } })
end

case('python: same name in a sibling function is not a definition', 'python', [[
def a():
    k = 1
def b():
    return k
]], { 'k', 2 }, {})

case('python: attribute is not a local', 'python', [[
def f(obj):
    obj.attr = 1
    return obj.attr
]], { 'attr', 2 }, {})

case('python: object of an attribute is', 'python', [[
def f(obj):
    obj.attr = 1
    return obj.attr
]], { 'obj', 3 }, { { 'obj', 1 } })

case('python: several bindings, nearest preceding first', 'python', [[
x = 1
x = 2
print(x)
x = 3
]], { 'x', 3 }, { { 'x', 2 }, { 'x', 1 }, { 'x', 4 } })

case('python: keyword argument name is not a local', 'python', [[
def f(key):
    return g(key=key)
]], { 'key', 2 }, {})

case('python: keyword argument value is', 'python', [[
def f(key):
    return g(key=key)
]], { 'key', 3 }, { { 'key', 1 } })

case('python: lambda parameters', 'python', [[
lam = lambda s, t=0: s + t
]], { 't', 2 }, { { 't', 1 } })

-- C++ members from out-of-line methods --------------------------------------

case('c++: member used in an out-of-line method, class in the same file', 'cpp', [[
class S {
 public:
  void g();
 private:
  int m_;
};
void S::g() { use(m_); }
]], { 'm_', 2 }, { { 'm_', 1 } })

case('c++: namespaced method with a reference return type', 'cpp', [[
namespace ns {
struct S { int& get(); int v_; };
int& ns::S::get() { return v_; }
}]], { 'v_', 2 }, { { 'v_', 1 } })

case('c++: a local shadows a member', 'cpp', [[
struct S { void g(); int m_; };
void S::g() {
  int m_ = 0;
  use(m_);
}]], { 'm_', 3 }, { { 'm_', 2 } })

case('c++: a parameter shadows a member', 'cpp', [[
struct S { void g(int m_); int m_; };
void S::g(int m_) { use(m_); }
]], { 'm_', 4 }, { { 'm_', 3 } })

case('c++: the member of the named class, not a same-named one', 'cpp', [[
struct A { int m_; };
struct B { void g(); int m_; };
void B::g() { use(m_); }
]], { 'm_', 3 }, { { 'm_', 2 } })

case('c++: class not in this file or its includes', 'cpp', [[
void T::g() { use(m_); }
]], { 'm_', 1 }, {})

case('c++: constructor initializer list names a member', 'cpp', [[
struct S { S(int x); int a_; };
S::S(int x) : a_(x) {}
]], { 'a_', 2 }, { { 'a_', 1 } })

-- Across files. The same three files, first through an in-memory io (pure),
-- then from disk through the buffer path.

local header_files = {
  ['/w/base.h'] = 'class Base {\n protected:\n  int b_;\n};\n',
  ['/w/foo.h'] = '#include "base.h"\nclass Foo : public Base {\n  void g();\n  int a_;\n};\n',
}
local foo_cc = '#include "foo.h"\nvoid Foo::g() { use(a_); use(b_); }\n'

do
  local members = require 'custom.local_def.members'
  local function unit(path, source)
    return { path = path, root = vim.treesitter.get_string_parser(source, 'cpp'):parse()[1]:root(), source = source }
  end
  local memory = {
    load = function(path)
      return header_files[path] and unit(path, header_files[path])
    end,
    include_path = function(from, include)
      local path = vim.fs.joinpath(vim.fs.dirname(from), include)
      return header_files[path] and path
    end,
  }
  local cc = unit('/w/foo.cc', foo_cc)
  local function where(found)
    return found and vim.tbl_map(function(def)
      return { def.path, def.pos[1] }
    end, found)
  end
  check('pure: member in the included header', where(members.lookup('Foo', 'a_', cc, memory)), { { '/w/foo.h', 3 } })
  check('pure: member inherited from a base in another header', where(members.lookup('Foo', 'b_', cc, memory)), { { '/w/base.h', 2 } })
  check('pure: class that is nowhere', members.lookup('Nope', 'a_', cc, memory), nil)
end

do
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  for path, source in pairs(header_files) do
    vim.fn.writefile(vim.split(source, '\n'), dir .. '/' .. vim.fs.basename(path))
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, dir .. '/foo.cc')
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(foo_cc, '\n'))
  vim.bo[bufnr].filetype = 'cpp'
  local lines = vim.split(foo_cc, '\n')
  local function from_disk(name)
    local pos = at(lines, name, 1)
    return vim.tbl_map(function(def)
      return { def.path and vim.fs.basename(def.path), def.row }
    end, local_def.find(bufnr, pos[1], pos[2]))
  end
  check('disk: member in the included header', from_disk 'a_', { { 'foo.h', 3 } })
  check('disk: member inherited through two headers', from_disk 'b_', { { 'base.h', 2 } })
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(dir, 'rf')
end

-- Methods resolve to their implementation ----------------------------------

case('c++: a called method goes to its out-of-line body, then its declaration', 'cpp', [[
class S {
 public:
  void a();
  void b();
};
void S::a() { b(); }
void S::b() {}
]], { 'b', 2 }, { { 'b', 3 }, { 'b', 1 } })

case('c++: a method with no body anywhere keeps its declaration', 'cpp', [[
class S {
 public:
  void a();
  virtual void b() = 0;
};
void S::a() { b(); }
]], { 'b', 2 }, { { 'b', 1 } })

case('c++: only the named class counts, not a same-named method elsewhere', 'cpp', [[
class S { void a(); void b(); };
class T { void b(); };
void T::b() {}
void S::a() { b(); }
void S::b() {}
]], { 'b', 4 }, { { 'b', 5 }, { 'b', 1 } })

do
  local members = require 'custom.local_def.members'
  local files = {
    ['/w/foo.h'] = 'class Foo {\n  void g();\n  void h();\n};\n',
    ['/w/foo.cc'] = '#include "foo.h"\nvoid Foo::h() {}\n',
    ['/w/other.cc'] = '#include "foo.h"\nvoid Foo::g() { h(); }\n',
  }
  local function unit(path)
    return { path = path, root = vim.treesitter.get_string_parser(files[path], 'cpp'):parse()[1]:root(), source = files[path] }
  end
  local memory = {
    load = function(path)
      return files[path] and unit(path)
    end,
    include_path = function(from, include)
      local path = vim.fs.joinpath(vim.fs.dirname(from), include)
      return files[path] and path
    end,
  }
  local found = members.lookup('Foo', 'h', unit '/w/other.cc', memory)
  check('pure: method body found in the source paired with the class header', vim.tbl_map(function(def)
    return { def.path, def.pos[1] }
  end, found), { { '/w/foo.cc', 1 }, { '/w/foo.h', 2 } })
end

-- Ranking grep hits ------------------------------------------------------------

do
  local rank = require 'custom.local_def.rank'
  local files = {
    ['/r/f.h'] = 'size_t F(int x,\n         int y);\nclass K;\nclass C {\n  int m;\n};\n',
    ['/r/f.cc'] = 'size_t F(int x,\n         int y) {\n  return x;\n}\nsize_t n = F(1, 2);\n',
  }
  local function load(path)
    return files[path] and { path = path, root = vim.treesitter.get_string_parser(files[path], 'cpp'):parse()[1]:root(), source = files[path] }
  end
  local function line(path, row)
    return vim.split(files[path], '\n')[row + 1]
  end
  check('rank: a prototype is a declaration', rank.kind(load '/r/f.h', 0, line('/r/f.h', 0), 'F'), 'declaration')
  check('rank: a function with a body is a definition', rank.kind(load '/r/f.cc', 0, line('/r/f.cc', 0), 'F'), 'definition')
  check('rank: a forward-declared class is a declaration', rank.kind(load '/r/f.h', 2, line('/r/f.h', 2), 'K'), 'declaration')
  check('rank: a class with a body is a definition', rank.kind(load '/r/f.h', 3, line('/r/f.h', 3), 'C'), 'definition')
  check('rank: a call inside an initializer is neither', rank.kind(load '/r/f.cc', 4, line('/r/f.cc', 4), 'F'), nil)

  local hits = {
    { filename = '/r/f.h', lnum = 1, col = 1, text = line('/r/f.h', 0) },
    { filename = 'notes.md', lnum = 3, col = 1, text = 'F(' },
    { filename = '/r/f.cc', lnum = 1, col = 1, text = line('/r/f.cc', 0) },
  }
  check('rank: definitions, then the rest, then declarations', vim.tbl_map(function(l)
    return l.filename
  end, rank.definitions_first(hits, 'F', load)), { '/r/f.cc', 'notes.md', '/r/f.h' })
end

print(('%d/%d passed'):format(count - failures, count))
if failures > 0 then
  os.exit(1)
end
