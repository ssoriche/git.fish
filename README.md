# git.fish

A collection of fish shell functions to enhance your git workflow and make git worktrees more manageable.

## Features

This package provides several enhanced git commands that integrate seamlessly with your existing git workflow:

- **Smart git worktree management** with automatic upstream branch detection
- **Interactive worktree navigation** using fzf
- **Safe worktree cleanup** with merge verification
- **Plain text git output** for scripting and automation
- **Seamless integration** through git subcommand wrapper

## Installation

### Option 1: Using Fisher Plugin Manager (Recommended)

If you're using [Fisher](https://github.com/jorgebucaran/fisher), you can install directly from the GitHub repository:

```fish
fisher install ssoriche/git.fish
```

### Option 2: Manual Installation

1. Clone this repository: `git clone https://github.com/ssoriche/git.fish.git`
2. Copy the `functions` directory to your fish configuration directory (`~/.config/fish/`)
3. Restart your fish shell or run `source ~/.config/fish/config.fish`

### Option 3: Direct Function Installation

You can also copy individual function files to `~/.config/fish/functions/` if you only want specific commands.

## Quick Setup

After installation, you may want to set up the standard git abbreviation:

```fish
# Add to your ~/.config/fish/config.fish
abbr g git
```

This allows you to use the short `g` command for all git operations:

```fish
g wadd feature-123    # Same as: git wadd feature-123
g wjump               # Same as: git wjump
g wclean ~/worktrees  # Same as: git wclean ~/worktrees
```

## Commands

### Worktree Management

#### `git wadd` / `git-wadd`

Create a new git worktree and automatically switch to it.

```fish
# Create worktree with new branch from upstream
git wadd feature-123
# Or with abbreviation: g wadd feature-123

# Create worktree from specific branch
git wadd hotfix develop
# Or: g wadd hotfix develop

# With additional git worktree options
git wadd feature-456 origin/main --force
```

**Features:**

- Automatically detects upstream branch if none specified
- Creates new branch and worktree in one command
- Switches to the new worktree directory after creation

#### `git wclean` / `git-wclean`

Clean up worktrees whose commits have been merged to upstream.

```fish
# Clean up merged worktrees
git wclean ~/git/myproject-worktrees

# Preview what would be removed
git wclean --dry-run ~/worktrees

# Clean worktrees but keep local branches
git wclean --no-delete-branch ~/worktrees

# Get help
git wclean --help
```

**Features:**

- Scans directory for git worktrees
- Checks if commits are merged to upstream branch
- Removes only safely merged worktrees
- **Automatically deletes associated local branches** (unless `--no-delete-branch` is used)
- Provides detailed summary of actions taken

#### `git wjump` / `git-wjump`

Interactive worktree selector using fzf (fuzzy finder).

```fish
# Open interactive worktree selector
git wjump
# Or with abbreviation: g wjump

# Start with search query
git wjump feature
# Or: g wjump feature
```

**Features:**

- Fuzzy search through available worktrees
- Preview pane showing recent commit history
- Automatic directory switching
- Requires: [fzf](https://github.com/junegunn/fzf)

#### `git wrm` / `git-wrm`

Safely remove a single worktree after verifying commits are merged.

```fish
# Remove worktree after verification
git wrm ~/worktrees/feature-branch

# Preview what would happen
git wrm --dry-run ~/worktrees/old-feature

# Force removal (use with caution!)
git wrm --force ~/worktrees/experimental

# Remove worktree but keep the local branch
git wrm --no-delete-branch ~/worktrees/feature-branch
```

**Features:**

- Verifies commits are merged to upstream before removal
- Smart upstream branch detection
- Force option for override (with warnings)
- **Automatically deletes associated local branch** (unless `--no-delete-branch` is used)
- Clear feedback and guidance when commits aren't merged

### Utility Commands

#### `cwb`

Get the current working branch name.

```fish
# Display current branch
cwb
# Output: main

# Use in scripts
set current_branch (cwb)
echo "Working on: $current_branch"
```

#### `git diff-plain` / `git-diff-plain`

Run git diff without pager for plain text output.

```fish
# Show diff without pager
git diff-plain

# Pipe to other tools
git diff-plain | grep "+function"

# With git diff options
git diff-plain --stat HEAD~1
```

#### `git show-plain` / `git-show-plain`

Run git show without pager for plain text output.

```fish
# Show commit without pager
git show-plain

# Show specific commit
git show-plain abc123

# Pipe to processing tools
git show-plain HEAD | grep "Author"
```

### Git Wrapper

The `git` function enhances the standard git command by:

- Automatically detecting and using custom fish functions
- Falling back to standard git for unrecognized commands
- Maintaining full compatibility with existing git usage

## Common Workflows

### Creating and Managing Feature Branches

```fish
# Create a new feature worktree
git wadd feature-user-auth
# Or: g wadd feature-user-auth

# Work on your feature...
# (commits, pushes, etc.)

# When done, jump back to main worktree
git wjump main
# Or: g wjump main

# Clean up merged worktrees
git wclean ~/git/myproject-worktrees
# Or: g wclean ~/git/myproject-worktrees
```

### Interactive Worktree Navigation

```fish
# Quickly switch between worktrees
git wjump
# Or: g wjump

# Search for specific worktrees
git wjump hotfix
# Or: g wjump hotfix
```

### Safe Worktree Cleanup

```fish
# Remove a specific worktree safely
git wrm ~/worktrees/completed-feature
# Or: g wrm ~/worktrees/completed-feature

# Bulk cleanup of merged worktrees
git wclean --dry-run ~/worktrees  # Preview first
git wclean ~/worktrees            # Actually clean up
# Or with abbreviation:
# g wclean --dry-run ~/worktrees
# g wclean ~/worktrees
```

## Configuration

All functions automatically detect your git configuration including:

- Upstream branches (with fallback to `origin/main`)
- Remote names and branch names
- Git repository structure

No additional configuration is required.

## Dependencies

- **fish shell** (obviously!)
- **git** (version 2.5+ recommended for full worktree support)
- **fzf** (for `git-wjump` only) - [Installation guide](https://github.com/junegunn/fzf#installation)

Optional tools that enhance the experience:

- **awk** (usually pre-installed)
- **realpath** (for path resolution)

## Best Practices

1. **Use upstream tracking**: Set up upstream branches for automatic branch detection

   ```fish
   git branch --set-upstream-to=origin/main
   ```

2. **Organize worktrees**: Keep worktrees in a dedicated directory

   ```fish
   mkdir ~/git/myproject-worktrees
   cd ~/git/myproject
   git wadd ~/git/myproject-worktrees/feature-123
   ```

3. **Regular cleanup**: Periodically clean up merged worktrees

   ```fish
   git wclean --dry-run ~/git/myproject-worktrees
   ```

4. **Use help**: All functions have comprehensive help
   ```fish
   git wadd --help
   git wclean --help
   # etc.
   ```

## License

This project is released under the same license as specified in the LICENSE file.

## Development

### Code Quality & Testing

This repository includes comprehensive CI/CD workflows to ensure code quality and functionality:

#### GitHub Actions & Forgejo Workflows

The project includes automated testing workflows for both GitHub Actions (`.github/workflows/test.yaml`) and Forgejo (`.forgejo/workflows/test.yaml`) that:

**Linting & Formatting:**

- ✅ **Syntax checking** using `fish --no-execute`
- ✅ **Code formatting** validation with `fish_indent`
- ✅ **Style consistency** enforcement

**Function Testing:**

- ✅ **Multi-version testing** (Fish 3.3.1, 3.6.0, latest)
- ✅ **Function loading** verification
- ✅ **Help system** testing
- ✅ **Cross-platform** compatibility

**Git Integration Testing:**

- ✅ **Git wrapper** functionality
- ✅ **Repository context** testing
- ✅ **Branch detection** validation

**Dependency Testing:**

- ✅ **Optional dependencies** (fzf) graceful handling
- ✅ **Missing dependencies** error handling

**Integration Testing:**

- ✅ **End-to-end** workflow testing
- ✅ **Real git repository** scenarios

#### Running Tests Locally

To run the same tests locally:

```fish
# Check syntax
fish --no-execute functions/*.fish

# Check formatting
for file in functions/*.fish
    fish_indent < $file > /tmp/(basename $file)
    diff -u $file /tmp/(basename $file)
end

# Test function loading
fish -c "
    set -p fish_function_path $PWD/functions
    for func_file in functions/*.fish
        source \$func_file
        echo 'Loaded: '(basename \$func_file .fish)
    end
"
```

#### Code Standards

All functions follow the standards defined in `.fishcheck.yaml`:

- **Formatting**: 4-space indentation, 100-character line limit
- **Naming**: kebab-case for functions, snake_case for variables
- **Documentation**: Required description, help option, examples, exit codes
- **Best Practices**: argparse usage, local variables, error handling
- **Git Integration**: Upstream detection, helpful error messages

### Contributing

1. **Fork the repository**
2. **Create a feature branch**: `git checkout -b feature/new-command`
3. **Follow code standards** (see `.fishcheck.yaml`)
4. **Add comprehensive documentation** and examples
5. **Test your changes** locally
6. **Submit a pull request**

All pull requests automatically run the full test suite to ensure quality and compatibility.
