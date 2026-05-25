# Worktree-creating commands anchor names to the container in bare layout

When invoked inside a `.bare` container layout (see ADR 0001), `git-wadd`, `git-wpr`, and `git-wrm` treat their first positional argument as a worktree NAME — resolved to `<container>/<name>` — rather than as a path resolved relative to cwd. Outside a bare layout, the argument behaves as a path (current behavior preserved). Names containing `/` are rejected in the bare layout to keep the container flat (use `.` or `-` as separators).

## Considered Options

- **Rule A: bare names only get anchored** (no slash in arg). Rejected: collides with common `<github-id>/<description>` branch-naming conventions.
- **Rule B: anchor any arg that doesn't start with `/`, `./`, `../`, or `~`** (chosen, then tightened). The explicit-path forms remain escape hatches in regular repos but the bare layout removes path semantics entirely — names with `/` are rejected outright to keep the container directory flat.
- **Rule C: always anchor unless absolute.** Rejected: too aggressive — `./foo` and `../bar` are clearly cwd-relative; remapping them silently would surprise users.

## Consequences

- The argument's meaning depends on cwd-as-bare-layout-or-not. A shared helper (`_git_bare_container`) provides the detection so each command resolves it the same way.
- Users in a bare layout never need to `cd` to the container before running `wadd`/`wpr`/`wrm` — names just work from any worktree.
- A worktree name like `feature/foo` is rejected with a clear error; the user picks `feature.foo` or `feature-foo` instead. Branch names are unaffected and can still contain `/`.
