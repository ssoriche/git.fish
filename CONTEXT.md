# git.fish

Fish shell functions that enhance git workflow, with a specific opinion about how repositories should be laid out for worktree-heavy work.

## Language

**Bare layout**:
The canonical repository organization for this project: a container directory holds a `.bare/` bare repo, a top-level `.git` file pointing at it, and sibling worktree directories.
_Avoid_: "worktree workflow" (too vague), ".bare clone" (verb-y)

**Container directory**:
The top-level directory of a bare layout — holds `.bare/`, the `.git` pointer file, and one directory per worktree.
_Avoid_: "project directory", "repo root", "parent directory"

**Initial worktree**:
The worktree created at clone time for the repository's default branch. Named after the branch (e.g., `main/`).
_Avoid_: "default worktree", "main worktree", "primary worktree"

**Worktree name**:
The argument passed to worktree-creating commands (`wadd`, `wpr`) inside a **bare layout**. A name, not a path — it gets anchored to the **container directory**. Must not contain `/` (use `.` or `-` as separators, e.g., `ssoriche.feat-x`).
_Avoid_: "worktree path" (paths are explicit; names are anchored)

## Relationships

- A **container directory** contains exactly one bare repo (at `.bare/`) and zero or more worktrees as sibling directories
- The **initial worktree** is one of those sibling directories, distinguished only by being created at clone time
- All worktree subcommands (`wadd`, `wjump`, `wrm`, `wclean`, `wpr`) operate within a **bare layout**

## Example dialogue

> **User:** "Where does `git wadd feature-x` put the worktree?"
> **Maintainer:** "Inside the **container directory**, as a sibling to the `.bare/` directory and the **initial worktree**."

## Flagged ambiguities

- "the repo" was used to mean both the bare repo (`.bare/`) and the **container directory** — resolved: the container directory is not itself a git repo, just a directory that holds one.
