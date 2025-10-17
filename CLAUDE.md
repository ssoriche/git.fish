# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

git.fish is a collection of fish shell functions that enhance git workflow, particularly for git worktree management. The project provides custom git subcommands through a wrapper function that seamlessly integrates with standard git commands.

## Development Commands

### Testing
```fish
# Run all tests (syntax + functional)
fish tests/run-tests.fish

# Run only syntax tests (fast)
fish tests/run-tests.fish syntax

# Run only functional tests
fish tests/run-tests.fish functional

# Quick tests (syntax compliance only)
fish tests/run-tests.fish quick
```

### Linting and Formatting
```fish
# Check syntax of all functions
fish --no-execute functions/*.fish

# Format a single function file
fish_indent < functions/git-wadd.fish > temp && mv temp functions/git-wadd.fish

# Check formatting without modifying
fish_indent < functions/git-wadd.fish | diff -u functions/git-wadd.fish -
```

### Local Development
```fish
# Load functions into current shell for testing
set -p fish_function_path $PWD/functions

# Test a specific function
git wadd --help

# Reload a modified function
source functions/git-wadd.fish
```

## Architecture

### Core Components

**git.fish wrapper** (`functions/git.fish`)
- Intercepts all `git` commands
- Checks if `git-<subcommand>` fish function exists
- Routes to custom function if found, otherwise falls back to standard git
- This enables seamless integration: `git wadd` → `git-wadd` function

**Worktree management functions**
- `git-wadd`: Create worktree with automatic upstream detection
- `git-wclean`: Bulk cleanup of merged worktrees in a directory
- `git-wjump`: Interactive worktree selector using fzf
- `git-wrm`: Remove single worktree after merge verification
- All functions detect upstream branch automatically, falling back to origin/main

**Branch management**
- `git-bclean`: Clean up merged local branches with pattern exclusion support

**Utility functions**
- `cwb`: Get current working branch name
- `git-diff-plain`: Git diff without pager
- `git-show-plain`: Git show without pager

### Key Patterns

**Upstream branch detection**
All worktree functions follow this pattern:
```fish
set -l upstream_branch (git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)
if test $status -ne 0
    set upstream_branch origin/main
end
```

**Help system**
Functions extract help from their own comments:
```fish
if set -q _flag_help
    printf '%s\n' (status function | head -n 1)
    printf '\n'
    functions git-wadd | string match -r '^\s*#\s.*' | string replace -r '^\s*#\s?' ''
    return 0
end
```

**Argument parsing**
All functions use argparse:
```fish
argparse --name=git-wadd h/help n/dry-run -- $argv
or return 1
```

**Security in git-wclean**
The git-wclean function includes comprehensive security validation:
- Path traversal prevention
- Command injection protection
- System directory protection
- Signal handling (INT, TERM) for cleanup - Note: Fish requires separate signal handlers, use `--on-signal INT` and `--on-signal TERM` on different functions
- Configuration file support (~/.config/git-wclean/config)

## Code Standards (from .fishcheck.yaml)

**Formatting**
- 4-space indentation
- 100-character line limit
- Use `fish_indent` for all formatting

**Naming conventions**
- Functions: kebab-case (git-wadd, git-wclean)
- Variables: snake_case (worktree_name, upstream_branch)

**Best practices**
- Use `argparse` for all argument handling
- Use `set -l` for local variables
- Use `printf` instead of `echo`
- Provide comprehensive help via --help flag
- Include exit codes in documentation
- Handle errors with proper exit codes (0=success, 1=invalid args, 2=git failure)

**Documentation requirements**
- Function description
- SYNOPSIS section
- DESCRIPTION section
- OPTIONS section
- EXAMPLES section
- EXIT STATUS section

**Git worktree compatibility**
- Use `test -e .git` not `test -d .git` (worktrees have .git as a file)
- Use `git -C <path>` to avoid directory changes when possible
- Always detect upstream branch, never hardcode

## Fish Shell Syntax (Critical)

**DO NOT use bash syntax:**
- ❌ `test ... -a ... -o ...` → ✅ `test ...; and test ...`
- ❌ `$(command)` → ✅ `(command)`
- ❌ `test ... ==` → ✅ `test ... =`
- ❌ `test ... and ...` → ✅ `test ...; and ...`

**Conditional patterns:**
```fish
# Correct
if test -d "$dir"; and test -r "$dir"
    # ...
end

# Correct with command
if git worktree add $name
    # Success path
else
    # Error path
end
```

## CI/CD

Tests run automatically on GitHub Actions and Forgejo for:
- All pushes to main/develop
- All pull requests to main

The CI validates:
1. Syntax compliance (fish --no-execute)
2. Formatting with fish_indent
3. Function loading
4. Help functionality
5. Git integration
6. Multi-version compatibility (Fish 3.3.1, 3.6.0, latest)

## Common Gotchas

1. **Worktrees have .git as a file, not directory** - Always use `test -e .git`
2. **Fish test operators** - Never use `-a` or `-o`, use `; and` and `; or`
3. **Command substitution** - Use `(command)` not `$(command)`
4. **String comparison** - Use single `=` not `==`
5. **Directory changes** - Prefer `git -C <path>` or `pushd/popd` over bare `cd`
6. **Global variables** - Functions like git-wclean use `set -g` for cross-function state; always clean up in cleanup functions
7. **Signal handlers** - Fish's `--on-signal` accepts only ONE signal per function. For multiple signals, create separate handler functions that call shared cleanup logic:
   ```fish
   function _cleanup_handler
       # shared cleanup logic
   end
   function _cleanup_int --on-signal INT
       _cleanup_handler
   end
   function _cleanup_term --on-signal TERM
       _cleanup_handler
   end
   ```
