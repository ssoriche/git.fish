# Fetch Progress Indicator — Design

**Date:** 2026-08-25
**Status:** Approved design, pending implementation

## Problem

Three commands run a `git fetch` before doing their real work, and on a slow
or unreachable remote they sit silent — the user cannot tell a slow fetch
from a hung command:

- `git-wlist` fetches silently up front (`functions/git-wlist.fish:87-100`)
- `git-wrm` fetches silently mid-verification (`functions/git-wrm.fish:218-238`)
- `git-wclean`'s `_wclean_fetch_remotes` prints a static line only on the
  timeout-utility path; the no-`timeout` fallback fetches silently and
  unbounded (`functions/git-wclean.fish:301-332`)

All three also carry a duplicated two-branch dance around the optional
`timeout`/`gtimeout` coreutils dependency, and `git-wclean --check` skips the
fetch entirely when no timeout utility exists.

## Decision

Add one shared private helper, `_git_fetch_progress`, that runs the fetch as
a background job and animates a spinner with elapsed time in the foreground.
Because the foreground loop tracks elapsed time itself, it enforces the
timeout natively by killing the job — the `timeout`/`gtimeout` dependency is
removed entirely.

Chosen over: (a) inline spinners per function — triplicates the loop, the
same duplication `_git_worktree_status` exists to prevent; (b) wrapping a
spinner around the existing `timeout_cmd` branches — keeps the dual-branch
complexity and the unbounded no-coreutils path.

`git-wclone` is out of scope: git's native clone/fetch progress already
shows there and is genuinely useful for long clones.

## Helper contract

New file `functions/_git_fetch_progress.fish`:

```
_git_fetch_progress --label <text> --timeout <secs> [--quiet] -- <git-fetch-args…>
```

- Runs `env GIT_TERMINAL_PROMPT=0 git fetch <args> >/dev/null 2>&1` as a fish
  background job (`begin …; end &`), capturing the fetch's exit status via a
  scratch file in `mktemp` (fish's `wait` does not propagate job status). Job
  pid comes from `$last_pid`.
- Foreground loop sleeps 0.1s per iteration, derives elapsed seconds from the
  iteration count, and:
  - **TTY + not quiet:** redraws `\r⠋ <label>… <N>s` cycling braille frames
    (⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏); clears the line with `\r\033[K` on completion.
  - **non-TTY + not quiet:** prints `<label>…` once before starting; no
    animation (clean CI logs and pipes). TTY detection via `isatty stdout`.
  - **`--quiet`:** no output at all (for the `--check` prompt hook).
- When elapsed ≥ timeout: `kill` the job, return **124** (matches coreutils
  `timeout`, which callers already test for).
- Return codes: **0** fetch succeeded, **1** invalid arguments, **2** fetch
  failed, **124** timed out. Callers keep ownership of user-facing
  success/warning lines — the helper draws only the in-progress indicator.
- Cleans up its scratch file on every path. Sets no globals.

## Call-site changes

1. **`_wclean_fetch_remotes`** (`git-wclean.fish`): the whole
   `timeout_cmd` block collapses to one helper call with
   `--timeout $_wclean_config_fetch_timeout`; the existing
   `✓ Fetched from origin` / timed-out / failed warnings key off the return
   status unchanged.
2. **`_wclean_run_check`** (`git-wclean.fish`): calls the helper with
   `--quiet`. Behavior improvement: `--check` previously skipped the fetch
   when no timeout utility existed; the native timeout means it now always
   fetches, still bounded and still silent. `GIT_TERMINAL_PROMPT=0` moves
   into the helper.
3. **`git-wlist`**: inline fetch block becomes one helper call. The comment
   explaining why it was kept inline ("wclean's helper prints progress and
   sets wclean globals") is obsolete and goes away.
4. **`git-wrm`**: helper call with `--timeout 30` (keeps its current
   hardcoded value; adopting `_git_wclean_config` there is out of scope) and
   fetch args `$remote_name $branch_name`; label
   `Fetching latest from <remote>`.

## Error handling

- Fetch failure and timeout are non-fatal everywhere, exactly as today: each
  caller warns and proceeds with local information.
- A Ctrl-C during the spinner kills the foreground loop; the background fetch
  (own process group) may briefly outlive it. Accepted: `git fetch` is
  idempotent, read-only, and self-terminating. Exposure is comparable to
  today's `timeout git fetch` being interrupted.
- If `mktemp` fails the helper returns 2 immediately (treated as fetch
  failure by callers).

## Testing

- Syntax tests pick up the new file automatically.
- Functional tests (non-TTY in the harness, so they exercise the static-line
  path):
  - success: fetch from a local `file://` remote → status 0, label line
    printed once.
  - failure: fetch from a nonexistent remote path → status 2.
  - timeout: `GIT_SSH_COMMAND='sleep 60' git fetch ssh://…` via the helper
    with `--timeout 1` → status 124, returns promptly.
  - quiet: `--quiet` produces no output on any path.

## Documentation

- README: remove `timeout`/`gtimeout` from optional dependencies (no longer
  used anywhere).
- CLAUDE.md: add `_git_fetch_progress` to the shared private helpers list.
