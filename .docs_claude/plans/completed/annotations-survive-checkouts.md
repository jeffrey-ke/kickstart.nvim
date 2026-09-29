# Annotations and washes that survive checkouts and worktrees

**Status: completed 2026-09-28.** Files: `lua/custom/anchor.lua` (new),
`lua/custom/haunt_anchor.lua` (new), `lua/custom/hi_store.lua` (new),
`lua/custom/annot.lua`, `lua/custom/plugins/haunt.lua`,
`lua/custom/plugins/highlighter.lua`, `tests/anchor_spec.lua` (new).

## Problem

haunt notes (`<leader>nn`) and vim-highlighter washes (`<leader>na`, `t<CR>`) vanished on
`git checkout` and never appeared in a new worktree. Two unrelated causes:

- haunt's store was keyed `sha256(root_commit .. "|" .. branch)` because
  `per_branch_bookmarks = true`. Another branch → another, empty file. A detached
  worktree is keyed by its short hash, so it never matched anything.
- Washes were keyed by the buffer's **absolute path** (`annot.lua`'s `M.slug`), so a
  worktree at a different path found nothing.

Sharing the stores exposes the third problem: both plugins persist only a line number,
so a note lands on the wrong line whenever the file differs between branches. And a
reload (`:e`, autoread after a checkout) leaves the extmarks **frozen at their old
rows** — verified headless on 0.12: after the read the mark reports the row it had
before, regardless of gravity — so the old `BufWinEnter` + `b:hi_restored` guard kept the
wrong rows and the next save wrote them back.

## What was done

| Piece | Where | What |
|---|---|---|
| Content anchor | `lua/custom/anchor.lua` | Pure functions over a lines array: `capture(lines, lnum)` → `{text, above[2], below[2]}` (whitespace stripped, nearest *non-blank* neighbours, two per side); `resolve(lines, anchor, expect, lo)` scores every line with equal text by neighbour agreement (nearest neighbour weighs 2, next 1; membership, not position), distance breaks ties; text under 3 chars needs at least one neighbour; `resolve_span` anchors both ends of a wash, the end searched at/after the new start |
| haunt integration | `lua/custom/haunt_anchor.lua` | `per_branch_bookmarks = false`; wraps `persistence._build_serializable` so `bookmark.anchor` reaches the JSON (load already keeps unknown fields); wraps `restoration.restore_buffer_bookmarks` to resolve before haunt draws; `BufReadPre` syncs the store once then drops the buffer's marks/signs/ids and restore tracking; anchors captured on `on_pre_save`, `BufWritePost` (which also calls `store.save()` — haunt has no TextChanged autosave despite its docs) and after every restore; `:HauntMergeBranches` |
| wash store | `lua/custom/hi_store.lua` | Replaces `:Hi save/load`. One JSON per file at `stdpath('data')/highlighter/<root commit:12>/<relpath, / → %>.json` (`_abs/` outside a repo); root from the *buffer's* path via `vim.fs.root(path, '.git')`, not cwd. Records `{color, l1, c1, l2, c2, anchor, end_anchor}`; marks re-created with `nvim_buf_set_extmark` in the plugin's `HiColor` namespace, indistinguishable from its own (erase, jump, `:Hi save`, `recolor()` all handle them). `BufReadPre` clears the namespace, `BufReadPost` loads. Pattern highlights are no longer persisted. `:AnnotMigrateHl` |
| Stale marks | both | Not found anywhere → old line clamped to the file, note drawn with `⚠ `, one notify per buffer, and — the part that matters — **the record/anchor is kept verbatim through later saves**, so the text it is looking for survives until the line reappears (checking the original branch back out heals it) or the note is edited/deleted |

## Verified (tmux, `NVIM_APPNAME=nvim-anchor` on a HEAD worktree of this config)

Scratch repo, branch `b` = 10 lines inserted at top, `beta()` moved to the end, `pass`
deleted, `delta()` re-indented; a detached worktree of `a`.

| Step | Result |
|---|---|
| notes on `y = 2`, `class Gamma` (3-line wash), `pass`; bare wash on `z = 3` | stores written with anchors |
| `git checkout b` + `:checktime` | `y = 2` → 29, `class Gamma` → 17, `z = 3` → 21 (re-indented); `pass` note ⚠ at old line; Gamma wash 17–19 (end lost, length kept, stale); one notify each |
| `:e` again, `:w` | no duplicates; stale records verbatim on disk (`l1=10,l2=12`, anchor `pass`) |
| fresh nvim started in the worktree | all 3 notes + 3 washes at their `a` lines |
| `checkout a` + `:checktime` | everything heals, ⚠ gone |
| `:cd /tmp` + `:e` | washes still load (per-buffer key); haunt's notes follow its own cwd-project rule |
| `f<BS>`, `f<C-L>` | store rewritten without the mark; deleted when empty |
| insert a line + `:w` | haunt store lines on disk shift with it (BufWritePost save) |
| `:HauntMergeBranches` in the work monorepo (copied stores) | 15 bookmarks from 3 branch files → shared file; 2 unmatched listed |
| `:AnnotMigrateHl` (copied `.hl`) | 1 + 4 + 7 washes converted, 3 gone files skipped; opening `track_birth_labels.cc` restores 7 notes + 7 washes |
| `nvim --headless -u NONE -l tests/anchor_spec.lua` | 19 checks pass |

## Traps worth keeping

- **Extmarks freeze across a reload; they do not collapse or track.** Any "re-restore
  on BufReadPost" has to remove them on `BufReadPre`, or the plugin's guards and syncs
  see them as live.
- haunt syncs `bookmark.line` from the extmark on *every* read (`store.get_all_raw()`),
  so a resolved line is overwritten unless `extmark_id` is nil first.
- haunt's project is **cwd-based**: a worktree file opened from an nvim whose cwd is
  another worktree shows no notes (the relative paths resolve against the cwd's root).
  One nvim per worktree — the normal pattern — is fine.
- With `per_branch_bookmarks = false` haunt's HEAD watcher is inert; a checkout is
  handled by the reload path instead.
- vim-highlighter's `:Hi save` errors (E716) on `line_hl_group` marks; nothing here
  makes one, so `hi_store` records only `hl_group` spans.
- Anchoring one context line per side is not enough: the `return nil` that ends one
  function has the same neighbour below as the one that ends the next once a block
  moves. Two per side, membership-scored, was the smallest thing that told them apart.

## Migration (one-off, per repo)

`:HauntMergeBranches` with cwd in the repo: recomputes every `sha256(pid|branch)` from
`for-each-ref` + worktree HEADs + `__default__`, merges by id into `sha256(pid)`, renames
sources to `.bak`, lists unmatched files. `:AnnotMigrateHl`: converts each `.hl` in the
data dir (path from the slug, anchors from the file on disk), renames to `.bak`. Old nvim
sessions still running the previous config write per-branch stores on exit; re-run the
merge after they are gone.
