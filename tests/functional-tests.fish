#!/usr/bin/env fish

# Functional Tests for git.fish functions
# This file tests the actual behavior and functionality of the git functions

function setup_test_repo --description "Setup a test git repository for testing"
    set -l test_dir /tmp/git-fish-test-(random)

    if test -d "$test_dir"
        rm -rf "$test_dir"
    end

    mkdir -p "$test_dir"
    cd "$test_dir"

    # Initialize with main as the initial branch
    git init -b main >/dev/null 2>&1
    git config user.name "Test User"
    git config user.email "test@example.com"
    git config commit.gpgsign false

    echo "# Test Repository" >README.md
    git add README.md
    git commit -m "Initial commit" >/dev/null 2>&1

    echo "$test_dir"
end

function cleanup_test_repo --description "Clean up test repository"
    set -l test_dir $argv[1]
    if test -d "$test_dir"
        cd /tmp
        rm -rf "$test_dir"
    end
end

function setup_test_bare_layout --description "Setup a .bare container layout for testing"
    set -l base /tmp/git-fish-bare-(random)

    if test -d "$base"
        rm -rf "$base"
    end

    mkdir -p "$base"

    # Create an upstream repo to clone from
    set -l upstream "$base/upstream.git"
    git init -q -b main --bare "$upstream"

    # Seed the upstream with one commit by cloning, committing, pushing
    set -l seed "$base/seed"
    git clone -q "$upstream" "$seed"
    git -C "$seed" config user.name "Test User"
    git -C "$seed" config user.email "test@example.com"
    git -C "$seed" config commit.gpgsign false
    echo "# Test" >"$seed/README.md"
    git -C "$seed" add README.md
    git -C "$seed" commit -q -m initial
    git -C "$seed" push -q origin main
    rm -rf "$seed"

    # Build the .bare container layout
    set -l container "$base/container"
    mkdir -p "$container"
    git clone -q --bare "$upstream" "$container/.bare"
    echo "gitdir: ./.bare" >"$container/.git"
    git -C "$container" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
    git -C "$container" fetch -q origin
    git -C "$container" worktree add -q main main

    # Return the base (for cleanup), the container path, and the upstream bare repo path
    echo "$base"
    echo "$container"
    echo "$upstream"
end

function cleanup_test_bare_layout --description "Clean up a bare-layout test fixture"
    set -l base $argv[1]
    if test -n "$base"; and test -d "$base"
        cd /tmp
        rm -rf "$base"
    end
end

function test_cwb_function --description "Test the cwb (current working branch) function"
    # Use environment variable or fall back to relative path
    set -l test_functions_dir "$FISH_FUNCTIONS_DIR"
    if test -z "$test_functions_dir"
        # Fall back to relative path from test file
        set -l test_file_dir (dirname (status --current-filename))
        set test_functions_dir "$test_file_dir/../functions"
        if test -d "$test_functions_dir"
            set test_functions_dir (realpath "$test_functions_dir")
        end
    end
    set -l test_repo (setup_test_repo)
    set -l failed_tests 0
    set -l total_tests 0

    echo "🔍 Testing cwb function..."

    # Register the functions dir so autoload can resolve cwb's private
    # helper dependencies (e.g. _git_help_from_doc_comment) — sourcing
    # cwb.fish alone does not pull those in.
    set -p fish_function_path $test_functions_dir

    # Check if functions directory exists
    if not test -d "$test_functions_dir"
        echo "❌ Functions directory not found: $test_functions_dir"
        echo "Working directory: "(pwd)
        echo "Test file: "(status --current-filename)
        return 1
    end

    # Source the function
    if not test -f "$test_functions_dir/cwb.fish"
        echo "❌ cwb.fish not found in: $test_functions_dir"
        return 1
    end
    source $test_functions_dir/cwb.fish

    # Test 1: Get current branch on main
    echo "Test 1: cwb on main branch..."
    set total_tests (math $total_tests + 1)

    cd "$test_repo"
    set -l current_branch (cwb)
    if test "$current_branch" = main
        echo "✅ cwb correctly returned 'main'"
    else
        echo "❌ cwb returned '$current_branch', expected 'main'"
        set failed_tests (math $failed_tests + 1)
    end

    # Test 2: Get current branch on a feature branch
    echo "Test 2: cwb on feature branch..."
    set total_tests (math $total_tests + 1)

    git checkout -b feature-test >/dev/null 2>&1
    set current_branch (cwb)
    if test "$current_branch" = feature-test
        echo "✅ cwb correctly returned 'feature-test'"
    else
        echo "❌ cwb returned '$current_branch', expected 'feature-test'"
        set failed_tests (math $failed_tests + 1)
    end

    # Test 3: Help functionality
    echo "Test 3: cwb help functionality..."
    set total_tests (math $total_tests + 1)

    cwb --help >/dev/null 2>&1
    if test $status -eq 0
        echo "✅ cwb help works correctly"
    else
        echo "❌ cwb help failed"
        set failed_tests (math $failed_tests + 1)
    end

    cleanup_test_repo "$test_repo"

    echo "📊 cwb test results: $failed_tests/$total_tests failed"
    return $failed_tests
end

function test_git_wrapper --description "Test the main git wrapper function"
    # Use environment variable or fall back to relative path
    set -l test_functions_dir "$FISH_FUNCTIONS_DIR"
    if test -z "$test_functions_dir"
        # Fall back to relative path from test file
        set -l test_file_dir (dirname (status --current-filename))
        set test_functions_dir "$test_file_dir/../functions"
        if test -d "$test_functions_dir"
            set test_functions_dir (realpath "$test_functions_dir")
        end
    end
    set -l test_repo (setup_test_repo)
    set -l failed_tests 0
    set -l total_tests 0

    echo "🔍 Testing git wrapper function..."

    # Check if functions directory exists
    if not test -d "$test_functions_dir"
        echo "❌ Functions directory not found: $test_functions_dir"
        echo "Working directory: "(pwd)
        echo "Test file: "(status --current-filename)
        return 1
    end

    # Source the git wrapper and cwb
    if not test -f "$test_functions_dir/git.fish"
        echo "❌ git.fish not found in: $test_functions_dir"
        return 1
    end
    if not test -f "$test_functions_dir/cwb.fish"
        echo "❌ cwb.fish not found in: $test_functions_dir"
        return 1
    end
    source $test_functions_dir/git.fish
    source $test_functions_dir/cwb.fish

    cd "$test_repo"

    # Test 1: Standard git command passthrough
    echo "Test 1: git command passthrough..."
    set total_tests (math $total_tests + 1)

    git status >/dev/null 2>&1
    if test $status -eq 0
        echo "✅ git wrapper correctly passes through standard commands"
    else
        echo "❌ git wrapper failed to pass through standard commands"
        set failed_tests (math $failed_tests + 1)
    end

    # Test 2: Custom function integration (using cwb as an example)
    echo "Test 2: custom function integration..."
    set total_tests (math $total_tests + 1)

    # This would work if cwb was implemented as git-cwb, but it's standalone
    # So we test that git correctly handles unknown subcommands
    git nonexistent-command >/dev/null 2>&1
    if test $status -ne 0
        echo "✅ git wrapper correctly rejects unknown commands"
    else
        echo "❌ git wrapper should have failed for unknown command"
        set failed_tests (math $failed_tests + 1)
    end

    cleanup_test_repo "$test_repo"

    echo "📊 git wrapper test results: $failed_tests/$total_tests failed"
    return $failed_tests
end

function test_git_wrm_validation --description "Test git-wrm input validation and error handling"
    # Use environment variable or fall back to relative path
    set -l test_functions_dir "$FISH_FUNCTIONS_DIR"
    if test -z "$test_functions_dir"
        # Fall back to relative path from test file
        set -l test_file_dir (dirname (status --current-filename))
        set test_functions_dir "$test_file_dir/../functions"
        if test -d "$test_functions_dir"
            set test_functions_dir (realpath "$test_functions_dir")
        end
    end
    set -l failed_tests 0
    set -l total_tests 0

    echo "🔍 Testing git-wrm validation..."

    # Check if functions directory exists
    if not test -d "$test_functions_dir"
        echo "❌ Functions directory not found: $test_functions_dir"
        echo "Working directory: "(pwd)
        echo "Test file: "(status --current-filename)
        return 1
    end

    # Source the function
    if not test -f "$test_functions_dir/git-wrm.fish"
        echo "❌ git-wrm.fish not found in: $test_functions_dir"
        return 1
    end
    # Put the functions dir on fish_function_path so git-wrm's calls to helpers like
    # _git_bare_worktree_path and _git_bare_container autoload correctly.
    set -p fish_function_path $test_functions_dir
    source $test_functions_dir/git-wrm.fish

    # Register the functions dir so autoload can resolve git-wrm's private
    # helper dependencies (_git_help_from_doc_comment, _git_bare_container) —
    # sourcing git-wrm.fish alone does not pull those in.
    set -p fish_function_path $test_functions_dir

    # Test 1: Help functionality
    echo "Test 1: git-wrm help..."
    set total_tests (math $total_tests + 1)

    git-wrm --help >/dev/null 2>&1
    if test $status -eq 0
        echo "✅ git-wrm help works correctly"
    else
        echo "❌ git-wrm help failed"
        set failed_tests (math $failed_tests + 1)
    end

    # Test 2: Missing argument handling
    echo "Test 2: git-wrm missing argument..."
    set total_tests (math $total_tests + 1)

    git-wrm 2>/dev/null
    if test $status -eq 1
        echo "✅ git-wrm correctly rejects missing arguments"
    else
        echo "❌ git-wrm should have failed with missing arguments"
        set failed_tests (math $failed_tests + 1)
    end

    # Test 3: Non-existent directory handling
    echo "Test 3: git-wrm non-existent directory..."
    set total_tests (math $total_tests + 1)

    git-wrm /nonexistent/directory 2>/dev/null
    if test $status -eq 1
        echo "✅ git-wrm correctly rejects non-existent directories"
    else
        echo "❌ git-wrm should have failed for non-existent directory"
        set failed_tests (math $failed_tests + 1)
    end

    echo "📊 git-wrm validation test results: $failed_tests/$total_tests failed"
    return $failed_tests
end

function test_git_wrm_merge_check --description "Test git-wrm only removes worktrees merged into the default branch"
    # Use environment variable or fall back to relative path
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

    echo "🔍 Testing git-wrm merge verification..."

    if not test -f "$test_functions_dir/git-wrm.fish"
        echo "❌ git-wrm.fish not found in: $test_functions_dir"
        return 1
    end
    # Put the functions dir on fish_function_path so git-wrm's calls to helpers like
    # _git_bare_worktree_path and _git_bare_container autoload correctly.
    set -p fish_function_path $test_functions_dir
    source $test_functions_dir/git-wrm.fish

    # Build a bare "remote" with a main branch
    set -l remote_dir /tmp/git-fish-wrm-remote-(random).git
    set -l main_dir /tmp/git-fish-wrm-main-(random)
    rm -rf "$remote_dir" "$main_dir"
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

    # Create a feature worktree with a commit pushed to its OWN remote branch
    # (origin/feature) but never merged into origin/main. This is the exact
    # scenario that the @{upstream} bug mishandled.
    set -l feature_wt /tmp/git-fish-wrm-feature-(random)
    rm -rf "$feature_wt"
    git -C "$main_dir" worktree add -b feature "$feature_wt" >/dev/null 2>&1
    echo "feature work" >"$feature_wt/feature.txt"
    git -C "$feature_wt" add feature.txt
    git -C "$feature_wt" commit -m "Unmerged feature work" >/dev/null 2>&1
    git -C "$feature_wt" push -u origin feature >/dev/null 2>&1

    # Test 1: refuses to remove a worktree not merged into origin/main
    echo "Test 1: git-wrm refuses unmerged worktree..."
    set total_tests (math $total_tests + 1)
    git-wrm "$feature_wt" >/dev/null 2>&1
    set -l rm_status $status
    if test $rm_status -eq 3; and test -d "$feature_wt"
        echo "✅ git-wrm refused to remove unmerged worktree (exit 3)"
    else
        echo "❌ git-wrm should refuse unmerged worktree: exit=$rm_status"
        set failed_tests (math $failed_tests + 1)
    end

    # Merge the feature work into origin/main; now it should be removable.
    git -C "$main_dir" merge --no-ff feature -m "Merge feature" >/dev/null 2>&1
    git -C "$main_dir" push origin main >/dev/null 2>&1

    # Test 2: dry-run reports it WOULD remove once merged into origin/main
    echo "Test 2: git-wrm allows merged worktree..."
    set total_tests (math $total_tests + 1)
    set -l dry_output (git-wrm --dry-run "$feature_wt" 2>&1)
    set -l dry_status $status
    if test $dry_status -eq 0; and string match -q '*Would remove*' "$dry_output"
        echo "✅ git-wrm recognizes merged worktree (dry-run would remove)"
    else
        echo "❌ git-wrm should allow merged worktree: exit=$dry_status"
        set failed_tests (math $failed_tests + 1)
    end

    # Test 3: fails with guidance when origin/HEAD is not set, instead of
    # silently assuming origin/main (which could delete unmerged work).
    echo "Test 3: git-wrm errors when origin/HEAD is unset..."
    set total_tests (math $total_tests + 1)
    git -C "$main_dir" symbolic-ref --delete refs/remotes/origin/HEAD >/dev/null 2>&1
    set -l noref_output (git-wrm "$feature_wt" 2>&1)
    set -l noref_status $status
    if test $noref_status -eq 2; and test -d "$feature_wt"; and string match -q '*origin/HEAD*' "$noref_output"
        echo "✅ git-wrm errors with guidance when origin/HEAD is unset (exit 2)"
    else
        echo "❌ git-wrm should error when origin/HEAD is unset: exit=$noref_status"
        set failed_tests (math $failed_tests + 1)
    end

    # Cleanup
    git -C "$main_dir" worktree remove --force "$feature_wt" >/dev/null 2>&1
    rm -rf "$remote_dir" "$main_dir" "$feature_wt"

    echo "📊 git-wrm merge check results: $failed_tests/$total_tests failed"
    return $failed_tests
end

function test_git_wrm_pr_merged --description "Test git-wrm consults gh for squash-merged PRs like the classifier does"
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

    echo "🔍 Testing git-wrm forge (gh) merge check..."

    set -p fish_function_path $test_functions_dir
    if not test -f "$test_functions_dir/git-wrm.fish"
        echo "❌ git-wrm.fish not found in: $test_functions_dir"
        return 1
    end
    source $test_functions_dir/git-wrm.fish

    # The forge gate opens when the remote URL contains 'github.com'. A LOCAL
    # bare remote whose path contains that string satisfies the gate while
    # keeping git-wrm's fetch offline (a real github.com URL would prompt for
    # credentials or hit the network).
    set -l remote_root /tmp/git-fish-wrmpr-github.com-(random)
    set -l remote_dir "$remote_root/repo.git"
    set -l main_dir /tmp/git-fish-wrmpr-main-(random)
    set -l feature_wt /tmp/git-fish-wrmpr-feature-(random)
    rm -rf "$remote_root" "$main_dir" "$feature_wt"
    mkdir -p "$remote_root"
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

    # Feature branch, then SQUASH-merge it into main: the feature commit is
    # never an ancestor of origin/main, so the ancestry check alone says
    # "not merged" even though the work landed.
    git -C "$main_dir" worktree add -b feature "$feature_wt" >/dev/null 2>&1
    echo "feature work" >"$feature_wt/feature.txt"
    git -C "$feature_wt" add feature.txt
    git -C "$feature_wt" commit -m "Squash-merged feature work" >/dev/null 2>&1
    git -C "$feature_wt" push -u origin feature >/dev/null 2>&1
    git -C "$main_dir" merge --squash feature >/dev/null 2>&1
    git -C "$main_dir" commit -m "Squash merge of feature (#42)" >/dev/null 2>&1
    git -C "$main_dir" push origin main >/dev/null 2>&1

    # gh stub: logs every invocation and answers with the state in
    # $stub_dir/state and the PR head SHA in $stub_dir/sha
    set -l stub_dir /tmp/git-fish-wrmpr-bin-(random)
    mkdir -p "$stub_dir"
    printf '#!/bin/sh\necho "$@" >> "%s/gh-called.log"\nprintf "%%s\\t42\\t%%s\\n" "$(cat "%s/state")" "$(cat "%s/sha")"\n' \
        "$stub_dir" "$stub_dir" "$stub_dir" >"$stub_dir/gh"
    chmod +x "$stub_dir/gh"
    git -C "$feature_wt" rev-parse HEAD >"$stub_dir/sha"
    set -l orig_path $PATH
    set -lx PATH $stub_dir $PATH

    echo "Test 1: dry-run treats a MERGED PR as merged..."
    set total_tests (math $total_tests + 1)
    echo MERGED >"$stub_dir/state"
    rm -f "$stub_dir/gh-called.log"
    set -l out (git-wrm --dry-run "$feature_wt" 2>&1)
    set -l st $status
    if test $st -eq 0; and string match -q '*Would remove*' "$out"
        and string match -q '*PR #42*' "$out"; and test -f "$stub_dir/gh-called.log"
        echo "✅ MERGED PR: dry-run would remove (exit 0, mentions PR #42)"
    else
        echo "❌ exit=$st, gh invoked: "(test -f "$stub_dir/gh-called.log"; and echo yes; or echo no)
        printf '%s\n' $out
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 2: a CLOSED (unmerged) PR is still refused..."
    set total_tests (math $total_tests + 1)
    echo CLOSED >"$stub_dir/state"
    rm -f "$stub_dir/gh-called.log"
    set -l out (git-wrm "$feature_wt" 2>&1)
    set -l st $status
    if test $st -eq 3; and test -d "$feature_wt"; and string match -q '*closed without merging*' "$out"
        echo "✅ CLOSED PR: refused with exit 3 and explanation"
    else
        echo "❌ exit=$st, dir exists: "(test -d "$feature_wt"; and echo yes; or echo no)
        printf '%s\n' $out
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 3: an OPEN PR is refused..."
    set total_tests (math $total_tests + 1)
    echo OPEN >"$stub_dir/state"
    set -l out (git-wrm "$feature_wt" 2>&1)
    set -l st $status
    if test $st -eq 3; and test -d "$feature_wt"
        echo "✅ OPEN PR: refused with exit 3"
    else
        echo "❌ exit=$st, dir exists: "(test -d "$feature_wt"; and echo yes; or echo no)
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 4: --no-forge never invokes gh and refuses..."
    set total_tests (math $total_tests + 1)
    echo MERGED >"$stub_dir/state"
    rm -f "$stub_dir/gh-called.log"
    git-wrm --no-forge "$feature_wt" >/dev/null 2>&1
    set -l st $status
    if test $st -eq 3; and test -d "$feature_wt"; and not test -f "$stub_dir/gh-called.log"
        echo "✅ --no-forge: gh skipped, refused with exit 3"
    else
        echo "❌ exit=$st, gh invoked: "(test -f "$stub_dir/gh-called.log"; and echo yes; or echo no)
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 5: MERGED PR whose head is not this HEAD (reused branch) is refused..."
    set total_tests (math $total_tests + 1)
    # New work on the same branch name after the old PR merged: gh still
    # reports the OLD PR as MERGED, but its head SHA no longer covers HEAD.
    echo "new work" >"$feature_wt/again.txt"
    git -C "$feature_wt" add again.txt
    git -C "$feature_wt" commit -m "Reused branch, unmerged work" >/dev/null 2>&1
    echo MERGED >"$stub_dir/state"
    set -l out (git-wrm "$feature_wt" 2>&1)
    set -l st $status
    if test $st -eq 3; and test -d "$feature_wt"; and string match -q '*does not cover*' "$out"
        echo "✅ reused branch: MERGED PR for an older head refused (exit 3)"
    else
        echo "❌ exit=$st, dir exists: "(test -d "$feature_wt"; and echo yes; or echo no)
        printf '%s\n' $out
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 6: MERGED PR covering HEAD removes the worktree and its local branch..."
    set total_tests (math $total_tests + 1)
    echo MERGED >"$stub_dir/state"
    git -C "$feature_wt" rev-parse HEAD >"$stub_dir/sha"
    set -l out (git-wrm "$feature_wt" 2>&1)
    set -l st $status
    set -l branch_left (git -C "$main_dir" branch --list feature)
    if test $st -eq 0; and not test -d "$feature_wt"; and test -z "$branch_left"
        echo "✅ MERGED PR: worktree and local branch removed"
    else
        echo "❌ exit=$st, dir exists: "(test -d "$feature_wt"; and echo yes; or echo no)", branch left: '$branch_left'"
        printf '%s\n' $out
        set failed_tests (math $failed_tests + 1)
    end

    # Cleanup
    set -lx PATH $orig_path
    git -C "$main_dir" worktree remove --force "$feature_wt" >/dev/null 2>&1
    rm -rf "$remote_root" "$main_dir" "$feature_wt" "$stub_dir"

    echo "📊 git-wrm forge merge check results: $failed_tests/$total_tests failed"
    return $failed_tests
end

function test_git_wclean_dry_run --description "Test git-wclean honors --dry-run and removes merged worktrees"
    # Use environment variable or fall back to relative path
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

    echo "🔍 Testing git-wclean --dry-run safety..."

    if not test -f "$test_functions_dir/git-wclean.fish"
        echo "❌ git-wclean.fish not found in: $test_functions_dir"
        return 1
    end
    source $test_functions_dir/git-wclean.fish

    # Build a bare "remote" with a main branch and a worktrees directory
    set -l remote_dir /tmp/git-fish-wclean-remote-(random).git
    set -l main_dir /tmp/git-fish-wclean-main-(random)
    set -l wts_dir /tmp/git-fish-wclean-wts-(random)
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

    # A merged worktree: a new branch pointing at main's HEAD (contained in
    # origin/main), so it is eligible for removal.
    mkdir -p "$wts_dir"
    git -C "$main_dir" worktree add "$wts_dir/merged" -b merged-copy >/dev/null 2>&1

    # git-wclean detects the remote/default branch from the current repo, so
    # run it from inside the repo (as documented usage implies).
    set -l orig_dir (pwd)
    cd "$main_dir"

    # Test 1: --dry-run must NOT delete the worktree
    echo "Test 1: git-wclean --dry-run keeps worktrees..."
    set total_tests (math $total_tests + 1)
    # The plan is a wlist-style table: one aligned row per worktree under a
    # "Would remove (N)" heading, no per-worktree "Processing:" chatter.
    set -l dry_output (git-wclean --dry-run "$wts_dir" 2>&1 | string collect)
    set -l misses 0
    test -d "$wts_dir/merged"; or set misses (math $misses + 1)
    string match -q '*Would remove (1)*' -- $dry_output; or set misses (math $misses + 1)
    string match -rq '(?m)^merged\s+merged-copy\s+merged\s+\d+d\s+remove, delete branch$' \
        -- $dry_output; or set misses (math $misses + 1)
    string match -q '*Would remove 1 of 1: 1 merged*' -- $dry_output
    or set misses (math $misses + 1)
    not string match -q '*Processing:*' -- $dry_output; or set misses (math $misses + 1)
    if test $misses -eq 0
        echo "✅ git-wclean --dry-run printed the plan table and left the worktree in place"
    else
        echo "❌ dry-run table wrong ($misses misses):"
        printf '%s\n' $dry_output
        set failed_tests (math $failed_tests + 1)
    end

    # Test 1b: --no-delete-branch shows up in the ACTION column
    echo "Test 1b: --dry-run --no-delete-branch plans to keep the branch..."
    set total_tests (math $total_tests + 1)
    set -l dry_output (git-wclean --dry-run --no-delete-branch "$wts_dir" 2>&1 | string collect)
    if string match -rq '(?m)^merged\s+merged-copy\s+merged\s+\d+d\s+remove, keep branch$' \
            -- $dry_output
        echo "✅ ACTION column reads 'remove, keep branch'"
    else
        echo "❌ expected 'remove, keep branch' row:"
        printf '%s\n' $dry_output
        set failed_tests (math $failed_tests + 1)
    end

    # Test 2: a real run prints the same plan, then one result line per
    # removal and a "Removed N of M" summary
    echo "Test 2: git-wclean removes merged worktree..."
    set total_tests (math $total_tests + 1)
    set -l out (git-wclean "$wts_dir" 2>&1 | string collect)
    set -l misses 0
    not test -d "$wts_dir/merged"; or set misses (math $misses + 1)
    string match -q '*Removing (1)*' -- $out; or set misses (math $misses + 1)
    string match -rq '(?m)^merged\s+merged-copy\s+merged\s+\d+d\s+remove, delete branch$' \
        -- $out; or set misses (math $misses + 1)
    string match -q '*✓ merged removed, branch merged-copy deleted*' -- $out
    or set misses (math $misses + 1)
    string match -q '*Removed 1 of 1: 1 merged*' -- $out; or set misses (math $misses + 1)
    if test $misses -eq 0
        echo "✅ git-wclean removed the merged worktree and reported it in the new format"
    else
        echo "❌ real-run output wrong ($misses misses):"
        printf '%s\n' $out
        set failed_tests (math $failed_tests + 1)
    end

    # Cleanup
    cd "$orig_dir"
    git -C "$main_dir" worktree prune >/dev/null 2>&1
    rm -rf "$remote_dir" "$main_dir" "$wts_dir"

    echo "📊 git-wclean dry-run results: $failed_tests/$total_tests failed"
    return $failed_tests
end

function test_git_wclean_help --description "Test git-wclean --help exits 0 and does not leak body comments"
    # Use environment variable or fall back to relative path
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

    echo "🔍 Testing git-wclean --help..."

    if not test -f "$test_functions_dir/git-wclean.fish"
        echo "❌ git-wclean.fish not found in: $test_functions_dir"
        return 1
    end
    source $test_functions_dir/git-wclean.fish

    # Register the functions dir so autoload can resolve git-wclean's
    # private helper dependency (_git_help_from_doc_comment) — sourcing
    # git-wclean.fish alone does not pull it in.
    set -p fish_function_path $test_functions_dir

    set -l help_output (git-wclean --help 2>&1)
    set -l help_status $status

    # Test 1: --help must exit 0, not fall through into normal execution
    echo "Test 1: git-wclean --help exits 0..."
    set total_tests (math $total_tests + 1)
    if test $help_status -eq 0
        echo "✅ git-wclean --help exited 0"
    else
        echo "❌ git-wclean --help exited $help_status, expected 0"
        set failed_tests (math $failed_tests + 1)
    end

    # Test 2: --help must not leak internal implementation comments from the
    # function body (only the leading doc block should be emitted).
    echo "Test 2: git-wclean --help does not leak body comments..."
    set total_tests (math $total_tests + 1)
    if string match -q '*Clean up before exit*' -- "$help_output"
        echo "❌ git-wclean --help leaked an internal body comment"
        set failed_tests (math $failed_tests + 1)
    else
        echo "✅ git-wclean --help did not leak internal body comments"
    end

    echo "📊 git-wclean help results: $failed_tests/$total_tests failed"
    return $failed_tests
end

function test_git_bare_container_helper --description "Test the _git_bare_container layout-detection helper"
    set -l test_functions_dir "$FISH_FUNCTIONS_DIR"
    if test -z "$test_functions_dir"
        set -l test_file_dir (dirname (status --current-filename))
        set test_functions_dir "$test_file_dir/../functions"
        if test -d "$test_functions_dir"
            set test_functions_dir (realpath "$test_functions_dir")
        end
    end

    echo "🔍 Testing _git_bare_container helper..."

    set -l fixture (setup_test_bare_layout)
    set -l base $fixture[1]
    set -l container $fixture[2]
    set -l failed 0
    set -l total 0

    # Source the helper into this shell
    set -p fish_function_path $test_functions_dir

    # Case 1: from container directory → prints container, exits 0
    set total (math $total + 1)
    set -l out (cd $container; and _git_bare_container)
    if test "$out" = "$container"
        echo "  ✅ Returns container path from container directory"
    else
        echo "  ❌ Expected '$container', got '$out'"
        set failed (math $failed + 1)
    end

    # Case 2: from inside the initial worktree → walks up, prints container
    set total (math $total + 1)
    set out (cd $container/main; and _git_bare_container)
    if test "$out" = "$container"
        echo "  ✅ Walks up from worktree to find container"
    else
        echo "  ❌ Expected '$container', got '$out'"
        set failed (math $failed + 1)
    end

    # Case 3: from a deep subdir inside the worktree → still walks up
    set total (math $total + 1)
    mkdir -p $container/main/deep/nested/dir
    set out (cd $container/main/deep/nested/dir; and _git_bare_container)
    if test "$out" = "$container"
        echo "  ✅ Walks up from deeply nested dir"
    else
        echo "  ❌ Expected '$container', got '$out'"
        set failed (math $failed + 1)
    end

    # Case 4: outside any .bare layout → returns non-zero, prints nothing
    set total (math $total + 1)
    set -l outside (mktemp -d)
    set -l out_text (cd $outside; and _git_bare_container)
    set -l out_status $status
    if test $out_status -ne 0; and test -z "$out_text"
        echo "  ✅ Returns non-zero when not in bare layout"
    else
        echo "  ❌ Expected non-zero with empty output, got status=$out_status text='$out_text'"
        set failed (math $failed + 1)
    end
    rm -rf $outside

    cleanup_test_bare_layout $base
    echo "📊 _git_bare_container: $total tests, $failed failed"
    return $failed
end

function test_git_wclone_happy_path --description "Test git-wclone produces a complete bare layout"
    set -l test_functions_dir "$FISH_FUNCTIONS_DIR"
    if test -z "$test_functions_dir"
        set -l test_file_dir (dirname (status --current-filename))
        set test_functions_dir "$test_file_dir/../functions"
        if test -d "$test_functions_dir"
            set test_functions_dir (realpath "$test_functions_dir")
        end
    end

    echo "🔍 Testing git-wclone happy path..."

    # We need a remote to clone from — set up an upstream-only fixture
    set -l base /tmp/git-fish-wclone-(random)
    mkdir -p $base
    set -l upstream "$base/upstream.git"
    git init -q -b main --bare $upstream
    set -l seed "$base/seed"
    git clone -q $upstream $seed
    git -C $seed config user.name "Test User"
    git -C $seed config user.email "test@example.com"
    git -C $seed config commit.gpgsign false
    echo "# Test" >$seed/README.md
    git -C $seed add README.md
    git -C $seed commit -q -m initial
    git -C $seed push -q origin main
    rm -rf $seed

    set -p fish_function_path $test_functions_dir

    set -l dest "$base/cloned"
    set -l failed 0
    set -l total 0

    set total (math $total + 1)
    cd $base
    git-wclone $upstream cloned >/dev/null 2>&1
    set -l clone_status $status
    if test $clone_status -eq 0
        echo "  ✅ git-wclone exits 0 on success"
    else
        echo "  ❌ git-wclone exited $clone_status"
        set failed (math $failed + 1)
    end

    set total (math $total + 1)
    if test -d $dest/.bare
        echo "  ✅ Created .bare/ directory"
    else
        echo "  ❌ .bare/ missing"
        set failed (math $failed + 1)
    end

    set total (math $total + 1)
    if test -f $dest/.git
        echo "  ✅ Created .git pointer file"
    else
        echo "  ❌ .git pointer missing"
        set failed (math $failed + 1)
    end

    set total (math $total + 1)
    if test -d $dest/main
        echo "  ✅ Created initial worktree at main/"
    else
        echo "  ❌ Initial worktree missing"
        set failed (math $failed + 1)
    end

    set total (math $total + 1)
    set -l refspec (git -C $dest config remote.origin.fetch)
    if test "$refspec" = "+refs/heads/*:refs/remotes/origin/*"
        echo "  ✅ remote.origin.fetch configured for remote-tracking refs"
    else
        echo "  ❌ refspec is '$refspec'"
        set failed (math $failed + 1)
    end

    rm -rf $base
    echo "📊 git-wclone happy path: $total tests, $failed failed"
    return $failed
end

function test_git_wclone_refuses_collision --description "Test git-wclone refuses non-empty or pre-existing destinations"
    set -l test_functions_dir "$FISH_FUNCTIONS_DIR"
    if test -z "$test_functions_dir"
        set -l test_file_dir (dirname (status --current-filename))
        set test_functions_dir "$test_file_dir/../functions"
        if test -d "$test_functions_dir"
            set test_functions_dir (realpath "$test_functions_dir")
        end
    end

    echo "🔍 Testing git-wclone collision refusal..."

    set -l base /tmp/git-fish-wclone-coll-(random)
    mkdir -p $base
    set -l upstream "$base/upstream.git"
    git init -q -b main --bare $upstream
    set -l seed "$base/seed"
    git clone -q $upstream $seed
    git -C $seed config user.name "Test User"
    git -C $seed config user.email "test@example.com"
    git -C $seed config commit.gpgsign false
    echo "# Test" >$seed/README.md
    git -C $seed add README.md
    git -C $seed commit -q -m initial
    git -C $seed push -q origin main
    rm -rf $seed

    set -p fish_function_path $test_functions_dir

    cd $base
    set -l failed 0
    set -l total 0

    # Case 1: destination contains arbitrary files → refuse
    set total (math $total + 1)
    mkdir -p $base/conflict
    echo junk >$base/conflict/stuff.txt
    git-wclone $upstream conflict >/dev/null 2>&1
    if test $status -eq 1
        echo "  ✅ Refuses non-empty dest with exit 1"
    else
        echo "  ❌ Did not refuse non-empty dest (status was $status)"
        set failed (math $failed + 1)
    end

    # Case 2: destination already contains .bare/ → refuse
    set total (math $total + 1)
    mkdir -p $base/withbare/.bare
    git-wclone $upstream withbare >/dev/null 2>&1
    if test $status -eq 1
        echo "  ✅ Refuses dest with existing .bare/ with exit 1"
    else
        echo "  ❌ Did not refuse dest with .bare/ (status was $status)"
        set failed (math $failed + 1)
    end

    # Case 3: destination is empty → proceeds
    set total (math $total + 1)
    mkdir -p $base/empty
    git-wclone $upstream empty >/dev/null 2>&1
    if test $status -eq 0
        echo "  ✅ Empty dest proceeds"
    else
        echo "  ❌ Refused empty dest (status was $status)"
        set failed (math $failed + 1)
    end

    rm -rf $base
    echo "📊 git-wclone collision: $total tests, $failed failed"
    return $failed
end

function test_git_wclone_no_checkout --description "Test git-wclone --no-checkout skips initial worktree"
    set -l test_functions_dir "$FISH_FUNCTIONS_DIR"
    if test -z "$test_functions_dir"
        set -l test_file_dir (dirname (status --current-filename))
        set test_functions_dir "$test_file_dir/../functions"
        if test -d "$test_functions_dir"
            set test_functions_dir (realpath "$test_functions_dir")
        end
    end

    echo "🔍 Testing git-wclone --no-checkout..."

    set -l base /tmp/git-fish-wclone-nc-(random)
    mkdir -p $base
    set -l upstream "$base/upstream.git"
    git init -q -b main --bare $upstream
    set -l seed "$base/seed"
    git clone -q $upstream $seed
    git -C $seed config user.name "Test User"
    git -C $seed config user.email "test@example.com"
    git -C $seed config commit.gpgsign false
    echo "# Test" >$seed/README.md
    git -C $seed add README.md
    git -C $seed commit -q -m initial
    git -C $seed push -q origin main
    rm -rf $seed

    set -p fish_function_path $test_functions_dir

    cd $base
    set -l dest "$base/cloned"
    set -l failed 0
    set -l total 0

    set total (math $total + 1)
    git-wclone --no-checkout $upstream cloned >/dev/null 2>&1
    if test $status -eq 0
        echo "  ✅ Exits 0"
    else
        echo "  ❌ Exited non-zero"
        set failed (math $failed + 1)
    end

    set total (math $total + 1)
    if test -d $dest/.bare
        echo "  ✅ Created .bare/"
    else
        echo "  ❌ .bare/ missing"
        set failed (math $failed + 1)
    end

    set total (math $total + 1)
    if not test -d $dest/main
        echo "  ✅ No initial worktree created"
    else
        echo "  ❌ Initial worktree created despite --no-checkout"
        set failed (math $failed + 1)
    end

    rm -rf $base
    echo "📊 git-wclone --no-checkout: $total tests, $failed failed"
    return $failed
end

function test_git_wadd_bare_layout_anchors --description "git-wadd anchors worktree name to container in bare layout"
    set -l test_functions_dir "$FISH_FUNCTIONS_DIR"
    if test -z "$test_functions_dir"
        set -l test_file_dir (dirname (status --current-filename))
        set test_functions_dir "$test_file_dir/../functions"
        if test -d "$test_functions_dir"
            set test_functions_dir (realpath "$test_functions_dir")
        end
    end

    echo "🔍 Testing git-wadd anchoring in bare layout..."

    set -l fixture (setup_test_bare_layout)
    set -l base $fixture[1]
    set -l container $fixture[2]
    set -l failed 0
    set -l total 0

    set -p fish_function_path $test_functions_dir

    # Run wadd from inside the initial worktree
    set total (math $total + 1)
    cd $container/main
    git-wadd feature-x >/dev/null 2>&1
    if test -d "$container/feature-x"; and not test -d "$container/main/feature-x"
        echo "  ✅ Worktree created at <container>/feature-x, not nested"
    else
        echo "  ❌ Worktree placement wrong (container/feature-x exists: "(test -d $container/feature-x; and echo yes; or echo no)", nested: "(test -d $container/main/feature-x; and echo yes; or echo no)")"
        set failed (math $failed + 1)
    end

    cleanup_test_bare_layout $base
    echo "📊 git-wadd anchoring: $total tests, $failed failed"
    return $failed
end

function test_git_wadd_bare_layout_rejects_slash --description "git-wadd rejects names with / in bare layout"
    set -l test_functions_dir "$FISH_FUNCTIONS_DIR"
    if test -z "$test_functions_dir"
        set -l test_file_dir (dirname (status --current-filename))
        set test_functions_dir "$test_file_dir/../functions"
        if test -d "$test_functions_dir"
            set test_functions_dir (realpath "$test_functions_dir")
        end
    end

    echo "🔍 Testing git-wadd / rejection in bare layout..."

    set -l fixture (setup_test_bare_layout)
    set -l base $fixture[1]
    set -l container $fixture[2]
    set -l failed 0
    set -l total 0

    set -p fish_function_path $test_functions_dir

    set total (math $total + 1)
    cd $container/main
    set -l err (git-wadd ssoriche/feature-x 2>&1 >/dev/null)
    set -l rc $status
    if test $rc -ne 0; and string match -q '*cannot contain*' -- "$err"
        echo "  ✅ Rejects name containing /"
    else
        echo "  ❌ Did not reject (rc=$rc, err='$err')"
        set failed (math $failed + 1)
    end

    set total (math $total + 1)
    if not test -d "$container/ssoriche"; and not test -d "$container/main/ssoriche"
        echo "  ✅ No worktree created"
    else
        echo "  ❌ A worktree was created despite the rejection"
        set failed (math $failed + 1)
    end

    cleanup_test_bare_layout $base
    echo "📊 git-wadd slash rejection: $total tests, $failed failed"
    return $failed
end

function test_git_wadd_bare_layout_rejects_invalid_names --description "git-wadd rejects invalid worktree names in bare layout"
    set -l test_functions_dir "$FISH_FUNCTIONS_DIR"
    if test -z "$test_functions_dir"
        set -l test_file_dir (dirname (status --current-filename))
        set test_functions_dir "$test_file_dir/../functions"
        if test -d "$test_functions_dir"
            set test_functions_dir (realpath "$test_functions_dir")
        end
    end

    echo "🔍 Testing git-wadd invalid-name rejection in bare layout..."

    set -l fixture (setup_test_bare_layout)
    set -l base $fixture[1]
    set -l container $fixture[2]
    set -l failed 0
    set -l total 0

    set -p fish_function_path $test_functions_dir

    # Names that _git_bare_worktree_path must reject, paired with a human label for output.
    # '--' precedes each name below so a leading '-' reaches the name validation instead of
    # being consumed by git-wadd's own argparse.
    set -l labels "'.'" "'..'" empty whitespace-only "leading '-'"
    set -l names . .. "" " " -x

    cd $container/main

    for i in (seq (count $names))
        set -l name $names[$i]
        set -l label $labels[$i]

        set total (math $total + 1)
        set -l err (git-wadd -- $name 2>&1 >/dev/null)
        set -l rc $status
        if test $rc -ne 0; and string match -q '*invalid worktree name*' -- "$err"
            echo "  ✅ Rejects $label worktree name"
        else
            echo "  ❌ Did not reject $label (rc=$rc, err='$err')"
            set failed (math $failed + 1)
        end

        set total (math $total + 1)
        set -l entries (ls $container)
        if test (count $entries) -eq 1; and test "$entries[1]" = main; and not test -e "$base/.git"
            echo "  ✅ No worktree created ($label)"
        else
            echo "  ❌ A worktree was created despite the rejection ($label)"
            set failed (math $failed + 1)
        end
    end

    cleanup_test_bare_layout $base
    echo "📊 git-wadd invalid-name rejection: $total tests, $failed failed"
    return $failed
end

function test_git_wadd_checks_out_existing_branch --description "git-wadd checks out an existing local branch instead of failing"
    set -l test_functions_dir "$FISH_FUNCTIONS_DIR"
    if test -z "$test_functions_dir"
        set -l test_file_dir (dirname (status --current-filename))
        set test_functions_dir "$test_file_dir/../functions"
        if test -d "$test_functions_dir"
            set test_functions_dir (realpath "$test_functions_dir")
        end
    end

    echo "🔍 Testing git-wadd existing-branch checkout..."

    set -l fixture (setup_test_bare_layout)
    set -l base $fixture[1]
    set -l container $fixture[2]
    set -l failed 0
    set -l total 0

    set -p fish_function_path $test_functions_dir

    cd $container/main

    # Seed a local branch that is not checked out anywhere, with its own commit ahead
    # of main so the assertion below can tell "checked out feature-y" apart from
    # "created a new branch from upstream".
    git config user.name "Test User"
    git config user.email "test@example.com"
    git config commit.gpgsign false
    git checkout -q -b feature-y
    printf '%s\n' existing-tip >existing-tip.txt
    git add existing-tip.txt
    git commit -q -m "Seed existing branch tip"
    set -l feature_sha (git rev-parse feature-y)
    git checkout -q main
    set -l main_sha (git rev-parse HEAD)

    # Existing branch, no start point: should check it out rather than run -b
    set total (math $total + 1)
    set -l out (git-wadd feature-y 2>&1)
    set -l rc $status
    if test $rc -eq 0; and test -d "$container/feature-y"
        echo "  ✅ Worktree created for existing branch"
    else
        echo "  ❌ Failed to create worktree for existing branch (rc=$rc, out='$out')"
        set failed (math $failed + 1)
    end

    set total (math $total + 1)
    set -l head_branch (git -C $container/feature-y rev-parse --abbrev-ref HEAD 2>/dev/null)
    set -l head_sha (git -C $container/feature-y rev-parse HEAD 2>/dev/null)
    if test "$head_branch" = feature-y; and test "$head_sha" = "$feature_sha"; and test "$head_sha" != "$main_sha"
        echo "  ✅ Worktree is on feature-y at its existing tip, ahead of main"
    else
        echo "  ❌ Worktree HEAD wrong (branch='$head_branch', sha='$head_sha', want '$feature_sha', main='$main_sha')"
        set failed (math $failed + 1)
    end

    set total (math $total + 1)
    if string match -q '*existing branch*' -- "$out"
        echo "  ✅ Output says an existing branch was checked out"
    else
        echo "  ❌ Output did not mention existing branch (out='$out')"
        set failed (math $failed + 1)
    end

    # Existing branch plus an explicit start point is contradictory: refuse clearly
    set total (math $total + 1)
    cd $container/main
    git branch -q feature-z
    set -l err (git-wadd feature-z origin/main 2>&1 >/dev/null)
    set rc $status
    if test $rc -eq 1; and string match -q '*already exists*' -- "$err"; and not test -d "$container/feature-z"
        echo "  ✅ Rejects existing branch with explicit start point"
    else
        echo "  ❌ Did not reject existing branch + start point (rc=$rc, err='$err', dir="(test -d $container/feature-z; and echo yes; or echo no)")"
        set failed (math $failed + 1)
    end

    cleanup_test_bare_layout $base
    echo "📊 git-wadd existing branch: $total tests, $failed failed"
    return $failed
end

function test_git_wadd_non_bare_preserves_path --description "git-wadd in non-bare repo creates worktree relative to cwd"
    set -l test_functions_dir "$FISH_FUNCTIONS_DIR"
    if test -z "$test_functions_dir"
        set -l test_file_dir (dirname (status --current-filename))
        set test_functions_dir "$test_file_dir/../functions"
        if test -d "$test_functions_dir"
            set test_functions_dir (realpath "$test_functions_dir")
        end
    end

    echo "🔍 Testing git-wadd non-bare backward compat..."

    # Build a plain clone (not a .bare layout) from a seeded upstream
    set -l base /tmp/git-fish-wadd-nonbare-(random)
    mkdir -p $base
    set -l upstream "$base/upstream.git"
    git init -q -b main --bare $upstream
    set -l seed "$base/seed"
    git clone -q $upstream $seed
    git -C $seed config user.name "Test User"
    git -C $seed config user.email "test@example.com"
    git -C $seed config commit.gpgsign false
    echo "# Test" >$seed/README.md
    git -C $seed add README.md
    git -C $seed commit -q -m initial
    git -C $seed push -q origin main
    rm -rf $seed
    set -l clone_dir "$base/plain-clone"
    git clone -q $upstream $clone_dir

    set -p fish_function_path $test_functions_dir

    set -l failed 0
    set -l total 0

    cd $clone_dir

    # Verify detection correctly reports non-bare
    set total (math $total + 1)
    _git_bare_container >/dev/null
    if test $status -ne 0
        echo "  ✅ Not in a bare layout (detection correct)"
    else
        echo "  ❌ Falsely detected bare layout in plain clone"
        set failed (math $failed + 1)
    end

    # git-wadd should create the worktree relative to cwd, not anchored elsewhere
    set total (math $total + 1)
    git-wadd feature-x origin/main >/dev/null 2>&1
    if test -d "$clone_dir/feature-x"; and not test -d "$base/feature-x"
        echo "  ✅ Worktree created cwd-relative, not anchored to parent"
    else
        echo "  ❌ Worktree not at expected cwd-relative location"
        set failed (math $failed + 1)
    end

    rm -rf $base
    echo "📊 git-wadd non-bare: $total tests, $failed failed"
    return $failed
end

function test_git_wrm_bare_layout_anchors --description "git-wrm resolves worktree name relative to container in bare layout"
    set -l test_functions_dir "$FISH_FUNCTIONS_DIR"
    if test -z "$test_functions_dir"
        set -l test_file_dir (dirname (status --current-filename))
        set test_functions_dir "$test_file_dir/../functions"
        if test -d "$test_functions_dir"
            set test_functions_dir (realpath "$test_functions_dir")
        end
    end

    echo "🔍 Testing git-wrm anchoring in bare layout..."

    set -l fixture (setup_test_bare_layout)
    set -l base $fixture[1]
    set -l container $fixture[2]
    set -l failed 0
    set -l total 0

    set -p fish_function_path $test_functions_dir

    # Create the worktree directly at the container-anchored location git-wadd would use.
    cd $container/main
    git worktree add -q -b feature-y "$container/feature-y" main >/dev/null 2>&1

    # If git-wrm resolved "feature-y" relative to cwd (container/main) instead of the
    # container, it would look for container/main/feature-y and fail with "does not exist".
    set total (math $total + 1)
    set -l out (git-wrm --dry-run feature-y 2>&1)
    set -l rc $status
    if test $rc -eq 0; and not string match -q '*does not exist*' -- "$out"
        echo "  ✅ Resolved worktree name relative to container, not cwd"
    else
        echo "  ❌ Did not resolve relative to container (rc=$rc, out='$out')"
        set failed (math $failed + 1)
    end

    cleanup_test_bare_layout $base
    echo "📊 git-wrm anchoring: $total tests, $failed failed"
    return $failed
end

function test_git_wpr_bare_layout_anchors --description "git-wpr anchors worktree name to container in bare layout"
    set -l test_functions_dir "$FISH_FUNCTIONS_DIR"
    if test -z "$test_functions_dir"
        set -l test_file_dir (dirname (status --current-filename))
        set test_functions_dir "$test_file_dir/../functions"
        if test -d "$test_functions_dir"
            set test_functions_dir (realpath "$test_functions_dir")
        end
    end

    echo "🔍 Testing git-wpr anchoring in bare layout..."

    set -l fixture (setup_test_bare_layout)
    set -l base $fixture[1]
    set -l container $fixture[2]
    set -l failed 0
    set -l total 0

    set -p fish_function_path $test_functions_dir

    # Dry-run avoids needing a real PR fetch; it still exercises path resolution.
    set total (math $total + 1)
    cd $container/main
    set -l out (git-wpr --dry-run 123 feature-pr 2>&1)
    if string match -q "*Would create worktree: $container/feature-pr *" -- "$out"
        echo "  ✅ Worktree would be created at <container>/feature-pr, not nested"
    else
        echo "  ❌ Worktree placement wrong: '$out'"
        set failed (math $failed + 1)
    end

    cleanup_test_bare_layout $base
    echo "📊 git-wpr anchoring: $total tests, $failed failed"
    return $failed
end

function test_git_wclean_bare_layout_default --description "git-wclean defaults to container directory in bare layout"
    set -l test_functions_dir "$FISH_FUNCTIONS_DIR"
    if test -z "$test_functions_dir"
        set -l test_file_dir (dirname (status --current-filename))
        set test_functions_dir "$test_file_dir/../functions"
        if test -d "$test_functions_dir"
            set test_functions_dir (realpath "$test_functions_dir")
        end
    end

    echo "🔍 Testing git-wclean default in bare layout..."

    set -l fixture (setup_test_bare_layout)
    set -l base $fixture[1]
    set -l container $fixture[2]
    set -l failed 0
    set -l total 0

    set -p fish_function_path $test_functions_dir

    # Invoke wclean with no args while inside the initial worktree.
    # We're testing that the path argument is implicitly defaulted to the container —
    # not the cleanup outcome (which depends on the existing worktree-state logic).
    # Assert the real contract: wclean must (a) succeed and (b) actually select the
    # container directory, not just "not print a missing-argument error". git-wclean
    # prints "Scanning worktrees in: <resolved-path>", so match against the container's
    # realpath (setup_test_bare_layout's $container may traverse a symlinked /tmp).
    set total (math $total + 1)
    cd $container/main
    set -l expected_container (realpath "$container")
    set -l err (git-wclean --dry-run 2>&1)
    set -l rc $status
    if test $rc -eq 0; and string match -q "*Scanning worktrees in: $expected_container*" -- "$err"
        echo "  ✅ wclean succeeded and selected the container ($expected_container)"
    else
        echo "  ❌ wclean did not succeed with the container selected (rc=$rc): '$err'"
        set failed (math $failed + 1)
    end

    cleanup_test_bare_layout $base
    echo "📊 git-wclean bare default: $total tests, $failed failed"
    return $failed
end

function test_git_wclean_path_validation --description "Regression tests for git-wclean path-traversal and system-dir guards"
    set -l test_functions_dir "$FISH_FUNCTIONS_DIR"
    if test -z "$test_functions_dir"
        set -l test_file_dir (dirname (status --current-filename))
        set test_functions_dir "$test_file_dir/../functions"
        if test -d "$test_functions_dir"
            set test_functions_dir (realpath "$test_functions_dir")
        end
    end
    set -l failed 0
    set -l total 0

    echo "🔍 Testing git-wclean path validation..."

    if not test -f "$test_functions_dir/git-wclean.fish"
        echo "❌ git-wclean.fish not found in: $test_functions_dir"
        return 1
    end
    source $test_functions_dir/git-wclean.fish

    # _wclean_validate_path reads this config global directly; set it so the
    # helper can be exercised without going through _git_wclean_config.
    set -g _wclean_config_max_path_length 4096

    # Test 1: a bare '..' must be rejected. The old pattern '*/..*' required a
    # '/' before the '..', so a standalone '..' slipped through validation.
    echo "Test 1: bare '..' rejected..."
    set total (math $total + 1)
    if not _wclean_validate_path ".." "test path" >/dev/null 2>&1
        echo "  ✅ bare '..' correctly rejected"
    else
        echo "  ❌ bare '..' should have been rejected"
        set failed (math $failed + 1)
    end

    # Test 2: a leading '../sibling' must be rejected -- same root cause as
    # Test 1: there's no leading '/' before the '..' component.
    echo "Test 2: '../sibling' rejected..."
    set total (math $total + 1)
    if not _wclean_validate_path "../sibling" "test path" >/dev/null 2>&1
        echo "  ✅ '../sibling' correctly rejected"
    else
        echo "  ❌ '../sibling' should have been rejected"
        set failed (math $failed + 1)
    end

    # Test 3: a legitimate path component that merely contains '..' as part of
    # a longer name must still be accepted. Guards against an overzealous fix
    # that rejects valid directory names like 'foo..bar'.
    echo "Test 3: 'foo..bar' still accepted..."
    set total (math $total + 1)
    if _wclean_validate_path "foo..bar" "test path" >/dev/null 2>&1
        echo "  ✅ 'foo..bar' correctly accepted"
    else
        echo "  ❌ 'foo..bar' should have been accepted (legitimate name, not traversal)"
        set failed (math $failed + 1)
    end

    # Test 4: an exact protected system directory (not just its descendants)
    # must be rejected by _wclean_setup_directory. We point the protected-dirs
    # config at a throwaway temp directory rather than a real system directory
    # like /etc, so this never touches a real protected path -- only the guard
    # logic that reuses the same code path. The config value is given a
    # trailing slash and is NOT itself pre-resolved through realpath, to also
    # exercise the non-canonical-config-value normalization the fix adds.
    echo "Test 4: exact protected directory rejected..."
    set total (math $total + 1)
    set -l fake_system_dir /tmp/git-fish-wclean-sysdir-(random)
    mkdir -p "$fake_system_dir"
    set -l fake_system_dir_real (realpath "$fake_system_dir")
    set -g _wclean_config_system_dirs "$fake_system_dir_real/"
    set -g _wclean_worktrees_dir "$fake_system_dir"
    set -l setup_err (_wclean_setup_directory 2>&1)
    set -l setup_rc $status
    if test $setup_rc -ne 0; and string match -q "*Operation not allowed on system directory*" -- "$setup_err"
        echo "  ✅ exact protected directory correctly rejected"
    else
        echo "  ❌ exact protected directory should have been rejected (rc=$setup_rc): '$setup_err'"
        set failed (math $failed + 1)
    end

    # Test 5: a descendant of a protected directory must still be rejected --
    # the pre-existing behavior the fix must not regress.
    echo "Test 5: descendant of protected directory still rejected..."
    set total (math $total + 1)
    set -l fake_system_subdir "$fake_system_dir_real/child"
    mkdir -p "$fake_system_subdir"
    set -g _wclean_worktrees_dir "$fake_system_subdir"
    set -l setup_err2 (_wclean_setup_directory 2>&1)
    set -l setup_rc2 $status
    if test $setup_rc2 -ne 0; and string match -q "*Operation not allowed on system directory*" -- "$setup_err2"
        echo "  ✅ descendant of protected directory correctly rejected"
    else
        echo "  ❌ descendant of protected directory should have been rejected (rc=$setup_rc2): '$setup_err2'"
        set failed (math $failed + 1)
    end

    set -e _wclean_config_system_dirs
    set -e _wclean_worktrees_dir
    rm -rf "$fake_system_dir"

    echo "📊 git-wclean path validation: $total tests, $failed failed"
    return $failed
end

function test_all_commands_help_no_leaked_comments --description "Data-driven check that every command's --help exits 0 and leaks no implementation comments"
    set -l test_functions_dir "$FISH_FUNCTIONS_DIR"
    if test -z "$test_functions_dir"
        set -l test_file_dir (dirname (status --current-filename))
        set test_functions_dir "$test_file_dir/../functions"
        if test -d "$test_functions_dir"
            set test_functions_dir (realpath "$test_functions_dir")
        end
    end
    set -l failed 0
    set -l total 0

    echo "🔍 Testing --help across all commands for leaked body comments..."

    if not test -d "$test_functions_dir"
        echo "❌ Functions directory not found: $test_functions_dir"
        return 1
    end

    set -p fish_function_path $test_functions_dir

    # Each command paired with a distinctive substring from one of ITS OWN
    # non-doc implementation comments (i.e. text that only exists in the
    # function body, never in its documented --help sections). If any of
    # these show up in --help output, the leading doc-comment block was not
    # correctly isolated from the rest of the function body.
    set -l commands cwb git-bclean git-diff-plain git-show-plain git-wadd git-wjump git-wclone git-wpr git-wrm git-wclean git-wlist
    set -l leak_markers "Check if we're in a git repository and get branch name" \
        "Extract remote name from upstream branch" \
        "Run git diff with pager disabled" \
        "Run git show with pager disabled" \
        "Layout-aware path resolution: in a bare layout, the argument is a worktree NAME" \
        "Check if fzf is available" \
        "Destination collision checks" \
        "Validate PR number is numeric" \
        "Note: Fish shell signal handling is different from bash" \
        "Clean up before exit" \
        "Enumerate registered worktrees"

    for i in (seq (count $commands))
        set -l cmd $commands[$i]
        set -l marker $leak_markers[$i]

        set total (math $total + 1)
        set -l help_output ($cmd --help 2>&1)
        set -l help_status $status

        if test $help_status -ne 0
            echo "❌ $cmd --help exited $help_status, expected 0"
            set failed (math $failed + 1)
            continue
        end

        if string match -q "*$marker*" -- "$help_output"
            echo "❌ $cmd --help leaked implementation comment: '$marker'"
            set failed (math $failed + 1)
        else
            echo "✅ $cmd --help exits 0 and does not leak implementation comments"
        end
    end

    echo "📊 --help leak check: $total tests, $failed failed"
    return $failed
end

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

    # Test 6: a fetch timeout the helper would reject falls back to 30 with a
    # warning (coreutils timeout once accepted 1.5; _git_fetch_progress does not)
    echo "Test 6: invalid fetch timeout -> 30 with a warning..."
    set total_tests (math $total_tests + 1)
    printf 'set -g _wclean_config_fetch_timeout 1.5\n' >"$fake_home/.config/git-wclean/config"
    set -l cfg_err (_git_wclean_config 2>&1 >/dev/null)
    _git_wclean_config 2>/dev/null
    set -l loud_value $_wclean_config_fetch_timeout
    set -l quiet_err (_git_wclean_config --quiet 2>&1)
    if test "$loud_value" = 30
        and string match -q "*warning: _wclean_config_fetch_timeout '1.5' is not a whole number*" -- "$cfg_err"
        and test -z "$quiet_err"
        echo "✅ 1.5 replaced by 30; warning shown, and suppressed under --quiet"
    else
        echo "❌ value=$loud_value stderr='$cfg_err' quiet='$quiet_err'"
        set failed_tests (math $failed_tests + 1)
    end

    # Cleanup
    set -lx HOME $orig_home
    cd "$orig_dir"
    rm -rf "$fake_home" "$work_dir"
    set -e _wclean_config_protected_branches
    set -e _wclean_config_default_upstream
    set -e _wclean_config_system_dirs
    set -e _wclean_config_max_path_length
    set -e _wclean_config_fetch_timeout
    set -e _wclean_config_stale_days

    echo "📊 _git_wclean_config results: $failed_tests/$total_tests failed"
    return $failed_tests
end

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

    # Fake HOME so a real user config (once --check becomes load-bearing in
    # Task 7) can never print output and break Test 4's silence assertion.
    set -l fake_home /tmp/git-fish-check-home-(random)
    mkdir -p "$fake_home"
    set -l orig_home $HOME
    set -lx HOME $fake_home

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

    set -lx HOME $orig_home
    rm -rf "$fake_home"

    echo "📊 --check flag results: $failed_tests/$total_tests failed"
    return $failed_tests
end

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

    echo "Test 10: non-numeric stale-days is rejected, exit 1..."
    set total_tests (math $total_tests + 1)
    set -l line (_git_worktree_status "$wts_dir/active" origin/main banana)
    set -l st $status
    if test $st -eq 1; and string match -q 'error	*' -- $line
        echo "✅ error line + return 1"
    else
        echo "❌ status=$st line='$line'"
        set failed_tests (math $failed_tests + 1)
    end

    # Cleanup
    functions -e _wts_field
    git -C "$main_dir" worktree prune >/dev/null 2>&1
    rm -rf "$remote_dir" "$main_dir" "$wts_dir"

    echo "📊 _git_worktree_status results: $failed_tests/$total_tests failed"
    return $failed_tests
end

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

    # gh stub: logs every invocation, answers MERGED with the PR head SHA
    # (the helper's third field) equal to the worktree HEAD
    set -l stub_dir /tmp/git-fish-prc-bin-(random)
    mkdir -p "$stub_dir"
    set -l pr_head (git -C "$wts_dir/pr" rev-parse HEAD)
    printf '#!/bin/sh\necho "$@" >> "%s/gh-called.log"\nprintf "MERGED\\t7\\t%s\\n"\n' \
        "$stub_dir" $pr_head >"$stub_dir/gh"
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
    if test "$state" = active; and not test -f "$stub_dir/gh-called.log"
        echo "✅ --no-forge skipped gh (state='$state')"
    else
        echo "❌ state='$state', gh invoked: "(test -f "$stub_dir/gh-called.log"; and echo yes; or echo no)
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 3: gh says OPEN -> falls through (active)..."
    set total_tests (math $total_tests + 1)
    rm -f "$stub_dir/gh-called.log"
    printf '#!/bin/sh\necho "$@" >> "%s/gh-called.log"\nprintf "OPEN\\t7\\t%s\\n"\n' \
        "$stub_dir" $pr_head >"$stub_dir/gh"
    chmod +x "$stub_dir/gh"
    set -l line (_git_worktree_status "$wts_dir/pr" origin/main 30)
    set -l state (string split \t -- $line)[1]
    if test "$state" = active; and test -f "$stub_dir/gh-called.log"
        echo "✅ OPEN PR leaves worktree active"
    else
        echo "❌ got '$state', want active (gh invoked: "(test -f "$stub_dir/gh-called.log"; and echo yes; or echo no)")"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 4: MERGED PR whose head is not this HEAD (reused branch) -> active..."
    set total_tests (math $total_tests + 1)
    rm -f "$stub_dir/gh-called.log"
    # Reused branch name: gh reports the OLD PR as MERGED, but its head is the
    # initial commit, which does not cover the worktree's HEAD.
    set -l old_head (git -C "$main_dir" rev-parse origin/main)
    printf '#!/bin/sh\necho "$@" >> "%s/gh-called.log"\nprintf "MERGED\\t7\\t%s\\n"\n' \
        "$stub_dir" $old_head >"$stub_dir/gh"
    chmod +x "$stub_dir/gh"
    set -l line (_git_worktree_status "$wts_dir/pr" origin/main 30)
    set -l state (string split \t -- $line)[1]
    if test "$state" = active; and test -f "$stub_dir/gh-called.log"
        echo "✅ stale PR head leaves worktree active"
    else
        echo "❌ got '$state', want active (gh invoked: "(test -f "$stub_dir/gh-called.log"; and echo yes; or echo no)")"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 5: non-github remote skips gh entirely..."
    set total_tests (math $total_tests + 1)
    git -C "$main_dir" remote set-url origin https://forgejo.example.com/example/repo.git
    printf '#!/bin/sh\necho "$@" >> "%s/gh-called.log"\nprintf "MERGED\\t7\\t%s\\n"\n' \
        "$stub_dir" $pr_head >"$stub_dir/gh"
    chmod +x "$stub_dir/gh"
    rm -f "$stub_dir/gh-called.log"
    set -l line (_git_worktree_status "$wts_dir/pr" origin/main 30)
    set -l state (string split \t -- $line)[1]
    if test "$state" = active; and not test -f "$stub_dir/gh-called.log"
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

    echo "Test 7: _wclean_config_default_upstream overrides origin/HEAD..."
    set total_tests (math $total_tests + 1)
    # wl-active's commit is NOT on origin/main (state: active). Push it to a
    # second remote branch and point the config override there: if the
    # override wins over origin/HEAD, wl-active reclassifies as merged.
    git -C "$wts_dir/wl-active" push origin wl-active:wl-alt >/dev/null 2>&1
    mkdir -p "$fake_home/.config/git-wclean"
    printf 'set -g _wclean_config_default_upstream origin/wl-alt\n' >"$fake_home/.config/git-wclean/config"
    set -l override_out (git-wlist 2>/dev/null | string collect)
    rm -f "$fake_home/.config/git-wclean/config"
    if string match -rq 'wl-active\s.*merged' -- $override_out
        echo "✅ config override took precedence over origin/HEAD"
    else
        echo "❌ override ignored; wl-active row:"
        printf '%s\n' $override_out | string match -e wl-active
        set failed_tests (math $failed_tests + 1)
    end

    # Cleanup (restore HOME, drop config globals leaked by running git-wlist)
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

    echo "📊 git-wlist results: $failed_tests/$total_tests failed"
    return $failed_tests
end

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
    # The plan row proves --prune ran (gone needs the pruned tracking ref);
    # the declined result line proves the 'n' was honored
    if test -d "$wts_dir/gone-wt"
        and string match -rq '(?m)^gone-wt\s+wcs-gone\s+gone\s+\d+d\s+remove after confirm$' -- $out
        and string match -q '*- gone-wt kept (declined)*' -- $out
        echo "✅ plan row shown (proves --prune ran), 'n' kept the worktree"
    else
        echo "❌ worktree exists: "(test -d "$wts_dir/gone-wt"; and echo yes; or echo no)", output: $out"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 2: gone + answer y removes the worktree..."
    set total_tests (math $total_tests + 1)
    set -l out (echo y | git-wclean "$wts_dir" 2>&1 | string collect)
    if not test -d "$wts_dir/gone-wt"
        echo "✅ 'y' removed the gone worktree"
    else
        echo "❌ gone worktree should be removed"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 2b: summary reports a per-category breakdown..."
    set total_tests (math $total_tests + 1)
    if string match -q '*Removed 1 of 1: 1 gone*' -- $out
        # a gone branch is not an ancestor of main, so git needs the force delete
        and string match -q '*✓ gone-wt removed, branch wcs-gone force-deleted*' -- $out
        echo "✅ result line and summary include '1 gone'"
    else
        echo "❌ summary breakdown missing: $out"
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
    if test -d "$wts_dir/gone-wt"
        and string match -rq '(?m)^gone-wt\s+wcs-gone2\s+gone\s+\d+d\s+remove after confirm$' -- $out
        and string match -q '*Would remove 1 of 1: 1 gone (confirm each)*' -- $out
        echo "✅ dry-run reports 'remove after confirm' without removing"
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
    set -l out (git-wclean --force "$wts_dir" </dev/null 2>&1 | string collect)
    # Dirty worktrees land in the Kept table with the reason spelled out
    if test -d "$wts_dir/dirty-merged"
        and string match -rq \
            '(?m)^dirty-merged\s+wcs-dirty\s+merged\s+\d+d\s+uncommitted changes$' -- $out
        and string match -q '*Kept 1: 1 uncommitted changes*' -- $out
        echo "✅ dirty merged worktree kept under --force and listed with its reason"
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
        git -C "$wts_dir/stale-wt" commit -m old >/dev/null 2>&1
    cd "$main_dir"
    set -l out (git-wclean --force "$wts_dir" </dev/null 2>&1 | string collect)
    # Anchor on the full Kept row so the worktree's own name cannot satisfy
    # a bare '*stale*' match vacuously
    if test -d "$wts_dir/stale-wt"
        and string match -rq \
            '(?m)^stale-wt\s+wcs-stale\s+stale\s+\d+d\s+stale, review manually$' -- $out
        and string match -q '*Kept 1: 1 stale*' -- $out
        echo "✅ stale worktree listed as kept with 'review manually'"
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

    echo "Test 9: pre-removal recheck refuses a worktree that changed since the plan..."
    set total_tests (math $total_tests + 1)
    _wcs_fixture "$remote_dir" "$main_dir" "$wts_dir"
    git -C "$main_dir" worktree add "$wts_dir/rc" -b wcs-rc >/dev/null 2>&1
    set -l planned (git -C "$wts_dir/rc" rev-parse HEAD)
    set -l misses 0
    # unchanged and clean: safe
    _wclean_recheck_worktree "$wts_dir/rc" "$planned" >/dev/null; or set misses (math $misses + 1)
    # untracked file appeared: refused, named as uncommitted changes
    echo u >"$wts_dir/rc/u.txt"
    set -l why (_wclean_recheck_worktree "$wts_dir/rc" "$planned")
    test $status -eq 1; and string match -q '*uncommitted changes*' -- "$why"
    or set misses (math $misses + 1)
    # new commit appeared: refused, named as new commits
    git -C "$wts_dir/rc" add u.txt
    git -C "$wts_dir/rc" commit -m later >/dev/null 2>&1
    set -l why (_wclean_recheck_worktree "$wts_dir/rc" "$planned")
    test $status -eq 1; and string match -q '*new commits*' -- "$why"
    or set misses (math $misses + 1)
    if test $misses -eq 0
        echo "✅ recheck accepts an unchanged clean worktree and refuses dirty or advanced ones"
    else
        echo "❌ recheck wrong ($misses misses)"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 10: a worktree dirtied while an earlier prompt waits is not removed..."
    set total_tests (math $total_tests + 1)
    _wcs_fixture "$remote_dir" "$main_dir" "$wts_dir"
    # Two gone worktrees; execution order is by state then name, so 'gone-a'
    # prompts first and blocks on stdin while 'gone-b' is still pending
    for n in a b
        git -C "$main_dir" worktree add "$wts_dir/gone-$n" -b wcs-gone-$n >/dev/null 2>&1
        echo $n >"$wts_dir/gone-$n/$n.txt"
        git -C "$wts_dir/gone-$n" add $n.txt
        git -C "$wts_dir/gone-$n" commit -m "gone $n" >/dev/null 2>&1
        git -C "$wts_dir/gone-$n" push -u origin wcs-gone-$n >/dev/null 2>&1
        git -C "$remote_dir" branch -D wcs-gone-$n >/dev/null 2>&1
    end
    cd "$main_dir"
    # The stdin producer waits until the plan is printed and the first prompt
    # is blocking, dirties gone-b, then answers both prompts with y. It must
    # be an external command: fish runs a builtin-only block to completion
    # before starting the rest of the pipeline, which would dirty gone-b
    # before the plan is even computed
    set -l out (sh -c 'sleep 3; echo dirty >"$0/gone-b/late.txt"; echo y; echo y' "$wts_dir" \
        | git-wclean "$wts_dir" 2>&1 | string collect)
    if not test -d "$wts_dir/gone-a"; and test -d "$wts_dir/gone-b"
        and string match -q '*✗ gone-b not removed (uncommitted changes since the plan)*' -- $out
        and string match -q '*1 changed since plan*' -- $out
        echo "✅ gone-a removed, gone-b kept after it changed mid-run"
    else
        echo "❌ recheck during execution wrong: $out"
        set failed_tests (math $failed_tests + 1)
    end

    # Cleanup (restore HOME, drop config globals leaked by running git-wclean)
    set -lx HOME $orig_home
    cd "$orig_dir"
    functions -e _wcs_fixture
    git -C "$main_dir" worktree prune >/dev/null 2>&1
    rm -rf "$remote_dir" "$main_dir" "$wts_dir" "$fake_home"
    set -e _wclean_config_protected_branches
    set -e _wclean_config_default_upstream
    set -e _wclean_config_system_dirs
    set -e _wclean_config_max_path_length
    set -e _wclean_config_fetch_timeout
    set -e _wclean_config_stale_days

    echo "📊 wclean state results: $failed_tests/$total_tests failed"
    return $failed_tests
end

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
        git -C "$wts_dir/chk-stale" commit -m old >/dev/null 2>&1
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
    # push --delete prunes the local tracking ref immediately; wclean's own
    # --prune coverage lives in test_git_wclean_states and in Test 4 below.
    git -C "$main_dir" push origin --delete chk-gone >/dev/null 2>&1
    set -l out (git-wclean --check 2>&1)
    set -l line_count (count $out)
    if test $line_count -eq 1
        and string match -q "*1 reapable*" -- $out
        and string match -q "*1 gone*" -- $out
        and string match -q "*1 stale*" -- $out
        and string match -q "*run 'git wclean'*" -- $out
        echo "✅ one-line nudge with counts"
    else
        echo "❌ lines=$line_count output='$out'"
        set failed_tests (math $failed_tests + 1)
    end

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
    set -l pre_cleared yes
    test -d "$wts_dir/chk-gone"; and set pre_cleared no
    if test $st -eq 0
        and test $pre_cleared = yes
        and test (count $out) -eq 1
        and string match -q "*1 gone*" -- $out
        echo "✅ fetch ran and pruned without a timeout utility (one-line nudge, exit 0)"
    else
        echo "❌ status=$st pre_cleared=$pre_cleared output='$out'"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 5: --check never invokes gh, even with a github remote..."
    set total_tests (math $total_tests + 1)
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
    if test $st -eq 0; and not test -f "$shim_dir/gh-called.log"
        echo "✅ --check classified with --no-forge (gh stub never invoked)"
    else
        echo "❌ status=$st, gh invoked: "(test -f "$shim_dir/gh-called.log"; and echo yes; or echo no)
        set failed_tests (math $failed_tests + 1)
    end
    rm -rf "$shim_dir"

    # Cleanup (restore HOME, drop config globals leaked by running git-wclean)
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

    echo "📊 --check results: $failed_tests/$total_tests failed"
    return $failed_tests
end

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

    echo "Test 2a: unusable TMPDIR falls back to /tmp instead of failing..."
    set total_tests (math $total_tests + 1)
    set -lx TMPDIR /nonexistent-git-fish-(random)
    _git_fetch_progress --quiet --label x --timeout 10 -- --prune origin >/dev/null 2>&1
    set -l st $status
    set -lx TMPDIR $tmp_dir
    if test $st -eq 0
        echo "✅ mktemp retried under /tmp and the fetch succeeded"
    else
        echo "❌ status=$st with a missing TMPDIR"
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
    # The recorded child pid is the precise check; pgrep -f also matches the
    # wrapper's own argv, which contains the sleep command text.
    set -l child_alive 0
    kill -0 (string trim <$kt_pidfile) 2>/dev/null; and set child_alive 1
    set -l survivors (pgrep -f 'sleep 6049')
    if test $st -eq 0; and test $child_alive -eq 0; and test -z "$survivors"
        echo "✅ ps walk found and killed the wrapper's child"
    else
        echo "❌ status=$st child_alive=$child_alive survivors='$survivors'"
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
    set -l child_alive 0
    kill -0 $kt_gitpid 2>/dev/null; and set child_alive 1
    set -l survivors (pgrep -f 'sleep 6049')
    if test $st -eq 0; and test $child_alive -eq 0; and test -z "$survivors"
        echo "✅ pid-file source killed git without ps"
    else
        echo "❌ status=$st child_alive=$child_alive survivors='$survivors'"
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
    set -l child_alive 0
    kill -0 (string trim <$kt_pidfile) 2>/dev/null; and set child_alive 1
    if test $st -eq 1; and test $child_alive -eq 1
        echo "✅ no ps and empty pid -> 1, child left running (this is the 125 case)"
    else
        echo "❌ status=$st child_alive=$child_alive"
        set failed_tests (math $failed_tests + 1)
    end
    # The test owns this orphan: kill it and the wrapper now.
    kill -TERM (string trim <$kt_pidfile) 2>/dev/null
    kill -TERM $kt_wrapper 2>/dev/null
    pkill -f 'sleep 6049' 2>/dev/null
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
    # 125 means the helper could not kill git: the test does it. Git first,
    # because a live git respawns its transport when the old one dies.
    pkill -f 'git fetch fp6047' 2>/dev/null
    pkill -f 'sleep 6047' 2>/dev/null
    echo "Test 8: SIGINT to the fish process stops the fetch, cleans up, and returns 130..."
    set total_tests (math $total_tests + 1)
    # This models the NON-interactive case (scripts, CI, kill -INT <fish>):
    # fish itself receives the signal, the INT handler cleans up, and the
    # spinner loop must then observe the interrupted flag and return 130
    # rather than resume and report a plain failure. The interactive case
    # (Ctrl-C goes to the foreground sleep, not to fish) is covered by
    # Test 9 (fish_postexec) and by the manual pty check in the spec.
    # The child fish records its own pid (the one to signal) and an sh
    # parent records its exit status, since fish's wait does not carry it.
    set -l child_pidfile $cap_dir/child8.pid
    set -l child_rcfile $cap_dir/child8.rc
    set -lx GIT_SSH_COMMAND 'sh -c "sleep 6048"'
    sh -c 'fish -c "$1"; echo $? >"$0"' $child_rcfile "printf '%s\n' \$fish_pid >$child_pidfile
        set -p fish_function_path $test_functions_dir
        source $test_functions_dir/_git_fetch_progress.fish
        cd $repo_dir
        _git_fetch_progress --label 'Fetching from fp6048' --timeout 30 -- fp6048
        set -l rc \$status
        printf 'rc=%s\n' \$rc >&2
        exit \$rc" >$cap_dir/out8 2>$cap_dir/err8 &
    set -e GIT_SSH_COMMAND
    # Wait for the label line: the fetch is then in flight.
    for _i in (seq 1 50)
        test -s $cap_dir/err8; and test -s $child_pidfile; and break
        sleep 0.1
    end
    sleep 0.5
    set -l child (string trim <$child_pidfile)
    kill -INT $child 2>/dev/null
    set -l child_alive 1
    for _i in (seq 1 80)
        if not kill -0 $child 2>/dev/null; and test -s $child_rcfile
            set child_alive 0
            break
        end
        sleep 0.1
    end
    sleep 0.3
    set -l child_rc (string trim <$child_rcfile 2>/dev/null)
    set -l err_text (string collect <$cap_dir/err8)
    set -l transport (pgrep -f 'sleep 6048')
    set -l gitproc (pgrep -f 'git fetch fp6048')
    set -l leftovers $tmp_dir/*
    if test $child_alive -eq 0
        and test "$child_rc" = 130
        and string match -q '*rc=130*' -- $err_text
        and test -z "$transport"
        and test -z "$gitproc"
        and test (count $leftovers) -eq 0
        echo "✅ INT handler killed git and transport, emptied TMPDIR, helper returned 130"
    else
        echo "❌ child_alive=$child_alive rc='$child_rc' stderr='$err_text' transport='$transport' git='$gitproc' leftovers=$leftovers"
        set failed_tests (math $failed_tests + 1)
    end
    test -n "$child"; and kill -TERM $child 2>/dev/null
    pkill -f 'sleep 6048' 2>/dev/null
    pkill -f 'git fetch fp6048' 2>/dev/null

    echo "Test 9: fish_postexec aborts a fetch left registered by a cancelled command line..."
    set total_tests (math $total_tests + 1)
    # Interactively Ctrl-C reaches the foreground sleep, not fish, so the INT
    # handler never runs and fish just abandons the helper. A fake in-flight
    # job (real scratch files plus a harmless sleeping wrapper) stands in for
    # that state; emitting fish_postexec must clean it up and leave neither
    # the job global nor the interrupted flag behind.
    set -l pe_status $cap_dir/pe-status
    touch $pe_status "$pe_status.pid"
    sleep 6045 &
    set -l pe_wrapper $last_pid
    set -l pe_out (fish -c "set -p fish_function_path $test_functions_dir
        source $test_functions_dir/_git_fetch_progress.fish
        set -g _git_fetch_progress_job $pe_status $pe_wrapper
        emit fish_postexec
        set -q _git_fetch_progress_job; and printf 'job-still-set\n'
        set -q _git_fetch_progress_interrupted; and printf 'flag-still-set\n'
        printf 'postexec-done\n'" 2>/dev/null)
    if test "$pe_out" = postexec-done
        and test ! -e $pe_status
        and test ! -e "$pe_status.pid"
        echo "✅ postexec hook removed the scratch files and cleared the globals"
    else
        echo "❌ child said '$pe_out' status-file-exists="(test -e $pe_status; and echo yes; or echo no)
        set failed_tests (math $failed_tests + 1)
    end
    kill -TERM $pe_wrapper 2>/dev/null

    echo "Test 9b: fish_prompt aborts a fetch left registered by a cancelled prompt hook..."
    set total_tests (math $total_tests + 1)
    # Ctrl-C during a fish_greeting or prompt-hook `git wclean --check` is
    # not followed by fish_postexec (there was no command line), so the
    # next fish_prompt must do the same cleanup.
    set -l pr_status $cap_dir/pr-status
    touch $pr_status "$pr_status.pid"
    sleep 6045 &
    set -l pr_wrapper $last_pid
    set -l pr_out (fish -c "set -p fish_function_path $test_functions_dir
        source $test_functions_dir/_git_fetch_progress.fish
        set -g _git_fetch_progress_job $pr_status $pr_wrapper
        emit fish_prompt
        set -q _git_fetch_progress_job; and printf 'job-still-set\n'
        set -q _git_fetch_progress_interrupted; and printf 'flag-still-set\n'
        printf 'prompt-done\n'" 2>/dev/null)
    # Match loosely: the child loads the user's config, whose own fish_prompt
    # handlers may print (e.g. OSC 7 cwd escapes).
    if string match -q '*prompt-done*' -- "$pr_out"
        and not string match -q '*still-set*' -- "$pr_out"
        and test ! -e $pr_status
        and test ! -e "$pr_status.pid"
        echo "✅ fish_prompt hook removed the scratch files and cleared the globals"
    else
        echo "❌ child said '$pr_out' status-file-exists="(test -e $pr_status; and echo yes; or echo no)
        set failed_tests (math $failed_tests + 1)
    end
    kill -TERM $pr_wrapper 2>/dev/null
    rm -f $pr_status "$pr_status.pid"

    echo "Test 10: timeout whose wrapper stays alive after SIGKILL -> 125, files left..."
    set total_tests (math $total_tests + 1)
    # A wrapper still alive after the TERM, the KILL and every wait means git
    # may still be running and the wrapper could recreate the status file, so
    # the helper must return 125 and leave the scratch files in place. Hard to
    # stage for real, so shadow the wait with a stub that always reports
    # "still alive" and drive the real timeout path.
    function _git_fetch_progress_wait_gone
        return 1
    end
    set -lx GIT_SSH_COMMAND 'sh -c "sleep 6047"'
    _git_fetch_progress --label "Fetching from fp6047" --timeout 1 -- fp6047 \
        >$cap_dir/out10 2>$cap_dir/err10
    set -l st $status
    set -e GIT_SSH_COMMAND
    functions -e _git_fetch_progress_wait_gone
    source $test_functions_dir/_git_fetch_progress.fish
    # The real wrapper is dead (the shadow lied), so these are the files the
    # helper chose to leave; clean them up here.
    set -l kept_status $tmp_dir/git-fish-fetch.*
    set -l kept_pid (string match -r '.*\.pid$' -- $kept_status)
    set -l kept_main (string match -rv '.*\.pid$' -- $kept_status)
    if test $st -eq 125; and test (count $kept_main) -eq 1; and test (count $kept_pid) -le 1
        echo "✅ unconfirmed wrapper exit gives 125 and the scratch files are left in place"
    else
        echo "❌ status=$st (expected 125) kept=$kept_status"
        set failed_tests (math $failed_tests + 1)
    end
    sleep 0.3
    pkill -f 'git fetch fp6047' 2>/dev/null
    pkill -f 'sleep 6047' 2>/dev/null
    set -l stray $tmp_dir/*
    test (count $stray) -gt 0; and rm -f $stray

    echo "Test 10b: a wrapper that outlives the wait is ended before the files go..."
    set total_tests (math $total_tests + 1)
    # Real waits, kill-tree stubbed: git (and therefore its wrapper) is still
    # alive when the wait runs out, so the reap must signal the wrapper and
    # confirm it gone before the files are removed. Killing git afterwards
    # would otherwise let a surviving wrapper recreate the status file.
    function _git_fetch_progress_kill_tree
        return 0
    end
    set -lx GIT_SSH_COMMAND 'sh -c "sleep 6047"'
    _git_fetch_progress --quiet --label x --timeout 1 -- fp6047 >/dev/null 2>&1
    set -l st $status
    set -e GIT_SSH_COMMAND
    functions -e _git_fetch_progress_kill_tree
    source $test_functions_dir/_git_fetch_progress.fish
    pkill -f 'git fetch fp6047' 2>/dev/null
    sleep 1
    set -l late $tmp_dir/*
    if test $st -eq 125; and test (count $late) -eq 0
        echo "✅ surviving wrapper was ended; no status file reappeared"
    else
        echo "❌ status=$st (expected 125) late=$late"
        set failed_tests (math $failed_tests + 1)
    end
    pkill -f 'git fetch fp6047' 2>/dev/null
    pkill -f 'sleep 6047' 2>/dev/null
    set -l stray $tmp_dir/*
    test (count $stray) -gt 0; and rm -f $stray

    echo "Test 11: a signal during the timeout wait window returns 130, not 124/125..."
    set total_tests (math $total_tests + 1)
    # Shadow the wait with a stub that runs the real abort (as the signal
    # handler would) while the helper sits in the wait; the abort owns the
    # file removal, the helper only reports 130.
    # One-shot: the first wait runs the abort; every later wait (including
    # the abort's own reap) delegates to the real function.
    functions -c _git_fetch_progress_wait_gone _real_wait_gone
    function _git_fetch_progress_wait_gone
        if not set -q _t11_fired
            set -g _t11_fired 1
            _git_fetch_progress_abort
            return 0
        end
        _real_wait_gone $argv
    end
    set -lx GIT_SSH_COMMAND 'sh -c "sleep 6047"'
    _git_fetch_progress --label "Fetching from fp6047" --timeout 1 -- fp6047 \
        >$cap_dir/out11 2>$cap_dir/err11
    set -l st $status
    set -e GIT_SSH_COMMAND
    functions -e _git_fetch_progress_wait_gone _real_wait_gone
    set -e _t11_fired
    source $test_functions_dir/_git_fetch_progress.fish
    set -l leftovers $tmp_dir/*
    sleep 1
    set -l late $tmp_dir/*
    if test $st -eq 130; and test (count $leftovers) -eq 0; and test (count $late) -eq 0
        and not set -q _git_fetch_progress_interrupted
        and not set -q _git_fetch_progress_job
        and not string match -q '*Unknown command*' -- (string collect <$cap_dir/err11)
        echo "✅ interrupt during the timeout wait returns 130 and cleans up"
    else
        echo "❌ status=$st (expected 130) leftovers=$leftovers late=$late"
        set failed_tests (math $failed_tests + 1)
    end
    pkill -f 'sleep 6047' 2>/dev/null
    pkill -f 'git fetch fp6047' 2>/dev/null
    sleep 0.3
    set -l stray $tmp_dir/*
    test (count $stray) -gt 0; and rm -f $stray

    echo "Test 12: a stale registered job is aborted on entry..."
    set total_tests (math $total_tests + 1)
    # Same shape as the real wrapper: an sh that exits once its child dies
    # (the abort kills the descendants, never the wrapper itself).
    touch $cap_dir/stale-status
    sh -c 'sleep 6043 & echo $! >"$0.pid"; wait $!' $cap_dir/stale-status >/dev/null 2>&1 &
    set -l stale_pid $last_pid
    for _i in (seq 1 30)
        test -s $cap_dir/stale-status.pid; and break
        sleep 0.1
    end
    set -g _git_fetch_progress_job $cap_dir/stale-status $stale_pid
    _git_fetch_progress --quiet --label x --timeout 10 -- --prune origin \
        >$cap_dir/out12 2>$cap_dir/err12
    set -l st $status
    sleep 0.2
    set -l stale_alive 0
    kill -0 $stale_pid 2>/dev/null; and set stale_alive 1
    kill -TERM $stale_pid 2>/dev/null
    if test $st -eq 0; and not test -e $cap_dir/stale-status
        and not test -e $cap_dir/stale-status.pid; and test $stale_alive -eq 0
        echo "✅ stale job killed and its files removed at entry"
    else
        printf '❌ status=%s alive=%s files=%s\n' $st $stale_alive (string join , (path filter $cap_dir/stale*))
        set failed_tests (math $failed_tests + 1)
    end
    set -e _git_fetch_progress_job
    rm -f $cap_dir/stale-status $cap_dir/stale-status.pid

    echo "Test 13: the wrapper refuses to write its pid through a planted symlink..."
    set total_tests (math $total_tests + 1)
    # "$0.pid" is predictable even though "$0" comes from mktemp: in a shared
    # TMPDIR another user could plant <status-file>.pid -> <victim>. Drive
    # the exact wrapper script by hand against such a symlink.
    set -l sl_status (mktemp $cap_dir/sl-status.XXXXXX)
    set -l sl_canary $cap_dir/sl-canary
    printf 'canary-content\n' >$sl_canary
    ln -s $sl_canary "$sl_status.pid"
    sh -c (_git_fetch_progress_wrapper_script | string collect) $sl_status fpbad >/dev/null 2>&1
    set -l canary_text (string collect <$sl_canary)
    set -l fetch_rc (string trim <$sl_status)
    if test "$canary_text" = canary-content
        and test -L "$sl_status.pid"
        and test -n "$fetch_rc"; and test "$fetch_rc" != 0
        echo "✅ noclobber kept the symlink target intact; the fetch still ran"
    else
        echo "❌ canary='$canary_text' symlink="(test -L "$sl_status.pid"; and echo yes; or echo no)" fetch_rc='$fetch_rc'"
        set failed_tests (math $failed_tests + 1)
    end
    rm -f $sl_status "$sl_status.pid" $sl_canary

    echo "Test 14: the fetch runs with askpass disabled as well as terminal prompts..."
    set total_tests (math $total_tests + 1)
    # GIT_TERMINAL_PROMPT=0 alone still lets git run GIT_ASKPASS/SSH_ASKPASS
    # (a GUI dialog); git skips askpass when GIT_ASKPASS is set but empty. A
    # fake git records the environment it was started with.
    set -l env_shim $cap_dir/shim-env
    set -l env_log $cap_dir/git-env.log
    mkdir -p $env_shim
    for tool in sh mktemp sleep date rm kill ps basename dirname
        ln -s (command -s $tool) $env_shim/$tool
    end
    printf '%s\n' '#!/bin/sh' \
        "printf 'TP=%s AP=[%s] SP=[%s]\\n' \"\$GIT_TERMINAL_PROMPT\" \"\$GIT_ASKPASS\" \"\$SSH_ASKPASS\" >>$env_log" \
        'exit 0' >$env_shim/git
    chmod +x $env_shim/git
    set -l orig_path $PATH
    set -lx GIT_ASKPASS /bin/echo
    set -lx SSH_ASKPASS /bin/echo
    set -lx PATH $env_shim
    _git_fetch_progress --quiet --label x --timeout 10 -- origin >/dev/null 2>&1
    set -l st $status
    set -lx PATH $orig_path
    set -e GIT_ASKPASS
    set -e SSH_ASKPASS
    set -l env_text (string collect <$env_log 2>/dev/null)
    if test $st -eq 0; and test "$env_text" = "TP=0 AP=[] SP=[]"
        echo "✅ git saw GIT_TERMINAL_PROMPT=0 with empty GIT_ASKPASS and SSH_ASKPASS"
    else
        echo "❌ status=$st env='$env_text'"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 15: a fetch that succeeds inside the post-kill wait is reported 0, not 124..."
    set total_tests (math $total_tests + 1)
    # The deadline can fire just before git exits 0 on its own. A fake git
    # sleeps past the 1s timeout but well inside the ~2s wait, and a
    # kill-tree stub kills nothing, so the status file ends up holding 0.
    # (1.5s: the timeout fires between 0 and ~1.1s after start, so git is
    # always still running then and always done before the wait ends.)
    set -l slow_shim $cap_dir/shim-slow
    mkdir -p $slow_shim
    for tool in sh mktemp sleep date rm kill ps basename dirname
        ln -s (command -s $tool) $slow_shim/$tool
    end
    printf '%s\n' '#!/bin/sh' 'sleep 1.5' 'exit 0' >$slow_shim/git
    chmod +x $slow_shim/git
    function _git_fetch_progress_kill_tree
        return 0
    end
    set -l orig_path $PATH
    set -lx PATH $slow_shim
    _git_fetch_progress --quiet --label x --timeout 1 -- origin >/dev/null 2>&1
    set -l st $status
    set -lx PATH $orig_path
    functions -e _git_fetch_progress_kill_tree
    source $test_functions_dir/_git_fetch_progress.fish
    set -l leftovers $tmp_dir/*
    if test $st -eq 0; and test (count $leftovers) -eq 0
        echo "✅ git's own exit 0 wins over the deadline"
    else
        echo "❌ status=$st (expected 0) leftovers=$leftovers"
        set failed_tests (math $failed_tests + 1)
    end
    set -l stray $tmp_dir/*
    test (count $stray) -gt 0; and rm -f $stray

    # Cleanup
    set -e TMPDIR
    cd "$orig_dir"
    rm -rf "$remote_dir" "$repo_dir" "$tmp_dir" "$cap_dir"

    echo "📊 _git_fetch_progress results: $failed_tests/$total_tests failed"
    return $failed_tests
end

function test_git_fetch_progress_callers --description "Test how wclean, wlist, and wrm react to fetch statuses 125 and 130"
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

    set -l cap_dir /tmp/git-fish-fpc-cap-(random)
    mkdir -p "$cap_dir"
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
    echo y | git-wclean "$wts_dir" >$cap_dir/wclean1 2>&1
    set -l st $status
    set -l out (string collect <$cap_dir/wclean1)
    if test $st -eq 2
        and test -d "$wts_dir/merged"
        and string match -q '*could not be confirmed stopped*' -- $out
        echo "✅ wclean aborted with exit 2 and the worktree intact"
    else
        echo "❌ status=$st exists="(test -d "$wts_dir/merged"; and echo yes; or echo no)" output: $out"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 1a: wclean's interrupt handler aborts an in-flight fetch before exiting..."
    set total_tests (math $total_tests + 1)
    # The handler ends in `exit 130`, so drive it in a child fish. A fake
    # in-flight job: a real scratch file plus a harmless sleeping wrapper.
    set -l fake_status $cap_dir/fake-status
    touch $fake_status "$fake_status.pid"
    sleep 6046 &
    set -l fake_wrapper $last_pid
    fish -c "set -p fish_function_path $test_functions_dir
        source $test_functions_dir/git-wclean.fish
        source $test_functions_dir/_git_fetch_progress.fish
        set -g _git_fetch_progress_job $fake_status $fake_wrapper
        _wclean_cleanup_handler" >/dev/null 2>&1
    set -l st $status
    sleep 0.3
    set -l wrapper_alive 0
    kill -0 $fake_wrapper 2>/dev/null; and set wrapper_alive 1
    if test $st -eq 130; and test ! -e $fake_status; and test ! -e "$fake_status.pid"
        echo "✅ handler exited 130 after removing the fetch scratch files"
    else
        echo "❌ status=$st status-file-exists="(test -e $fake_status; and echo yes; or echo no)" wrapper_alive=$wrapper_alive"
        set failed_tests (math $failed_tests + 1)
    end
    kill -TERM $fake_wrapper 2>/dev/null

    echo "Test 1b: wclean's interrupt handler is silent under --check..."
    set total_tests (math $total_tests + 1)
    # A prompt-hook --check must never print, even when interrupted.
    fish -c "set -p fish_function_path $test_functions_dir
        source $test_functions_dir/git-wclean.fish
        set -g _wclean_flag_check 1
        _wclean_cleanup_handler" >/dev/null 2>$cap_dir/handler1b
    set -l st $status
    set -l err (string collect <$cap_dir/handler1b)
    if test $st -eq 130; and test -z "$err"
        echo "✅ handler exited 130 with no message under --check"
    else
        echo "❌ status=$st stderr='$err'"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 2: git-wclean --check exits 2 silently on 125..."
    set total_tests (math $total_tests + 1)
    git-wclean --check >$cap_dir/check 2>&1
    set -l st $status
    set -l out (string collect <$cap_dir/check)
    if test $st -eq 2; and test -z "$out"
        echo "✅ --check: exit 2, no output"
    else
        echo "❌ status=$st output='$out'"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 3: git-wlist warns on 125 and still prints its table..."
    set total_tests (math $total_tests + 1)
    git-wlist >$cap_dir/wlist 2>&1
    set -l st $status
    set -l out (string collect <$cap_dir/wlist)
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
    set -l pwd_before $PWD
    git-wrm "$wts_dir/merged" >$cap_dir/wrm 2>&1
    set -l st $status
    set -l pwd_after $PWD
    set -l out (string collect <$cap_dir/wrm)
    if test $st -eq 2
        and test -d "$wts_dir/merged"
        and test "$pwd_before" = "$pwd_after"
        and string match -q '*could not be confirmed stopped*' -- $out
        echo "✅ wrm refused to remove with exit 2"
    else
        echo "❌ status=$st exists="(test -d "$wts_dir/merged"; and echo yes; or echo no)" pwd_before=$pwd_before pwd_after=$pwd_after output: $out"
        set failed_tests (math $failed_tests + 1)
    end

    # Second stub round: 130 means the user interrupted the fetch, so every
    # caller must stop at once with 130 and touch nothing.
    function _git_fetch_progress
        return 130
    end

    echo "Test 5: git-wclean stops with 130 on an interrupted fetch, removes nothing..."
    set total_tests (math $total_tests + 1)
    echo y | git-wclean "$wts_dir" >$cap_dir/wclean5 2>&1
    set -l st $status
    if test $st -eq 130; and test -d "$wts_dir/merged"
        echo "✅ wclean exited 130 with the worktree intact"
    else
        echo "❌ status=$st exists="(test -d "$wts_dir/merged"; and echo yes; or echo no)" output: "(string collect <$cap_dir/wclean5)
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 6: git-wclean --check exits 130 silently on an interrupted fetch..."
    set total_tests (math $total_tests + 1)
    git-wclean --check >$cap_dir/check6 2>&1
    set -l st $status
    set -l out (string collect <$cap_dir/check6)
    if test $st -eq 130; and test -z "$out"
        echo "✅ --check: exit 130, no output"
    else
        echo "❌ status=$st output='$out'"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 7: git-wlist exits 130 on an interrupted fetch..."
    set total_tests (math $total_tests + 1)
    git-wlist >$cap_dir/wlist7 2>&1
    set -l st $status
    set -l out (string collect <$cap_dir/wlist7)
    if test $st -eq 130; and not string match -q '*NAME*' -- $out
        echo "✅ wlist: exit 130, no table"
    else
        echo "❌ status=$st output: $out"
        set failed_tests (math $failed_tests + 1)
    end

    echo "Test 8: git-wrm exits 130 on an interrupted fetch, worktree kept, cwd unchanged..."
    set total_tests (math $total_tests + 1)
    set -l pwd_before $PWD
    git-wrm "$wts_dir/merged" >$cap_dir/wrm8 2>&1
    set -l st $status
    set -l pwd_after $PWD
    if test $st -eq 130
        and test -d "$wts_dir/merged"
        and test "$pwd_before" = "$pwd_after"
        echo "✅ wrm exited 130 without removing anything"
    else
        echo "❌ status=$st exists="(test -d "$wts_dir/merged"; and echo yes; or echo no)" pwd_before=$pwd_before pwd_after=$pwd_after output: "(string collect <$cap_dir/wrm8)
        set failed_tests (math $failed_tests + 1)
    end

    # Restore the real helper and clean up
    functions -e _git_fetch_progress
    source $test_functions_dir/_git_fetch_progress.fish
    set -lx HOME $orig_home
    cd "$orig_dir"
    git -C "$main_dir" worktree prune >/dev/null 2>&1
    rm -rf "$remote_dir" "$main_dir" "$wts_dir" "$fake_home" "$cap_dir"
    set -e _wclean_config_protected_branches
    set -e _wclean_config_default_upstream
    set -e _wclean_config_system_dirs
    set -e _wclean_config_max_path_length
    set -e _wclean_config_fetch_timeout
    set -e _wclean_config_stale_days

    echo "📊 fetch-progress caller results: $failed_tests/$total_tests failed"
    return $failed_tests
end

function run_functional_tests --description "Run all functional tests"
    set -l total_failed 0

    echo "🚀 Running functional tests for git.fish..."
    echo ""

    test_cwb_function
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_wrapper
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_wrm_validation
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_wrm_merge_check
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_wrm_pr_merged
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_wclean_dry_run
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_wclean_help
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_bare_container_helper
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_wclone_happy_path
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_wclone_no_checkout
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_wclone_refuses_collision
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_wadd_bare_layout_anchors
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_wadd_bare_layout_rejects_slash
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_wadd_bare_layout_rejects_invalid_names
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_wadd_checks_out_existing_branch
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_wadd_non_bare_preserves_path
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_wrm_bare_layout_anchors
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_wpr_bare_layout_anchors
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_wclean_bare_layout_default
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_wclean_path_validation
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_wclean_config_helper
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_wclean_check_flags
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_worktree_status_classifier
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_worktree_status_pr_closed
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_wlist
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_wclean_states
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_wclean_check
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_fetch_progress
    set total_failed (math $total_failed + $status)

    echo ""

    test_git_fetch_progress_callers
    set total_failed (math $total_failed + $status)

    echo ""

    test_all_commands_help_no_leaked_comments
    set total_failed (math $total_failed + $status)

    echo ""
    echo "🏁 Overall functional test results:"
    if test $total_failed -eq 0
        echo "🎉 All functional tests passed!"
        return 0
    else
        echo "💥 Some functional tests failed"
        return 1
    end
end

# Run tests if script is executed directly
if test (basename (status --current-filename)) = "functional-tests.fish"
    run_functional_tests
    exit $status
end
