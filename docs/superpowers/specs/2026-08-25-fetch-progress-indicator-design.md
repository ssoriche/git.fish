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
  background a `begin … end` block or a function: fish has never forked for
  blocks or functions (there are no subshells), so they run synchronously
  and `$last_pid` stays empty. This is a design constraint of the shell, not
  a version quirk; `$last_pid` itself exists since fish 3.1, so every version
  in the CI matrix (3.3.1, 3.6.0, latest) has it. Because the helper only
  ever backgrounds an external `sh`, the CI matrix exercises the real
  behavior on all three versions through the functional tests below. The
  job must be a single external command:

  ```fish
  sh -c 'GIT_TERMINAL_PROMPT=0 git fetch "$@" >/dev/null 2>&1 &
         echo $! >"$0.pid"; wait $!; echo $? >"$0"' \
      $status_file $fetch_args 2>/dev/null &
  ```

  The scratch status file (from `mktemp`) carries the fetch's exit status,
  since fish's `wait` does not propagate job status. It is passed as the
  sh script's `$0` positional — fish locals are not exported, so referencing
  a `$STATUS_FILE` variable inside the single-quoted script would silently
  expand to empty and lose the status. The wrapper also records the `git
  fetch` pid in `$0.pid` via POSIX `$!` before `wait`ing on it, so the
  helper can target the git process directly on the timeout path without
  any process-table tool (`pgrep` was the previous design; `$!` has no
  dependency and cannot race with git forking). The outer `2>/dev/null`
  matters too: it silences the wrapper's own job notice
  (`Terminated: 15  git fetch …`) that `sh` otherwise prints to the
  inherited stderr when its child is killed on the timeout path.
  `$last_pid` is the `sh` wrapper's pid; the `git fetch` process is its
  *child*, whose pid is in the pid file.
- When the job ends before timeout, the helper `wait`s on `$last_pid` (the
  wrapper is already gone, so this returns immediately — it just makes the
  reap explicit on every path, not only the timeout path) and then reads the
  status file: `0` → return 0; anything else, including an empty or missing
  file (the exact symptom of a wrapper plumbing bug) → return 2.
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
- When elapsed ≥ timeout: call `_git_fetch_progress_kill_tree $last_pid
  $git_pid` (where `$git_pid` is read from `$0.pid` and may be empty), then
  return **124** regardless of what lands in the status file (matches
  coreutils `timeout`, which callers already test for). The `sh` wrapper then
  exits on its own after writing git's signal status, which avoids fish's
  "Job N terminated" notice that SIGTERM-ing the job itself would print in an
  interactive shell. Before removing the scratch files, the timeout path
  briefly waits for the wrapper to exit (bounded — it dies as soon as git
  does); deleting the files first would let the wrapper's trailing `echo`
  recreate the status file and leak it in `$TMPDIR`.
  - *`_git_fetch_progress_kill_tree <wrapper-pid> [<git-pid>]`* is a private
    function in the same file so the test suite can drive its fallbacks
    directly. It builds a kill set from two independent sources and SIGTERMs
    the union (never `<wrapper-pid>` itself, see the job-notice point above):
    1. every descendant of `<wrapper-pid>` found by walking `ps -eo
       pid=,ppid=` breadth-first — this reaches git *and* its transport
       whether or not the pid file was written;
    2. `<git-pid>` when non-empty — this reaches git even when `ps` is
       unavailable.
    Returns 0 when at least one source contributed a target, 1 when neither
    did (no `ps` *and* empty pid). In that case the helper kills
    `<wrapper-pid>` alone and returns **125** instead of 124 so callers can
    tell "timed out, fetch is dead" from "timed out, fetch may still be
    running". The helper prints nothing on this path: the return code is the
    whole signal, and the caller-owned warning (see *Error handling*) is what
    the user sees. This keeps the `--quiet` contract literal — the helper's
    only output is ever the in-progress indicator, so `--quiet` is silent on
    every path including 125. That double failure requires both a broken
    `$TMPDIR` mid-run and a system without `ps`; it is surfaced to the
    caller rather than designed around.
  - *Why git itself must die:* killing only `$last_pid` would orphan the
    still-running `git fetch` — unacceptable for `git-wclean`, which goes on
    to delete branches while that fetch mutates refs. Both sources above
    reach git, so an empty or missing pid file (the wrapper-plumbing-bug
    symptom) does **not** leave git alive: the `ps` walk from the wrapper
    finds it anyway.
  - *Why the descendants must die too:* git does **not** propagate SIGTERM to
    its transport child. Verified with git 2.55 and
    `GIT_SSH_COMMAND='sh -c "sleep 6047"'`: after `kill -TERM <git pid>` the
    `sleep` survived as an orphan. Today's coreutils `timeout` kills the
    whole process group, so trusting git here would be a regression that
    leaks a hung `ssh` per timed-out fetch. The `ps` walk covers them (`ps`
    is in the base system on macOS and in procps and busybox on Linux, so it
    is far more universal than `pgrep`). If `ps` is somehow unavailable, the
    pid file still kills git alone: ref safety is preserved because git is
    dead; the orphaned transport self-terminates.
  - A process-group kill (`kill -- -$last_pid`) is not an option: background
    jobs only get their own pgroup in interactive fish; non-interactively
    (tests, CI, scripts) they share the caller's pgroup and a group kill
    would take out the harness.
- Return codes: **0** fetch succeeded, **1** invalid arguments, **2** fetch
  failed (or `mktemp` failure, or empty/missing status file), **124** timed
  out and the fetch tree was killed, **125** timed out but the fetch could
  not be confirmed stopped (the double-failure path above). Callers keep ownership of
  user-facing success/warning lines — the helper draws only the in-progress
  indicator.
- **Interruption (Ctrl-C / SIGTERM):** the background job has its own
  process group, so without handling the wrapper and `git fetch` would
  outlive an interrupted command with no timeout enforcer left alive, and
  both scratch files would leak — a regression from today's
  `timeout git fetch`, where Ctrl-C kills the whole foreground group. All
  cleanup goes through one shared `_git_fetch_progress_abort`, which reads
  the in-flight job from the global `_git_fetch_progress_job`
  (`<status-file> <wrapper-pid>`, set immediately after the wrapper is
  spawned and erased on every return path), erases it, sets the global
  flag `_git_fetch_progress_interrupted`, runs
  `_git_fetch_progress_kill_tree` with the wrapper pid and the pid-file
  contents, waits briefly for the wrapper as the timeout path does, clears
  the spinner line when stderr is a TTY, and removes both scratch files.
  When the job global is unset the abort is a no-op, so every hook below is
  inert outside a fetch. The abort is reached two ways, because fish
  behaves differently depending on who receives the signal (verified on
  fish 4.9.3):
  - *Interactive Ctrl-C* is delivered to the foreground external command —
    the spinner's `sleep 0.1`, which runs in its own process group. Fish
    itself never receives SIGINT and does **not** run `--on-signal INT`
    handlers; it simply cancels the running function. So the helper also
    defines `_git_fetch_progress_on_postexec --on-event fish_postexec`:
    `fish_postexec` fires after every interactive command line, including
    one cancelled by Ctrl-C, and runs the abort (then erases the
    interrupted flag, since no helper loop is left to consume it). Verified
    in a pty: the global is cleared, the fetch tree is killed, and `TMPDIR`
    is emptied.
  - *When fish itself receives the signal* (non-interactive scripts, CI,
    `kill -INT <fish pid>`), the two handler functions in the same file —
    `_git_fetch_progress_on_int --on-signal INT` and
    `_git_fetch_progress_on_term --on-signal TERM` (fish accepts one signal
    per handler, the same pattern `git-wclean` uses) — run the abort. Fish
    does **not** cancel the function afterwards: the spinner loop resumes.
    The loop therefore checks `_git_fetch_progress_interrupted` at the top
    of every iteration; when it is set the loop breaks, the helper erases
    the flag, makes sure both scratch files and the job global are gone,
    and returns **130**.
  The helper also erases a stale interrupted flag on entry, so an abort
  with no loop to consume it can never cut the next fetch short.
- Cleans up both scratch files (status and pid) on every path, including
  interruption via the hooks above. The globals are
  `_git_fetch_progress_job`, which exists only while a job is in flight,
  and `_git_fetch_progress_interrupted`, which exists only between an abort
  and the loop (or postexec hook) that consumes it; the hook functions are
  defined at file load and carry no state of their own. Does not check remote existence — the `contains origin (git remote)`
  guards stay in the callers.

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

- Fetch failure (2) and a clean timeout (124) are non-fatal everywhere,
  exactly as today: each caller warns and proceeds with local information.
- An unconfirmed timeout (125) is handled by what the caller does next:
  - `git-wclean` (full run and `--check`) and `git-wrm` go on to delete
    worktrees and branches, so they treat 125 as fatal: print their own
    warning that the fetch timed out and could not be confirmed stopped
    (the helper itself prints nothing on 125 — it owns only the indicator),
    remove nothing, exit 2. A fetch that may still be rewriting
    remote-tracking refs must not race a branch deletion. `--check` stays
    silent and simply exits 2, as its `--quiet` hook contract requires.
  - `git-wlist` is read-only, so it warns and proceeds like 124; the worst
    outcome is a slightly stale dashboard.
- A Ctrl-C during the spinner runs the abort described under *Helper
  contract → Interruption*: the fetch tree is killed, both scratch files are
  removed, and the spinner line is cleared — the same end state as
  interrupting today's `timeout git fetch`. Interactively fish has already
  abandoned the command, and the `fish_postexec` hook cleans up after it.
  When the signal reaches fish instead, the helper returns 130 and every
  caller stops at once with 130 and does no further work: `git-wclean` (full
  run, after its normal cleanup, and `--check`, silently), `git-wlist` (no
  table), and `git-wrm` (which pops its `pushd` first; no message, since
  the user pressed Ctrl-C).
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
    returns promptly, the git pid recorded in the pid file is gone, and the
    transport process is gone too. The fixture makes the transport uniquely
    identifiable (e.g. `sleep 6047` with an unusual duration) and the test
    asserts directly with `pgrep -f` that no such process survives — git is
    *not* trusted to reap it (see the timeout bullet above: it does not).
  - kill-tree fallbacks, driving `_git_fetch_progress_kill_tree` directly
    against a hand-built wrapper `sh -c 'sleep 6049 & echo $! >"$0"; wait'`
    so each source can be removed in isolation:
    - pid file suppressed: call with an *empty* git pid → the `ps` walk alone
      must leave no `sleep 6049` behind (this is the "pid file empty or
      missing" path on the real timeout route).
    - `ps` suppressed: call with the git pid under a shim PATH that lacks
      `ps` → `sleep 6049` must still be gone (pid-file source alone).
    - both suppressed: empty pid *and* no `ps` → function returns 1 and the
      `sleep 6049` is expected to *survive* (the test kills it itself
      afterwards); this is the one case where cleanup is honestly
      unconfirmed, which is exactly why it maps to 125 rather than 124.
  - 125 propagation: stub `_git_fetch_progress` with a test-local function
    that returns 125 and assert that `git-wclean` (full run and `--check`)
    and `git-wrm` exit 2 having removed nothing, while `git-wlist` still
    prints its table.
  - interruption, non-interactive: run the helper in a child `fish -c`
    against the hanging `ssh://` fixture with a generous `--timeout`, a
    private `TMPDIR`, and `GIT_SSH_COMMAND='sh -c "sleep 6048"'`; the child
    prints `rc=<status>` and exits with the helper's status. After the label
    line appears, send SIGINT to the child fish pid *only* (fish itself
    receives the signal, as in scripts and CI). Assert the child exits with
    130, its stderr contains `rc=130`, no `sleep 6048` or `git fetch`
    process survives, and the private `TMPDIR` is empty.
  - interruption, interactive: Ctrl-C never reaches fish, so a child fish
    registers a fake in-flight job (real scratch files plus a harmless
    sleeping wrapper) and runs `emit fish_postexec`; assert both scratch
    files are gone and neither the job global nor the interrupted flag
    remains. The full interactive path is checked manually in a pty: start
    the helper against the hanging fixture in `fish -i`, press Ctrl-C, and
    confirm no `sleep 6048` survives, `TMPDIR` is empty, and
    `_git_fetch_progress_job` is unset.
  - 130 propagation: stub `_git_fetch_progress` to return 130 and assert
    `git-wclean` (full run and `--check`, the latter silent), `git-wlist`,
    and `git-wrm` all exit 130 having removed nothing, with `git-wrm`
    leaving the cwd unchanged.
  - quiet: `--quiet` produces no output on any path, including 125 — the
    both-suppressed kill-tree fixture above is driven through the real
    helper (shim PATH without `ps`, pid file emptied before the timeout
    fires) and stderr is asserted empty.
  - stream separation: non-TTY label line lands on stderr; stdout stays
    empty.
- **Rework of existing `--check` tests that assert the removed behavior**
  (`tests/functional-tests.fish`):
  - Test 4 (~line 2302, "no timeout utility → fetch skipped") asserts the
    gone-branch ref is *not* pruned when `timeout`/`gtimeout` are absent —
    inverted by the always-fetch design. Its PATH shim (only `git`, `date`,
    `basename`) also lacks the helper's dependencies (`sh`, `mktemp`,
    `sleep`, `ps`, `rm` — fish has no builtin `rm`; the status and pid files
    should be read with fish's builtin `read < file`, not `cat`, to avoid one
    more dependency), so left alone it could keep passing accidentally through the
    helper's mktemp-failure path. Rewrite it to assert the new behavior (fetch runs,
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
