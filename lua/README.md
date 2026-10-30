# lua/

## Normal-mode keys that insert a shell command's output

`insert_command_output(argv, cwd)` in `keymaps.lua` is the normal-mode, inline form of
`:r !cmd`. It runs `argv` from `cwd` (default: the current buffer's directory), waits for it, and
puts its stdout after the cursor as one line, space-joining multiple lines.
A nonzero exit or empty output inserts nothing, so cancelling a picker is a no-op.

The command can be interactive if it brings its own UI. nvim blocks while it
runs and gives it no terminal, but `fzf --tmux` opens a tmux popup and prints
the pick to stdout, so it works as-is. A plain `fzf` without `--tmux` would have
no tty to draw on.

Except inside a tmux popup: tmux will not open a popup from another one, so
`fzf --tmux` exits 0 at once with nothing picked. `insert_terminal_output(argv, cwd)`
is the variant for there. It runs `argv` in a floating terminal with `TMUX`
unset, so fzf draws inline, and inserts its stdout the same way once it exits.
A popup is detectable because tmux sets `TMUX_PANE` only for a pane's processes.

Adding a key:

```lua
vim.keymap.set('n', '<lhs>', function()
  insert_command_output { 'cmd', 'arg', ... }
end, { desc = '...' })
```

To try a command before mapping it, run `:r !cmd`, which puts the output below
the current line. If that works, the mapping will work too.

Current users:

- `<C-g>` + `b e f h l r s t w`: the fzf-git.sh pickers (branches, refs,
  files, hashes, reflog, remotes, stashes, tags, worktrees), through
  `bash ~/dotfiles/fzf-git.sh/fzf-git.sh --run <picker>`. The letters match the
  shell's `C-g` bindings. They run from the buffer's directory when it is in a
  git repo, else from nvim's cwd, so they work in bash's vi-mode `v` buffer
  (`/tmp/lineedit.*/line.sh`), where nvim's cwd is the shell's. That editor
  runs in a tmux popup, so there they take `insert_terminal_output`. A bare
  `<C-g>` (file info) now waits out `timeoutlen`.
