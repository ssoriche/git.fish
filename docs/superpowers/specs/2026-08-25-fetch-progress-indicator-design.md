# Fetch Progress Indicator — Design

**Date:** 2026-08-25
**Status:** Approved design, pending implementation

## Problem

Three commands run a `git fetch` before doing their real work, and on a slow
or unreachable remote nothing moves — the user cannot tell a slow fetch from
a hung command:

- `git-wlist` fetches silently up front (`functions/git-wlist.fish:87-100`)
- `git-wrm` prints a static `Fetching latest from <remote>...` line, then
  nothing until the fetch returns (`functions/git-wrm.fish:218-238`)
- `git-wclean`'s `_wclean_fetch_remotes` prints a static line on both paths,
  but the no-`timeout` fallback fetches unbounded
  (`functions/git-wclean.fish:301-332`)

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

- Runs the fetch as a backgrounded external wrapper command — fish cannot
  background a `begin … end` block or a function (verified on fish 4.7.1:
  they run synchronously and `$last_pid` stays empty), so the job must be a
  single external command:

  ```fish
  sh -c 'GIT_TERMINAL_PROMPT=0 git fetch "$@" >/dev/null 2>&1; echo $? >"$STATUS_FILE"' -- $fetch_args &
  ```

  The scratch `$STATUS_FILE` (from `mktemp`) carries the fetch's exit status,
  since fish's `wait` does not propagate job status. `$last_pid` is the `sh`
  wrapper's pid; the `git fetch` process is its *child*.
- `GIT_TERMINAL_PROMPT=0` applies at every call site (today only `--check`
  sets it). This is an intended behavior change: a fetch that would have
  prompted for credentials now fails and the caller warns — a background job
  can't take a prompt anyway.
- All indicator output goes to **stderr** (git's own convention for progress),
  so piped stdout — notably `git wlist | …` — never gains a progress line.
  TTY detection is therefore `isatty stderr`.
- Foreground loop: exits as soon as the job is gone (liveness check via
  `kill -0 $last_pid`), sleeps 0.1s per iteration, derives elapsed seconds
  from epoch time (`date +%s` at start vs. now — iteration counting
  undercounts because draw/spawn overhead adds to each cycle), and:
  - **TTY + not quiet:** redraws `\r⠋ <label>… <N>s` cycling braille frames
    (⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏); clears the line with `\r\033[K` on completion.
  - **non-TTY + not quiet:** prints `<label>…` once before starting; no
    animation (clean CI logs and pipes).
  - **`--quiet`:** no output at all (for the `--check` prompt hook).
- When elapsed ≥ timeout: kill the *git child* — the pids from
  `pgrep -P $last_pid` (`pgrep` is base on both macOS and Linux) — and return
  **124** regardless of what lands in the status file (matches coreutils
  `timeout`, which callers already test for). The `sh` wrapper then exits on
  its own after writing git's signal status, which avoids fish's
  "Job N terminated" notice that SIGTERM-ing the job itself would print in an
  interactive shell. Killing only `$last_pid` would instead orphan the
  still-running `git fetch` — unacceptable for `git-wclean`, which goes on to
  delete branches while that fetch mutates refs. A process-group kill
  (`kill -- -$last_pid`) is not an option: background jobs only get their own
  pgroup in interactive fish; non-interactively (tests, CI, scripts) they
  share the caller's pgroup and a group kill would take out the harness. If
  `pgrep` is somehow unavailable, kill `$last_pid` alone and accept the
  orphaned fetch (it self-terminates).
- Return codes: **0** fetch succeeded, **1** invalid arguments, **2** fetch
  failed (or `mktemp` failure), **124** timed out. Callers keep ownership of
  user-facing success/warning lines — the helper draws only the in-progress
  indicator.
- Cleans up its scratch file on every path. Sets no globals. Does not check
  remote existence — the `contains origin (git remote)` guards stay in the
  callers.

## Call-site changes

1. **`_wclean_fetch_remotes`** (`git-wclean.fish`): the whole
   `timeout_cmd` block collapses to one helper call with
   `--label "Fetching from origin"` and
   `--timeout $_wclean_config_fetch_timeout`; the existing
   `✓ Fetched from origin` / timed-out / failed warnings key off the return
   status unchanged.
2. **`_wclean_run_check`** (`git-wclean.fish`): calls the helper with
   `--quiet` (a label is still passed but never drawn), keeping its existing
   `contains origin (git remote)` guard.
   Behavior improvement: `--check` previously skipped the fetch when no
   timeout utility existed; the native timeout means it now always fetches,
   still bounded and still silent. `GIT_TERMINAL_PROMPT=0` moves into the
   helper.
3. **`git-wlist`**: inline fetch block becomes one helper call with
   `--label "Fetching from origin"` and
   `--timeout $_wclean_config_fetch_timeout` (already loaded there). The
   comment explaining why it was kept inline ("wclean's helper prints
   progress and sets wclean globals") is obsolete and goes away.
4. **`git-wrm`**: helper call with `--timeout 30` (keeps its current
   hardcoded value; adopting `_git_wclean_config` there is out of scope) and
   fetch args `$remote_name $branch_name`; label
   `Fetching latest from <remote>`.

## Error handling

- Fetch failure and timeout are non-fatal everywhere, exactly as today: each
  caller warns and proceeds with local information.
- A Ctrl-C during the spinner kills the foreground loop; the background fetch
  may briefly outlive it (interactively it sits in its own process group and
  won't receive the SIGINT). Accepted: `git fetch` is idempotent, read-only
  in the worktree, and self-terminating, and the interrupted command does no
  further work afterwards. Exposure is comparable to today's
  `timeout git fetch` being interrupted.
- If `mktemp` fails the helper returns 2 immediately (treated as fetch
  failure by callers).

## Testing

- Syntax tests pick up the new file automatically.
- Functional tests (non-TTY in the harness, so they exercise the static-line
  path):
  - success: fetch from a local `file://` remote → status 0, label line
    printed once.
  - failure: fetch from a nonexistent remote path → status 2.
  - timeout: fetch from an `ssh://` remote with
    `GIT_SSH_COMMAND='sh -c "sleep 60"'` (git appends host/command as
    positional args, which the inner `sh -c` ignores, so the transport
    genuinely hangs — a bare `sleep 60` would reject the extra operands and
    fail fast instead) via the helper with `--timeout 1` → status 124,
    returns promptly, and the fetch's direct child (`pgrep -P` target) is
    gone afterwards (`pgrep -P` kills one level deep; git's own SIGTERM
    handling is trusted to reap its transport grandchildren).
  - quiet: `--quiet` produces no output on any path.
  - stream separation: non-TTY label line lands on stderr; stdout stays
    empty.
- **Rework of existing `--check` tests that assert the removed behavior**
  (`tests/functional-tests.fish`):
  - Test 4 (~line 2302, "no timeout utility → fetch skipped") asserts the
    gone-branch ref is *not* pruned when `timeout`/`gtimeout` are absent —
    inverted by the always-fetch design. Its PATH shim (only `git`, `date`,
    `basename`) also lacks `mktemp`, `sleep`, `env`, `sh`, and `pgrep`, so
    left alone it could keep passing accidentally through the helper's
    mktemp-failure path. Rewrite it to assert the new behavior (fetch runs,
    bounded) with a shim PATH that includes the helper's dependencies.
  - Test 5 (~line 2334) and the Test 3 comment (~lines 2284-2287) rely on
    the skipped fetch for network isolation — Test 5 points origin at a real
    `https://github.com/...` URL. With the fetch now always live, repoint
    origin at a local `file://` path (or unreachable local address plus a
    short configured timeout) so CI never touches the network.

## Documentation

- Sweep every `timeout`/`gtimeout` mention: README optional dependencies and
  the fetch-timeout prose (~lines 296-298, 364-366 — "--check skips the
  fetch entirely when no timeout utility is installed" becomes false), plus
  in-function doc comments at `git-wlist.fish:26`, `git-wrm.fish:218-221`,
  and `git-wclean.fish:301-304` / `699-704`.
- CLAUDE.md: add `_git_fetch_progress` to the shared private helpers list.
