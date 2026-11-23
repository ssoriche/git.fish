---
name: git-fish
description: Use when creating, checking out, listing, switching between, removing, or cleaning up git worktrees; starting a branch in its own worktree; checking out a GitHub PR as a worktree; cloning a repo into a bare worktree layout; or when a directory has a `.bare/` folder beside a `.git` file. Covers the git.fish bare layout and its commands (git wclone, wadd, wpr, wlist, wrm, wclean, bclean).
---

# git.fish worktree commands

The user's git is extended by git.fish: fish functions reachable as `git <sub>`.
Prefer them over raw `git worktree` / `git clone` for any worktree task.

## Running them

The Bash tool is not fish. Always run through fish:

    fish -c 'git wadd feat-x'

Check availability once per session: `fish -c 'git wadd --help >/dev/null'`.
If that fails, git.fish (or its `git` wrapper) is not installed: fall back to
plain git and say so.

Commands that "change to the new worktree" (`wclone`, `wadd`, `wpr`) only change
the fish subprocess's directory. `cd` into the result yourself afterwards.

For flags, arguments, and exit codes run `fish -c 'git <sub> --help'`. The help
text is the source of truth; do not guess flags.

## The bare layout

    myrepo/               <- container directory (not itself a git repo)
      .bare/              <- the bare repository
      .git                <- file: "gitdir: ./.bare"
      main/               <- initial worktree (default branch, made at clone time)
      ssoriche.feat-x/    <- another worktree, a sibling of main/

- Detect it: a directory with `.bare/` and a `.git` *file*. From anywhere
  inside, `fish -c _git_bare_container` prints the container directory
  (exit 1 when not in a bare layout).
- Inside a bare layout, `wadd`, `wpr`, and `wrm` take a **worktree name**, not a
  path: it is anchored to the container directory no matter which worktree
  you run from. Names must not contain `/`; use `.` or `-` (`ssoriche.feat-x`).
- Outside a bare layout the argument is an ordinary path relative to cwd.
- Never run `git fetch --depth` in a container: it grafts a shallow boundary
  that breaks every worktree's history.

## Which command for which job

| Job | Command |
|---|---|
| Clone a repo into a bare layout | `git wclone <url> [dest]` |
| Start work on a new branch | `git wadd <name> [start-point]` (creates branch `<name>`; the start point defaults to the current branch's upstream, else `origin/main`, so pass the integration branch explicitly when it matters) |
| Check out an existing local branch as a worktree | `git wadd <branch>`; for a branch name containing `/` (rejected as a worktree name) use `git worktree add <container>/<name-without-slash> <branch>` |
| Check out a GitHub PR | `git wpr <pr-number> [name]` |
| See every worktree's state (merged, pr-merged, pr-closed, gone, stale, active) | `git wlist` |
| Remove one worktree after its work is merged | `git wrm <name>` |
| Remove all merged worktrees | `git wclean` in a bare layout (defaults to the container directory); elsewhere `git wclean <worktrees-directory>` |
| Delete merged local branches | `git bclean` |
| Print the current branch | `cwb` |
| Diff / show without a pager | `git diff-plain`, `git show-plain` |
| Jump between worktrees | `git wjump` is interactive (fzf + cd): do not use it. Use `git wlist` and `cd` to the path instead |

## Destructive commands

`git wrm`, `git wclean`, and `git bclean` delete worktrees and branches.

- Run each command with `--dry-run` first and show the user what would go.
  `git wlist` is an extra overview, not a substitute: it does not show local
  branches without a worktree, which `bclean` can delete.
- `git wrm --dry-run <name>` gives the verdict without removing anything:
  exit 0 means it would be removed, exit 3 means the work is not merged, and
  exit 4 means it is merged but has uncommitted changes (listed in the
  output). On 3 or 4, stop and ask the user.
- Removing a worktree deletes everything in it that is not committed. If the
  installed `wrm` predates exit 4 (its `--help` does not list it), also run
  `git -C <path> status --porcelain --untracked-files=all` first (the flag
  matters: `status.showUntrackedFiles=no` would hide untracked files); if it
  prints anything, stop and ask the user.
- Ignored files (`.env`, local config) are deleted too and show in neither
  check. Run `git -C <path> status --porcelain --ignored`; if anything other
  than build output or dependencies is listed, name it to the user first.
- Do not pass `--force` unless the user asks for it.
- `wclean` asks for confirmation on `gone` and `pr-closed` rows; those may hold
  unmerged work. Leave that decision to the user.
- Never remove a bare-layout worktree with raw `git worktree remove` or `rm -rf`;
  `git wrm` checks that the work is merged first.
