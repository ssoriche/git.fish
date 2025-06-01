function git-wjump --description "Interactively select and jump to a git worktree using fzf"
    # Git Worktree Jump - Fuzzy find and switch to worktrees
    #
    # SYNOPSIS
    #   git-wjump [OPTIONS] [search-query]
    #   git wjump [OPTIONS] [search-query]
    #
    # DESCRIPTION
    #   This command provides an interactive way to select and jump to git worktrees
    #   using fzf (fuzzy finder). It displays a list of available worktrees with a
    #   preview showing recent commit history, allowing you to quickly navigate
    #   between different worktrees.
    #
    #   Features:
    #   - Interactive fuzzy search through worktree names
    #   - Preview pane showing recent commit history
    #   - Filters out the main repository (bare repo entries)
    #   - Automatically changes to selected worktree directory
    #
    # OPTIONS
    #   -h, --help       Show this help message
    #
    # ARGUMENTS
    #   search-query     Optional initial search query for fzf
    #
    # EXAMPLES
    #   # Open interactive worktree selector
    #   git-wjump
    #
    #   # Start with search query 'feature'
    #   git-wjump feature
    #
    #   # Can also be called as git subcommand
    #   git wjump hotfix
    #
    # DEPENDENCIES
    #   - fzf: Command-line fuzzy finder
    #   - awk: Text processing (usually available by default)
    #
    # EXIT STATUS
    #   0    Success - changed to selected worktree
    #   1    Invalid arguments or fzf not available
    #   2    No worktree selected or command failed

    # Parse command line arguments
    argparse --name=git-wjump h/help -- $argv
    or return 1

    # Show help if requested
    if set -q _flag_help
        printf '%s\n' (status function | head -n 1)
        printf '\n%s\n' (functions git-wjump | string match -r '#.*' | string trim -c '# ')
        return 0
    end

    # Check if fzf is available
    if not command -v fzf >/dev/null 2>&1
        printf "Error: fzf is required but not found in PATH.\n" >&2
        printf "Please install fzf: https://github.com/junegunn/fzf\n" >&2
        return 1
    end

    # Check if we're in a git repository
    if not git rev-parse --git-dir >/dev/null 2>&1
        printf "Error: Not in a git repository.\n" >&2
        return 1
    end

    printf "Loading worktrees...\n"

    # Get worktree list and filter, then use fzf for selection
    set -l selected_worktree (
        git worktree list 2>/dev/null | \
        string match -v -r '/\.\s' | \
        fzf --prompt="Select worktree: " \
            --preview='git log --oneline -n10 {2} 2>/dev/null || echo "No commits found"' \
            --preview-window='right:50%' \
            --query="$argv" \
            --select-1 \
            --exit-0 \
            --height=70% | \
        awk '{print $1}'
    )

    # Check if a worktree was selected
    if test -z "$selected_worktree"
        printf "No worktree selected.\n" >&2
        return 2
    end

    # Validate the selected path exists
    if not test -d "$selected_worktree"
        printf "Error: Selected worktree directory '%s' does not exist.\n" $selected_worktree >&2
        return 2
    end

    printf "Jumping to worktree: %s\n" (basename $selected_worktree)

    # Change to the selected worktree
    cd $selected_worktree
    or begin
        printf "Error: Failed to change to worktree directory '%s'.\n" $selected_worktree >&2
        return 2
    end

    printf "✓ Now in worktree: %s\n" (basename $PWD)
    return 0
end
