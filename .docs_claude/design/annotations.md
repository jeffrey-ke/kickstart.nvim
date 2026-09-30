# Annotations: program model, data model, and the engines underneath

Reference for `lua/custom/{versions,hi_store,haunt_anchor,anchor}.lua` and the two plugin
specs that wire them (`lua/custom/plugins/{haunt,highlighter}.lua`). Read this before
changing any of them: most of the code is shaped by facts about Neovim, xdiff, haunt.nvim and
vim-highlighter that are not visible from the code itself, and several of those facts were
learned by getting them wrong. Each is marked **[measured]** (verified on nvim 0.12.4 /
haunt `c973175` / vim-highlighter 1.64.1 during 2026-09-28/29) or **[read]** (from the
plugin source at those versions).

History: [plans/completed/annotations-survive-checkouts.md](../plans/completed/annotations-survive-checkouts.md)
(shared stores + text anchors) and
[plans/completed/annotations-diff-mapped-versions.md](../plans/completed/annotations-diff-mapped-versions.md)
(snapshots + diff mapping). This document describes the result, not the path.

---

## 1. The idea in one paragraph

A **mark** is a note (haunt.nvim) or a wash (vim-highlighter) attached to a place in a file.
A place is a line and column, and a line number is only meaningful for one exact text. So
every annotated file has a **snapshot** — a copy of the text its stored positions are exact
for — and whenever a buffer's text differs from its snapshot, every position is pushed
through the **diff** between the two before anything is drawn, and the snapshot is then
replaced by the new text (**re-based**). This is the model of a code-review tool carrying a
comment across pushes, or of Google Docs keeping a highlight on its words while you type
above it: positions are *carried through edits*, not looked up again. Text lookup survives
in exactly one role: a position whose line the diff says was **deleted** is parked where the
deletion happened, flagged **stale**, and keeps its old text so it can snap back if that text
reappears.

While a buffer is open, none of this is needed: marks are **extmarks**, and Neovim moves
them with the text exactly. The machinery is only for the moments the text changes
*underneath* the marks — a `git checkout`, a pull, a formatter, `:e`.

---

## 2. Glossary

| Term | Meaning |
|---|---|
| **note** | haunt.nvim bookmark with annotation text. Drawn as `virt_text` at end of line plus a gutter sign. |
| **wash** | vim-highlighter *positional* highlight: an extmark with `hl_group = 'HiColorN'` over a `(row,col)…(end_row,end_col)` span. Not a *pattern* highlight (`f<CR>`, a window `matchadd`), which is not persisted. |
| **pen** | the current wash color, `vim.g.annot_pen`, an index into the background-only groups `HiColor80..89` (annot.lua). |
| **store** | a JSON file holding a file's (or project's) marks. haunt: one per project. hi_store: one per file. |
| **snapshot** | the file text the store's positions are exact for. One per file, shared by both stores. |
| **file key** | `versions.file_key(path)`: `<root commit:12>/<path relative to repo root, / → %>`, or `_abs/<absolute path, / → %>` outside a repo. Names the hi store and the snapshot. |
| **root commit** | `git rev-list --max-parents=0 HEAD | head -1`. Shared by every branch, worktree and clone of a repo — the identity of "the same repo". Also what haunt keys its project store by. |
| **mapping** | `versions.mapper(old_lines, new_lines)`: the function from positions in `old` to positions in `new`, derived from xdiff hunks. |
| **detached** | buffer state between `BufReadPre` and the next mapping: its marks have been dropped on purpose and nothing may be persisted from it. |
| **stale** | a mark whose line/range the diff reports deleted and whose text was not found elsewhere. Parked, flagged, anchor preserved. |
| **anchor** | `anchor.capture(lines, lnum)`: `{text, above[2], below[2]}` — the line's text with whitespace removed and its two nearest non-blank neighbours each side, likewise normalized. Used only to resurrect stale marks and to place stores that predate snapshots. |
| **persist** | `versions.persist([bufnr])`: write hi store + haunt store + snapshot for a buffer (or all mapped buffers), atomically in the sense that all three describe the same text. |

---

## 3. The engines and what is true about them

### 3.1 Extmarks (Neovim)

- Positions are 0-based `(row, col)` with `col` a **byte** offset; `end_col` is exclusive.
  All stored positions use these conventions; the mapper's `line()` is 1-based because the
  diff is (see 3.2) — hi_store converts at the boundary (`rec.l1 + 1`).
- `right_gravity = true` (default) means text inserted *at* the mark's start goes before it
  (the mark moves right); `end_right_gravity = false` (default) means text inserted at the
  end stays outside. Both plugins use the defaults; hi_store creates marks the same way.
  **[read]** vim-highlighter `s:SetPosHighlight` sets neither, so `priority` is 4096, too.
- **[measured] A buffer reload does not move or remove extmarks.** After `:e`, `:checktime`
  with `autoread`, or a `W12` "Load File", every extmark reports the *same* `(row, col)` it
  had before, regardless of gravity. This is why both plugins would otherwise keep showing
  old positions after a checkout, and why `BufReadPre` drops all marks: anything left in
  the namespace is a lie the plugins trust (haunt refuses to restore a buffer that has any
  extmark in its namespace, restoration.lua:109-114; and it syncs `bookmark.line` from
  whatever extmark is there, store.lua:107-138).
- A named namespace is shared: `nvim_create_namespace('HiColor')` from Lua returns the id
  vim-highlighter created (autoload/highlighter.vim:157, `s:NS`). Marks placed there with the
  plugin's shape are indistinguishable from its own; **[measured]** `f<BS>` erase, the `Hi{}`
  jumps, `:Hi save` and annot.lua's `recolor()` all operate on them.

### 3.2 xdiff via `vim.diff` / `vim.text.diff`

`vim.diff` (renamed `vim.text.diff` in 0.12; both exist there — `versions.lua` uses whichever
is present) is libxdiff, the same engine git uses. Called with

```lua
{ result_type = 'indices', algorithm = 'histogram', ignore_whitespace = true, linematch = 60 }
```

- **Hunk shape [measured]:** each hunk is `{ start_a, count_a, start_b, count_b }`,
  **1-based**, mirroring a unified header `@@ -a,b +c,d @@`. For a zero-count side the start
  is the line the change comes *after*: `{2, 0, 3, 2}` = new lines 3–4 inserted after old
  line 2; `{3, 1, 2, 0}` = old line 3 deleted, the gap sits after new line 2. `mapper.line`
  depends on exactly this; `tests/versions_spec.lua` pins it.
- **`ignore_whitespace` [measured, load-bearing]:** without it, an upstream commit that
  re-indented a whole file made every line a change and the mapping was worse than text
  search (a mark on `mapleader` landed on a random comment). With it, a re-indented line is
  `exact` for the diff, and only the column mapping (3.5) sees the indent.
- **`linematch = 60` [measured]:** for hunks up to 60 lines, xdiff re-pairs lines within a
  change by similarity and splits the hunk. This is what turns a 30-line
  `vim.opt.* → vim.o.*` block into thirty 1→1 rewrites, so a mark on one line lands on *its*
  rewrite instead of proportionally somewhere in the block. It also has readings you must not
  fight: `c → c1 c2 c3` becomes "insert two, rewrite c into c3" (`{2,0,3,2}, {3,1,5,1}`), so
  a mark on `c` follows it to `c3`; `c d → C` becomes "delete c, rewrite d". Positions follow
  the diff's pairing; the spec pins these so a change in xdiff shows up as a failing test.
- Input must end in a newline for the last line to count: the mapper joins with `'\n'` and
  appends one.

### 3.3 Buffer reload — the autocmd sequence

**[measured]** For `:checktime` with `autoread` (also `:e`, which additionally fires
`BufUnload` first):

| Event | Buffer text | Extmarks | `changedtick` |
|---|---|---|---|
| `BufReadPre` | **already empty** — one blank line | still present, frozen at old rows | old value |
| `BufReadPost` | new text | as above unless something cleared them | **still the old value** |
| `FileChangedShellPost` (checktime only) | new | | old |
| afterwards | | | incremented |

Two consequences, both of which bit during the build:

1. **Nothing may be captured from the buffer at `BufReadPre`.** A snapshot taken there is a
   blank line; an anchor is `text = ''`. `detach` therefore persists nothing. It does not
   need to: every mutation persists itself (§5), so the stores and snapshot already describe
   the last saved state, and unsaved edits are precisely what the reload throws away.
2. **`changedtick` cannot key "already handled this reload".** At `BufReadPost` it equals the
   value the previous mapping saw. Mapping state is therefore an explicit flag
   (`mapped[bufnr]`) that `detach` clears; the snapshot cache is a content sha, not a tick.

### 3.4 haunt.nvim internals that the integration depends on **[read]**

| Fact | Where | Why it matters |
|---|---|---|
| Store is a single Lua array of bookmarks `{file (absolute, normalized), line, note, id, extmark_id?, annotation_extmark_id?}`; `get_all_raw()` returns **live references** | store.lua:280 | `haunt_anchor` mutates `bm.line`, `bm.anchor`, `bm.stale` in place |
| Every read goes through `synced_bookmarks()`, which sets `bm.line` from `display.get_extmark_line(bufnr, extmark_id)` whenever `extmark_id` is set and the file's buffer is loaded | store.lua:107-150 | a frozen extmark would overwrite a mapped line → `detach` nils `extmark_id` first |
| `restore_buffer_bookmarks(bufnr)` skips if `restored_buffers[bufnr]` or if any extmark exists in the display namespace; then places each bookmark at `bm.line` via `display.set_bookmark_mark`, which **errors (notify) and skips** a line past EOF | restoration.lua:88-163, display.lua:389-435 | `detach` calls `cleanup_buffer_tracking` and `clear_buffer_marks`; `reanchor` clamps lines |
| The restore function is looked up on the module table at call time (`api.lua:974`, `:1022`) | | replacing `restoration.restore_buffer_bookmarks` intercepts BufReadPost, the startup pass, and `api.reload` |
| Serialization is a fixed whitelist `{file, line, note, id, absolute?}` in `persistence._build_serializable`, result index-aligned with input; **load keeps unknown fields** | persistence.lua:135-165, 241-265 | the serializer is wrapped to add `anchor` and `stale`; nothing is needed on load |
| Save happens after each api mutation and at `VimLeavePre` — **no TextChanged/BufWritePost autosave**, despite the docs | init.lua:295, api.lua | `versions.persist` is what saves on `:w`; haunt's `on_post_save` hook triggers a full persist so all three artefacts agree |
| Store key: `sha256(project_id [.. '|' .. branch])[1:12]`; `project_id` = root commit, from **cwd**, cached 5 s | persistence.lua:95-112, project.lua | `per_branch_bookmarks = false` here; a worktree file opened from an nvim whose cwd is another worktree shows no notes (relative paths resolve against cwd's root). One nvim per worktree is the working pattern |
| `restore_bookmark_display` draws the note text as given (`bm.note`), not via any hook | restoration.lua:43-78 | the `⚠` marker is applied by re-rendering stale notes *after* the original restore; annot.lua's fold/redraw asks `haunt_anchor.display_note(bm)` |
| Hooks (`on_pre_save`, `on_post_save`, `on_update`, `on_delete`, …) receive live references, run under pcall, return values ignored; re-emitting inside a hook recurses | hooks.lua | `persist` has a re-entrancy guard because it calls `store.save()` which emits `on_post_save` which calls `persist` |
| `bm.extmark_id` is never cleared on `BufDelete` | | ids are nil'd in `detach`; a fresh buffer's namespace is empty at `BufReadPre`, so a stale id cannot alias |

### 3.5 vim-highlighter internals that the integration depends on **[read]**

| Fact | Where | Why it matters |
|---|---|---|
| Positional highlights are only extmarks in `s:NS = nvim_create_namespace('HiColor')`; **no side table** | autoload:157 | enumerating the namespace *is* the plugin's model; hi_store reads and writes it directly |
| Shape: `{end_row, end_col, hl_group = 'HiColorN'}`; a visual block is one extmark per row; `HiSetPos(line)` would make a `line_hl_group` mark, which `:Hi save` cannot serialize (E716) | autoload:415-479, 1243 | this config never makes `line_hl_group` marks (`V` selections clamp to `len+1` → span), so hi_store persists `hl_group` spans only |
| Colors `HiColor1..14` set fg+bg (flatten syntax); `HiColor80..89` set bg only ("multiline colors") | autoload:205 | the pen indexes 80..89; `HiColorN` groups exist only after `s:Load()` ran — `annot.ensure_loaded()` (calls `highlighter#Command('/')`) before placing marks |
| `s:LoadHighlight` clears the namespace, then `nvim_buf_set_extmark`s stored coordinates, skipping a start past EOL and erroring on an end past EOF | autoload:1254-1307 | hi_store replaces it; positions are clamped to the mapped lines' lengths before placing |
| `:Hi save` format `%:color,l1,c1,l2,c2`, 1-based, end exclusive; `.hl.o` backup rename | autoload:1210-1252 | only `:AnnotMigrateHl` still reads it |
| `s:GetNearPosHighlight` (used by `Hi{}` jumps) deletes zero-width single-line marks on sight | autoload:662-665 | hi_store does not persist zero-width *fresh* marks; a stale mark parked on an empty line is zero-width but is persisted via the stale table, so a jump can delete it — accepted |

---

## 4. Data model

All under `vim.fn.stdpath('data')` (`~/.local/share/nvim/`, or `~/.local/share/<NVIM_APPNAME>/`).
Nothing is ever written into a repo.

### 4.1 Snapshot — `annot-snapshots/<file key>`

The file's text, one line per line, as `vim.fn.writefile(lines)` writes it. **Invariant I1**:
for every file with at least one mark, the positions in *both* stores are exact for this
text. **Invariant I2**: the snapshot exists iff the file has at least one mark
(`persist` deletes it otherwise).

### 4.2 Wash store — `highlighter/<file key>.json`

```jsonc
{ "version": 1,
  "marks": [
    { "color": 80,                 // N of HiColorN
      "l1": 89, "c1": 0,           // start: 0-based row, byte col   (extmark conventions)
      "l2": 89, "c2": 21,          // end:   0-based row, byte col, exclusive
      "anchor":     { "text": "vim.g.mapleader=''", "above": ["--NOTE:…"], "below": ["vim.g.maplocalleader=''", "…"], "col": 0 },
      "end_anchor": { "text": "…", "above": [...], "below": [...], "col": 21 },
      "stale": true                // present only when parked (§6.3)
    } ] }
```

`anchor`/`end_anchor` are `anchor.capture` of the start and end rows **plus `col`**, the
original column, so a resurrected range gets its width back. For a stale record they are the
anchors of *where the range was*; `l1..c2` are where it is *parked*.

### 4.3 Note store — `haunt/<sha256(root commit)[1:12]>.json` (haunt's own file)

haunt v2 shape with two added fields:

```jsonc
{ "version": 2,
  "bookmarks": [
    { "id": "8f4c9ac30a26cf39", "file": "init.lua",   // relative to project root (haunt)
      "line": 90, "note": "leader is space",          // 1-based (haunt)
      "anchor": { "text": "vim.g.mapleader=''", "above": [...], "below": [...] },
      "stale": true } ] }                              // present only when parked
```

Notes are line-only; no columns. `file` is resolved by haunt against the cwd's project root.

### 4.4 In-memory state

| Module | State | Lifetime |
|---|---|---|
| `versions` | `mapped[bufnr]` (bool), `detached[bufnr]` (bool), `snap_sha[bufnr]` (sha256 of snapshot text), `generation[bufnr]` (int), `pid_cache[root]`, `persisting` (re-entrancy guard) | per buffer until `BufWipeout`; cache forever |
| `hi_store` | `stale[bufnr][extmark_id] = record`, `loaded[bufnr]` | `stale` reset on detach/load; `loaded` gates pruning |
| `haunt_anchor` | `stale[id] = true`, `reported[bufnr] = generation` | `stale` cleared by resurrection, `on_update`, `on_delete` |

---

## 5. Program model

### 5.1 Per-buffer state machine

```
            open / :e / checktime
  ┌──────────┐  BufReadPre   ┌──────────┐  BufReadPost (or haunt restore, or remap)  ┌────────┐
  │ unmapped │ ────────────▶ │ detached │ ─────────── ensure_mapped ────────────────▶ │ mapped │
  └──────────┘               └──────────┘                                            └────────┘
       ▲                          ▲                                                       │
       │ BufWipeout (forget)      └──────────────────── BufReadPre (detach) ───────────────┘
```

- **detach** (`BufReadPre`, `remap`): `mapped = nil`, `detached = true`; clear the `HiColor`
  namespace; nil haunt's `extmark_id`/`annotation_extmark_id` for this file, clear haunt's
  marks + signs, `cleanup_buffer_tracking`. Persist **nothing** (3.3).
- **ensure_mapped** (`BufReadPost`; also the haunt restore wrapper and `remap`): no-op if
  `mapped and not detached`. Else: `cur = buffer lines`; `snap = read snapshot`;
  `mapper = snap and mapper(snap, cur)`; `hi_store.load(bufnr, cur, mapper)`;
  `haunt_anchor.reanchor(bufnr, cur, mapper)`; `mapped = true; detached = nil;
  generation += 1`; **`persist(bufnr)`** (re-base: positions and snapshot now describe `cur`).
- **persist(only?)**: for each loaded, `mapped`, non-`detached` buffer with a file key:
  `hi_store.write(b)` (records from live extmarks; delete store if none and `loaded[b]`),
  `haunt_anchor.capture_buffer(b)` (refresh anchors of non-stale notes; returns count), then
  write the snapshot if `has_washes or notes > 0` and its sha changed (else delete it);
  finally `haunt_anchor.save_store()` once. Guarded against re-entry (haunt's `on_post_save`
  calls back in).

### 5.2 Who triggers what

| Event | Handler | Effect |
|---|---|---|
| `BufReadPre` | `versions` autocmd | detach |
| `BufReadPost` | `versions` autocmd (registered at startup, so it runs *before* haunt's, which is registered at `UIEnter`) | ensure_mapped |
| haunt `restore_buffer_bookmarks(bufnr)` (BufReadPost, startup pass over loaded buffers, `api.reload`) | wrapper in `haunt_anchor` | ensure_mapped (no-op if done) → original restore → re-render stale notes with `⚠` → one notify per `generation` |
| wash made / erased / recolored (`t<CR>`, `f<BS>`, `f<C-L>`, `<leader>nr`, `<leader>na`) | annot.lua → `hi_store.autosave()` | `persist(0)` |
| note made / edited / deleted | haunt `store.save()` → `on_post_save` | `persist()` (all buffers) |
| `on_update` (note text changed) | `haunt_anchor` | clear stale, recapture anchors — the user vouched for the line |
| `BufWritePost`, `BufWinLeave` | `versions` | `persist(buf)` |
| `VimLeavePre` | `versions` | `persist()` |
| `<leader>Hl` | `versions.remap(0)` | detach → ensure_mapped → `haunt_anchor.redraw` |
| `<leader>Hs` | `hi_store.save()` | `persist(0)` + message |
| `BufWipeout` | `versions` | forget per-buffer state |

### 5.3 Ordering guarantees you rely on

1. `versions.setup()` runs in the vim-highlighter spec's `init` (startup, before any file is
   read), so its autocmds exist before the command-line file's `BufReadPost`.
2. haunt is `lazy = false`; `haunt_anchor.install()` runs in its `config`, so the restore and
   serializer wrappers exist before haunt's `UIEnter`-scheduled startup restore.
3. Within `ensure_mapped`, hi_store is loaded **before** haunt is re-anchored, and both before
   `persist` — so the persisted positions are the mapped ones and the snapshot is `cur`.
4. `persist` writes both stores **and** the snapshot in one call; there is no code path that
   writes one without the others (I1).

---

## 6. The mapping, precisely

Given hunks `H = [{sa, ca, sb, cb}, …]` sorted by `sa`, old line `l` (1-based), and whether the
position is a range *end*:

```
delta = 0
for each hunk:
  if ca == 0:                         -- insertion after old line sa
      if l <= sa: break               -- unaffected (a line equal to sa is before the insert)
      delta += cb
  else:
      if l < sa: break
      if l <= sa + ca - 1:            -- inside the hunk
          if cb == 0:                 -- deleted; gap follows new line sb
              return clamp(is_end ? sb : sb + 1, 1, n_new), 'deleted'
          k = l - sa
          off = is_end ? ceil((k+1) * cb / ca) - 1 : floor(k * cb / ca)
          return sb + clamp(off, 0, cb - 1), 'modified'
      delta += cb - ca
return clamp(l + delta, 1, n_new), 'exact'
```

- `ca == cb` ⇒ `off = k`: 1→1 exact pairing (what `linematch` produces for rewrites).
- `1 → M`: start on the first replacement line, end on the last (a range expands over the
  replacement). `N → 1`: both collapse onto it.
- **Deleted**: a start parks on the line *after* the gap, an end on the line *before*, both
  clamped into the file. For a wash whose start survived and whose end was deleted right
  after it, `end < start` can result; hi_store shrinks the range to its start line.

### 6.1 Columns (`map_col(old_line, new_line, c, is_end)`)

Only when the two lines' texts differ (whitespace changes included, since the diff ignored
them). `p` = common prefix length, `s` = common suffix length (bounded so they don't overlap),
`shift = #new - #old`:

| position | `c <= p` | `c >= #old - s` | in the rewritten middle |
|---|---|---|---|
| start | keep `c` — *unless* also `>= #old - s`, then shift | `c + shift` | `p` (front of the replacement) |
| end | keep `c` | `c + shift` — *unless* also `<= p`, then keep | `#new - s` (back of the replacement) |

The precedence rules encode gravity: text inserted at a range's start edge is not swallowed
(start clings to the text after it); text inserted at its end edge is not swallowed either.
Known cosmetic limit: rewrite + re-indent in one line (`vim.op.number` → `  vim.o.number`)
gives `p = 0`, so a start at 0 stays at 0 instead of moving to 2.

### 6.2 What a consumer does with the result

**hi_store.place(rec)** — in order:
1. `rec.stale` → try `resurrect()`; else park at `mapper.line(l1)` (whole line, stale).
2. else if `mapper` → map start (`is_end=false`) and end (`is_end=true`); both `deleted` → try
   `resurrect()`, else park at the start's parking line; otherwise place, shrinking `end` to
   `start` if it came out before it.
3. else (no snapshot) → `resurrect()` via anchors if present (stale unless exact), else the
   stored numbers clamped.
4. Clamp columns to the lines' lengths; `nvim_buf_set_extmark` in `HiColor` with
   `hl_group = 'HiColorN'`; remember the record in `stale[bufnr][id]` if stale.

**haunt_anchor.reanchor(bm)** — same three branches on `bm.line` only; a `deleted` result
tries `resurrect()` before parking; `stale[bm.id]` set/cleared accordingly. haunt then draws at
`bm.line`; the wrapper re-renders stale notes as `'⚠ ' .. note`.

### 6.3 Stale semantics (**Invariant I3**)

A stale mark's **anchors are never recaptured** — `capture_buffer` skips it, `records_of`
copies the stored anchors forward — so the text it is looking for survives any number of
saves while parked. It stops being stale when: `anchor.resolve` finds its text (any later
mapping), or, for notes, the user edits the note (`on_update`) or deletes it. Its *position*
does ride along through later mappings like any other mark, so it stays visible near where
its line was.

`anchor.resolve` is exact on whitespace-normalized text; neighbours only rank candidates
(nearest weighs 2, next 1) and are required for text under 3 characters (`}`, `end`). It is
the one place anything is "found again"; it is deliberately not reached for `exact` or
`modified` results.

---

## 7. Failure modes and what happens

| Situation | Behaviour |
|---|---|
| Snapshot missing (first run after upgrade; deleted by hand) | `mapper = nil` → anchors if the store has them, else stored numbers clamped; then `persist` creates the snapshot |
| Store missing, snapshot present | nothing to place; `persist` deletes the orphan snapshot (I2) |
| Snapshot present, file unchanged | `mapper.identity`, every position `exact` — cost one diff of equal texts |
| haunt not loaded (`require 'haunt.store'` fails) | `haunt_anchor` functions return early; washes work alone |
| Error inside `persist` | pcall → `vim.notify` WARN "annot: persist failed: …"; buffer state unchanged |
| `nvim_buf_set_extmark` rejects a position | pcall → that record is not placed this session and **not written back** (it is absent from the namespace); it stays in the store only if the store is not rewritten — `persist` rewrites from the namespace, so the record is lost. Clamping is there to make this unreachable |
| Buffer modified (unsaved) when the file changes on disk and the user chooses to reload | edits are discarded by nvim; marks are mapped from the last persisted state, which the discarded edits never reached — consistent, minus any drift those edits caused |
| Same file open in two nvims | each persists its own view; last writer wins. Snapshot and positions still go out together per writer (I1 holds per write) |
| Repo with no commits / not a repo | key falls back to `_abs/<path>`; everything else identical |

---

## 8. Invariants (the contract every edit must keep)

- **I1** For any file with marks, `hi store positions`, `haunt store positions` and
  `snapshot` were all written by the same `persist` call from the same buffer text.
- **I2** `snapshot exists ⇔ file has ≥ 1 mark`.
- **I3** A stale record's `anchor`/`end_anchor` are those of the range's original location and
  are never recaptured while stale.
- **I4** Nothing is captured from a buffer between `BufReadPre` and the next `ensure_mapped`
  (`detached` gates `persist`).
- **I5** `ensure_mapped` runs at most once per detach, regardless of how many paths call it.
- **I6** Marks hi_store places are indistinguishable from vim-highlighter's own (namespace,
  `hl_group`, no extra options), so every plugin key keeps working on them.
- **I7** All haunt mutation happens on the live references from `store.get_all_raw()`; haunt's
  own `extmark_id` sync must be neutralized (ids nil'd) before any `bm.line` write is trusted.

---

## 9. Testing

- `nvim --headless -u NONE -l tests/versions_spec.lua` — 33 checks: hunk conventions,
  parking at both ends of the file, `linematch` readings (1→3, 2→1, unrelated 4→7),
  whitespace-only lines, column prefix/suffix rules, deleted-position columns.
- `nvim --headless -u NONE -l tests/anchor_spec.lua` — 19 checks on the text fallback.
- **Live acceptance (do not run against the live config):** worktree at HEAD, symlinked to
  `~/.config/<appname>`, run with `NVIM_APPNAME=<appname>`; stores and snapshots then live under
  `~/.local/share/<appname>/`. Procedure that caught both `BufReadPre`/`changedtick` bugs:
  clone kickstart.nvim, annotate at `282cbb9`, edit a line and commit on a branch,
  `git checkout 80743df` in a shell, `:checktime` in nvim, dump
  `require('haunt.store').get_all_raw()` lines and the `HiColor` extmarks, check the snapshot
  equals the file on disk; check the branch back out and confirm the round trip is lossless.
- When changing anything in §6, add the case to `versions_spec.lua` *with the hunks pinned*
  (`eq(m.hunks, {...})`), so an xdiff behaviour change and a mapper bug are told apart.

---

## 10. Non-goals and rejected alternatives

- **Following history commit by commit** (`git blame --reverse -w -M -C`) was verified to give
  the same answers for surviving lines and would follow moves across files; not used because
  it needs both ends committed and an ancestor relation, making dirty trees, divergent
  branches and non-git files separate code paths. One xdiff path covers all of them.
- **Carrying marks with `git merge-file`** (marker tokens in a 3-way merge) needs no mapping
  code but cannot ignore whitespace, which is the single most important option (3.2).
- **Git blobs as snapshots** (`HEAD:path` when clean) save 40 KB per file and add a failure
  mode (dangling blobs are pruned; dirty files still need a copy). A plain copy was chosen.
- **Text search as the primary mechanism** (the 2026-09-28 design) treats an *edited* line as
  a different line. Kept only as the deleted-line fallback.
