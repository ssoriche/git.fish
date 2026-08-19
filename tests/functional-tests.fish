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
    echo "# Test" > "$main_dir/README.md"
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
    echo "feature work" > "$feature_wt/feature.txt"
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
    echo "# Test" > "$main_dir/README.md"
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
    set -l dry_output (git-wclean --dry-run "$wts_dir" 2>&1)
    if test -d "$wts_dir/merged"; and string match -q '*Would remove*' "$dry_output"
        echo "✅ git-wclean --dry-run left the worktree in place"
    else
        echo "❌ git-wclean --dry-run should not delete the worktree"
        set failed_tests (math $failed_tests + 1)
    end

    # Test 2: a real run removes the merged worktree
    echo "Test 2: git-wclean removes merged worktree..."
    set total_tests (math $total_tests + 1)
    git-wclean "$wts_dir" >/dev/null 2>&1
    if not test -d "$wts_dir/merged"
        echo "✅ git-wclean removed the merged worktree"
    else
        echo "❌ git-wclean should have removed the merged worktree"
        set failed_tests (math $failed_tests + 1)
    end

    # Cleanup
    cd "$orig_dir"
    git -C "$main_dir" worktree prune >/dev/null 2>&1
    rm -rf "$remote_dir" "$main_dir" "$wts_dir"

    echo "📊 git-wclean dry-run results: $failed_tests/$total_tests failed"
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

    test_git_wclean_dry_run
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
