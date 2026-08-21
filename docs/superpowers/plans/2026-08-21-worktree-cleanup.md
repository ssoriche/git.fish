# Worktree Cleanup Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add worktree lifecycle visibility and smarter reaping to git.fish: a `_git_worktree_status` classifier helper, a `git-wlist` dashboard, `[gone]`/PR-closed/stale detection in `git-wclean`, and a `git wclean --check` prompt-hook nudge.

**Architecture:** A private classifier helper (`_git_worktree_status`) is the single source of truth for a worktree's lifecycle state; a shared config loader (`_git_wclean_config`) replaces wclean's private one. `git-wlist` and `git wclean --check` enumerate via `git worktree list --porcelain`; `git-wclean` keeps its directory scan but routes per-worktree decisions through the classifier.

**Tech Stack:** fish shell functions (see CLAUDE.md for fish syntax rules — no bash-isms), `argparse`, existing test harness in `tests/functional-tests.fish`.

**Spec:** `docs/superpowers/specs/2026-08-20-worktree-cleanup-design.md` — read it before starting. It pins every behavioral decision; when this plan and the spec disagree, the spec wins.

**Conventions that apply to every task:**
- 4-space indent, 100-char lines, `fish_indent` formatting, `printf` not `echo` (except where existing helpers use `echo` to return values).
- Worktrees have `.git` as a *file*: always `test -e .git`, never `test -d .git`.
- Run the whole suite with `fish tests/run-tests.fish` and syntax-only with `fish tests/run-tests.fish syntax`.
- Test functions follow the house pattern: resolve `$FISH_FUNCTIONS_DIR` with the relative-path fallback, `set -p fish_function_path $test_functions_dir` so private helpers autoload, count `total_tests`/`failed_tests`, return `$failed_tests`.
- Commit messages: conventional commits, no credit taken.
- Line numbers cited for `git-wclean.fish` are pre-Chunk-1 positions and drift as earlier
  tasks delete code — trust the named functions, not the numbers.

---

## Chunk 1: Shared helpers (`_git_wclean_config`, `_git_worktree_status`)

### Task 1: Extract `_git_wclean_config` shared config loader

**Files:**
- Create: `functions/_git_wclean_config.fish`
- Modify: `functions/git-wclean.fish` (delete `_wclean_load_config` at lines 78–99; change the call at line 759; add `_wclean_config_stale_days` to both cleanup functions)
- Test: `tests/functional-tests.fish` (new `test_git_wclean_config_helper`, registered in `run_functional_tests`)

- [ ] **Step 1: Write the failing test**

Add to `tests/functional-tests.fish` (before `run_functional_tests`):

```fish
function test_git_wclean_config_helper --description "Test _git_wclean_config defaults, precedence, --allow-local, --quiet"
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

    echo "🔍 Testing _git_wclean_config helper..."

    set -p fish_function_path $test_functions_dir
    if not test -f "$test_functions_dir/_git_wclean_config.fish"
        echo "❌ _git_wclean_config.fish not found in: $test_functions_dir"
        return 1
    end
    source $test_functions_dir/_git_wclean_config.fish

    # Fake HOME so real user config never interferes
    set -l fake_home /tmp/git-fish-config-home-(random)
    set -l work_dir /tmp/git-fish-config-work-(random)
    mkdir -p "$fake_home" "$work_dir"
    set -l orig_home $HOME
    set -l orig_dir (pwd)
    set -lx HOME $fake_home
    cd "$work_dir"

    # Test 1: defaults with no config files present
    echo "Test 1: defaults..."
    set total_tests (math $total_tests + 1)
    _git_wclean_config --quiet
    if test "$_wclean_config_stale_days" = 30
        and test "$_wclean_config_fetch_timeout" = 30
        and contains trunk $_wclean_config_protected_branches
        echo "✅ defaults set (stale_days=30, fetch_timeout=30, trunk protected)"
    else
        echo "❌ defaults wrong: stale_days=$_wclean_config_stale_days"
        set failed_tests (math $failed_tests + 1)
    end

    # Test 2: user config wins, loading message goes to stderr not stdout
    echo "Test 2: user config file..."
    set total_tests (math $total_tests + 1)
    mkdir -p "$fake_home/.config/git-wclean"
    printf 'set -g _wclean_config_stale_days 7\n' >"$fake_home/.config/git-wclean/config"
    set -l cfg_stdout (_git_wclean_config 2>/dev/null)
    if test "$_wclean_config_stale_days" = 7; and test -z "$cfg_stdout"
        echo "✅ user config loaded; nothing on stdout"
    else
        echo "❌ stale_days=$_wclean_config_stale_days stdout='$cfg_stdout'"
        set failed_tests (math $failed_tests + 1)
    end

    # Test 3: --quiet suppresses the loading message on stderr too
    echo "Test 3: --quiet..."
    set total_tests (math $total_tests + 1)
    set -l cfg_all (_git_wclean_config --quiet 2>&1)
    if test -z "$cfg_all"
        echo "✅ --quiet produces no output at all"
    else
        echo "❌ --quiet emitted: '$cfg_all'"
        set failed_tests (math $failed_tests + 1)
    end

    # Test 4: repo-local config ignored without --allow-local
    echo "Test 4: local config needs --allow-local..."
    set total_tests (math $total_tests + 1)
    rm -rf "$fake_home/.config"
    printf 'set -g _wclean_config_stale_days 3\n' >"$work_dir/.git-wclean-config"
    _git_wclean_config --quiet
    set -l without_local $_wclean_config_stale_days
    _git_wclean_config --quiet --allow-local
    set -l with_local $_wclean_config_stale_days
    if test "$without_local" = 30; and test "$with_local" = 3
        echo "✅ local config only honored with --allow-local"
    else
        echo "❌ without=$without_local with=$with_local (want 30 / 3)"
        set failed_tests (math $failed_tests + 1)
    end

    # Test 5: first-match-wins — user config present means local is never read
    echo "Test 5: first-match-wins..."
    set total_tests (math $total_tests + 1)
    mkdir -p "$fake_home/.config/git-wclean"
    printf 'set -g _wclean_config_stale_days 7\n' >"$fake_home/.config/git-wclean/config"
    _git_wclean_config --quiet --allow-local
    if test "$_wclean_config_stale_days" = 7
        echo "✅ user config shadows repo-local config"
    else
        echo "❌ stale_days=$_wclean_config_stale_days, want 7"
        set failed_tests (math $failed_tests + 1)
    end

    # Cleanup
    set -lx HOME $orig_home
    cd "$orig_dir"
    rm -rf "$fake_home" "$work_dir"
    set -e _wclean_config_protected_branches _wclean_config_default_upstream
    set -e _wclean_config_system_dirs _wclean_config_max_path_length
    set -e _wclean_config_fetch_timeout _wclean_config_stale_days

    echo "📊 _git_wclean_config results: $failed_tests/$total_tests failed"
    return $failed_tests
end
```

Register it in `run_functional_tests` (add before the help-leak call, following the existing pattern):

```fish
    test_git_wclean_config_helper
    set total_failed (math $total_failed + $status)

    echo ""
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fish -c 'source tests/functional-tests.fish; test_git_wclean_config_helper'`
Expected: FAIL — `_git_wclean_config.fish not found`

- [ ] **Step 3: Create `functions/_git_wclean_config.fish`**

```fish
function _git_wclean_config --description "Load git-wclean config: defaults, then first existing config file"
    # Shared configuration loader for git-wclean, git-wlist, and git wclean --check.
    #
    # SYNOPSIS
    #   _git_wclean_config [--allow-local] [--quiet]
    #
    # DESCRIPTION
    #   Sets the _wclean_config_* globals to their defaults, then sources the
    #   FIRST existing config file (first-match-wins) from:
    #     1. ~/.config/git-wclean/config
    #     2. ~/.git-wclean-config
    #     3. ./.git-wclean-config   (only when --allow-local is passed)
    #
    #   The repo-local file is gated behind --allow-local because sourcing an
    #   arbitrary file from the current directory is code execution: only an
    #   explicit, interactive `git wclean` run may opt in. Hook-driven callers
    #   (git wclean --check) and read-only callers (git-wlist) must not pass it.
    #
    # OPTIONS
    #   --allow-local   Include ./.git-wclean-config as the last-resort fallback
    #   --quiet         Suppress the "Loading configuration from" stderr message
    #
    # EXIT STATUS
    #   0    Always (a missing config file is not an error)
    argparse allow-local quiet -- $argv
    or return 1

    # Defaults
    set -g _wclean_config_protected_branches main master develop trunk
    # Empty by default: the integration branch is auto-detected from origin/HEAD.
    # Set this in a config file ONLY to override that detection explicitly.
    set -g _wclean_config_default_upstream ""
    set -g _wclean_config_system_dirs /etc /bin /usr/bin /sbin /usr/sbin
    set -g _wclean_config_max_path_length 4096
    set -g _wclean_config_fetch_timeout 30
    set -g _wclean_config_stale_days 30

    set -l config_files ~/.config/git-wclean/config ~/.git-wclean-config
    if set -q _flag_allow_local
        set -a config_files ./.git-wclean-config
    end

    for config_file in $config_files
        if test -f "$config_file"; and test -r "$config_file"
            if not set -q _flag_quiet
                printf "Loading configuration from: %s\n" $config_file >&2
            end
            source "$config_file"
            break
        end
    end
    return 0
end
```

- [ ] **Step 4: Wire it into `git-wclean.fish`**

In `functions/git-wclean.fish`:
1. Delete the whole `_wclean_load_config` function (lines 78–99).
2. Replace the call in the `git-wclean` main body (`_wclean_load_config` at line 759) with `_git_wclean_config --allow-local`.
3. In BOTH `_wclean_cleanup_handler` and `_wclean_normal_cleanup`, add `set -e _wclean_config_stale_days` next to the other `_wclean_config_*` erasures.

- [ ] **Step 5: Run tests to verify they pass**

Run: `fish -c 'source tests/functional-tests.fish; test_git_wclean_config_helper'` — Expected: PASS (0 failed)
Run: `fish tests/run-tests.fish` — Expected: all existing tests still pass (wclean behavior unchanged: `--allow-local` preserves the old three-path search).

- [ ] **Step 6: Format and commit**

Also update the stale comment at `tests/functional-tests.fish:1179` that still names
`_wclean_load_config` — point it at `_git_wclean_config`.

```bash
fish --no-execute functions/_git_wclean_config.fish && \
fish_indent < functions/_git_wclean_config.fish | diff -u functions/_git_wclean_config.fish - && \
git add functions/_git_wclean_config.fish functions/git-wclean.fish tests/functional-tests.fish && \
git commit -m "refactor(wclean): extract shared _git_wclean_config loader with --allow-local gating"
```

If `fish_indent` shows a diff, apply it (`fish_indent < f > tmp && mv tmp f`) before committing.

### Task 2: `_git_worktree_status` classifier — core states

**Files:**
- Create: `functions/_git_worktree_status.fish`
- Test: `tests/functional-tests.fish` (new `test_git_worktree_status_classifier`, registered in `run_functional_tests`)

The classifier is pure: explicit args in, one TSV line out, no fetch, no config reads. The forge (`gh`) branch of the logic is Task 3 — this task implements everything else, with the `pr-closed` slot present but inert until Task 3's code lands (write the full function including the forge block now; Task 3 only adds its tests).

- [ ] **Step 1: Write the failing test**

Add to `tests/functional-tests.fish`:

```fish
function test_git_worktree_status_classifier --description "Test _git_worktree_status core state classification"
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

    echo "🔍 Testing _git_worktree_status classifier..."

    set -p fish_function_path $test_functions_dir
    if not test -f "$test_functions_dir/_git_worktree_status.fish"
        echo "❌ _git_worktree_status.fish not found in: $test_functions_dir"
        return 1
    end
    source $test_functions_dir/_git_worktree_status.fish

    # Fixture: bare remote + main clone + worktrees, one per scenario
    set -l remote_dir /tmp/git-fish-wts-remote-(random).git
    set -l main_dir /tmp/git-fish-wts-main-(random)
    set -l wts_dir /tmp/git-fish-wts-wts-(random)
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
    mkdir -p "$wts_dir"

    # merged: branch at main's HEAD (ancestor of origin/main)
    git -C "$main_dir" worktree add "$wts_dir/merged" -b wts-merged >/dev/null 2>&1

    # gone: branch pushed with upstream, then deleted on the remote and pruned
    git -C "$main_dir" worktree add "$wts_dir/gone" -b wts-gone >/dev/null 2>&1
    echo change >"$wts_dir/gone/gone.txt"
    git -C "$wts_dir/gone" add gone.txt
    git -C "$wts_dir/gone" commit -m "gone work" >/dev/null 2>&1
    git -C "$wts_dir/gone" push -u origin wts-gone >/dev/null 2>&1
    git -C "$main_dir" push origin --delete wts-gone >/dev/null 2>&1
    git -C "$main_dir" fetch --prune origin >/dev/null 2>&1

    # stale: unmerged, no upstream, backdated commit
    git -C "$main_dir" worktree add "$wts_dir/stale" -b wts-stale >/dev/null 2>&1
    echo old >"$wts_dir/stale/old.txt"
    git -C "$wts_dir/stale" add old.txt
    env GIT_COMMITTER_DATE="2020-01-01T00:00:00" GIT_AUTHOR_DATE="2020-01-01T00:00:00" \
        git -C "$wts_dir/stale" commit -m "old work" >/dev/null 2>&1

    # dirty + active: unmerged recent commit plus an uncommitted file
    git -C "$main_dir" worktree add "$wts_dir/dirty" -b wts-dirty >/dev/null 2>&1
    echo work >"$wts_dir/dirty/work.txt"
    git -C "$wts_dir/dirty" add work.txt
    git -C "$wts_dir/dirty" commit -m "recent work" >/dev/null 2>&1
    echo uncommitted >"$wts_dir/dirty/uncommitted.txt"

    # detached HEAD
    set -l main_sha (git -C "$main_dir" rev-parse HEAD)
    git -C "$main_dir" worktree add --detach "$wts_dir/detached" $main_sha >/dev/null 2>&1

    # active: unmerged recent commit, clean
    git -C "$main_dir" worktree add "$wts_dir/active" -b wts-active >/dev/null 2>&1
    echo a >"$wts_dir/active/a.txt"
    git -C "$wts_dir/active" add a.txt
    git -C "$wts_dir/active" commit -m "active work" >/dev/null 2>&1

    # Helper: classify and return the requested TSV field (1=state 4=dirty 5=age)
    function _wts_field
        set -l line (_git_worktree_status $argv[2..-1])
        string split \t -- $line | sed -n "$argv[1]p"
    end

    echo "Test 1: merged..."
    set total_tests (math $total_tests + 1)
    set -l state (_wts_field 1 "$wts_dir/merged" origin/main 30)
    if test "$state" = merged
        echo "✅ merged"
    else
        echo "❌ got '$state', want merged"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 2: gone..."
    set total_tests (math $total_tests + 1)
    set -l state (_wts_field 1 "$wts_dir/gone" origin/main 30)
    if test "$state" = gone
        echo "✅ gone"
    else
        echo "❌ got '$state', want gone"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 3: stale..."
    set total_tests (math $total_tests + 1)
    set -l state (_wts_field 1 "$wts_dir/stale" origin/main 30)
    if test "$state" = stale
        echo "✅ stale"
    else
        echo "❌ got '$state', want stale"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 4: dirty flag on an active worktree..."
    set total_tests (math $total_tests + 1)
    set -l state (_wts_field 1 "$wts_dir/dirty" origin/main 30)
    set -l dirty (_wts_field 4 "$wts_dir/dirty" origin/main 30)
    if test "$state" = active; and test "$dirty" = dirty
        echo "✅ active + dirty"
    else
        echo "❌ got state='$state' dirty='$dirty', want active/dirty"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 5: detached..."
    set total_tests (math $total_tests + 1)
    set -l state (_wts_field 1 "$wts_dir/detached" origin/main 30)
    if test "$state" = detached
        echo "✅ detached"
    else
        echo "❌ got '$state', want detached"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 6: protected wins over merged..."
    set total_tests (math $total_tests + 1)
    set -l state (_wts_field 1 "$wts_dir/merged" origin/main 30 wts-merged)
    if test "$state" = protected
        echo "✅ protected takes precedence"
    else
        echo "❌ got '$state', want protected"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 7: error on non-worktree path, exit 1..."
    set total_tests (math $total_tests + 1)
    set -l line (_git_worktree_status /nonexistent-(random) origin/main 30)
    set -l st $status
    if test $st -eq 1; and string match -q 'error	*' -- $line
        echo "✅ error line + return 1"
    else
        echo "❌ status=$st line='$line'"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 8: active worktree, clean..."
    set total_tests (math $total_tests + 1)
    set -l state (_wts_field 1 "$wts_dir/active" origin/main 30)
    set -l dirty (_wts_field 4 "$wts_dir/active" origin/main 30)
    if test "$state" = active; and test "$dirty" = clean
        echo "✅ active + clean"
    else
        echo "❌ got state='$state' dirty='$dirty'"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 9: empty integration branch skips merged, still classifies gone..."
    set total_tests (math $total_tests + 1)
    set -l state (_wts_field 1 "$wts_dir/gone" "" 30)
    if test "$state" = gone
        echo "✅ gone without an integration branch"
    else
        echo "❌ got '$state', want gone"
        set failed_tests (math $failed_tests + 1)
    end

    # Cleanup
    functions -e _wts_field
    git -C "$main_dir" worktree prune >/dev/null 2>&1
    rm -rf "$remote_dir" "$main_dir" "$wts_dir"

    echo "📊 _git_worktree_status results: $failed_tests/$total_tests failed"
    return $failed_tests
end
```

Register in `run_functional_tests` after the config-helper test, same pattern.

- [ ] **Step 2: Run test to verify it fails**

Run: `fish -c 'source tests/functional-tests.fish; test_git_worktree_status_classifier'`
Expected: FAIL — `_git_worktree_status.fish not found`

- [ ] **Step 3: Create `functions/_git_worktree_status.fish`**

```fish
function _git_worktree_status --description "Classify a git worktree's lifecycle state as one TSV line"
    # Git Worktree Status (private helper) - single source of truth for
    # "what state is this worktree in", consumed by git-wlist and git-wclean.
    #
    # SYNOPSIS
    #   _git_worktree_status [--no-forge] <worktree-path> <integration-branch> \
    #       <stale-days> [protected-branch ...]
    #
    # OUTPUT
    #   Exactly one tab-separated line on stdout:
    #     <state> <branch> <upstream> <dirty> <age-days> <path>
    #   state:    protected|detached|merged|pr-closed|gone|stale|active
    #             (first match wins, in that order), or error (see below)
    #   branch:   checked-out branch, or '-' for detached HEAD
    #   upstream: configured upstream ref, or '-' if none
    #   dirty:    clean|dirty (any uncommitted changes, untracked included)
    #   age-days: whole days since HEAD's committer date
    #
    #   If the path is not a resolvable worktree, prints
    #   'error	-	-	-	-	<path>' and returns 1. Callers must treat
    #   'error' as keep-and-report, never as a removal candidate.
    #
    # NOTES
    #   - Performs no fetch and reads no config: callers run
    #     'git fetch --prune origin' first and pass everything explicitly.
    #   - An empty <integration-branch> skips the merged check (the other
    #     states still classify).
    #   - The only network call is 'gh pr view' for github.com remotes,
    #     disabled entirely by --no-forge; any gh failure falls through.
    argparse no-forge -- $argv
    or return 1

    set -l worktree_path $argv[1]
    set -l integration_branch $argv[2]
    set -l stale_days $argv[3]
    set -l protected_branches $argv[4..-1]

    if test -z "$worktree_path"; or not test -d "$worktree_path"; or not test -e "$worktree_path/.git"
        printf 'error\t-\t-\t-\t-\t%s\n' "$worktree_path"
        return 1
    end

    set -l head_commit (git -C "$worktree_path" rev-parse HEAD 2>/dev/null)
    if test $status -ne 0; or test -z "$head_commit"
        printf 'error\t-\t-\t-\t-\t%s\n' "$worktree_path"
        return 1
    end

    # Branch name; empty on detached HEAD
    set -l branch (git -C "$worktree_path" symbolic-ref --short -q HEAD 2>/dev/null)

    # Dirty: any staged, unstaged, or untracked changes
    set -l dirty clean
    set -l porcelain (git -C "$worktree_path" status --porcelain 2>/dev/null)
    if test -n "$porcelain"
        set dirty dirty
    end

    # Age in whole days since HEAD's committer date
    set -l age_days 0
    set -l head_epoch (git -C "$worktree_path" log -1 --format=%ct 2>/dev/null)
    if test -n "$head_epoch"
        set -l now (date +%s)
        set age_days (math "floor(($now - $head_epoch) / 86400)")
    end

    # Upstream ref and its tracking status ('[gone]' when the remote-tracking
    # ref has been pruned but the upstream is still configured)
    set -l upstream -
    set -l track ""
    if test -n "$branch"
        set -l up (git -C "$worktree_path" for-each-ref \
            --format='%(upstream:short)' refs/heads/$branch 2>/dev/null)
        test -n "$up"; and set upstream $up
        set track (git -C "$worktree_path" for-each-ref \
            --format='%(upstream:track)' refs/heads/$branch 2>/dev/null)
    end

    set -l branch_display $branch
    test -z "$branch_display"; and set branch_display -

    # State decision: first match wins
    set -l state ""

    if test -n "$branch"; and contains -- $branch $protected_branches
        set state protected
    else if test -z "$branch"
        set state detached
    end

    # merged: HEAD is an ancestor of the integration branch
    if test -z "$state"; and test -n "$integration_branch"
        set -l unmerged (git -C "$worktree_path" rev-list $head_commit \
            --not $integration_branch 2>/dev/null)
        if test $status -eq 0; and test -z "$unmerged"
            set state merged
        end
    end

    # pr-closed: the branch's GitHub PR is merged or closed. gh runs with the
    # worktree as cwd so it resolves the repo from that worktree's remotes.
    # Caveat (accepted in spec): 'gh pr view <branch>' reports the most recent
    # PR for a reused branch name.
    if test -z "$state"; and not set -q _flag_no_forge
        and command -q gh; and test -n "$branch"
        set -l remote origin
        if test "$upstream" != -
            # index form instead of -f1: works on fish < 3.4 too
            set remote (string split -- / $upstream)[1]
        end
        set -l remote_url (git -C "$worktree_path" remote get-url $remote 2>/dev/null)
        if string match -q '*github.com*' -- "$remote_url"
            if pushd "$worktree_path" >/dev/null 2>&1
                set -l pr_state (gh pr view $branch --json state --jq .state 2>/dev/null)
                popd >/dev/null
                if contains -- "$pr_state" MERGED CLOSED
                    set state pr-closed
                end
            end
        end
    end

    # gone: upstream configured but its remote-tracking ref no longer exists
    if test -z "$state"; and test "$track" = "[gone]"
        set state gone
    end

    # stale: no commits within the staleness window
    if test -z "$state"; and test $age_days -gt $stale_days
        set state stale
    end

    test -z "$state"; and set state active

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' $state $branch_display $upstream $dirty $age_days $worktree_path
    return 0
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `fish -c 'source tests/functional-tests.fish; test_git_worktree_status_classifier'`
Expected: PASS (0 failed). If Test 2 (gone) fails, verify with `git -C <fixture> for-each-ref --format='%(upstream:track)' refs/heads/wts-gone` that git reports `[gone]` — it requires the `push -u`, remote delete, and `fetch --prune` sequence in that order.

- [ ] **Step 5: Syntax check, format, commit**

```bash
fish --no-execute functions/_git_worktree_status.fish && \
fish_indent < functions/_git_worktree_status.fish | diff -u functions/_git_worktree_status.fish - && \
git add functions/_git_worktree_status.fish tests/functional-tests.fish && \
git commit -m "feat: add _git_worktree_status classifier helper for worktree lifecycle state"
```

### Task 3: Classifier `pr-closed` state and `--no-forge` (gh stub tests)

**Files:**
- Modify: none (the forge code shipped in Task 2 — this task proves it)
- Test: `tests/functional-tests.fish` (new `test_git_worktree_status_pr_closed`, registered in `run_functional_tests`)

- [ ] **Step 1: Write the test**

```fish
function test_git_worktree_status_pr_closed --description "Test pr-closed detection via a gh PATH stub and --no-forge"
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

    echo "🔍 Testing _git_worktree_status pr-closed via gh stub..."

    set -p fish_function_path $test_functions_dir
    if not test -f "$test_functions_dir/_git_worktree_status.fish"
        echo "❌ _git_worktree_status.fish not found in: $test_functions_dir"
        return 1
    end
    source $test_functions_dir/_git_worktree_status.fish

    # Fixture: one unmerged branch with an upstream that still exists
    set -l remote_dir /tmp/git-fish-prc-remote-(random).git
    set -l main_dir /tmp/git-fish-prc-main-(random)
    set -l wts_dir /tmp/git-fish-prc-wts-(random)
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
    mkdir -p "$wts_dir"
    git -C "$main_dir" worktree add "$wts_dir/pr" -b wts-pr >/dev/null 2>&1
    echo pr >"$wts_dir/pr/pr.txt"
    git -C "$wts_dir/pr" add pr.txt
    git -C "$wts_dir/pr" commit -m "pr work" >/dev/null 2>&1
    git -C "$wts_dir/pr" push -u origin wts-pr >/dev/null 2>&1

    # Classifier gates the gh call on the remote URL containing github.com.
    # It never fetches, so rewriting the URL after all pushes is safe.
    git -C "$main_dir" remote set-url origin https://github.com/example/repo.git

    # gh stub: logs every invocation, answers MERGED
    set -l stub_dir /tmp/git-fish-prc-bin-(random)
    mkdir -p "$stub_dir"
    printf '#!/bin/sh\necho "$@" >> "%s/gh-called.log"\necho MERGED\n' "$stub_dir" >"$stub_dir/gh"
    chmod +x "$stub_dir/gh"
    set -l orig_path $PATH
    set -lx PATH $stub_dir $PATH

    echo "Test 1: gh says MERGED -> pr-closed..."
    set total_tests (math $total_tests + 1)
    set -l line (_git_worktree_status "$wts_dir/pr" origin/main 30)
    set -l state (string split \t -- $line)[1]
    if test "$state" = pr-closed; and test -f "$stub_dir/gh-called.log"
        echo "✅ pr-closed via gh stub"
    else
        echo "❌ got '$state' (stub log exists: "(test -f "$stub_dir/gh-called.log"; and echo yes; or echo no)")"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 2: --no-forge never invokes gh..."
    set total_tests (math $total_tests + 1)
    rm -f "$stub_dir/gh-called.log"
    set -l line (_git_worktree_status --no-forge "$wts_dir/pr" origin/main 30)
    set -l state (string split \t -- $line)[1]
    if test "$state" != pr-closed; and not test -f "$stub_dir/gh-called.log"
        echo "✅ --no-forge skipped gh (state='$state')"
    else
        echo "❌ state='$state', gh invoked: "(test -f "$stub_dir/gh-called.log"; and echo yes; or echo no)
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 3: gh says OPEN -> falls through (active)..."
    set total_tests (math $total_tests + 1)
    printf '#!/bin/sh\necho OPEN\n' >"$stub_dir/gh"
    chmod +x "$stub_dir/gh"
    set -l line (_git_worktree_status "$wts_dir/pr" origin/main 30)
    set -l state (string split \t -- $line)[1]
    if test "$state" = active
        echo "✅ OPEN PR leaves worktree active"
    else
        echo "❌ got '$state', want active"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 4: non-github remote skips gh entirely..."
    set total_tests (math $total_tests + 1)
    git -C "$main_dir" remote set-url origin https://forgejo.example.com/example/repo.git
    printf '#!/bin/sh\necho "$@" >> "%s/gh-called.log"\necho MERGED\n' "$stub_dir" >"$stub_dir/gh"
    chmod +x "$stub_dir/gh"
    rm -f "$stub_dir/gh-called.log"
    set -l line (_git_worktree_status "$wts_dir/pr" origin/main 30)
    set -l state (string split \t -- $line)[1]
    if test "$state" != pr-closed; and not test -f "$stub_dir/gh-called.log"
        echo "✅ non-github remote never calls gh (state='$state')"
    else
        echo "❌ state='$state', gh invoked: "(test -f "$stub_dir/gh-called.log"; and echo yes; or echo no)
        set failed_tests (math $failed_tests + 1)
    end

    # Cleanup
    set -lx PATH $orig_path
    git -C "$main_dir" worktree prune >/dev/null 2>&1
    rm -rf "$remote_dir" "$main_dir" "$wts_dir" "$stub_dir"

    echo "📊 pr-closed results: $failed_tests/$total_tests failed"
    return $failed_tests
end
```

Register in `run_functional_tests` after the classifier test.

- [ ] **Step 2: Run the test**

Run: `fish -c 'source tests/functional-tests.fish; test_git_worktree_status_pr_closed'`
Expected: PASS if Task 2's forge block is correct. If Test 1 fails, debug the remote-derivation logic (`string split -f1 -- / $upstream`) and the `github.com` URL match before touching anything else.

- [ ] **Step 3: Commit**

```bash
git add tests/functional-tests.fish && \
git commit -m "test: pin pr-closed classification, --no-forge, and forge dispatch via gh stub"
```

---

## Chunk 2: git-wlist dashboard

### Task 4: `git-wlist` command

**Files:**
- Create: `functions/git-wlist.fish`
- Test: `tests/functional-tests.fish` (new `test_git_wlist`, registered in `run_functional_tests`; add `git-wlist` + its leak marker to `test_all_commands_help_no_leaked_comments` — the `commands` and `leak_markers` lists at lines 1289–1299 are hardcoded parallel lists, the glob does NOT pick new commands up)

- [ ] **Step 1: Write the failing test**

```fish
function test_git_wlist --description "Test git-wlist table output, sorting, and flags"
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

    echo "🔍 Testing git-wlist..."

    set -p fish_function_path $test_functions_dir
    if not test -f "$test_functions_dir/git-wlist.fish"
        echo "❌ git-wlist.fish not found in: $test_functions_dir"
        return 1
    end
    source $test_functions_dir/git-wlist.fish

    # Fixture: bare remote, main clone, merged + gone + active worktrees
    set -l remote_dir /tmp/git-fish-wlist-remote-(random).git
    set -l main_dir /tmp/git-fish-wlist-main-(random)
    set -l wts_dir /tmp/git-fish-wlist-wts-(random)
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
    mkdir -p "$wts_dir"
    git -C "$main_dir" worktree add "$wts_dir/wl-merged" -b wl-merged >/dev/null 2>&1
    git -C "$main_dir" worktree add "$wts_dir/wl-gone" -b wl-gone >/dev/null 2>&1
    echo g >"$wts_dir/wl-gone/g.txt"
    git -C "$wts_dir/wl-gone" add g.txt
    git -C "$wts_dir/wl-gone" commit -m "gone work" >/dev/null 2>&1
    git -C "$wts_dir/wl-gone" push -u origin wl-gone >/dev/null 2>&1
    git -C "$main_dir" push origin --delete wl-gone >/dev/null 2>&1
    git -C "$main_dir" worktree add "$wts_dir/wl-active" -b wl-active >/dev/null 2>&1
    echo a >"$wts_dir/wl-active/a.txt"
    git -C "$wts_dir/wl-active" add a.txt
    git -C "$wts_dir/wl-active" commit -m "active work" >/dev/null 2>&1

    # Fake HOME so a real user config can't change protected branches or
    # stale_days under the test (same pattern as the config-helper test)
    set -l fake_home /tmp/git-fish-wlist-home-(random)
    mkdir -p "$fake_home"
    set -l orig_home $HOME
    set -lx HOME $fake_home

    set -l orig_dir (pwd)
    cd "$main_dir"

    echo "Test 1: table lists every registered worktree with its state..."
    set total_tests (math $total_tests + 1)
    # wl-gone is already [gone] locally (push --delete pruned the tracking
    # ref); wclean's tests own the fetch --prune regression coverage.
    # Accumulate match failures rather than one long multi-line condition —
    # simpler to read and no single line breaks the 100-char limit.
    set -l output (git-wlist 2>/dev/null | string collect)
    set -l misses 0
    string match -q '*NAME*' -- $output; or set misses (math $misses + 1)
    string match -rq 'wl-merged\s.*merged' -- $output; or set misses (math $misses + 1)
    string match -rq 'wl-gone\s.*gone' -- $output; or set misses (math $misses + 1)
    string match -rq 'wl-active\s.*active' -- $output; or set misses (math $misses + 1)
    string match -q '*protected*' -- $output; or set misses (math $misses + 1)
    if test $misses -eq 0
        echo "✅ all worktrees listed with expected states"
    else
        echo "❌ table missing rows/states:"
        printf '%s\n' $output
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 2: reapable states sort above active/protected..."
    set total_tests (math $total_tests + 1)
    # The protected row is the main worktree; its NAME is the basename of
    # $main_dir, so key off the STATE column instead of the name.
    set -l lines (git-wlist 2>/dev/null)
    set -l merged_idx 0
    set -l active_idx 0
    set -l protected_idx 0
    for i in (seq (count $lines))
        string match -q '*wl-merged*' -- $lines[$i]; and set merged_idx $i
        string match -q '*wl-active*' -- $lines[$i]; and set active_idx $i
        string match -q '*protected*' -- $lines[$i]; and set protected_idx $i
    end
    if test $merged_idx -gt 0; and test $merged_idx -lt $active_idx; and test $active_idx -lt $protected_idx
        echo "✅ sort order: merged < active < protected"
    else
        echo "❌ row order wrong: merged=$merged_idx active=$active_idx protected=$protected_idx"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 3: --stale-days validates its argument..."
    set total_tests (math $total_tests + 1)
    git-wlist --stale-days 5 >/dev/null 2>&1
    set -l ok_status $status
    git-wlist --stale-days banana >/dev/null 2>&1
    set -l bad_status $status
    if test $ok_status -eq 0; and test $bad_status -eq 1
        echo "✅ --stale-days validates its argument"
    else
        echo "❌ ok=$ok_status (want 0) bad=$bad_status (want 1)"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 4: locked worktrees carry a [locked] annotation..."
    set total_tests (math $total_tests + 1)
    git -C "$main_dir" worktree lock "$wts_dir/wl-active" >/dev/null 2>&1
    set -l locked_out (git-wlist 2>/dev/null | string collect)
    git -C "$main_dir" worktree unlock "$wts_dir/wl-active" >/dev/null 2>&1
    if string match -rq 'wl-active \[locked\]' -- $locked_out
        echo "✅ [locked] shown in NAME column"
    else
        echo "❌ locked annotation missing:"
        printf '%s\n' $locked_out
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 5: positional arguments are rejected..."
    set total_tests (math $total_tests + 1)
    git-wlist somearg >/dev/null 2>&1
    if test $status -eq 1
        echo "✅ positional argument rejected with exit 1"
    else
        echo "❌ expected exit 1"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 6: outside a git repo exits 2..."
    set total_tests (math $total_tests + 1)
    set -l empty_dir /tmp/git-fish-wlist-empty-(random)
    mkdir -p "$empty_dir"
    cd "$empty_dir"
    git-wlist >/dev/null 2>&1
    if test $status -eq 2
        echo "✅ non-repo exits 2"
    else
        echo "❌ expected exit 2, got $status"
        set failed_tests (math $failed_tests + 1)
    end
    cd "$main_dir"
    rm -rf "$empty_dir"

    # Cleanup (restore HOME, drop config globals leaked by running git-wlist)
    set -lx HOME $orig_home
    cd "$orig_dir"
    git -C "$main_dir" worktree prune >/dev/null 2>&1
    rm -rf "$remote_dir" "$main_dir" "$wts_dir" "$fake_home"
    set -e _wclean_config_protected_branches _wclean_config_default_upstream
    set -e _wclean_config_system_dirs _wclean_config_max_path_length
    set -e _wclean_config_fetch_timeout _wclean_config_stale_days

    echo "📊 git-wlist results: $failed_tests/$total_tests failed"
    return $failed_tests
end
```

Register in `run_functional_tests`. Then extend the help-leak lists in `test_all_commands_help_no_leaked_comments`: append `git-wlist` to `set -l commands ...` (line 1289) and append the marker string `"Enumerate registered worktrees"` to `set -l leak_markers ...` — the implementation below must contain exactly that body comment.

- [ ] **Step 2: Run test to verify it fails**

Run: `fish -c 'source tests/functional-tests.fish; test_git_wlist'`
Expected: FAIL — `git-wlist.fish not found`

- [ ] **Step 3: Create `functions/git-wlist.fish`**

```fish
function git-wlist --description "List git worktrees with lifecycle state"
    # Git Worktree List - Dashboard of every registered worktree's lifecycle state
    #
    # SYNOPSIS
    #   git-wlist [OPTIONS]
    #   git wlist [OPTIONS]
    #
    # DESCRIPTION
    #   Lists every worktree registered in the current repository (via
    #   'git worktree list --porcelain') with its branch, lifecycle state,
    #   dirty flag, and age in days since the last commit. States:
    #
    #     merged      HEAD is contained in the integration branch (origin/HEAD)
    #     pr-closed   The branch's GitHub PR is merged or closed (needs gh)
    #     gone        The branch's upstream was deleted on the remote
    #     stale       No commits within the staleness window (default 30 days)
    #     error       The worktree could not be classified
    #     detached    Detached HEAD
    #     active      None of the above
    #     protected   Branch is in the protected set (main master develop trunk
    #                 plus config)
    #
    #   Rows are sorted in that state order, oldest first within each state.
    #   Git's own locked/prunable annotations are appended to the NAME column.
    #   Runs one 'git fetch --prune origin' up front (bounded by the
    #   _wclean_config_fetch_timeout setting when a timeout utility exists).
    #
    #   Reads the same config as git-wclean (~/.config/git-wclean/config or
    #   ~/.git-wclean-config) but never the repo-local ./.git-wclean-config.
    #
    # OPTIONS
    #   -h, --help            Show this help message
    #   -s, --stale-days N    Staleness threshold in days (default: 30, or
    #                         _wclean_config_stale_days from config)
    #
    # EXAMPLES
    #   # List all worktrees in the current repo/container
    #   git wlist
    #
    #   # Use a tighter staleness window
    #   git wlist --stale-days 7
    #
    # DEPENDENCIES
    #   - gh (optional): enables pr-closed detection for github.com remotes
    #
    # EXIT STATUS
    #   0    Success
    #   1    Invalid arguments
    #   2    Git command failed or not inside a git repository
    argparse --name=git-wlist h/help 's/stale-days=' -- $argv
    or return 1

    if set -q _flag_help
        _git_help_from_doc_comment git-wlist
        return 0
    end

    if test (count $argv) -gt 0
        printf "Error: git-wlist takes no arguments\n" >&2
        printf "Usage: git-wlist [OPTIONS]\n" >&2
        return 1
    end

    if not git rev-parse --git-dir >/dev/null 2>&1
        printf "Error: not inside a git repository\n" >&2
        return 2
    end

    # Shared config; repo-local config is deliberately not honored here
    _git_wclean_config

    set -l stale_days $_wclean_config_stale_days
    if set -q _flag_stale_days
        if not string match -qr '^\d+$' -- $_flag_stale_days
            printf "Error: --stale-days requires a non-negative integer\n" >&2
            return 1
        end
        set stale_days $_flag_stale_days
    end

    # One fetch --prune, timeout-guarded (mirrors _wclean_fetch_remotes; kept
    # inline because wclean's helper prints progress and sets wclean globals)
    if contains origin (git remote 2>/dev/null)
        set -l timeout_cmd
        command -q timeout; and set timeout_cmd timeout
        test -z "$timeout_cmd"; and command -q gtimeout; and set timeout_cmd gtimeout
        if test -n "$timeout_cmd"
            $timeout_cmd $_wclean_config_fetch_timeout git fetch --prune origin >/dev/null 2>&1
            or printf "warning: fetch failed; results may be stale\n" >&2
        else
            git fetch --prune origin >/dev/null 2>&1
            or printf "warning: fetch failed; results may be stale\n" >&2
        end
    end

    # Integration branch from origin/HEAD; config override wins. Empty is
    # tolerated: the classifier then skips the merged check.
    set -l integration_branch (git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
        | string replace 'refs/remotes/' '')
    if test -z "$integration_branch"; and test -n "$_wclean_config_default_upstream"
        set integration_branch $_wclean_config_default_upstream
    end

    # Enumerate registered worktrees (skip the bare repo entry); collect
    # locked/prunable annotations per path
    set -l wt_paths
    set -l wt_notes
    set -l current_path ""
    set -l current_notes ""
    set -l is_bare 0
    for line in (git worktree list --porcelain 2>/dev/null)
        if string match -q 'worktree *' -- $line
            if test -n "$current_path"; and test $is_bare -eq 0
                set -a wt_paths $current_path
                set -a wt_notes "$current_notes"
            end
            set current_path (string replace 'worktree ' '' -- $line)
            set current_notes ""
            set is_bare 0
        else if test "$line" = bare
            set is_bare 1
        else if string match -q 'locked*' -- $line
            set current_notes (string trim -- "$current_notes locked")
        else if string match -q 'prunable*' -- $line
            set current_notes (string trim -- "$current_notes prunable")
        end
    end
    if test -n "$current_path"; and test $is_bare -eq 0
        set -a wt_paths $current_path
        set -a wt_notes "$current_notes"
    end

    if test (count $wt_paths) -eq 0
        printf "No worktrees found.\n"
        return 0
    end

    # Classify each worktree; build sortable rows
    set -l state_order merged pr-closed gone stale error detached active protected
    set -l rows
    for i in (seq (count $wt_paths))
        set -l line (_git_worktree_status $wt_paths[$i] "$integration_branch" \
            $stale_days $_wclean_config_protected_branches)
        set -l f (string split \t -- $line)
        set -l order (contains -i -- $f[1] $state_order)
        or set order 9
        set -l name (basename $f[6])
        if test -n "$wt_notes[$i]"
            set name "$name [$wt_notes[$i]]"
        end
        # error rows carry '-' for age; render it bare, not '-d' (spec)
        set -l age_disp "$f[5]"d
        test "$f[5]" = -; and set age_disp -
        set -a rows (printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
            $order $f[5] $name $f[2] $f[1] $f[4] $age_disp)
    end

    # Sort by state order, then oldest first; render aligned
    begin
        printf 'NAME\tBRANCH\tSTATE\tDIRTY\tAGE\n'
        printf '%s\n' $rows | sort -t \t -k1,1n -k2,2nr | cut -f3-
    end | column -t -s \t
    return 0
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `fish -c 'source tests/functional-tests.fish; test_git_wlist'` — Expected: PASS.
Run: `fish -c 'source tests/functional-tests.fish; test_all_commands_help_no_leaked_comments'` — Expected: PASS including the new `git-wlist` row (the marker "Enumerate registered worktrees" exists only in the body, not the doc block).

- [ ] **Step 5: Syntax check, format, full suite, commit**

```bash
fish --no-execute functions/git-wlist.fish && \
fish_indent < functions/git-wlist.fish | diff -u functions/git-wlist.fish - && \
fish tests/run-tests.fish && \
git add functions/git-wlist.fish tests/functional-tests.fish && \
git commit -m "feat: add git-wlist worktree lifecycle dashboard"
```

---

## Chunk 3: git-wclean integration, --check, docs

### Task 5: wclean argument parsing — `--stale-days`, `--check`, main-flow reorder

**Files:**
- Modify: `functions/git-wclean.fish` (`_wclean_parse_args`, `git-wclean` main body, both cleanup functions)
- Test: `tests/functional-tests.fish` (new `test_git_wclean_check_flags`, registered in `run_functional_tests`)

- [ ] **Step 1: Write the failing test**

```fish
function test_git_wclean_check_flags --description "Test --check/--stale-days argument validation"
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

    echo "🔍 Testing git-wclean --check/--stale-days flag validation..."

    set -p fish_function_path $test_functions_dir
    source $test_functions_dir/git-wclean.fish

    echo "Test 1: --check with --force exits 1..."
    set total_tests (math $total_tests + 1)
    git-wclean --check --force >/dev/null 2>&1
    if test $status -eq 1
        echo "✅ --check --force rejected"
    else
        echo "❌ expected exit 1, got $status"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 2: --check with a directory argument exits 1..."
    set total_tests (math $total_tests + 1)
    git-wclean --check /tmp >/dev/null 2>&1
    if test $status -eq 1
        echo "✅ --check <dir> rejected"
    else
        echo "❌ expected exit 1, got $status"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 3: --stale-days rejects non-numeric values..."
    set total_tests (math $total_tests + 1)
    git-wclean --stale-days banana /tmp >/dev/null 2>&1
    if test $status -eq 1
        echo "✅ non-numeric --stale-days rejected"
    else
        echo "❌ expected exit 1, got $status"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 4: --check outside a git repo exits 0 silently..."
    set total_tests (math $total_tests + 1)
    set -l empty_dir /tmp/git-fish-check-empty-(random)
    mkdir -p "$empty_dir"
    set -l orig_dir (pwd)
    cd "$empty_dir"
    set -l out (git-wclean --check 2>&1)
    set -l st $status
    cd "$orig_dir"
    rm -rf "$empty_dir"
    if test $st -eq 0; and test -z "$out"
        echo "✅ silent exit 0 outside a repo"
    else
        echo "❌ status=$st output='$out'"
        set failed_tests (math $failed_tests + 1)
    end

    echo "📊 --check flag results: $failed_tests/$total_tests failed"
    return $failed_tests
end
```

Register in `run_functional_tests`.

- [ ] **Step 2: Run test to verify it fails**

Run: `fish -c 'source tests/functional-tests.fish; test_git_wclean_check_flags'`
Expected: FAIL — argparse rejects the unknown `--check`/`--stale-days` flags with a usage error whose exit code may already be 1 for Tests 1–3, but Test 4 fails (unknown flag error output, and no silent-0 path exists yet).

- [ ] **Step 3: Modify `_wclean_parse_args`**

Replace the argparse line and add validation. New body of `_wclean_parse_args` (replacing lines 141–192):

```fish
function _wclean_parse_args
    argparse --name=git-wclean h/help n/dry-run f/force no-delete-branch check 's/stale-days=' -- $argv
    or return 1

    # Show help if requested. argparse populates _flag_help only in this
    # function's local scope, so promote it to a global (cleaned up in the
    # cleanup handlers) so the caller in git-wclean can detect it and stop
    # cleanly instead of falling through into directory setup.
    set -e _wclean_flag_help
    if set -q _flag_help
        _git_help_from_doc_comment git-wclean
        set -g _wclean_flag_help
        return 0
    end

    # --check is a standalone mode: any other flag or a positional argument is
    # a misconfigured hook and must fail loudly (runtime conditions inside the
    # check itself stay silent instead)
    set -e _wclean_flag_check
    if set -q _flag_check
        if set -q _flag_dry_run; or set -q _flag_force
            or set -q _flag_no_delete_branch; or set -q _flag_stale_days
            or test (count $argv) -gt 0
            printf "Error: --check cannot be combined with other options or arguments\n" >&2
            return 1
        end
        set -g _wclean_flag_check
        return 0
    end

    # Validate and promote --stale-days (flag overrides config later)
    set -e _wclean_stale_days
    if set -q _flag_stale_days
        if not string match -qr '^\d+$' -- $_flag_stale_days
            printf "Error: --stale-days requires a non-negative integer\n" >&2
            return 1
        end
        set -g _wclean_stale_days $_flag_stale_days
    end

    # Layout-aware default: in a .bare layout, if no path was given, use the container
    if test (count $argv) -eq 0
        set -l _container (_git_bare_container)
        if test $status -eq 0
            set argv $_container
        end
    end

    # Check if directory path is provided
    if test (count $argv) -eq 0
        printf "Error: Missing required argument <worktrees-directory>\n" >&2
        printf "Usage: git-wclean [OPTIONS] <worktrees-directory>\n" >&2
        printf "(No argument needed inside a canonical .bare layout.)\n" >&2
        printf "Try 'git-wclean --help' for more information.\n" >&2
        return 1
    end

    if test (count $argv) -gt 1
        printf "Error: Too many arguments. Expected one directory path.\n" >&2
        printf "Usage: git-wclean [OPTIONS] <worktrees-directory>\n" >&2
        return 1
    end

    # argparse populates _flag_* only in THIS function's local scope. The helper
    # functions run in separate scopes and cannot see those locals, so promote
    # the flags they need to globals (cleaned up in the cleanup handlers).
    set -e _wclean_flag_dry_run
    set -e _wclean_flag_force
    set -e _wclean_flag_no_delete_branch
    set -q _flag_dry_run; and set -g _wclean_flag_dry_run
    set -q _flag_force; and set -g _wclean_flag_force
    set -q _flag_no_delete_branch; and set -g _wclean_flag_no_delete_branch

    # Set the global worktrees directory
    set -g _wclean_worktrees_dir $argv[1]
    return 0
end
```

- [ ] **Step 4: Reorder the `git-wclean` main body**

Config used to load before argument parsing; `--check` needs flags first (to pick `--quiet` and withhold `--allow-local`). Replace the start of the main body (currently: set `_wclean_original_dir`, `_wclean_load_config` call, `_wclean_parse_args`, help check) with:

```fish
    # Store original directory for cleanup
    set -g _wclean_original_dir (pwd)

    # Parse and validate arguments first: --check changes how config loads
    if not _wclean_parse_args $argv
        return 1
    end

    # --help is handled inside _wclean_parse_args (prints help, returns 0),
    # but argparse's _flag_help is local to that function's scope, so it
    # promotes _wclean_flag_help to a global (see the other _wclean_flag_*
    # promotions below) so we can detect it here and stop cleanly instead
    # of falling through into directory setup.
    if set -q _wclean_flag_help
        _wclean_normal_cleanup
        return 0
    end

    # --check: silent one-line nudge mode; never sources repo-local config
    if set -q _wclean_flag_check
        _git_wclean_config --quiet
        _wclean_run_check
        _wclean_normal_cleanup
        return 0
    end

    # Load configuration (full runs may opt into repo-local config)
    _git_wclean_config --allow-local

    # Staleness window: --stale-days flag beats config
    set -q _wclean_stale_days
    or set -g _wclean_stale_days $_wclean_config_stale_days

    # Fresh stale report per run: an earlier aborted run in the same shell
    # may have leaked the global, and set -ga would append across runs
    set -e _wclean_stale_report
```

`_wclean_run_check` does not exist yet — add a placeholder now so Step 5's tests can run, replaced for real in Task 7:

```fish
# Placeholder until the real check mode lands (Task 7): silent success.
function _wclean_run_check
    return 0
end
```

- [ ] **Step 5: Update cleanup functions**

In BOTH `_wclean_cleanup_handler` and `_wclean_normal_cleanup`, next to the other flag erasures add:

```fish
    set -e _wclean_flag_check
    set -e _wclean_stale_days
    set -e _wclean_stale_report
```

(`_wclean_stale_report` is introduced in Task 6; adding its erasure now avoids touching these functions twice.)

- [ ] **Step 6: Run tests**

Run: `fish -c 'source tests/functional-tests.fish; test_git_wclean_check_flags'` — Expected: PASS.
Run: `fish tests/run-tests.fish` — Expected: all pass (existing wclean tests unaffected by the reorder).

- [ ] **Step 7: Commit**

```bash
git add functions/git-wclean.fish tests/functional-tests.fish && \
git commit -m "feat(wclean): add --check and --stale-days parsing, reorder config after args"
```

### Task 6: wclean classifier integration — gone/pr-closed confirm, dirty block, stale report, `--prune`

**Files:**
- Modify: `functions/git-wclean.fish` (delete `_wclean_check_merge_status` and `_wclean_get_worktree_info`; rewrite `_wclean_process_worktree`; add `--prune` in `_wclean_fetch_remotes`; extend `_wclean_show_summary`; prune stale global erasures)
- Test: `tests/functional-tests.fish` (new `test_git_wclean_states`, registered in `run_functional_tests`)

- [ ] **Step 1: Write the failing test**

```fish
function test_git_wclean_states --description "Test wclean gone-confirm, dirty block, stale report, and --prune"
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

    echo "🔍 Testing git-wclean state-driven cleanup..."

    set -p fish_function_path $test_functions_dir
    source $test_functions_dir/git-wclean.fish

    # Fake HOME: Test 8 relies on the default protected set ('develop') and
    # the stale test on the default 30-day window; a real user config could
    # flip either
    set -l fake_home /tmp/git-fish-wcs-home-(random)
    mkdir -p "$fake_home"
    set -l orig_home $HOME
    set -lx HOME $fake_home

    # Rebuildable fixture: bare remote + main + a fresh worktrees dir per scenario
    function _wcs_fixture --argument-names remote_dir main_dir wts_dir
        rm -rf "$remote_dir" "$main_dir" "$wts_dir"
        git init --bare -b main "$remote_dir" >/dev/null 2>&1
        git clone "$remote_dir" "$main_dir" >/dev/null 2>&1
        git -C "$main_dir" config user.name "Test User"
        git -C "$main_dir" config user.email "test@example.com"
        git -C "$main_dir" config commit.gpgsign false
        # A global fetch.prune=true would make the --prune regression test
        # non-discriminating; pin it off so only wclean's own --prune prunes
        git -C "$main_dir" config fetch.prune false
        echo "# Test" >"$main_dir/README.md"
        git -C "$main_dir" add README.md
        git -C "$main_dir" commit -m "Initial commit" >/dev/null 2>&1
        git -C "$main_dir" push -u origin main >/dev/null 2>&1
        git -C "$main_dir" remote set-head origin main >/dev/null 2>&1
        mkdir -p "$wts_dir"
    end

    set -l remote_dir /tmp/git-fish-wcs-remote-(random).git
    set -l main_dir /tmp/git-fish-wcs-main-(random)
    set -l wts_dir /tmp/git-fish-wcs-wts-(random)
    set -l orig_dir (pwd)

    # --- gone scenarios: delete the branch directly in the bare remote.
    # A 'git push --delete' from $main_dir would remove the local tracking
    # ref immediately and defeat the point: deleting in the remote leaves the
    # tracking ref in place, so ONLY wclean's own fetch --prune can produce
    # the gone state — this is the spec-required --prune coverage. ---
    _wcs_fixture "$remote_dir" "$main_dir" "$wts_dir"
    git -C "$main_dir" worktree add "$wts_dir/gone-wt" -b wcs-gone >/dev/null 2>&1
    echo g >"$wts_dir/gone-wt/g.txt"
    git -C "$wts_dir/gone-wt" add g.txt
    git -C "$wts_dir/gone-wt" commit -m "gone work" >/dev/null 2>&1
    git -C "$wts_dir/gone-wt" push -u origin wcs-gone >/dev/null 2>&1
    git -C "$remote_dir" branch -D wcs-gone >/dev/null 2>&1
    cd "$main_dir"

    echo "Test 1: gone + answer n keeps the worktree (and wclean's fetch pruned)..."
    set total_tests (math $total_tests + 1)
    set -l out (echo n | git-wclean "$wts_dir" 2>&1 | string collect)
    if test -d "$wts_dir/gone-wt"; and string match -q '*Candidate:*upstream gone*' -- $out
        echo "✅ candidate line shown (proves --prune ran), 'n' kept the worktree"
    else
        echo "❌ worktree exists: "(test -d "$wts_dir/gone-wt"; and echo yes; or echo no)", output: $out"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 2: gone + answer y removes the worktree..."
    set total_tests (math $total_tests + 1)
    echo y | git-wclean "$wts_dir" >/dev/null 2>&1
    if not test -d "$wts_dir/gone-wt"
        echo "✅ 'y' removed the gone worktree"
    else
        echo "❌ gone worktree should be removed"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 3: gone + --dry-run lists 'needs confirm' and keeps..."
    set total_tests (math $total_tests + 1)
    _wcs_fixture "$remote_dir" "$main_dir" "$wts_dir"
    git -C "$main_dir" worktree add "$wts_dir/gone-wt" -b wcs-gone2 >/dev/null 2>&1
    echo g >"$wts_dir/gone-wt/g.txt"
    git -C "$wts_dir/gone-wt" add g.txt
    git -C "$wts_dir/gone-wt" commit -m "gone work" >/dev/null 2>&1
    git -C "$wts_dir/gone-wt" push -u origin wcs-gone2 >/dev/null 2>&1
    git -C "$remote_dir" branch -D wcs-gone2 >/dev/null 2>&1
    cd "$main_dir"
    set -l out (git-wclean --dry-run "$wts_dir" 2>&1 | string collect)
    if test -d "$wts_dir/gone-wt"; and string match -q '*needs confirm*' -- $out
        echo "✅ dry-run reports 'needs confirm' without removing"
    else
        echo "❌ dry-run wrong: $out"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 4: gone + --force removes without a prompt..."
    set total_tests (math $total_tests + 1)
    git-wclean --force "$wts_dir" </dev/null >/dev/null 2>&1
    if not test -d "$wts_dir/gone-wt"
        echo "✅ --force removed with no prompt (stdin closed)"
    else
        echo "❌ --force should have removed the gone worktree"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 5: merged + dirty is kept, even with --force..."
    set total_tests (math $total_tests + 1)
    _wcs_fixture "$remote_dir" "$main_dir" "$wts_dir"
    git -C "$main_dir" worktree add "$wts_dir/dirty-merged" -b wcs-dirty >/dev/null 2>&1
    echo uncommitted >"$wts_dir/dirty-merged/uncommitted.txt"
    cd "$main_dir"
    git-wclean --force "$wts_dir" </dev/null >/dev/null 2>&1
    if test -d "$wts_dir/dirty-merged"
        echo "✅ dirty merged worktree kept under --force"
    else
        echo "❌ dirty worktree must never be removed"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 6: merged + clean still removed with no prompt..."
    set total_tests (math $total_tests + 1)
    rm "$wts_dir/dirty-merged/uncommitted.txt"
    git-wclean "$wts_dir" </dev/null >/dev/null 2>&1
    if not test -d "$wts_dir/dirty-merged"
        echo "✅ clean merged worktree removed promptlessly"
    else
        echo "❌ clean merged worktree should be removed"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 7: stale is reported but never removed, even with --force..."
    set total_tests (math $total_tests + 1)
    _wcs_fixture "$remote_dir" "$main_dir" "$wts_dir"
    git -C "$main_dir" worktree add "$wts_dir/stale-wt" -b wcs-stale >/dev/null 2>&1
    echo s >"$wts_dir/stale-wt/s.txt"
    git -C "$wts_dir/stale-wt" add s.txt
    env GIT_COMMITTER_DATE="2020-01-01T00:00:00" GIT_AUTHOR_DATE="2020-01-01T00:00:00" \
        git -C "$wts_dir/stale-wt" commit -m "old" >/dev/null 2>&1
    cd "$main_dir"
    set -l out (git-wclean --force "$wts_dir" </dev/null 2>&1 | string collect)
    # match the report text, not '*stale*': the 'Processing: stale-wt' line
    # would satisfy that vacuously via the worktree's own name
    if test -d "$wts_dir/stale-wt"; and string match -q '*never auto-removed*' -- $out
        echo "✅ stale worktree reported and kept"
    else
        echo "❌ stale handling wrong: $out"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 8: --force removes a merged protected worktree; default keeps it..."
    set total_tests (math $total_tests + 1)
    _wcs_fixture "$remote_dir" "$main_dir" "$wts_dir"
    # 'develop' is in the default protected set; branch at main's HEAD = merged
    git -C "$main_dir" worktree add "$wts_dir/develop" -b develop >/dev/null 2>&1
    cd "$main_dir"
    git-wclean "$wts_dir" </dev/null >/dev/null 2>&1
    set -l kept (test -d "$wts_dir/develop"; and echo yes; or echo no)
    git-wclean --force "$wts_dir" </dev/null >/dev/null 2>&1
    set -l removed (test -d "$wts_dir/develop"; and echo no; or echo yes)
    if test $kept = yes; and test $removed = yes
        echo "✅ protected kept by default, removed with --force"
    else
        echo "❌ kept=$kept removed=$removed"
        set failed_tests (math $failed_tests + 1)
    end

    # Cleanup
    set -lx HOME $orig_home
    cd "$orig_dir"
    functions -e _wcs_fixture
    git -C "$main_dir" worktree prune >/dev/null 2>&1
    rm -rf "$remote_dir" "$main_dir" "$wts_dir" "$fake_home"

    echo "📊 wclean state results: $failed_tests/$total_tests failed"
    return $failed_tests
end
```

Register in `run_functional_tests`.

- [ ] **Step 2: Run test to verify it fails**

Run: `fish -c 'source tests/functional-tests.fish; test_git_wclean_states'`
Expected: FAIL — Tests 1–4 fail (no gone handling yet: the unmerged gone worktree is just kept with no prompt), Test 5 fails (dirty merged is currently removed), Test 7 fails (its "never auto-removed" report text does not exist yet).

- [ ] **Step 3: Add `--prune` to `_wclean_fetch_remotes`**

In `_wclean_fetch_remotes`, change both fetch invocations:
- `$timeout_cmd $_wclean_config_fetch_timeout git fetch origin` → `$timeout_cmd $_wclean_config_fetch_timeout git fetch --prune origin`
- `git fetch origin` → `git fetch --prune origin`

- [ ] **Step 4: Delete dead/migrated helpers**

Delete the whole `_wclean_check_merge_status` function (dead code — defined but never called) and the whole `_wclean_get_worktree_info` function (its outputs now come from the classifier). Remove the erasures of `_wclean_head_commit`, `_wclean_current_branch`, and `_wclean_upstream_branch` from both cleanup functions (nothing sets them any more).

- [ ] **Step 5: Rewrite `_wclean_process_worktree`**

```fish
# Helper function to process a single worktree, driven by the shared classifier.
# Returns 0 when the worktree was removed (or would be, in dry-run), 1 otherwise.
function _wclean_process_worktree
    set -l worktree_path $argv[1]

    if test -z "$worktree_path"
        printf "Error: No worktree path provided for processing\n" >&2
        return 1
    end

    if not _wclean_validate_path "$worktree_path" "worktree path"
        return 1
    end

    if not test -d "$worktree_path"
        return 1
    end

    if not test -e "$worktree_path/.git"
        printf "Skipping '%s': Not a git repository.\n" (basename $worktree_path)
        return 1
    end

    set -l name (basename $worktree_path)
    printf "Processing: %s\n" $name

    # --force preserves the documented escape hatch by classifying with an
    # empty protected list, so protected worktrees fall through to the normal
    # rules (the basename guard in _wclean_remove_worktree is force-gated too)
    set -l protected_list $_wclean_config_protected_branches
    set -q _wclean_flag_force; and set protected_list

    set -l line (_git_worktree_status "$worktree_path" "$_wclean_default_branch" \
        $_wclean_stale_days $protected_list)
    set -l f (string split \t -- $line)
    set -l state $f[1]
    set -l branch $f[2]
    test "$branch" = -; and set branch ""
    set -l dirty $f[4]
    set -l age $f[5]

    switch $state
        case merged
            if test "$dirty" = dirty
                printf "  ✗ Merged into %s but has uncommitted changes. Keeping worktree.\n" \
                    $_wclean_default_branch
                return 1
            end
            printf "  ✓ Merged into %s.\n" $_wclean_default_branch
            if not _wclean_find_main_repo "$worktree_path"
                return 1
            end
            if _wclean_remove_worktree "$worktree_path" "$_wclean_main_repo" "$branch"
                return 0
            end
            return 1
        case gone pr-closed
            set -l reason "upstream gone"
            test $state = pr-closed; and set reason "PR merged/closed"
            if test "$dirty" = dirty
                printf "  ✗ %s but has uncommitted changes. Keeping worktree.\n" $reason
                return 1
            end
            # Printed before the prompt: read -P shows nothing on non-tty
            # stdin, so this line is the only visible removal-candidate signal
            printf "  Candidate: %s (%s)\n" $name $reason
            if set -q _wclean_flag_dry_run
                printf "Would remove worktree: %s (needs confirm: %s)\n" $name $reason
                return 0
            end
            if not set -q _wclean_flag_force
                read -l -P "Remove '$name' ($reason)? [y/N] " reply
                if not string match -qi y -- "$reply"
                    printf "  Keeping worktree.\n"
                    return 1
                end
            end
            if not _wclean_find_main_repo "$worktree_path"
                return 1
            end
            if _wclean_remove_worktree "$worktree_path" "$_wclean_main_repo" "$branch"
                return 0
            end
            return 1
        case stale
            printf "  - Stale (%sd, threshold %sd). Review manually; never auto-removed.\n" \
                $age $_wclean_stale_days
            set -ga _wclean_stale_report "$name ($age"d")"
            return 1
        case protected
            printf "  Protected: '%s' worktree will not be removed for safety.\n" $name
            return 1
        case detached
            printf "  - Detached HEAD. Keeping worktree.\n"
            return 1
        case error
            printf "  Error: could not classify worktree. Keeping it.\n" >&2
            return 1
        case '*'
            printf "  - Not merged (state: %s). Keeping worktree.\n" $state
            return 1
    end
end
```

- [ ] **Step 6: Extend `_wclean_show_summary`**

After the existing "Kept/Skipped" line, add the stale section:

```fish
    if set -q _wclean_stale_report[1]
        printf "\nStale — review manually:\n"
        for entry in $_wclean_stale_report
            printf "  %s\n" $entry
        end
    end
```

- [ ] **Step 7: Run tests**

Run: `fish -c 'source tests/functional-tests.fish; test_git_wclean_states'` — Expected: PASS (all 8).
Run: `fish tests/run-tests.fish` — Expected: all pass. `test_git_wclean_dry_run` must still pass: merged+clean still removes, dry-run still prints "Would remove".

- [ ] **Step 8: Format and commit**

```bash
fish_indent < functions/git-wclean.fish | diff -u functions/git-wclean.fish - && \
git add functions/git-wclean.fish tests/functional-tests.fish && \
git commit -m "feat(wclean): classifier-driven cleanup with gone/pr-closed confirm, dirty block, stale report"
```

### Task 7: `--check` nudge mode

**Files:**
- Modify: `functions/git-wclean.fish` (replace the placeholder `_wclean_run_check`)
- Test: `tests/functional-tests.fish` (new `test_git_wclean_check`, registered in `run_functional_tests`)

- [ ] **Step 1: Write the failing test**

```fish
function test_git_wclean_check --description "Test git wclean --check silence, output, and fetch guard"
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

    echo "🔍 Testing git wclean --check..."

    set -p fish_function_path $test_functions_dir
    source $test_functions_dir/git-wclean.fish

    # Fake HOME so a real user config (stale_days, protected branches) can't
    # change the silence/count assertions
    set -l fake_home /tmp/git-fish-chk-home-(random)
    mkdir -p "$fake_home"
    set -l orig_home $HOME
    set -lx HOME $fake_home

    set -l remote_dir /tmp/git-fish-chk-remote-(random).git
    set -l main_dir /tmp/git-fish-chk-main-(random)
    set -l wts_dir /tmp/git-fish-chk-wts-(random)
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
    mkdir -p "$wts_dir"

    set -l orig_dir (pwd)
    cd "$main_dir"

    echo "Test 1: nothing reapable -> silent, exit 0..."
    set total_tests (math $total_tests + 1)
    set -l out (git-wclean --check 2>&1)
    set -l st $status
    if test $st -eq 0; and test -z "$out"
        echo "✅ silent exit 0 with nothing reapable"
    else
        echo "❌ status=$st output='$out'"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 2: stale-only repo stays silent..."
    set total_tests (math $total_tests + 1)
    git -C "$main_dir" worktree add "$wts_dir/chk-stale" -b chk-stale >/dev/null 2>&1
    echo s >"$wts_dir/chk-stale/s.txt"
    git -C "$wts_dir/chk-stale" add s.txt
    env GIT_COMMITTER_DATE="2020-01-01T00:00:00" GIT_AUTHOR_DATE="2020-01-01T00:00:00" \
        git -C "$wts_dir/chk-stale" commit -m "old" >/dev/null 2>&1
    set -l out (git-wclean --check 2>&1)
    if test -z "$out"
        echo "✅ stale alone does not trigger the nudge"
    else
        echo "❌ output='$out'"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 3: gone worktree -> one-line nudge including stale count..."
    set total_tests (math $total_tests + 1)
    git -C "$main_dir" worktree add "$wts_dir/chk-gone" -b chk-gone >/dev/null 2>&1
    echo g >"$wts_dir/chk-gone/g.txt"
    git -C "$wts_dir/chk-gone" add g.txt
    git -C "$wts_dir/chk-gone" commit -m "gone work" >/dev/null 2>&1
    git -C "$wts_dir/chk-gone" push -u origin chk-gone >/dev/null 2>&1
    # Deliberately push --delete here (NOT remote branch -D): it prunes the
    # local tracking ref immediately, so this test passes even on machines
    # with no timeout utility where --check skips its fetch. wclean's own
    # --prune coverage lives in test_git_wclean_states.
    git -C "$main_dir" push origin --delete chk-gone >/dev/null 2>&1
    set -l out (git-wclean --check 2>&1)
    set -l line_count (count $out)
    if test $line_count -eq 1
        and string match -q "*1 reapable*"     -- $out
        and string match -q "*1 gone*"          -- $out
        and string match -q "*1 stale*"         -- $out
        and string match -q "*run 'git wclean'*" -- $out
        echo "✅ one-line nudge with counts"
    else
        echo "❌ lines=$line_count output='$out'"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 4: no timeout utility -> fetch skipped (unpruned gone stays invisible)..."
    set total_tests (math $total_tests + 1)
    # Remove the pruned tracking ref knowledge: recreate a deleted remote
    # branch whose tracking ref is still present locally, then strip
    # timeout/gtimeout from PATH. If --check skipped the fetch (correct), the
    # ref is not pruned and nothing is reapable -> silent. If it fetched
    # anyway, the ref gets pruned and the nudge appears -> fail.
    echo y | git-wclean "$wts_dir" >/dev/null 2>&1  # clear the gone worktree first
    git -C "$main_dir" worktree add "$wts_dir/chk-gone2" -b chk-gone2 >/dev/null 2>&1
    echo g >"$wts_dir/chk-gone2/g.txt"
    git -C "$wts_dir/chk-gone2" add g.txt
    git -C "$wts_dir/chk-gone2" commit -m "gone work" >/dev/null 2>&1
    git -C "$wts_dir/chk-gone2" push -u origin chk-gone2 >/dev/null 2>&1
    git -C "$remote_dir" branch -D chk-gone2 >/dev/null 2>&1
    set -l shim_dir /tmp/git-fish-chk-bin-(random)
    mkdir -p "$shim_dir"
    ln -s (command -s git) "$shim_dir/git"
    ln -s (command -s date) "$shim_dir/date"
    ln -s (command -s basename) "$shim_dir/basename"
    set -l orig_path $PATH
    set -lx PATH $shim_dir
    set -l out (git-wclean --check 2>&1)
    set -l st $status
    set -lx PATH $orig_path
    rm -rf "$shim_dir"
    if test $st -eq 0; and test -z "$out"
        echo "✅ fetch skipped without a timeout utility (silent, exit 0)"
    else
        echo "❌ status=$st output='$out'"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 5: --check never invokes gh, even with a github remote..."
    set total_tests (math $total_tests + 1)
    # Arm the forge gate (github URL + gh on PATH) and prove --no-forge holds.
    # PATH also omits timeout/gtimeout so the fetch is skipped: no network,
    # no credential prompt, and the URL rewrite is inert.
    git -C "$main_dir" remote set-url origin https://github.com/example/repo.git
    set -l shim_dir /tmp/git-fish-chk-gh-(random)
    mkdir -p "$shim_dir"
    ln -s (command -s git) "$shim_dir/git"
    ln -s (command -s date) "$shim_dir/date"
    ln -s (command -s basename) "$shim_dir/basename"
    printf '#!/bin/sh\necho "$@" >> "%s/gh-called.log"\necho MERGED\n' "$shim_dir" >"$shim_dir/gh"
    chmod +x "$shim_dir/gh"
    set -l orig_path2 $PATH
    set -lx PATH $shim_dir
    git-wclean --check >/dev/null 2>&1
    set -l st $status
    set -lx PATH $orig_path2
    if test $st -eq 0; and not test -f "$shim_dir/gh-called.log"
        echo "✅ --check classified with --no-forge (gh stub never invoked)"
    else
        echo "❌ status=$st, gh invoked: "(test -f "$shim_dir/gh-called.log"; and echo yes; or echo no)
        set failed_tests (math $failed_tests + 1)
    end
    rm -rf "$shim_dir"

    # Cleanup
    set -lx HOME $orig_home
    cd "$orig_dir"
    git -C "$main_dir" worktree prune >/dev/null 2>&1
    rm -rf "$remote_dir" "$main_dir" "$wts_dir" "$fake_home"

    echo "📊 --check results: $failed_tests/$total_tests failed"
    return $failed_tests
end
```

Register in `run_functional_tests`.

- [ ] **Step 2: Run test to verify it fails**

Run: `fish -c 'source tests/functional-tests.fish; test_git_wclean_check'`
Expected: Tests 3 and 4 FAIL (placeholder `_wclean_run_check` prints nothing, ever).

- [ ] **Step 3: Replace the placeholder `_wclean_run_check`**

```fish
# --check mode: at most one line on stdout, only when something is reapable.
# Every runtime failure is silent success — a prompt hook must never break
# the shell. Reapable = state in {merged, gone} AND clean; pr-closed is
# impossible here because classification always runs --no-forge (a hung gh
# call must never stall a prompt). Stale is appended only when reapable > 0.
function _wclean_run_check
    git rev-parse --git-dir >/dev/null 2>&1
    or return 0

    # Fetch guard: only fetch when a timeout utility exists — an unbounded
    # fetch is unacceptable in a prompt hook. Otherwise classify against the
    # last-fetched state.
    set -l timeout_cmd
    command -q timeout; and set timeout_cmd timeout
    test -z "$timeout_cmd"; and command -q gtimeout; and set timeout_cmd gtimeout
    if test -n "$timeout_cmd"; and contains origin (git remote 2>/dev/null)
        $timeout_cmd $_wclean_config_fetch_timeout git fetch --prune origin >/dev/null 2>&1
    end

    set -l integration_branch (git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
        | string replace 'refs/remotes/' '')
    if test -z "$integration_branch"; and test -n "$_wclean_config_default_upstream"
        set integration_branch $_wclean_config_default_upstream
    end

    # Enumerate registered worktrees, skipping the bare repo entry
    set -l paths
    set -l current_path ""
    set -l is_bare 0
    for line in (git worktree list --porcelain 2>/dev/null)
        if string match -q 'worktree *' -- $line
            if test -n "$current_path"; and test $is_bare -eq 0
                set -a paths $current_path
            end
            set current_path (string replace 'worktree ' '' -- $line)
            set is_bare 0
        else if test "$line" = bare
            set is_bare 1
        end
    end
    if test -n "$current_path"; and test $is_bare -eq 0
        set -a paths $current_path
    end

    set -l merged_count 0
    set -l gone_count 0
    set -l stale_count 0
    for p in $paths
        set -l line (_git_worktree_status --no-forge "$p" "$integration_branch" \
            $_wclean_config_stale_days $_wclean_config_protected_branches)
        set -l f (string split \t -- $line)
        switch $f[1]
            case merged
                test "$f[4]" = clean; and set merged_count (math $merged_count + 1)
            case gone
                test "$f[4]" = clean; and set gone_count (math $gone_count + 1)
            case stale
                set stale_count (math $stale_count + 1)
        end
    end

    set -l reapable (math $merged_count + $gone_count)
    if test $reapable -gt 0
        set -l msg (printf "git-wclean: %d reapable (%d merged, %d gone)" \
            $reapable $merged_count $gone_count)
        if test $stale_count -gt 0
            set msg "$msg, $stale_count stale"
        end
        printf "%s — run 'git wclean'\n" $msg
    end
    return 0
end
```

- [ ] **Step 4: Run tests**

Run: `fish -c 'source tests/functional-tests.fish; test_git_wclean_check'` — Expected: PASS (all 4).
Run: `fish tests/run-tests.fish` — Expected: all pass.

- [ ] **Step 5: Format and commit**

```bash
fish_indent < functions/git-wclean.fish | diff -u functions/git-wclean.fish - && \
git add functions/git-wclean.fish tests/functional-tests.fish && \
git commit -m "feat(wclean): add --check prompt-hook nudge with fetch guard"
```

### Task 8: Documentation and final verification

**Files:**
- Modify: `functions/git-wclean.fish` (doc comment only), `README.md`, `CLAUDE.md`

- [ ] **Step 1: Update the git-wclean doc comment**

In the `git-wclean` leading doc block:

1. DESCRIPTION — after the existing numbered list, add:

```fish
    #   Beyond ancestry-merged worktrees, wclean also detects worktrees whose
    #   upstream branch was deleted on the remote ('gone', the usual squash-merge
    #   aftermath) and, for github.com remotes with gh installed, worktrees whose
    #   PR is merged or closed. Both are removed only after a per-worktree y/N
    #   confirmation (--force skips the prompt). Worktrees with uncommitted
    #   changes are never removed, in any state, even with --force. Worktrees
    #   older than the staleness window are reported for manual review and never
    #   auto-removed.
```

2. OPTIONS — add two lines:

```fish
    #   -s, --stale-days N   Staleness window in days (default 30)
    #   --check              Print a one-line summary of reapable worktrees and
    #                        exit 0; silent when there is nothing to reap. For
    #                        fish_greeting/prompt hooks. Cannot be combined with
    #                        other options or arguments.
```

3. CONFIGURATION — update the config-paths list note and add the new key:

```fish
    #   Configuration files are loaded from (first match wins):
    #   1. ~/.config/git-wclean/config
    #   2. ~/.git-wclean-config
    #   3. ./.git-wclean-config   (full runs only; git-wlist and --check never
    #      source repo-local config)
```

and to the example config block:

```fish
    #   # Staleness window in days for the 'stale' state
    #   set -g _wclean_config_stale_days 30
```

4. EXIT STATUS — add:

```fish
    #   Under --check, runtime conditions (not a repo, fetch failure) always
    #   exit 0; only invalid flag combinations exit 1.
```

- [ ] **Step 2: Update README.md**

Add `git-wlist` to the command list (matching the existing per-command style), document the new wclean flags, and add a "Cleanup nudge" section:

````markdown
### Cleanup nudge

Add a one-line reminder about reapable worktrees to your shell greeting:

```fish
function fish_greeting
    git wclean --check
end
```

`--check` prints at most one line, only when something is reapable, always
exits 0, never runs `gh`, never sources repo-local config, and skips the
fetch entirely when no `timeout`/`gtimeout` utility is installed.
````

- [ ] **Step 3: Update CLAUDE.md**

In the "Worktree management functions" list add:
`- git-wlist: Dashboard of worktree lifecycle states (merged/gone/stale/...)`
and mention `_git_worktree_status` + `_git_wclean_config` under a "Shared private helpers" note.

- [ ] **Step 4: Full verification**

Run: `fish tests/run-tests.fish`
Expected: every suite passes (syntax, functional including all new tests, help-leak including git-wlist).

Run: `fish -c 'set -p fish_function_path $PWD/functions; git wlist --help'` and `git wclean --help`
Expected: exit 0, doc text shown, no body comments leaked.

- [ ] **Step 5: Commit**

```bash
git add functions/git-wclean.fish README.md CLAUDE.md && \
git commit -m "docs: document git-wlist, wclean --check/--stale-days, and the greeting nudge"
```
