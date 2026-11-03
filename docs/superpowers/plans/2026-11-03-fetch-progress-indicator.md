# Fetch Progress Indicator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the three copy-pasted `timeout`/`gtimeout` fetch blocks in `git-wclean`, `git-wlist`, and `git-wrm` with one shared helper, `_git_fetch_progress`, that runs `git fetch` in the background, draws a spinner on a TTY, and enforces the timeout itself.

**Architecture:** One new autoloaded file `functions/_git_fetch_progress.fish` holds the public helper plus four private siblings: `_git_fetch_progress_kill_tree` (SIGTERM a wrapper's descendants and/or a known git pid), `_git_fetch_progress_wait_gone` (bounded wait for a pid), `_git_fetch_progress_abort` (shared Ctrl-C/SIGTERM cleanup) and the two one-signal handler functions that call it. The fetch runs as a single backgrounded external `sh -c` wrapper that records git's pid in a pid file and git's exit status in a status file; fish polls `kill -0` on the wrapper, draws, and kills the tree when elapsed time passes the timeout. Callers switch on the return code (0/2/124/125) and keep ownership of all user-facing success and warning lines.

**Tech Stack:** fish shell (3.3.1+ compatible; `$last_pid` needs 3.1), POSIX `sh`, `git`, `ps`, `mktemp`, `sleep`, `date`, `kill`. Tests are plain fish functions in `tests/functional-tests.fish`.

**Spec:** `docs/superpowers/specs/2026-08-25-fetch-progress-indicator-design.md` — read it first; every task below cites the spec bullet it implements.

## Global Constraints

- Fish syntax rules enforced by `tests/syntax-tests.fish` on every file in `functions/`: never write `test … -a …` or `test … -o …` (the grep is `test.*-a\|test.*-o` on any uncommented line, so keep `set -a` and `-o` flags off lines that also contain the word `test`); never `$(…)`; never `==`; `; and` / `; or` between tests; `test -e .git` not `test -d .git`.
- Formatting: 4-space indent, 100-char lines in `functions/*.fish`, output of `fish_indent` must be byte-identical (`fish_indent < f | diff -u f -`).
- `printf`, never `echo`, inside `functions/*.fish`. (Tests may use `echo`; they already do.)
- `argparse` for all argument handling; `set -l` for locals; conventional-commit messages; no self-credit in commits.
- The helper's only output is the indicator, always on **stderr**; it never prints warnings. Callers own every user-facing line (spec: *Helper contract*, return-codes bullet).
- `GIT_TERMINAL_PROMPT=0` is set inside the wrapper for every call site (spec: intended behavior change).
- Return codes: **0** fetched, **1** bad args, **2** fetch failed / `mktemp` failed / empty status file, **124** timed out and tree killed, **125** timed out but unconfirmed (no `ps` *and* empty pid file). `git-wclean` (full and `--check`) and `git-wrm` treat 125 as fatal (remove nothing, exit 2); `git-wlist` warns and proceeds.
- Scratch files (status file and `<status file>.pid`, from `mktemp`) are removed on every path including interruption. The one global is `_git_fetch_progress_job`, present only while a fetch is in flight.
- No process-group kill anywhere (`kill -- -$pid`): non-interactive fish shares the caller's pgroup.
- Tests must never touch the network: hanging transports are simulated with `GIT_SSH_COMMAND='sh -c "sleep <unique>"'` against `ssh://localhost/...` URLs; each fixture uses a unique sleep duration so `pgrep -f` can assert the transport is gone.
- CI runs on `ubuntu-latest` with Ubuntu's `fish` package (3.x) and no `timeout` tricks; `ps`, `pgrep`, `pkill` are in procps there and in the macOS base system.
- `_git_fetch_progress_kill_tree` and the other private siblings live in `_git_fetch_progress.fish`, so tests must `source functions/_git_fetch_progress.fish` explicitly (autoload only finds a function whose name matches the file name).
- Running one test function without the whole suite (the file auto-runs only when executed directly):

  ```fish
  set -gx FISH_FUNCTIONS_DIR $PWD/functions
  set -p fish_function_path $FISH_FUNCTIONS_DIR
  sed '/^# Run tests if script is executed directly/,$d' tests/functional-tests.fish | source
  test_git_fetch_progress
  ```

- Verified fish semantics the code relies on (fish 4.9.3 locally; re-verify on CI through the tests): `read var <file` assigns to an *existing* local declared in an enclosing block (so declare with `set -l var ''` first, then `read var <file` inside an `if`); `set -l x (cmd)` leaves `$status` as `cmd`'s status; `wait <pid>` on an already-reaped pid returns 0 (stderr silenced); `kill -0` on a dead pid returns 1; a `--on-signal INT` handler fires both when SIGINT is delivered to a non-interactive fish and when Ctrl-C is typed at an interactive fish whose foreground job is an external `sleep`, and in both cases the interrupted function does not resume; `kill` in fish is a function wrapping the external `kill`, so PATH shims need `kill` too.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `functions/_git_fetch_progress.fish` (create) | Helper + kill-tree + wait-gone + abort + INT/TERM handlers. Nothing else. |
| `functions/git-wclean.fish` (modify) | `_wclean_fetch_remotes` (~285-347) and `_wclean_run_check` (~833-849) call the helper; 125 → return non-zero so `git-wclean` exits 2 (main already does `if not _wclean_fetch_remotes … return 2`). Help EXIT STATUS text (~1010-1017), inline comments. |
| `functions/git-wlist.fish` (modify) | Fetch block (~87-100) → helper; 124/125 warn and proceed. Doc comment lines 25-26. |
| `functions/git-wrm.fish` (modify) | Fetch block (~227-247) → helper; 125 → exit 2. Inline comment 228-230. |
| `tests/functional-tests.fish` (modify) | New `test_git_fetch_progress` (helper behavior) and `test_git_fetch_progress_callers` (125 propagation); rework `test_git_wclean_check` Tests 4 and 5; register the two new functions in `run_functional_tests`. |
| `README.md`, `CLAUDE.md` (modify) | Remove `timeout`/`gtimeout` dependency claims; document the helper. |

---

### Task 1: Helper skeleton — argument validation, success and failure paths

**Files:**
- Create: `functions/_git_fetch_progress.fish`
- Test: `tests/functional-tests.fish` (new function `test_git_fetch_progress`, registered in `run_functional_tests`)

**Interfaces:**
- Produces: `_git_fetch_progress --label <text> --timeout <secs> [--quiet] -- <git-fetch-args…>` returning 0/1/2 (124/125 come in Task 3). Sets global `_git_fetch_progress_job` (`<status-file> <wrapper-pid>`) while the job is in flight and erases it before returning.
- Spec bullets: *Helper contract* — wrapper command, status file via `$0`, pid file via `$!`, normal-completion `wait`, stderr-only output, non-TTY label line, `--quiet`.

- [ ] **Step 1: Write the failing tests (Tests 1-3 and the fixture)**

Insert this function in `tests/functional-tests.fish` immediately before `function run_functional_tests`:

```fish
function test_git_fetch_progress --description "Test _git_fetch_progress: success, failure, timeout, kill-tree, quiet, interruption"
    set -l test_functions_dir "$FISH_FUNCTIONS_DIR"
    if test -z "$test_functions_dir"
        set -l test_file_dir (dirname (status --current-filename))
        set test_functions_dir "$test_file_dir/../functions"
        if test -d "$test_functions_dir"
            set test_functions_dir (realpath "$test_functions_dir")
        end
    end
    set -l failed_tests 0
    set -l total_tests 0

    echo "🔍 Testing _git_fetch_progress..."

    set -p fish_function_path $test_functions_dir
    # The kill-tree and abort siblings live in this file, so autoload alone
    # would not find them; source it explicitly.
    source $test_functions_dir/_git_fetch_progress.fish

    # Fixture: a bare remote, a clone, a private TMPDIR (so "no scratch files
    # left behind" is a directory-is-empty check), and a capture dir for
    # stdout/stderr that must NOT live under TMPDIR.
    set -l remote_dir /tmp/git-fish-fp-remote-(random).git
    set -l repo_dir /tmp/git-fish-fp-repo-(random)
    set -l tmp_dir /tmp/git-fish-fp-tmp-(random)
    set -l cap_dir /tmp/git-fish-fp-cap-(random)
    rm -rf "$remote_dir" "$repo_dir" "$tmp_dir" "$cap_dir"
    mkdir -p "$tmp_dir" "$cap_dir"
    git init --bare -b main "$remote_dir" >/dev/null 2>&1
    git clone "$remote_dir" "$repo_dir" >/dev/null 2>&1
    git -C "$repo_dir" config user.name "Test User"
    git -C "$repo_dir" config user.email "test@example.com"
    git -C "$repo_dir" config commit.gpgsign false
    echo "# Test" >"$repo_dir/README.md"
    git -C "$repo_dir" add README.md
    git -C "$repo_dir" commit -m "Initial commit" >/dev/null 2>&1
    git -C "$repo_dir" push -u origin main >/dev/null 2>&1
    # Remotes that can never be reached: a missing local path (fails fast)
    # and ssh:// URLs whose transport is replaced by GIT_SSH_COMMAND below
    # (hangs without touching the network). The remote NAMES are unique so
    # pgrep -f can find the git process by its argv.
    git -C "$repo_dir" remote add fpbad /tmp/git-fish-fp-missing-(random)
    git -C "$repo_dir" remote add fp6047 ssh://localhost/nonexistent-6047.git
    git -C "$repo_dir" remote add fp6048 ssh://localhost/nonexistent-6048.git

    set -l orig_dir (pwd)
    cd "$repo_dir"
    set -lx TMPDIR $tmp_dir

    echo "Test 1: successful fetch -> 0, label once on stderr, stdout empty, no scratch files..."
    set total_tests (math $total_tests + 1)
    _git_fetch_progress --label "Fetching from origin" --timeout 10 -- --prune origin \
        >$cap_dir/out1 2>$cap_dir/err1
    set -l st $status
    set -l err_text (string collect <$cap_dir/err1)
    set -l leftovers $tmp_dir/*
    if test $st -eq 0
        and test ! -s $cap_dir/out1
        and test "$err_text" = "Fetching from origin…"
        and test (count $leftovers) -eq 0
        and not set -q _git_fetch_progress_job
        echo "✅ success path: status 0, one label line on stderr, clean TMPDIR"
    else
        echo "❌ status=$st stderr='$err_text' stdout-size="(wc -c <$cap_dir/out1)" leftovers=$leftovers"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 2: fetch from a missing path -> 2, scratch files removed..."
    set total_tests (math $total_tests + 1)
    _git_fetch_progress --label "Fetching from fpbad" --timeout 10 -- fpbad \
        >$cap_dir/out2 2>$cap_dir/err2
    set -l st $status
    set -l leftovers $tmp_dir/*
    if test $st -eq 2; and test ! -s $cap_dir/out2; and test (count $leftovers) -eq 0
        echo "✅ failure path: status 2, clean TMPDIR"
    else
        echo "❌ status=$st leftovers=$leftovers"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 3: argument validation -> 1..."
    set total_tests (math $total_tests + 1)
    set -l misses 0
    _git_fetch_progress --timeout 5 -- origin >/dev/null 2>&1
    test $status -eq 1; or set misses (math $misses + 1)
    _git_fetch_progress --label x -- origin >/dev/null 2>&1
    test $status -eq 1; or set misses (math $misses + 1)
    _git_fetch_progress --label x --timeout 0 -- origin >/dev/null 2>&1
    test $status -eq 1; or set misses (math $misses + 1)
    _git_fetch_progress --label x --timeout abc -- origin >/dev/null 2>&1
    test $status -eq 1; or set misses (math $misses + 1)
    _git_fetch_progress --label x --timeout 5 >/dev/null 2>&1
    test $status -eq 1; or set misses (math $misses + 1)
    if test $misses -eq 0
        echo "✅ missing/invalid --label, --timeout, or fetch args exit 1"
    else
        echo "❌ $misses validation cases did not exit 1"
        set failed_tests (math $failed_tests + 1)
    end

    # TASK 2 TESTS GO HERE
    # TASK 3 TESTS GO HERE
    # TASK 4 TESTS GO HERE

    # Cleanup
    set -e TMPDIR
    cd "$orig_dir"
    rm -rf "$remote_dir" "$repo_dir" "$tmp_dir" "$cap_dir"

    echo "📊 _git_fetch_progress results: $failed_tests/$total_tests failed"
    return $failed_tests
end
```

Register it in `run_functional_tests`, after the `test_git_wclean_check` block and before `test_all_commands_help_no_leaked_comments`:

```fish
    test_git_fetch_progress
    set total_failed (math $total_failed + $status)

    echo ""
```

- [ ] **Step 2: Run the test to verify it fails**

Run (from the repo root):

```fish
set -gx FISH_FUNCTIONS_DIR $PWD/functions
set -p fish_function_path $FISH_FUNCTIONS_DIR
sed '/^# Run tests if script is executed directly/,$d' tests/functional-tests.fish | source
test_git_fetch_progress
```

Expected: `source` of the missing file errors, Tests 1-3 fail (`_git_fetch_progress` is an unknown command → status 127, not 0/2/1). Return value 3.

- [ ] **Step 3: Write the helper (validation, success and failure paths only)**

Create `functions/_git_fetch_progress.fish`:

```fish
function _git_fetch_progress --description "Run git fetch in the background with a spinner and a native timeout"
    # Git Fetch Progress (private helper) - the one fetch runner shared by
    # git-wclean, git-wlist, and git-wrm. Runs 'git fetch' as a background
    # job, animates a spinner with elapsed seconds on a TTY, and enforces the
    # timeout itself, so no timeout/gtimeout utility is needed.
    #
    # SYNOPSIS
    #   _git_fetch_progress --label <text> --timeout <secs> [--quiet] -- <git-fetch-args...>
    #
    # OPTIONS
    #   --label <text>    Text drawn beside the spinner (TTY) or printed once (non-TTY)
    #   --timeout <secs>  Whole seconds (>= 1) before the fetch is killed
    #   -q, --quiet       Draw nothing at all (for prompt hooks)
    #
    # OUTPUT
    #   Indicator only, always on stderr; stdout is never written. The helper
    #   prints no warnings of its own: callers own every user-facing line and
    #   key them off the exit status.
    #
    # EXAMPLES
    #   _git_fetch_progress --label "Fetching from origin" --timeout 30 -- --prune origin
    #   _git_fetch_progress --quiet --label fetch --timeout 30 -- --prune origin
    #
    # EXIT STATUS
    #   0    Fetch succeeded
    #   1    Invalid arguments
    #   2    Fetch failed (also: mktemp failed, or the status file came back empty)
    #   124  Timed out; the fetch process tree was killed
    #   125  Timed out; the fetch could not be confirmed stopped (no ps AND no
    #        pid file). Callers that go on to delete things must abort.
    #
    # NOTES
    #   - GIT_TERMINAL_PROMPT=0 is always set: a background job cannot answer a
    #     credential prompt, so such a fetch fails instead of hanging.
    #   - Ctrl-C / SIGTERM run _git_fetch_progress_abort through the handlers
    #     at the bottom of this file: the fetch tree is killed and both scratch
    #     files are removed. The only global, _git_fetch_progress_job, exists
    #     only while a fetch is in flight.
    argparse --name=_git_fetch_progress 'label=' 'timeout=' q/quiet -- $argv
    or return 1

    if not set -q _flag_label; or not set -q _flag_timeout
        printf 'usage: _git_fetch_progress --label <text> --timeout <secs> [--quiet] -- <git-fetch-args...>\n' >&2
        return 1
    end
    if not string match -qr '^[1-9][0-9]*$' -- $_flag_timeout
        printf '_git_fetch_progress: --timeout must be a whole number of seconds >= 1\n' >&2
        return 1
    end
    if test (count $argv) -eq 0
        printf '_git_fetch_progress: no git fetch arguments given\n' >&2
        return 1
    end

    set -l quiet 0
    set -q _flag_quiet; and set quiet 1
    set -l tty 0
    if test $quiet -eq 0; and isatty stderr
        set tty 1
    end

    # Scratch files: the wrapper writes git's pid to "$0.pid" and git's exit
    # status to "$0". They are passed as the sh script's $0 because fish
    # locals are not exported and would expand to nothing inside the script.
    set -l status_file (mktemp 2>/dev/null)
    or return 2
    set -l pid_file "$status_file.pid"

    # Single external command so fish can background it (fish never forks
    # for blocks or functions). The trailing 2>/dev/null silences sh's own
    # "Terminated" job notice when git is killed on the timeout path.
    sh -c 'GIT_TERMINAL_PROMPT=0 git fetch "$@" >/dev/null 2>&1 &
        echo $! >"$0.pid"; wait $!; echo $? >"$0"' $status_file $argv 2>/dev/null &
    set -l wrapper_pid $last_pid
    set -g _git_fetch_progress_job $status_file $wrapper_pid

    if test $quiet -eq 0; and test $tty -eq 0
        printf '%s…\n' $_flag_label >&2
    end

    set -l frames ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏
    set -l frame 0
    set -l started (date +%s)
    set -l timed_out 0
    while kill -0 $wrapper_pid 2>/dev/null
        set -l elapsed (math (date +%s) - $started)
        if test $elapsed -ge $_flag_timeout
            set timed_out 1
            break
        end
        if test $tty -eq 1
            set frame (math "$frame % 10 + 1")
            printf '\r%s %s… %ds' $frames[$frame] $_flag_label $elapsed >&2
        end
        sleep 0.1
    end
    if test $tty -eq 1
        printf '\r\033[K' >&2
    end

    set -l rc 2
    if test $timed_out -eq 1
        # Task 3 fills this branch in.
        set rc 124
    else
        # Explicit reap on the normal path; the wrapper is already gone so
        # this returns at once, and fish's wait does not carry the status,
        # which is why the status file exists.
        wait $wrapper_pid 2>/dev/null
        set -l fetch_status ''
        if test -r $status_file
            read fetch_status <$status_file
        end
        if test "$fetch_status" = 0
            set rc 0
        end
    end

    rm -f $status_file $pid_file
    set -e _git_fetch_progress_job
    return $rc
end
```

- [ ] **Step 4: Format, lint, and run the test**

Run:

```fish
fish_indent < functions/_git_fetch_progress.fish > /tmp/fp.fish; and cat /tmp/fp.fish > functions/_git_fetch_progress.fish
fish --no-execute functions/_git_fetch_progress.fish
fish tests/run-tests.fish syntax
```

Then the single-test command from Step 2. Expected: Tests 1-3 ✅, `0/3 failed`. The syntax suite must pass (watch for the `test.*-a` grep).

- [ ] **Step 5: Commit**

```fish
git add functions/_git_fetch_progress.fish tests/functional-tests.fish
git commit -m "feat(fetch-progress): add _git_fetch_progress helper with background fetch and status file"
```

---

### Task 2: `_git_fetch_progress_kill_tree` with its three fallback tests

**Files:**
- Modify: `functions/_git_fetch_progress.fish` (append two functions)
- Test: `tests/functional-tests.fish` → `test_git_fetch_progress`, at the `# TASK 2 TESTS GO HERE` marker

**Interfaces:**
- Produces: `_git_fetch_progress_kill_tree <wrapper-pid> [<git-pid>]` → 0 when at least one source (ps walk or non-empty git pid) contributed targets and they were SIGTERMed; 1 when neither source was available. Never signals `<wrapper-pid>` itself.
- Produces: `_git_fetch_progress_wait_gone <pid>` → 0 once `kill -0` fails, 1 after ~2 s.
- Spec bullets: *kill_tree* (two sources, union, return 0/1), *Why git itself must die*, *Why the descendants must die too*, no process-group kill.

- [ ] **Step 1: Write the failing tests**

Replace the `# TASK 2 TESTS GO HERE` line with:

```fish
    # Kill-tree fallbacks are driven against a hand-built wrapper shaped like
    # the real one: sh backgrounds a uniquely named sleep, records its pid in
    # a file, and waits. Each case removes one source of truth.
    echo "Test 4a: kill-tree via the ps walk alone (empty git pid)..."
    set total_tests (math $total_tests + 1)
    set -l kt_pidfile $cap_dir/kt-a.pid
    sh -c 'sleep 6049 & echo $! >"$0"; wait' $kt_pidfile 2>/dev/null &
    set -l kt_wrapper $last_pid
    sleep 0.3
    _git_fetch_progress_kill_tree $kt_wrapper ''
    set -l st $status
    sleep 0.3
    set -l survivors (pgrep -f 'sleep 6049')
    if test $st -eq 0; and test -z "$survivors"
        echo "✅ ps walk found and killed the wrapper's child"
    else
        echo "❌ status=$st survivors='$survivors'"
        set failed_tests (math $failed_tests + 1)
        pkill -f 'sleep 6049' 2>/dev/null
    end

    echo "Test 4b: kill-tree via the pid file alone (no ps on PATH)..."
    set total_tests (math $total_tests + 1)
    set -l kt_pidfile $cap_dir/kt-b.pid
    sh -c 'sleep 6049 & echo $! >"$0"; wait' $kt_pidfile 2>/dev/null &
    set -l kt_wrapper $last_pid
    sleep 0.3
    set -l kt_gitpid (string trim <$kt_pidfile)
    set -l shim_dir $cap_dir/shim-no-ps
    mkdir -p $shim_dir
    ln -s (command -s kill) $shim_dir/kill
    set -l orig_path $PATH
    set -lx PATH $shim_dir
    _git_fetch_progress_kill_tree $kt_wrapper $kt_gitpid
    set -l st $status
    set -lx PATH $orig_path
    sleep 0.3
    set -l survivors (pgrep -f 'sleep 6049')
    if test $st -eq 0; and test -z "$survivors"
        echo "✅ pid-file source killed git without ps"
    else
        echo "❌ status=$st survivors='$survivors'"
        set failed_tests (math $failed_tests + 1)
        pkill -f 'sleep 6049' 2>/dev/null
    end

    echo "Test 4c: both sources suppressed -> returns 1 and (honestly) kills nothing..."
    set total_tests (math $total_tests + 1)
    set -l kt_pidfile $cap_dir/kt-c.pid
    sh -c 'sleep 6049 & echo $! >"$0"; wait' $kt_pidfile 2>/dev/null &
    set -l kt_wrapper $last_pid
    sleep 0.3
    set -lx PATH $shim_dir
    _git_fetch_progress_kill_tree $kt_wrapper ''
    set -l st $status
    set -lx PATH $orig_path
    set -l survivors (pgrep -f 'sleep 6049')
    if test $st -eq 1; and test -n "$survivors"
        echo "✅ no ps and empty pid -> 1, child left running (this is the 125 case)"
    else
        echo "❌ status=$st survivors='$survivors'"
        set failed_tests (math $failed_tests + 1)
    end
    # The test owns this orphan: kill it and the wrapper now.
    kill -TERM (string trim <$kt_pidfile) 2>/dev/null
    kill -TERM $kt_wrapper 2>/dev/null
    pkill -f 'sleep 6049' 2>/dev/null
```

- [ ] **Step 2: Run the test to verify it fails**

Run the single-test command. Expected: Tests 1-3 still ✅; 4a/4b/4c ❌ with `Unknown command: _git_fetch_progress_kill_tree` (status 127). 4c leaves no orphan because of the trailing kills.

- [ ] **Step 3: Implement kill-tree and wait-gone**

Append to `functions/_git_fetch_progress.fish`:

```fish

function _git_fetch_progress_kill_tree --description "SIGTERM a wrapper's descendants and/or a known git pid"
    # Two independent sources, union of targets, never the wrapper itself
    # (killing the wrapper by signal would make interactive fish print a
    # "Job terminated" notice; the wrapper exits on its own once git dies):
    #   1. every descendant of <wrapper-pid> by a breadth-first walk of
    #      'ps -eo pid=,ppid=' - reaches git AND its ssh/remote-helper
    #      children, which git does not signal itself;
    #   2. <git-pid> from the pid file - reaches git even without ps.
    # Returns 0 when at least one source contributed, 1 when neither did.
    set -l wrapper_pid $argv[1]
    set -l git_pid $argv[2]
    set -l targets
    set -l have_source 0

    if command -q ps
        set -l table (command ps -eo pid=,ppid= 2>/dev/null)
        if test $status -eq 0
            set have_source 1
            set -l frontier $wrapper_pid
            while test (count $frontier) -gt 0
                set -l next
                for line in $table
                    set -l fields (string split -n ' ' -- (string trim -- $line))
                    if contains -- $fields[2] $frontier
                        set -a targets $fields[1]
                        set -a next $fields[1]
                    end
                end
                set frontier $next
            end
        end
    end

    if test -n "$git_pid"
        set have_source 1
        contains -- $git_pid $targets
        or set -a targets $git_pid
    end

    if test $have_source -eq 0
        return 1
    end
    for pid in $targets
        kill -TERM $pid 2>/dev/null
    end
    return 0
end

function _git_fetch_progress_wait_gone --description "Wait up to ~2s for a pid to disappear"
    for _i in (seq 1 20)
        kill -0 $argv[1] 2>/dev/null
        or return 0
        sleep 0.1
    end
    return 1
end
```

Note the `set -l table (…)` / `if test $status -eq 0` pair: `set` propagates the substitution's status, so a missing or failing `ps` leaves `have_source` at 0.

- [ ] **Step 4: Format, lint, run**

Same three commands as Task 1 Step 4, then the single test. Expected: `0/6 failed`, and `pgrep -f 'sleep 6049'` prints nothing afterwards.

- [ ] **Step 5: Commit**

```fish
git add functions/_git_fetch_progress.fish tests/functional-tests.fish
git commit -m "feat(fetch-progress): kill the fetch tree from ps walk and pid file with tested fallbacks"
```

---

### Task 3: Timeout path — 124, 125, transport cleanup, quiet on every path

**Files:**
- Modify: `functions/_git_fetch_progress.fish` (the `if test $timed_out -eq 1` branch)
- Test: `tests/functional-tests.fish` → `test_git_fetch_progress`, at the `# TASK 3 TESTS GO HERE` marker

**Interfaces:**
- Consumes: `_git_fetch_progress_kill_tree`, `_git_fetch_progress_wait_gone` from Task 2.
- Produces: return **124** (tree confirmed killed) / **125** (unconfirmed) from `_git_fetch_progress`.
- Spec bullets: *When elapsed ≥ timeout*, bounded wait before deleting scratch files, 125 path prints nothing, Testing → timeout, quiet (including 125).

- [ ] **Step 1: Write the failing tests**

Replace `# TASK 3 TESTS GO HERE` with:

```fish
    echo "Test 5: timeout -> 124 promptly, git and its transport gone, no scratch files..."
    set total_tests (math $total_tests + 1)
    set -l t0 (date +%s)
    set -lx GIT_SSH_COMMAND 'sh -c "sleep 6047"'
    _git_fetch_progress --label "Fetching from fp6047" --timeout 1 -- fp6047 \
        >$cap_dir/out5 2>$cap_dir/err5
    set -l st $status
    set -e GIT_SSH_COMMAND
    set -l took (math (date +%s) - $t0)
    sleep 0.3
    set -l transport (pgrep -f 'sleep 6047')
    set -l gitproc (pgrep -f 'git fetch fp6047')
    set -l leftovers $tmp_dir/*
    if test $st -eq 124
        and test $took -le 6
        and test -z "$transport"
        and test -z "$gitproc"
        and test (count $leftovers) -eq 0
        and not set -q _git_fetch_progress_job
        echo "✅ timed out in "$took"s with git and transport dead, TMPDIR clean"
    else
        echo "❌ status=$st took=$took transport='$transport' git='$gitproc' leftovers=$leftovers"
        set failed_tests (math $failed_tests + 1)
    end
    pkill -f 'sleep 6047' 2>/dev/null
    pkill -f 'git fetch fp6047' 2>/dev/null

    echo "Test 6: --quiet on the success path prints nothing on either stream..."
    set total_tests (math $total_tests + 1)
    _git_fetch_progress --quiet --label "Fetching from origin" --timeout 10 -- --prune origin \
        >$cap_dir/out6 2>$cap_dir/err6
    set -l st $status
    if test $st -eq 0; and test ! -s $cap_dir/out6; and test ! -s $cap_dir/err6
        echo "✅ quiet success is silent"
    else
        echo "❌ status=$st stdout-size="(wc -c <$cap_dir/out6)" stderr-size="(wc -c <$cap_dir/err6)
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 7: --quiet on the 125 path (no ps, pid file emptied) is silent and returns 125..."
    set total_tests (math $total_tests + 1)
    # Shim PATH has everything the helper and git need EXCEPT ps. A second
    # external process empties the pid file shortly after the wrapper writes
    # it, so when the timeout fires both kill sources are gone -> 125.
    set -l shim_dir $cap_dir/shim-125
    mkdir -p $shim_dir
    for tool in git sh mktemp sleep date rm kill basename dirname
        ln -s (command -s $tool) $shim_dir/$tool
    end
    sh -c 'sleep 0.6; for f in "$0"/*.pid; do : >"$f"; done' $tmp_dir &
    set -l orig_path $PATH
    set -lx PATH $shim_dir
    set -lx GIT_SSH_COMMAND 'sh -c "sleep 6047"'
    _git_fetch_progress --quiet --label "Fetching from fp6047" --timeout 2 -- fp6047 \
        >$cap_dir/out7 2>$cap_dir/err7
    set -l st $status
    set -e GIT_SSH_COMMAND
    set -lx PATH $orig_path
    set -l leftovers $tmp_dir/*
    if test $st -eq 125
        and test ! -s $cap_dir/out7
        and test ! -s $cap_dir/err7
        and test (count $leftovers) -eq 0
        echo "✅ unconfirmed timeout returns 125 with no output and no scratch files"
    else
        echo "❌ status=$st stdout-size="(wc -c <$cap_dir/out7)" stderr-size="(wc -c <$cap_dir/err7)" leftovers=$leftovers"
        set failed_tests (math $failed_tests + 1)
    end
    # 125 means the helper could not kill git: the test does it.
    pkill -f 'sleep 6047' 2>/dev/null
    pkill -f 'git fetch fp6047' 2>/dev/null
```

- [ ] **Step 2: Run the test to verify it fails**

Run the single-test command. Expected: Test 5 ❌ (status is 124 from the placeholder but `transport`/`gitproc` survive, so the assertion fails); Test 6 ✅ already (quiet success needs no new code — that is fine, it guards a regression); Test 7 ❌ (status 124, not 125). Everything else ✅.

- [ ] **Step 3: Implement the timeout branch**

Replace the placeholder branch in `_git_fetch_progress`:

```fish
    if test $timed_out -eq 1
        # Task 3 fills this branch in.
        set rc 124
    else
```

with:

```fish
    if test $timed_out -eq 1
        # Kill git (and its transport) rather than the wrapper: the wrapper
        # then exits on its own after writing git's signal status, which
        # avoids fish's "Job terminated" notice. 125 = both kill sources were
        # unavailable; the helper prints nothing either way (callers own the
        # warning, and --quiet must stay literal).
        set -l git_pid ''
        if test -r $pid_file
            read git_pid <$pid_file
        end
        if _git_fetch_progress_kill_tree $wrapper_pid $git_pid
            set rc 124
        else
            kill -TERM $wrapper_pid 2>/dev/null
            set rc 125
        end
        # Let the wrapper finish its trailing 'echo $? >"$0"' before the
        # scratch files go, or it would recreate the status file afterwards.
        _git_fetch_progress_wait_gone $wrapper_pid
    else
```

- [ ] **Step 4: Format, lint, run**

Format + syntax commands, then the single test. Expected: `0/9 failed`; afterwards `pgrep -f 'sleep 604'` prints nothing and `_git_fetch_progress_job` is unset.

- [ ] **Step 5: Commit**

```fish
git add functions/_git_fetch_progress.fish tests/functional-tests.fish
git commit -m "feat(fetch-progress): enforce the timeout natively, return 124 or 125, stay silent under --quiet"
```

---

### Task 4: Interruption — abort routine and INT/TERM handlers

**Files:**
- Modify: `functions/_git_fetch_progress.fish` (append three functions)
- Test: `tests/functional-tests.fish` → `test_git_fetch_progress`, at the `# TASK 4 TESTS GO HERE` marker

**Interfaces:**
- Consumes: `_git_fetch_progress_job` global, `_git_fetch_progress_kill_tree`, `_git_fetch_progress_wait_gone`.
- Produces: `_git_fetch_progress_abort` (no args), `_git_fetch_progress_on_int --on-signal INT`, `_git_fetch_progress_on_term --on-signal TERM`.
- Spec bullets: *Interruption (Ctrl-C / SIGTERM)*, *Error handling* Ctrl-C bullet, Testing → interruption.

- [ ] **Step 1: Write the failing test**

Replace `# TASK 4 TESTS GO HERE` with:

```fish
    echo "Test 8: SIGINT to the fish process alone kills the fetch tree and removes scratch files..."
    set total_tests (math $total_tests + 1)
    # A child fish runs the helper against a hanging transport. Signalling
    # only the child's pid (not its process group) models an interactive
    # Ctrl-C, where the background job sits in its own group and never sees
    # the signal: only the INT handler can clean up.
    set -lx GIT_SSH_COMMAND 'sh -c "sleep 6048"'
    fish -c "set -p fish_function_path $test_functions_dir
        source $test_functions_dir/_git_fetch_progress.fish
        cd $repo_dir
        _git_fetch_progress --label 'Fetching from fp6048' --timeout 30 -- fp6048" \
        >$cap_dir/out8 2>$cap_dir/err8 &
    set -l child $last_pid
    set -e GIT_SSH_COMMAND
    # Wait for the label line: the fetch is then in flight.
    for _i in (seq 1 50)
        test -s $cap_dir/err8; and break
        sleep 0.1
    end
    sleep 0.5
    kill -INT $child 2>/dev/null
    set -l child_alive 1
    for _i in (seq 1 40)
        if not kill -0 $child 2>/dev/null
            set child_alive 0
            break
        end
        sleep 0.1
    end
    sleep 0.3
    set -l transport (pgrep -f 'sleep 6048')
    set -l gitproc (pgrep -f 'git fetch fp6048')
    set -l leftovers $tmp_dir/*
    if test $child_alive -eq 0
        and test -z "$transport"
        and test -z "$gitproc"
        and test (count $leftovers) -eq 0
        echo "✅ INT handler killed git and transport and emptied TMPDIR"
    else
        echo "❌ child_alive=$child_alive transport='$transport' git='$gitproc' leftovers=$leftovers"
        set failed_tests (math $failed_tests + 1)
    end
    kill -TERM $child 2>/dev/null
    pkill -f 'sleep 6048' 2>/dev/null
    pkill -f 'git fetch fp6048' 2>/dev/null
```

- [ ] **Step 2: Run the test to verify it fails**

Run the single-test command. Expected: Test 8 ❌ — the child fish exits on SIGINT but `sleep 6048` survives and two scratch files remain in `TMPDIR` (`leftovers=` shows them). All earlier tests ✅.

- [ ] **Step 3: Implement abort and handlers**

Append to `functions/_git_fetch_progress.fish`:

```fish

function _git_fetch_progress_abort --description "Ctrl-C/SIGTERM cleanup for an in-flight _git_fetch_progress job"
    # A signal abandons _git_fetch_progress mid-loop, so neither its normal
    # nor its timeout exit runs. Interactively the background job has its
    # own process group and never sees the Ctrl-C, so without this the fetch
    # would outlive the command with no timeout enforcer and both scratch
    # files would leak. No-op when nothing is in flight.
    set -q _git_fetch_progress_job
    or return 0
    set -l status_file $_git_fetch_progress_job[1]
    set -l wrapper_pid $_git_fetch_progress_job[2]
    set -e _git_fetch_progress_job

    set -l git_pid ''
    if test -r "$status_file.pid"
        read git_pid <"$status_file.pid"
    end
    _git_fetch_progress_kill_tree $wrapper_pid $git_pid
    or kill -TERM $wrapper_pid 2>/dev/null
    _git_fetch_progress_wait_gone $wrapper_pid
    if isatty stderr
        printf '\r\033[K' >&2
    end
    rm -f $status_file "$status_file.pid"
end

# fish accepts one signal per handler, so two thin handlers share the abort
# (same pattern as git-wclean's own cleanup handlers).
function _git_fetch_progress_on_int --on-signal INT
    _git_fetch_progress_abort
end

function _git_fetch_progress_on_term --on-signal TERM
    _git_fetch_progress_abort
end
```

- [ ] **Step 4: Format, lint, run**

Format + syntax commands, then the single test. Expected: `0/10 failed`. Also run `fish -c "source functions/_git_fetch_progress.fish"` to confirm the `--on-signal` definitions load (the syntax suite's Test 7 does this too).

- [ ] **Step 5: Commit**

```fish
git add functions/_git_fetch_progress.fish tests/functional-tests.fish
git commit -m "feat(fetch-progress): clean up the fetch tree and scratch files on INT/TERM"
```

---

### Task 5: `git-wclean` call sites, 125 handling, and the `--check` test rework

**Files:**
- Modify: `functions/git-wclean.fish` — `_wclean_fetch_remotes` (lines 294-328 today), `_wclean_run_check` (lines 837-849), EXIT STATUS help text (lines 1016-1017)
- Test: `tests/functional-tests.fish` — new `test_git_fetch_progress_callers` (registered after `test_git_fetch_progress`), and `test_git_wclean_check` Tests 4 and 5

**Interfaces:**
- Consumes: `_git_fetch_progress` (autoloads by name; no explicit `source` needed in the functions).
- Produces: `_wclean_fetch_remotes` returns 2 on helper status 125 (main already converts any non-zero into `return 2` after `_wclean_normal_cleanup`); `_wclean_run_check` returns 2 silently on 125.
- Spec: *Call-site changes* 1-2, *Error handling* (125 fatal for wclean full and `--check`), Testing → 125 propagation, rework of `--check` Tests 4 and 5.

- [ ] **Step 1: Write the failing 125-propagation tests (wclean part)**

Insert before `function run_functional_tests` (after `test_git_fetch_progress`):

```fish
function test_git_fetch_progress_callers --description "Test how wclean, wlist, and wrm react to an unconfirmed fetch timeout (125)"
    set -l test_functions_dir "$FISH_FUNCTIONS_DIR"
    if test -z "$test_functions_dir"
        set -l test_file_dir (dirname (status --current-filename))
        set test_functions_dir "$test_file_dir/../functions"
        if test -d "$test_functions_dir"
            set test_functions_dir (realpath "$test_functions_dir")
        end
    end
    set -l failed_tests 0
    set -l total_tests 0

    echo "🔍 Testing callers' handling of _git_fetch_progress status 125..."

    set -p fish_function_path $test_functions_dir
    source $test_functions_dir/git-wclean.fish
    source $test_functions_dir/git-wlist.fish
    source $test_functions_dir/git-wrm.fish

    # Fake HOME so a real user config cannot change the outcome
    set -l fake_home /tmp/git-fish-fpc-home-(random)
    mkdir -p "$fake_home"
    set -l orig_home $HOME
    set -lx HOME $fake_home

    set -l remote_dir /tmp/git-fish-fpc-remote-(random).git
    set -l main_dir /tmp/git-fish-fpc-main-(random)
    set -l wts_dir /tmp/git-fish-fpc-wts-(random)
    rm -rf "$remote_dir" "$main_dir" "$wts_dir"
    git init --bare -b main "$remote_dir" >/dev/null 2>&1
    git clone "$remote_dir" "$main_dir" >/dev/null 2>&1
    git -C "$main_dir" config user.name "Test User"
    git -C "$main_dir" config user.email "test@example.com"
    git -C "$main_dir" config commit.gpgsign false
    echo "# Test" >"$main_dir/README.md"
    git -C "$main_dir" add README.md
    git -C "$main_dir" commit -m "Initial commit" >/dev/null 2>&1
    git -C "$main_dir" push -u origin main >/dev/null 2>&1
    git -C "$main_dir" remote set-head origin main >/dev/null 2>&1
    # A merged worktree: removable by every command if the fetch were fine
    mkdir -p "$wts_dir"
    git -C "$main_dir" worktree add "$wts_dir/merged" -b merged-copy >/dev/null 2>&1

    set -l orig_dir (pwd)
    cd "$main_dir"

    # Stub the helper: fish functions are global, so this shadows the
    # autoloaded one until it is erased at the end of this test.
    function _git_fetch_progress
        return 125
    end

    echo "Test 1: git-wclean treats 125 as fatal: exit 2, removes nothing, explains why..."
    set total_tests (math $total_tests + 1)
    set -l out (echo y | git-wclean "$wts_dir" 2>&1 | string collect)
    set -l st $pipestatus[2]
    if test $st -eq 2
        and test -d "$wts_dir/merged"
        and string match -q '*could not be confirmed stopped*' -- $out
        echo "✅ wclean aborted with exit 2 and the worktree intact"
    else
        echo "❌ status=$st exists="(test -d "$wts_dir/merged"; and echo yes; or echo no)" output: $out"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 2: git-wclean --check exits 2 silently on 125..."
    set total_tests (math $total_tests + 1)
    set -l out (git-wclean --check 2>&1 | string collect)
    set -l st $pipestatus[1]
    if test $st -eq 2; and test -z "$out"
        echo "✅ --check: exit 2, no output"
    else
        echo "❌ status=$st output='$out'"
        set failed_tests (math $failed_tests + 1)
    end

    # TASK 6 TESTS GO HERE

    # Restore the real helper and clean up
    functions -e _git_fetch_progress
    source $test_functions_dir/_git_fetch_progress.fish
    set -lx HOME $orig_home
    cd "$orig_dir"
    git -C "$main_dir" worktree prune >/dev/null 2>&1
    rm -rf "$remote_dir" "$main_dir" "$wts_dir" "$fake_home"
    set -e _wclean_config_protected_branches
    set -e _wclean_config_default_upstream
    set -e _wclean_config_system_dirs
    set -e _wclean_config_max_path_length
    set -e _wclean_config_fetch_timeout
    set -e _wclean_config_stale_days

    echo "📊 fetch-progress caller results: $failed_tests/$total_tests failed"
    return $failed_tests
end
```

Register in `run_functional_tests` right after the `test_git_fetch_progress` block:

```fish
    test_git_fetch_progress_callers
    set total_failed (math $total_failed + $status)

    echo ""
```

- [ ] **Step 2: Rewrite `test_git_wclean_check` Tests 4 and 5 (they assert the removed behavior)**

Replace the whole `Test 4` block (from `echo "Test 4: no timeout utility -> fetch skipped …"` through its `end`) with:

```fish
    echo "Test 4: fetch runs without any timeout utility (native timeout) and prunes the gone ref..."
    set total_tests (math $total_tests + 1)
    # A deleted remote branch whose tracking ref is still present locally is
    # invisible until a fetch --prune runs. The old design skipped the fetch
    # when timeout/gtimeout were missing; the helper bounds it natively, so
    # with a PATH that has no timeout utility the nudge MUST still appear.
    echo y | git-wclean "$wts_dir" >/dev/null 2>&1 # clear the gone worktree first
    git -C "$main_dir" worktree add "$wts_dir/chk-gone2" -b chk-gone2 >/dev/null 2>&1
    echo g >"$wts_dir/chk-gone2/g.txt"
    git -C "$wts_dir/chk-gone2" add g.txt
    git -C "$wts_dir/chk-gone2" commit -m "gone work" >/dev/null 2>&1
    git -C "$wts_dir/chk-gone2" push -u origin chk-gone2 >/dev/null 2>&1
    git -C "$remote_dir" branch -D chk-gone2 >/dev/null 2>&1
    set -l shim_dir /tmp/git-fish-chk-bin-(random)
    mkdir -p "$shim_dir"
    # Everything the helper and git need; deliberately no timeout/gtimeout.
    for tool in git date basename dirname sh mktemp sleep ps rm kill
        ln -s (command -s $tool) "$shim_dir/$tool"
    end
    set -l orig_path $PATH
    set -lx PATH $shim_dir
    set -l out (git-wclean --check 2>&1)
    set -l st $status
    set -lx PATH $orig_path
    rm -rf "$shim_dir"
    if test $st -eq 0
        and test (count $out) -eq 1
        and string match -q "*1 gone*" -- $out
        echo "✅ fetch ran and pruned without a timeout utility (one-line nudge, exit 0)"
    else
        echo "❌ status=$st output='$out'"
        set failed_tests (math $failed_tests + 1)
    end
```

In `Test 5`, keep the github.com URL (it arms the forge gate) but make the fetch fail instantly and offline: the URL scheme becomes `ssh://` and `GIT_SSH_COMMAND` exits non-zero. Replace the block from `git -C "$main_dir" remote set-url origin https://github.com/example/repo.git` through `set -lx PATH $orig_path2` with:

```fish
    # Arm the forge gate (github.com URL + gh on PATH) and prove --no-forge
    # holds. The fetch now always runs, so point the URL at github.com over
    # ssh and replace the transport with a command that fails at once: no
    # network, no prompt, and the classifier still sees a github.com remote.
    git -C "$main_dir" remote set-url origin ssh://git@github.com/example/repo.git
    set -l shim_dir /tmp/git-fish-chk-gh-(random)
    mkdir -p "$shim_dir"
    for tool in git date basename dirname sh mktemp sleep ps rm kill
        ln -s (command -s $tool) "$shim_dir/$tool"
    end
    printf '#!/bin/sh\necho "$@" >> "%s/gh-called.log"\necho MERGED\n' "$shim_dir" >"$shim_dir/gh"
    chmod +x "$shim_dir/gh"
    set -l orig_path2 $PATH
    set -lx PATH $shim_dir
    set -lx GIT_SSH_COMMAND 'sh -c "exit 255"'
    git-wclean --check >/dev/null 2>&1
    set -l st $status
    set -e GIT_SSH_COMMAND
    set -lx PATH $orig_path2
```

Also delete the now-wrong comment in Test 3 (`# Deliberately push --delete here … lives in test_git_wclean_states.`) and replace it with:

```fish
    # push --delete prunes the local tracking ref immediately; wclean's own
    # --prune coverage lives in test_git_wclean_states and in Test 4 below.
```

- [ ] **Step 3: Run the tests to verify they fail**

Run the single-test command with `test_git_fetch_progress_callers test_git_wclean_check` (the runner accepts several names when you loop; or run them one at a time). Expected: callers Test 1 ❌ (wclean still uses its own `timeout_cmd` block and ignores the stub, so it removes the worktree with exit 0); callers Test 2 ❌ (exit 0); `--check` Test 4 ❌ (silent: the old guard skips the fetch); Test 5 ✅ or ❌ is irrelevant yet.

- [ ] **Step 4: Rewrite `_wclean_fetch_remotes` fetch block**

In `functions/git-wclean.fish`, replace lines 294-328 (from `# Try to fetch from origin if it exists. Guard the fetch with a timeout` through the `else … printf "⚠️  Note: No 'origin' remote found.\n" … end`) with:

```fish
    # Fetch from origin when it exists. _git_fetch_progress runs the fetch in
    # the background with its own timeout and spinner; its exit status is
    # the whole signal (it prints no warnings), so every user-facing line is
    # ours. 125 means the timed-out fetch could not be confirmed dead: a
    # fetch that may still be rewriting remote-tracking refs must not race a
    # branch deletion, so the whole run aborts (main maps this to exit 2).
    if contains origin $_wclean_remotes
        _git_fetch_progress --label "Fetching from origin" \
            --timeout $_wclean_config_fetch_timeout -- --prune origin
        switch $status
            case 0
                printf "✓ Fetched from origin\n"
            case 124
                printf "⚠️  Warning: Fetch from origin timed out after %ds. Proceeding with local information.\n" $_wclean_config_fetch_timeout
            case 125
                printf "Error: Fetch from origin timed out after %ds and could not be confirmed stopped.\n" $_wclean_config_fetch_timeout >&2
                printf "Refusing to remove anything while that fetch may still be running.\n" >&2
                return 2
            case '*'
                printf "⚠️  Warning: Failed to fetch from origin. Proceeding with local information.\n"
        end
    else
        printf "⚠️  Note: No 'origin' remote found.\n"
    end
```

(Those two `printf` warning lines exceed 100 characters exactly as the existing ones at 313 and 315 do; `fish_indent` leaves them alone and the syntax suite does not measure length. Keep them on one line so the message text stays greppable.)

- [ ] **Step 5: Rewrite `_wclean_run_check` fetch guard**

Replace lines 837-849 (the comment block starting `# Fetch guard: only fetch when a timeout utility exists` through the `if contains origin … end`) with:

```fish
    # Always fetch, bounded by the helper's native timeout and silent under
    # --quiet (a prompt hook must never draw). GIT_TERMINAL_PROMPT=0 is set
    # inside the helper. 125 (timed out, fetch not confirmed dead) exits 2
    # silently: the nudge must not be computed from refs still in flux.
    if contains origin (git remote 2>/dev/null)
        _git_fetch_progress --quiet --label "Fetching from origin" \
            --timeout $_wclean_config_fetch_timeout -- --prune origin
        if test $status -eq 125
            return 2
        end
    end
```

- [ ] **Step 6: Update the EXIT STATUS help text**

Replace lines 1016-1017:

```fish
    #   Under --check, runtime conditions (not a repo, fetch failure) always
    #   exit 0; only invalid flag combinations exit 1.
```

with:

```fish
    #   Under --check, runtime conditions (not a repo, fetch failure or
    #   timeout) exit 0; invalid flag combinations exit 1; a timed-out fetch
    #   that could not be confirmed stopped exits 2 (silently).
```

- [ ] **Step 7: Format, lint, run**

```fish
fish_indent < functions/git-wclean.fish > /tmp/wc.fish; and cat /tmp/wc.fish > functions/git-wclean.fish
fish tests/run-tests.fish syntax
```

Then run `test_git_fetch_progress_callers`, `test_git_wclean_check`, `test_git_wclean_dry_run`, `test_git_wclean_states`, `test_git_wclean_help`, `test_all_commands_help_no_leaked_comments`. Expected: all ✅. (`test_git_wclean_dry_run` and `_states` run real fetches against local bare remotes; the header line `Fetching from origin…` now lands on stderr, which those tests merge with `2>&1`, and none of them asserts on it.)

- [ ] **Step 8: Commit**

```fish
git add functions/git-wclean.fish tests/functional-tests.fish
git commit -m "feat(wclean): fetch through _git_fetch_progress; abort on an unconfirmed timeout"
```

---

### Task 6: `git-wlist` and `git-wrm` call sites

**Files:**
- Modify: `functions/git-wlist.fish` lines 25-26 (doc) and 87-100 (fetch block)
- Modify: `functions/git-wrm.fish` lines 227-247 (fetch block) and line 21 is fine as is
- Test: `tests/functional-tests.fish` → `test_git_fetch_progress_callers`, at `# TASK 6 TESTS GO HERE`

**Interfaces:**
- Consumes: `_git_fetch_progress`.
- Produces: `git-wlist` warns on 124/125 and still prints its table; `git-wrm` exits 2 on 125 having removed nothing, warns and proceeds on 2/124.
- Spec: *Call-site changes* 3-4, *Error handling* (wlist read-only → warn; wrm → fatal).

- [ ] **Step 1: Write the failing tests**

Replace `# TASK 6 TESTS GO HERE` with:

```fish
    echo "Test 3: git-wlist warns on 125 and still prints its table..."
    set total_tests (math $total_tests + 1)
    set -l out (git-wlist 2>&1 | string collect)
    set -l st $pipestatus[1]
    if test $st -eq 0
        and string match -q '*NAME*' -- $out
        and string match -q '*merged-copy*' -- $out
        and string match -q '*warning:*' -- $out
        echo "✅ wlist: warning plus a full table"
    else
        echo "❌ status=$st output: $out"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 4: git-wrm treats 125 as fatal: exit 2, worktree kept..."
    set total_tests (math $total_tests + 1)
    set -l out (git-wrm "$wts_dir/merged" 2>&1 | string collect)
    set -l st $pipestatus[1]
    if test $st -eq 2
        and test -d "$wts_dir/merged"
        and string match -q '*could not be confirmed stopped*' -- $out
        echo "✅ wrm refused to remove with exit 2"
    else
        echo "❌ status=$st exists="(test -d "$wts_dir/merged"; and echo yes; or echo no)" output: $out"
        set failed_tests (math $failed_tests + 1)
    end
```

- [ ] **Step 2: Run the test to verify it fails**

Run `test_git_fetch_progress_callers`. Expected: Tests 1-2 ✅; Test 3 ❌ (no `warning:` because wlist still fetches on its own and succeeds); Test 4 ❌ (wrm removes the merged worktree, exit 0).

- [ ] **Step 3: Rewrite the `git-wlist` fetch block**

Replace lines 87-100 of `functions/git-wlist.fish` (from `# One fetch --prune, timeout-guarded …` through the matching `end`) with:

```fish
    # One fetch --prune through the shared helper (native timeout, spinner on
    # a TTY, label line otherwise - all on stderr so piped stdout stays a
    # clean table). wlist is read-only, so even an unconfirmed timeout (125)
    # only costs freshness: warn and carry on.
    if contains origin (git remote 2>/dev/null)
        _git_fetch_progress --label "Fetching from origin" \
            --timeout $_wclean_config_fetch_timeout -- --prune origin
        switch $status
            case 0
            case 124 125
                printf "warning: fetch timed out; results may be stale\n" >&2
            case '*'
                printf "warning: fetch failed; results may be stale\n" >&2
        end
    end
```

And update the doc comment at lines 25-26:

```fish
    #   Runs one 'git fetch --prune origin' up front, bounded by the
    #   _wclean_config_fetch_timeout setting (no timeout utility needed).
```

- [ ] **Step 4: Rewrite the `git-wrm` fetch block**

Replace lines 227-247 of `functions/git-wrm.fish` (from `# Fetch latest from the remote so the merge check uses up-to-date refs.` through the `end` that closes `if test -n "$timeout_cmd" … else … end`) with:

```fish
    # Fetch latest from the remote so the merge check uses up-to-date refs.
    # The shared helper bounds the fetch itself (30s here; git-wrm does not
    # read the wclean config) and never prompts. 125 means the timed-out
    # fetch could not be confirmed dead; a removal must not race it.
    _git_fetch_progress --label "Fetching latest from $remote_name" --timeout 30 \
        -- $remote_name $branch_name
    switch $status
        case 0
        case 124
            printf "  Warning: Fetch from %s timed out. Proceeding with local information.\n" $remote_name
        case 125
            printf "  Error: Fetch from %s timed out and could not be confirmed stopped.\n" $remote_name >&2
            printf "  Refusing to remove the worktree while that fetch may still be running.\n" >&2
            return 2
        case '*'
            printf "  Warning: Failed to fetch from %s. Proceeding with local information.\n" $remote_name
    end
```

- [ ] **Step 5: Format, lint, run**

```fish
for f in functions/git-wlist.fish functions/git-wrm.fish
    fish_indent < $f > /tmp/x.fish; and cat /tmp/x.fish > $f
end
fish tests/run-tests.fish syntax
```

Then run `test_git_fetch_progress_callers`, `test_git_wlist`, `test_git_wrm_validation`, `test_git_wrm_merge_check`, `test_git_wrm_pr_merged`, `test_git_wrm_bare_layout_anchors`. Expected: all ✅. (`test_git_wlist` reads stdout only in places — the helper's label line goes to stderr, so the table assertions are unaffected.)

- [ ] **Step 6: Commit**

```fish
git add functions/git-wlist.fish functions/git-wrm.fish tests/functional-tests.fish
git commit -m "feat(wlist,wrm): fetch through _git_fetch_progress with per-command 125 handling"
```

---

### Task 7: Documentation sweep and full verification

**Files:**
- Modify: `README.md` lines 311-312, 378-380, 460-462; `CLAUDE.md` shared-helpers list (after the `_git_wclean_config` entry, ~line 83)
- Verify: `rg -n -i 'gtimeout|timeout utility|timeout_cmd' functions README.md CLAUDE.md` returns only the helper's own prose and the `_wclean_config_fetch_timeout` config key.

**Interfaces:** none (docs only).

**Spec:** *Documentation* section; CLAUDE.md helper list.

- [ ] **Step 1: README**

Lines 311-312 (wlist features) become:

```markdown
- Runs a single `git fetch --prune origin` up front, bounded by the fetch
  timeout config (enforced natively; no `timeout` utility needed)
```

Lines 378-380 (`--check` paragraph) become:

```markdown
`--check` prints at most one line, only when something is reapable, never runs
`gh`, never sources repo-local config, and always fetches with the configured
timeout. It exits 0 in every runtime condition except one: a timed-out fetch
that could not be confirmed stopped exits 2 (still silently), so a stale ref
set is never counted.
```

Lines 460-462 (optional dependency bullet) are deleted entirely; add in their place:

```markdown
- **ps** (procps / base system) - lets a timed-out fetch's whole process tree
  be killed; without it the fetch itself is still killed via its recorded pid
```

- [ ] **Step 2: CLAUDE.md**

After the `_git_wclean_config` bullet in **Shared private helpers**, add:

```markdown
- `_git_fetch_progress`: The one fetch runner for `git-wclean` (full and
  `--check`), `git-wlist`, and `git-wrm`. Backgrounds `git fetch` in an
  external `sh` wrapper, draws a spinner (TTY) or one label line (non-TTY)
  on stderr, enforces the timeout itself, and returns 0/2/124/125. It prints
  no warnings (callers own those). 125 = timed out but not confirmed dead:
  `git-wclean`/`git-wrm` abort with exit 2, `git-wlist` warns. INT/TERM
  handlers in the same file kill the fetch tree and remove the scratch files.
```

- [ ] **Step 3: Verify nothing else still mentions the old dependency**

Run:

```fish
rg -n -i 'gtimeout|timeout utility|timeout_cmd' functions README.md CLAUDE.md docs/superpowers/specs
```

Expected: hits only inside the spec (historical) and the helper's own doc comment ("no timeout/gtimeout utility is needed"). Fix any other hit.

- [ ] **Step 4: Full suite, formatting check, help check**

```fish
fish tests/run-tests.fish
for f in functions/*.fish
    fish_indent < $f | diff -u $f - >/dev/null; or echo "needs fish_indent: $f"
end
fish -c 'set -p fish_function_path $PWD/functions; for f in git-wclean git-wlist git-wrm; $f --help >/dev/null; or echo "help failed: $f"; end'
pgrep -fl 'sleep 604' ; or echo "no leaked fixtures"
```

Expected: syntax and functional suites both pass; no formatting diffs; help works; no leaked `sleep 604x` processes.

- [ ] **Step 5: Commit, then open the PR**

```fish
git add README.md CLAUDE.md
git commit -m "docs: drop the timeout/gtimeout dependency; document _git_fetch_progress"
git push -u origin feat/fetch-progress-helper
```

PR body: describe the helper, the behavior changes (`--check` always fetches; `GIT_TERMINAL_PROMPT=0` everywhere; 125 → exit 2), and link the spec. Do **not** quote worktree or branch names from any real container. CodeRabbit will review; expect its stale changes-requested verdict to need dismissal after threads resolve.

---

## Self-review against the spec

- **Helper contract:** wrapper command, `$0` status file, `$!` pid file, outer `2>/dev/null`, explicit `wait` on normal completion, stderr-only output, TTY spinner with braille frames and `\r\033[K`, non-TTY label once, `--quiet` silent, epoch-based elapsed, `kill -0` liveness, 0.1 s sleep → Task 1 / Task 3.
- **Timeout:** kill_tree union of ps-walk + pid file, never the wrapper on 124, bounded wait before `rm`, 124 vs 125, no output on 125, no pgroup kill → Tasks 2-3.
- **Interruption:** INT+TERM handlers, shared abort, single global, spinner line cleared, non-interactive case harmless → Task 4.
- **Call sites 1-4:** Task 5 (wclean full + `--check`), Task 6 (wlist, wrm with `--timeout 30` and `$remote_name $branch_name`).
- **Error handling:** 2/124 non-fatal everywhere; 125 fatal for wclean/`--check`/wrm with exit 2, warn-and-proceed for wlist; mktemp failure → 2 → Tasks 1, 5, 6.
- **Testing:** success, failure, timeout with unique transport asserted via `pgrep -f`, three kill-tree fallbacks, 125 propagation via stub for all four commands, quiet on success and on 125, stream separation (Test 1 checks stdout empty and stderr has the label), interruption with SIGINT to the child fish only, `--check` Tests 4/5 rework with offline fixtures → Tasks 1-6.
- **Documentation:** README three passages, CLAUDE.md helper, inline comments in all three functions, wclean help EXIT STATUS → Tasks 5-7.
- **Names used consistently:** `_git_fetch_progress`, `_git_fetch_progress_kill_tree`, `_git_fetch_progress_wait_gone`, `_git_fetch_progress_abort`, `_git_fetch_progress_on_int`, `_git_fetch_progress_on_term`, global `_git_fetch_progress_job`; test functions `test_git_fetch_progress`, `test_git_fetch_progress_callers`.
