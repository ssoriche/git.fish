# Worktree Cleanup: wlist, wclean smarts, and the --check nudge

**Date:** 2026-08-20
**Status:** Approved design, pending implementation plan

## Problem

Worktrees accumulate faster than they get cleaned up. `git wclean` today only
reaps worktrees whose HEAD is an *ancestor* of the integration branch, which
misses the most common modern case: squash-merged PRs, where the local commits
never appear in upstream history. The result is a growing pile of dead
worktrees, and nothing in the workflow reminds the user they exist.

Inspired by the pre-warmed-pool `wt` tool described in
<https://daveschumaker.net/use-git-worktrees-they-said-itll-be-fun-they-said/>,
but scoped to this project's actual pain: visibility and reaping, not slow
worktree creation. The pool concept was considered and deliberately deferred.

## Goals

1. **Visibility** — a dashboard (`git wlist`) showing every worktree's state.
2. **Smarter reaping** — `git wclean` detects squash-merged work via
   `[gone]` upstreams and closed GitHub PRs, and flags stale worktrees.
3. **A nudge** — `git wclean --check` emits a one-line summary suitable for
   `fish_greeting`/prompt integration, so forgotten worktrees surface
   themselves.

## Non-goals

- Pre-warmed worktree pools / slot recycling (deferred; separate feature if
  dependency-install cost ever justifies it).
- Forgejo/Gitea PR-state API integration. Non-GitHub remotes rely on
  gone-upstream detection, which fires on any forge once the PR branch is
  deleted. The forge dispatch point is designed so an API backend can be added
  later.
- Auto-removal of stale worktrees. Age alone never justifies deletion.
- Multi-repo scanning. `--check` covers the current repo/container only.

## Architecture

### Shared classifier: `functions/_git_worktree_status.fish`

A private helper (house pattern: `_git_bare_container.fish`,
`_git_help_from_doc_comment.fish`) that is the single source of truth for
"what state is this worktree in". `git-wlist`, `git-wclean`, and
`git wclean --check` all consume it, so they can never disagree about what is
reapable.

**Contract:**

```
_git_worktree_status [--no-forge] <worktree-path> <integration-branch> <stale-days> [protected-branch ...]
```

All inputs are explicit arguments — the classifier reads no globals and loads
no config, which keeps it pure and independently testable. Callers resolve
the integration branch (origin/HEAD, as wclean does today) and load config
first. To make that possible without duplicating wclean's config loader,
`_wclean_load_config` is extracted into a shared private helper
`_git_wclean_config` (same file format, same `~/.config/git-wclean/config`
path, same `_wclean_config_*` variable names) that both `git-wclean` and
`git-wlist` call.

On success, prints exactly one tab-separated line to stdout and returns 0:

```
<state>\t<branch>\t<upstream>\t<dirty>\t<age-days>\t<path>
```

- `branch` is the checked-out branch name, or `-` for detached HEAD.
- `upstream` is the configured upstream ref, or `-` if none.
- `dirty` is `clean` or `dirty`, from `git -C <path> status --porcelain`
  (non-empty output = dirty).
- `age-days` is whole days since HEAD's committer date.

**States, decided in precedence order (first match wins):**

| State       | Condition                                                                                    |
| ----------- | -------------------------------------------------------------------------------------------- |
| `protected` | Branch is in the protected-branches set (defaults: main, master, develop, trunk — matching the existing `_wclean_config_protected_branches` default — plus wclean config) |
| `detached`  | Worktree is on a detached HEAD                                                                |
| `merged`    | HEAD is an ancestor of the integration branch (existing wclean ancestry check, relocated)     |
| `pr-closed` | The branch's upstream remote (falling back to `origin`) has a github.com URL, `gh` is available/authenticated, and `gh pr view <branch> --json state` — invoked with the worktree as its working directory so `gh` resolves the repo from its remotes — reports `MERGED` or `CLOSED` |
| `gone`      | Branch has an upstream configured but its remote-tracking ref no longer exists                |
| `stale`     | HEAD committer date older than `<stale-days>` days (default 30)                               |
| `active`    | Everything else                                                                               |

**Fetching:** the classifier performs no fetch. Each consuming command runs
one `git fetch --prune` (bounded by the existing `fetch_timeout` config) up
front, then classifies all worktrees against that snapshot — one fetch per
command run, never per worktree. Note this is a deliberate behavior change to
existing `git-wclean`, which currently fetches *without* `--prune`; the
`--prune` is what makes gone-detection possible and needs its own test
coverage.

**Network in the classifier:** only the `gh` call, only for github.com
remotes, only when `gh` is installed and authenticated. Any `gh` failure
(missing, unauthenticated, rate-limited) silently skips the `pr-closed` check
for that run; affected worktrees fall through to `gone`/`stale`/`active`.
`gh` has no client-side timeout mechanism, so the check is gated by a
classifier flag: `--no-forge` disables the `pr-closed` state entirely.
Interactive commands (`git-wlist`, full `git wclean`) run with forge checks
on — a slow `gh` there is visible and interruptible. `git wclean --check`
always passes `--no-forge` (see below), so a hung `gh` can never stall a
prompt hook. Caveat: `gh pr view <branch>` reports the most recent PR for a
branch name, so a *reused* branch name whose old PR was merged classifies as
`pr-closed`; the clean-tree requirement plus the per-worktree confirm prompt
makes this low-risk.

**Failure behavior:** if the path is not a registered, resolvable worktree or
a `git -C` command fails mid-classification, the classifier prints
`error\t-\t-\t-\t-\t<path>` and returns 1. Consumers must treat `error` as
"keep and report", never as a removal candidate.

**Safety property:** a failed or timed-out fetch can never make gone-detection
more aggressive. `gone` requires an upstream to be *configured* while its
tracking ref is *missing*; only a successful `fetch --prune` removes tracking
refs, so a network failure cannot fabricate a `gone` state.

## Commands

### `git-wlist` (new)

```
git wlist [-h|--help] [-s|--stale-days N]
```

Read-only dashboard. Works anywhere inside a container or plain repo.
Enumeration uses `git worktree list --porcelain` — the registered-worktree
list — **not** wclean's directory scan. This is a deliberate difference: it
requires no directory argument, works in plain repos, and is the source of
git's `locked`/`prunable` annotations. Consequence (accepted): a registered
worktree living outside a wclean target directory appears in wlist but is
untouched by a wclean run over that directory, and an *unregistered* stray
directory is invisible to wlist. Runs one `fetch --prune` (timeout-bounded),
classifies every worktree, prints an aligned table sorted
reapable-states-first, oldest-first:

NAME is the basename of the worktree path.

```
NAME          BRANCH        STATE      DIRTY  AGE
pr-1423       pr-1423       pr-closed  clean  12d
fix-auth      fix-auth      gone       clean  8d
big-refactor  big-refactor  stale      dirty  45d
main          main          protected  clean  0d
feature-x     feature-x     active     clean  1d
```

Git's own `locked` and `prunable` worktree annotations are appended to the
NAME column when present. No porcelain output mode (YAGNI — the classifier's
line format is already the machine interface if one is ever needed).

Exit status: 0 success, 1 invalid arguments, 2 git failure.

### `git-wclean` (extended)

Per-worktree action is now driven by classifier state:

| State                   | Action                                                                                       |
| ----------------------- | -------------------------------------------------------------------------------------------- |
| `merged`                | Removed with no prompt (existing behavior, unchanged); `--dry-run` lists as "would remove"   |
| `pr-closed`, `gone`     | If clean: single `y/N` prompt per worktree (e.g. `Remove 'fix-auth' (upstream gone)? [y/N]`). `--force` skips the prompt; `--dry-run` lists as "would remove (needs confirm)". If dirty: kept and reported. |
| `stale`                 | Never removed (even with `--force`); listed in a "stale — review manually" summary section    |
| `protected`, `detached`, `active`, any dirty | Kept, as today                                                          |

`--force` and protected branches: today `--force` bypasses protected-branch
skipping (documented as "Force removal including protected worktrees"), and
that escape hatch is preserved without duplicating logic: when `--force` is
set, wclean passes an **empty** protected-branch list to the classifier, so
protected worktrees classify by the remaining rules (`merged`, `gone`, …) and
are handled like any other worktree. Without `--force`, the protected list is
passed and `protected` wins precedence as specified.

New flag: `--stale-days N` (overrides config). Existing `--dry-run`,
`--force`, `--no-delete-branch` apply uniformly. New config variable in
`~/.config/git-wclean/config`, following the existing convention:
`_wclean_config_stale_days` (default 30), loaded by the shared
`_git_wclean_config` helper so `git-wlist` reads the identical value (along
with `fetch_timeout` and protected branches). The summary output gains
per-category counts.

Refactor boundary: `_wclean_check_merge_status` and the classification parts
of `_wclean_get_worktree_info` migrate into `_git_worktree_status`, and
`_wclean_load_config` becomes the shared `_git_wclean_config` helper. The
removal machinery, path validation, protected-branch enforcement, system-dir
protection, and signal handlers are untouched.

### `git wclean --check` (new mode)

The nudge for `fish_greeting`/prompt integration. Unlike the rest of wclean,
`--check` takes no directory argument and enumerates via
`git worktree list --porcelain` (same mechanism as wlist), so it works in
plain repos and `.bare` containers alike — exactly the contexts a generic
greeting hook runs in. It always passes `--no-forge` to the classifier, so no
`gh` call can ever hang the shell; squash-merged PRs still surface via `gone`
once the branch is deleted. It fetches (timeout-bounded), classifies, and
prints **at most one line**, only when something is reapable:

```
git-wclean: 3 reapable (1 merged, 1 gone, 1 pr-closed), 1 stale — run 'git wclean'
```

- Silent with exit 0 when nothing is reapable — including when stale
  worktrees exist but reapable count is 0. The stale count is appended only
  when at least one worktree is reapable; stale alone never makes the
  greeting noisy.
- Always exits 0, including on errors (not a repo, fetch failure): a prompt
  hook must never break the shell, and a greeting cannot act on errors anyway.
- A documented fish_greeting one-liner ships in the README.

## Error handling

- **Fetch timeout/failure:** proceed with last-known remote state; warn on
  stderr (`warning: fetch failed; results may be stale`). `--check` stays
  silent. Gone-detection cannot be inflated by a failed fetch (see safety
  property above).
- **`gh` unavailable:** `pr-closed` silently skipped; gone-detection carries
  the load.
- **Detached / locked / prunable worktrees:** surfaced by wlist, never
  auto-removed.
- Exit codes follow house style: 0 success, 1 invalid args, 2 git failure
  (except `--check`, always 0).

## Testing

Extends `tests/functional-tests.fish` using the existing throwaway
fixture-repo pattern (commit signing disabled):

- **Classifier:** fixture repo + bare "remote"; assert the exact state line
  for: merged branch; squash-merge simulation (delete remote branch, `fetch
  --prune` → `gone`); stale via backdated `GIT_COMMITTER_DATE`; dirty tree;
  detached HEAD; protected branch.
- **`gh` stub:** a PATH-shim script makes `pr-closed` testable offline,
  covering `MERGED`, `OPEN`, and gh-absent.
- **wclean:** gone+clean prompts answered `y` and `n` via stdin; `--force`
  skips prompts; `--dry-run` removes nothing; stale never removed even with
  `--force`; `--force` still removes a merged protected worktree (empty
  protected list passed to classifier) while the default run keeps it; a
  squash-merged branch survives a fetch *without* `--prune` but classifies
  `gone` after `fetch --prune`.
- **`--check`:** silent + exit 0 when clean; one-line summary when reapable;
  silent + exit 0 outside a repo; works in a plain repo with no directory
  argument; never invokes the `gh` stub (verifying `--no-forge`).
- **Classifier failure:** invalid worktree path yields the `error` line,
  return 1, and is never treated as a removal candidate by wclean.
- Syntax, `fish_indent`, and `--help` checks pick up new files via existing
  test globs.

## Decisions log

| Decision                | Choice                                                        |
| ----------------------- | ------------------------------------------------------------- |
| Gone-upstream safety    | Reapable when clean, per-worktree y/N confirm                 |
| Fetch policy            | Every command fetches, bounded by `fetch_timeout`             |
| Forge dispatch          | By remote host; GitHub via `gh`, others via gone heuristic    |
| Nudge scope             | Current repo only; user wires greeting/prompt themselves      |
| Stale policy            | Report-only, default 30 days, configurable                    |
| Architecture            | Shared `_git_worktree_status` classifier helper               |
| Classifier inputs       | Explicit arguments; shared `_git_wclean_config` config loader |
| Enumeration             | wlist/--check via `git worktree list --porcelain`; wclean keeps its directory scan |
| gh hang risk            | `--check` always classifies with `--no-forge`                 |
| `--force` vs protected  | Escape hatch preserved: `--force` passes an empty protected list to the classifier |
| Pre-warmed pool         | Deferred (not this project's pain)                            |
