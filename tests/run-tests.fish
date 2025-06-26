#!/usr/bin/env fish

# Test Runner for git.fish
# Run all tests: syntax, functional, and integration tests

function print_header --description "Print a formatted header"
    set -l text $argv[1]
    set -l length (string length "$text")
    set -l border (string repeat -n (math $length + 4) "=")

    echo ""
    echo $border
    echo "  $text"
    echo $border
    echo ""
end

function run_all_tests --description "Run all test suites"
    set -l total_exit_code 0
    set -l test_dir (dirname (status --current-filename))

    print_header "🚀 Running git.fish Test Suite"

    # Run syntax tests
    print_header "📝 Fish Shell Syntax Tests"
    fish "$test_dir/syntax-tests.fish"
    set -l syntax_result $status
    if test $syntax_result -ne 0
        set total_exit_code 1
        echo "❌ Syntax tests failed"
    else
        echo "✅ Syntax tests passed"
    end

    # Run functional tests
    print_header "⚙️  Functional Tests"
    fish "$test_dir/functional-tests.fish"
    set -l functional_result $status
    if test $functional_result -ne 0
        set total_exit_code 1
        echo "❌ Functional tests failed"
    else
        echo "✅ Functional tests passed"
    end

    # Summary
    print_header "📊 Test Summary"
    echo "Syntax Tests:     " (test $syntax_result -eq 0; and echo "✅ PASSED" || echo "❌ FAILED")
    echo "Functional Tests: " (test $functional_result -eq 0; and echo "✅ PASSED" || echo "❌ FAILED")
    echo ""

    if test $total_exit_code -eq 0
        echo "🎉 All tests passed!"
    else
        echo "💥 Some tests failed. Check the output above for details."
    end

    return $total_exit_code
end

function run_quick_tests --description "Run quick syntax and validation tests only"
    set -l test_dir (dirname (status --current-filename))

    print_header "⚡ Running Quick Tests"

    echo "Running syntax compliance tests..."
    fish "$test_dir/syntax-tests.fish"
    set -l result $status

    if test $result -eq 0
        echo "🎉 Quick tests passed!"
    else
        echo "💥 Quick tests failed!"
    end

    return $result
end

function show_help --description "Show help for the test runner"
    echo "git.fish Test Runner"
    echo ""
    echo "Usage:"
    echo "  fish tests/run-tests.fish [command]"
    echo ""
    echo "Commands:"
    echo "  all      Run all tests (default)"
    echo "  quick    Run quick syntax tests only"
    echo "  syntax   Run syntax compliance tests"
    echo "  func     Run functional tests"
    echo "  help     Show this help message"
    echo ""
    echo "Examples:"
    echo "  fish tests/run-tests.fish"
    echo "  fish tests/run-tests.fish quick"
    echo "  fish tests/run-tests.fish syntax"
end

# Main command dispatcher
function main
    set -l command $argv[1]
    set -l test_dir (dirname (status --current-filename))

    switch "$command"
        case "" "all"
            run_all_tests
        case "quick"
            run_quick_tests
        case "syntax"
            print_header "📝 Syntax Tests"
            fish "$test_dir/syntax-tests.fish"
        case "func" "functional"
            print_header "⚙️  Functional Tests"
            fish "$test_dir/functional-tests.fish"
        case "help" "-h" "--help"
            show_help
        case "*"
            echo "Unknown command: $command"
            echo "Run 'fish tests/run-tests.fish help' for usage information."
            return 1
    end
end

# Run main function if script is executed directly
if test (basename (status --current-filename)) = "run-tests.fish"
    main $argv
    exit $status
end
