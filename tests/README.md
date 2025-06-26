# git.fish Test Suite

This directory contains comprehensive tests for the git.fish project to ensure code quality, syntax compliance, and functional correctness.

## Test Files

### `syntax-tests.fish`

Tests for fish shell syntax compliance and common coding errors:

- **Bash-style test operators**: Detects usage of `-a` and `-o` instead of proper fish `and`/`or`
- **Semicolon usage**: Ensures proper `;` usage with `and`/`or` operators
- **Variable scoping**: Checks that all variables use proper `-l` or `-g` flags
- **String comparison**: Validates use of `=` instead of `==`
- **Command substitution**: Ensures `(...)` instead of `$(...)`
- **Function loading**: Validates all functions can be loaded without syntax errors
- **Git worktree detection**: Checks for proper `.git` file vs directory detection

### `functional-tests.fish`

Tests for actual functionality and behavior:

- **cwb function**: Tests current working branch detection
- **git wrapper**: Tests integration and command passthrough
- **git-wrm validation**: Tests input validation and error handling
- **Repository setup/teardown**: Automated test environment management

### `run-tests.fish`

Main test runner with multiple modes:

- `all`: Run all tests (default)
- `quick`: Run syntax tests only
- `syntax`: Run syntax compliance tests
- `func`: Run functional tests
- `help`: Show usage information

## Running Tests

### Local Testing

```fish
# Run all tests
fish tests/run-tests.fish

# Run quick syntax tests only
fish tests/run-tests.fish quick

# Run specific test suites
fish tests/run-tests.fish syntax
fish tests/run-tests.fish func
```

### Individual Test Files

```fish
# Run syntax tests directly
fish tests/syntax-tests.fish

# Run functional tests directly
fish tests/functional-tests.fish
```

## CI/CD Integration

The tests are integrated into GitHub Actions workflows:

- **Syntax compliance tests** run on every push/PR
- **Functional tests** run on every push/PR
- **Lint checks** ensure code formatting
- **Function loading tests** validate all functions can be loaded

## Preventing Common Issues

The test suite specifically prevents these issues:

### 1. Fish Syntax Errors

**Issue**: Using bash-style `-a` and `-o` in test conditions

```fish
# ❌ Wrong (bash-style)
if test -n "$var" -a (not set -q _flag_option)

# ✅ Correct (fish-style)
if test -n "$var"; and not set -q _flag_option
```

### 2. Git Worktree Detection

**Issue**: Using `test -d .git` which fails for worktrees

```fish
# ❌ Wrong (fails for worktrees)
if not test -d "$path/.git"

# ✅ Correct (works for worktrees)
if not test -e "$path/.git"
```

### 3. Variable Scoping

**Issue**: Using unscoped variables in functions

```fish
# ❌ Wrong (global by default)
set my_var "value"

# ✅ Correct (properly scoped)
set -l my_var "value"
```

## Adding New Tests

When adding new functions or fixing bugs:

1. **Add syntax tests** in `syntax-tests.fish` for new patterns to avoid
2. **Add functional tests** in `functional-tests.fish` for new behaviors
3. **Update CI workflow** if new test dependencies are needed
4. **Run full test suite** before committing changes

## Test Philosophy

- **Prevent regressions**: Catch issues that have been fixed before
- **Syntax compliance**: Ensure proper fish shell syntax usage
- **Error handling**: Validate proper error messages and exit codes
- **Cross-platform**: Tests should work on different operating systems
- **Fast feedback**: Quick tests for common issues, comprehensive tests for full validation
