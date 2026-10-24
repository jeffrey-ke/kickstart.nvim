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
  (`/tmp/bash-fc.*`), where nvim's cwd is the shell's. A bare `<C-g>` (file
  info) now waits out `timeoutlen`.
