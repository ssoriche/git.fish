function git --description "Enhanced git wrapper with custom fish function integration"
    # Git Wrapper - Extends git with custom fish functions
    #
    # SYNOPSIS
    #   git <subcommand> [args...]
    #
    # DESCRIPTION
    #   This function wraps the standard git command and extends it with custom
    #   fish functions. When you call 'git <subcommand>', it first checks if
    #   there's a corresponding 'git-<subcommand>' fish function available.
    #   If found, it uses the fish function; otherwise, it falls back to the
    #   standard git command.
    #
    #   This allows seamless integration of custom git workflows while maintaining
    #   full compatibility with standard git commands.
    #
    # CUSTOM SUBCOMMANDS
    #   wadd      Create and switch to new worktree (git-wadd)
    #   wclean    Clean up merged worktrees (git-wclean)
    #   wjump     Interactive worktree selector (git-wjump)
    #   wrm       Safely remove a worktree (git-wrm)
    #   diff-plain    Git diff without pager (git-diff-plain)
    #   show-plain    Git show without pager (git-show-plain)
    #
    # EXAMPLES
    #   # Standard git commands work as usual
    #   git status
    #   git commit -m "message"
    #
    #   # Custom functions are automatically available
    #   git wadd feature-123
    #   git wjump
    #   git wclean ~/worktrees
    #
    #   # Get help for custom functions
    #   git wadd --help
    #
    # EXIT STATUS
    #   Returns the exit status of the executed command

    # If no arguments provided, show git help
    if test (count $argv) -eq 0
        command git
        return $status
    end

    # Get the subcommand and remaining arguments
    set -l subcommand $argv[1]
    set -l remaining_args $argv[2..-1]

    # Construct the potential fish function name
    set -l git_func "git-$subcommand"

    # Check if the custom fish function exists
    if functions --query $git_func
        # Call the custom fish function
        $git_func $remaining_args
        return $status
    else
        # Fall back to standard git command
        command git $argv
        return $status
    end
end
