# Annotations carried across file versions by diff, not by text search

**Status: completed 2026-09-29.** Follow-up to
[annotations-survive-checkouts.md](annotations-survive-checkouts.md) (2026-09-28), which shared
the note/wash stores across branches and worktrees and re-found lines by *content*. Files:
`lua/custom/versions.lua` (new), `lua/custom/hi_store.lua`, `lua/custom/haunt_anchor.lua`,
`lua/custom/anchor.lua` (demoted to fallback), `lua/custom/plugins/highlighter.lua`,
`tests/versions_spec.lua` (new).

## Why the change

Content matching had one behaviour the user did not want: a line you *edit* is, to a text
search, a different line. Edit `vim.opt.number` → `vim.op.number`, save, check out a commit
where upstream has `vim.o.number`, and the note is ⚠ — it was looking for text nobody has. The
request was the Google-Docs / review-tool model: a mark is a *position in a known version of
the text*, and moving to another version means accumulating the edits between the two.

## What was done

| Piece | Where | What |
|---|---|---|
| Snapshot | `versions.lua` | One copy of the file text per annotated file, `stdpath('data')/annot-snapshots/<root commit:12>/<rel%path>`, written whenever the stores are (`persist()`): a mark made or erased, `:w`, `BufWinLeave`, `VimLeavePre`, haunt's own `on_post_save`. Deleted when the file has no marks left. It is *the* text the stored positions are exact for; both stores share it |
| Mapping | `versions.mapper(old, new)` | xdiff via `vim.diff` / `vim.text.diff` (0.12) with `result_type='indices'`, `algorithm='histogram'`, `ignore_whitespace`, `linematch=60`. `line(l, is_end)` → new line + `exact`/`modified`/`deleted`; `pos(l, c, is_end)` adds a column through common prefix/suffix of the two lines (a start clings to the text after it, an end to the text before it, so insertions at a range's edge are not swallowed). Inside an N→M hunk positions map proportionally; `linematch` makes most rewrites 1→1 |
| Lifecycle | `versions.lua` | `BufReadPre` → `detach` (clear both plugins' marks, mark buffer detached, invalidate mapping); `BufReadPost` and haunt's restore wrapper → `ensure_mapped` (once per detach: read snapshot, map both stores' positions, then `persist` = re-base); `remap()` for `<leader>Hl` |
| Consumers | `hi_store.load/write`, `haunt_anchor.reanchor/capture_buffer` | take `(bufnr, lines, mapper)`; nothing else knows about snapshots |
| Fallback | `anchor.lua` | only for `deleted` positions (resurrection when the same text turns up) and for stores from before snapshots existed |
| Keys | `versions.file_key` | moved here from hi_store; `<root commit:12>/<rel%path>`, `_abs/…` outside a repo |

## Verified (tmux, `NVIM_APPNAME=nvim-anchor` on a HEAD worktree)

Demo repo: a clone of kickstart.nvim. Notes/washes made at `282cbb9` (2025-02), the user
edited `vim.opt.number` → `vim.op.number` plus two inserted lines, committed as branch `jeff`.

| Step | Result |
|---|---|
| open on `jeff` (stores from the text-anchor era, no snapshot) | all 7 marks at 91/104/166/200–202 via anchors; snapshot written == file |
| `checkout 80743df` (2026-09, whole file re-indented, `vim.opt`→`vim.o`) + `:checktime` | `vim.op.number` note+wash → **110 `vim.o.number = true`**, not stale; others 98/186/249–251; wash columns +2 for the indent; snapshot re-based; no warnings |
| `checkout jeff` + `:checktime` | everything back at 91/104/166/200–202, original columns; snapshot == `jeff` file |
| `tests/versions_spec.lua` | 33 checks: hunk conventions, deletion parking at both ends of the file, 1→3 and 2→1 as linematch reads them, an unrelated 4→7 block, whitespace-only lines, prefix/suffix columns |

## Traps found (and measured)

- **At `BufReadPre` the buffer is already empty** — one blank line, with the extmarks still
  there, frozen. Anything captured from the buffer at that moment (a snapshot, an anchor) is
  garbage. Nothing is persisted at detach; every mutation already persisted itself, and unsaved
  edits are exactly what the reload discards.
- **At `BufReadPost` `changedtick` is still the pre-reload value** (4 → 4, then 5 afterwards).
  A tick-keyed "already mapped" guard treats a reload as done and a tick-keyed snapshot cache
  skips the rewrite. Mapping state is a flag cleared by detach; the snapshot is compared by
  content sha.
- `vim.diff` indices mirror the unified header: for a 0-count side, `start` is the line the
  change comes *after* (`{2,0,3,2}` = insert new 3–4 after old 2; `{3,1,2,0}` = delete old 3,
  gap after new 2).
- `linematch` reads `c → c1 c2 c3` as "insert two, rewrite c into c3" and `c d → C` as
  "delete c, rewrite d": the mark follows the diff's pairing, not a guess at intent. The spec
  pins these so a change in xdiff shows up.
- Without `ignore_whitespace`, upstream's whole-file re-indent makes every line a change and
  the mapping is worse than text search. With it, a re-indented line is `exact` and only the
  column mapping sees the indent.
- Prefix/suffix column mapping can't separate "rewrite" from "re-indent" in one line
  (`vim.op.number` → `  vim.o.number`): the start lands at col 0 instead of 2. Cosmetic.

## What git offers instead, and why it was not used for the mapping

`git blame --reverse -w -M -C -L n,n A..B` answers "where did line n go" through the actual
commit path and was verified to agree (90→98, 164→186, 198→249; the rewritten line stops at
the last commit that had it). It needs both ends committed and an ancestor relation, so the
dirty-buffer, divergent-branch and non-git cases all need a second code path — while xdiff via
`vim.diff` is the same engine with one path. `git merge-file` with marker tokens would carry
positions with zero mapping code but has no ignore-whitespace. Snapshots could be
`HEAD:path` blobs when clean; a 40 KB copy was chosen over a second failure mode.
