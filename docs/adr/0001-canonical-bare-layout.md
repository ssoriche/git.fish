# Canonical `.bare` layout

git.fish standardizes on the `.bare` container layout for worktree-heavy workflows: a top-level directory holds `.bare/` (the bare repo), a `.git` file pointing at it, and one sibling directory per worktree. `git wclone` is the entry point that constructs this layout; all other worktree commands assume it (with backward-compatible fallback for non-bare repos).

## Considered Options

- **Sibling-directory layout** (one regular clone + sibling worktree directories elsewhere): rejected because the main checkout collides in name with one of the worktrees, and worktree organization scatters across the filesystem.
- **Support both layouts as first-class** (no canonical choice): rejected because every command's documentation would have to branch on layout, and users would face the same "which way do I do this?" tax forever.
- **Container layout** (chosen): one directory contains everything for a project. `git wclone` builds it; every worktree is a peer; nothing collides.

## Consequences

- README and command examples describe the container layout as the default. Legacy sibling-layout usage continues to work but is no longer shown.
- Worktree-aware commands (`wadd`, `wpr`, `wrm`, `wclean`) detect the layout and adapt their behavior — see ADR 0002.
