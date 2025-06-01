function cwb --description "Get the current working branch name"
    # Current Working Branch - Display the current git branch name
    #
    # SYNOPSIS
    #   cwb [OPTIONS]
    #
    # DESCRIPTION
    #   This command displays the name of the current git branch. It's a simple
    #   wrapper around 'git rev-parse --abbrev-ref HEAD' that provides a shorter
    #   command for getting the current branch name.
    #
    #   This is useful for scripting or when you need to quickly check which
    #   branch you're currently on.
    #
    # OPTIONS
    #   -h, --help       Show this help message
    #
    # EXAMPLES
    #   # Get current branch name
    #   cwb
    #   # Output: main
    #
    #   # Use in variable assignment
    #   set current_branch (cwb)
    #
    #   # Use in command interpolation
    #   echo "Working on branch: (cwb)"
    #
    # EXIT STATUS
    #   0    Success - branch name displayed
    #   1    Invalid arguments
    #   2    Not in a git repository or git command failed

    # Parse command line arguments
    argparse --name=cwb h/help -- $argv
    or return 1

    # Show help if requested
    if set -q _flag_help
        printf '%s\n' (status function | head -n 1)
        printf '\n%s\n' (functions cwb | string match -r '#.*' | string trim -c '# ')
        return 0
    end

    # Check for unexpected arguments
    if test (count $argv) -gt 0
        printf "Error: Unexpected arguments. This command takes no arguments.\n" >&2
        printf "Usage: cwb [--help]\n" >&2
        printf "Try 'cwb --help' for more information.\n" >&2
        return 1
    end

    # Check if we're in a git repository and get branch name
    set -l branch_name (git rev-parse --abbrev-ref HEAD 2>/dev/null)

    if test $status -ne 0
        printf "Error: Not in a git repository or failed to get branch name.\n" >&2
        return 2
    end

    # Display the branch name
    printf '%s\n' $branch_name
    return 0
end
