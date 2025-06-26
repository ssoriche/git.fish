#!/usr/bin/env fish

# Fish Shell Syntax Tests
# This file contains tests to catch common fish shell syntax errors
# and ensure all functions use proper fish shell syntax

function test_fish_syntax_compliance --description "Test all functions for proper fish shell syntax"
    set -l test_functions_dir (dirname (status --current-filename))/../functions
    set -l failed_tests 0
    set -l total_tests 0

    echo "🔍 Testing fish shell syntax compliance..."

    # Test 1: Check for bash-style test operators
    echo "Test 1: Checking for bash-style test operators (-a, -o)..."
    set total_tests (math $total_tests + 1)

    set -l bash_operators_found (grep -r 'test.*-a\|test.*-o' $test_functions_dir 2>/dev/null | grep -v '#' | wc -l)
    if test $bash_operators_found -gt 0
        echo "❌ Found bash-style test operators (-a, -o) in functions:"
        grep -r 'test.*-a\|test.*-o' $test_functions_dir | grep -v '#'
        echo "   Use 'and' and 'or' instead of '-a' and '-o'"
        set failed_tests (math $failed_tests + 1)
    else
        echo "✅ No bash-style test operators found"
    end

    # Test 2: Check for proper semicolon usage with 'and'/'or'
    echo "Test 2: Checking for proper semicolon usage with 'and'/'or'..."
    set total_tests (math $total_tests + 1)

    # Look for patterns like 'test ... and' without semicolon
    set -l missing_semicolons (grep -rn 'test.*[^;] and\|test.*[^;] or' $test_functions_dir 2>/dev/null | grep -v '#' | wc -l)
    if test $missing_semicolons -gt 0
        echo "❌ Found 'and'/'or' without proper semicolon separation:"
        grep -rn 'test.*[^;] and\|test.*[^;] or' $test_functions_dir | grep -v '#'
        echo "   Use '; and' or '; or' for proper fish syntax"
        set failed_tests (math $failed_tests + 1)
    else
        echo "✅ Proper semicolon usage with 'and'/'or'"
    end

            # Test 3: Check for proper variable scoping (advisory only)
    echo "Test 3: Checking for proper variable scoping (advisory)..."
    set total_tests (math $total_tests + 1)

    # Look for 'set' without '-l' (local) or '-g' (global) inside functions
    # This is advisory only - many reassignments are acceptable patterns
    set -l unscoped_count 0
    for func_file in $test_functions_dir/*.fish
        set -l unscoped_in_file (grep -n '^[[:space:]]*set [^-]' $func_file | grep -v '#' | wc -l)
        set unscoped_count (math $unscoped_count + $unscoped_in_file)
    end

    if test $unscoped_count -gt 0
        echo "ℹ️  Found $unscoped_count unscoped variables (this is advisory only)"
        echo "   Many patterns like reassignments and counters are acceptable"
        echo "   Consider using 'set -l' for truly local variables"
    else
        echo "✅ All variables are explicitly scoped"
    end

    # This test is advisory only - don't fail CI for it

    # Test 4: Check for proper string comparison
    echo "Test 4: Checking for proper string comparison..."
    set total_tests (math $total_tests + 1)

    # Look for == instead of = in test conditions
    set -l double_equals (grep -rn 'test.*==' $test_functions_dir 2>/dev/null | grep -v '#' | wc -l)
    if test $double_equals -gt 0
        echo "❌ Found double equals (==) in test conditions:"
        grep -rn 'test.*==' $test_functions_dir | grep -v '#'
        echo "   Use single equals (=) for string comparison in fish"
        set failed_tests (math $failed_tests + 1)
    else
        echo "✅ Proper string comparison syntax"
    end

    # Test 5: Check for proper command substitution
    echo "Test 5: Checking for proper command substitution..."
    set total_tests (math $total_tests + 1)

    # Look for $(...) instead of (...)
    set -l dollar_parens (grep -rn '\$(' $test_functions_dir 2>/dev/null | grep -v '#' | wc -l)
    if test $dollar_parens -gt 0
        echo "❌ Found bash-style command substitution \$(...):"
        grep -rn '\$(' $test_functions_dir | grep -v '#'
        echo "   Use (...) instead of \$(...) in fish"
        set failed_tests (math $failed_tests + 1)
    else
        echo "✅ Proper command substitution syntax"
    end

    # Test 6: Validate all functions can be loaded without syntax errors
    echo "Test 6: Validating function loading..."
    set total_tests (math $total_tests + 1)

    set -l syntax_errors 0
    for func_file in $test_functions_dir/*.fish
        if not fish --no-execute $func_file 2>/dev/null
            if test $syntax_errors -eq 0
                echo "❌ Syntax errors found in functions:"
            end
            echo "   File: $func_file"
            fish --no-execute $func_file
            set syntax_errors (math $syntax_errors + 1)
        end
    end
    if test $syntax_errors -eq 0
        echo "✅ All functions load without syntax errors"
    else
        set failed_tests (math $failed_tests + 1)
    end

    echo ""
    echo "📊 Test Results:"
    echo "   Total tests: $total_tests"
    echo "   Failed tests: $failed_tests"
    echo "   Passed tests: "(math $total_tests - $failed_tests)

    if test $failed_tests -eq 0
        echo "🎉 All syntax tests passed!"
        return 0
    else
        echo "💥 $failed_tests test(s) failed"
        return 1
    end
end

# Test 7: Function-specific tests for common issues
function test_function_specific_issues --description "Test for specific issues in individual functions"
    set -l test_functions_dir (dirname (status --current-filename))/../functions
    set -l failed_tests 0
    set -l total_tests 0

    echo "🔍 Testing function-specific issues..."

    # Test git-wrm for the specific issue we just fixed
    echo "Test: git-wrm syntax compliance..."
    set total_tests (math $total_tests + 1)

    if test -f $test_functions_dir/git-wrm.fish
        # Check for the specific patterns we fixed
        set -l old_syntax (grep -n 'test.*-a.*_flag_no_delete_branch' $test_functions_dir/git-wrm.fish | wc -l)
        if test $old_syntax -gt 0
            echo "❌ git-wrm still contains old -a syntax"
            grep -n 'test.*-a.*_flag_no_delete_branch' $test_functions_dir/git-wrm.fish
            set failed_tests (math $failed_tests + 1)
        else
            echo "✅ git-wrm uses proper fish syntax"
        end
    else
        echo "⚠️  git-wrm.fish not found"
    end

    # Test that all git-* functions use proper .git detection
    echo "Test: git worktree detection..."
    set total_tests (math $total_tests + 1)

    # Look for old pattern: test -d .git (should be test -e .git for worktrees)
    set -l wrong_git_check (grep -rn 'test -d.*\.git' $test_functions_dir | grep -v '#' | wc -l)
    if test $wrong_git_check -gt 0
        echo "❌ Found incorrect .git directory checks (should use -e for worktrees):"
        grep -rn 'test -d.*\.git' $test_functions_dir | grep -v '#'
        set failed_tests (math $failed_tests + 1)
    else
        echo "✅ Proper .git detection for worktrees"
    end

    echo ""
    echo "📊 Function-specific test results:"
    echo "   Total tests: $total_tests"
    echo "   Failed tests: $failed_tests"
    echo "   Passed tests: "(math $total_tests - $failed_tests)

    if test $failed_tests -eq 0
        echo "🎉 All function-specific tests passed!"
        return 0
    else
        echo "💥 $failed_tests test(s) failed"
        return 1
    end
end

# Main test runner
function run_syntax_tests --description "Run all syntax tests"
    set -l exit_code 0

    test_fish_syntax_compliance
    if test $status -ne 0
        set exit_code 1
    end

    echo ""

    test_function_specific_issues
    if test $status -ne 0
        set exit_code 1
    end

    return $exit_code
end

# Run tests if script is executed directly
if test (basename (status --current-filename)) = "syntax-tests.fish"
    run_syntax_tests
    exit $status
end
