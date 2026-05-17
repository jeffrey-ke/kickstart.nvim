# `:St` / `:St!` / `:Com` — staging + commit popup

User added `lua/custom/stage_commit.lua`, wired in via `require('custom.stage_commit').setup()` at the bottom of `lua/keymaps.lua`. It defines three user commands:

| Command | Effect |
|---|---|
| `:St` / `[range]St` | Stage the current hunk (or visual range) via gitsigns. |
| `:St!` / `[range]St!` | Same as `:St`, then open a floating commit popup restricted to the current file (`git commit -- <path>`). |
| `:Com` | Open the commit popup for whatever is staged repo-wide. |

The popup is an `acwrite` `gitcommit` buffer. `:wq` commits via `git commit -F <tempfile>`; `:q!` cancels.

## Bugs fixed during this session

### 1. gitsigns staging is async

**Symptom:** `:St!` reported "nothing staged" even though `git diff --cached` showed the line had been staged.

**Cause:** `gitsigns.stage_hunk()` returns immediately and schedules the `git apply --cached` for later. The popup's existence check ran before staging had actually mutated the index.

**Fix:** Snapshot `git diff --cached` before calling `stage_hunk`, then `vim.wait(2000, ..., 30)` until the snapshot differs. If the wait times out, bail with a warning instead of opening an empty popup.

### 2. git ran in the wrong repo

**Symptom:** Even after the async fix, `:St!` on `file.py` still said "nothing staged for file.py" — but the file *was* staged, and the popup still didn't appear.

**Cause:** `vim.system({'git', ...})` inherits nvim's cwd. When editing a file in some other project, nvim's cwd was a different repo entirely, so `git diff --cached -- /abs/path/to/file.py` was querying the wrong repository and returning empty. Gitsigns dodged this because it attaches per-buffer and knows the file's real repo.

**Fix:** Every `run_git` call now accepts a `cwd` argument. The buffer's directory (after `vim.fn.resolve` for symlinks) is passed for `:St` / `:St!`; `vim.fn.getcwd()` for `:Com`. `M.popup.cwd` is stored so the eventual `git commit` in `on_write` also runs in the right repo.

## Pattern worth remembering

When wrapping plugins that use vim's async runtime (gitsigns, telescope, lspconfig handlers), don't assume side effects are visible synchronously after the call returns. Either:

- Use the plugin's async-aware callback API if one exists, or
- `vim.wait` on an observable side effect (here: `git diff --cached` output changing).

And: never trust nvim's cwd to match the buffer's repo. For any per-file git operation, derive cwd from the buffer path.
