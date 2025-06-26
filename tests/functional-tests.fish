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

    echo "# Test Repository" > README.md
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

function test_cwb_function --description "Test the cwb (current working branch) function"
    # More robust path resolution for CI environments
    set -l test_file_dir (dirname (status --current-filename))
    set -l test_functions_dir "$test_file_dir/../functions"
    if test -d "$test_functions_dir"
        set test_functions_dir (realpath "$test_functions_dir")
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
    if test "$current_branch" = "main"
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
    if test "$current_branch" = "feature-test"
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
    # More robust path resolution for CI environments
    set -l test_file_dir (dirname (status --current-filename))
    set -l test_functions_dir "$test_file_dir/../functions"
    if test -d "$test_functions_dir"
        set test_functions_dir (realpath "$test_functions_dir")
    end
    set -l test_repo (setup_test_repo)
    set -l failed_tests 0
    set -l total_tests 0

    echo "🔍 Testing git wrapper function..."

    # Source the git wrapper and cwb
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
    # More robust path resolution for CI environments
    set -l test_file_dir (dirname (status --current-filename))
    set -l test_functions_dir "$test_file_dir/../functions"
    if test -d "$test_functions_dir"
        set test_functions_dir (realpath "$test_functions_dir")
    end
    set -l failed_tests 0
    set -l total_tests 0

    echo "🔍 Testing git-wrm validation..."

    # Source the function
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
