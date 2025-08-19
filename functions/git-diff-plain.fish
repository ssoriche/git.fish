function git-diff-plain --description "Run git diff without a pager for plain text output"
    # Git Diff Plain - Git diff without pager output
    #
    # SYNOPSIS
    #   git-diff-plain [OPTIONS] [git-diff-options...]
    #   git diff-plain [OPTIONS] [git-diff-options...]
    #
    # DESCRIPTION
    #   This command runs 'git diff' with the pager disabled, providing plain text
    #   output that can be easily processed by other tools or scripts. This is
    #   particularly useful for scripting, piping output to other commands, or
    #   when you want to see the full diff without pagination.
    #
    # OPTIONS
    #   -h, --help       Show this help message
    #
    # ARGUMENTS
    #   git-diff-options  All standard git diff options and arguments
    #
    # EXAMPLES
    #   # Show diff without pager
    #   git-diff-plain
    #
    #   # Compare specific files
    #   git-diff-plain HEAD~1 file.txt
    #
    #   # Pipe to grep for specific changes
    #   git-diff-plain | grep "+function"
    #
    #   # Can also be called as git subcommand
    #   git diff-plain --stat
    #
    # EXIT STATUS
    #   Returns the exit status of the git diff command

    # Parse command line arguments
    argparse --name=git-diff-plain h/help -- $argv
    or return 1

    # Show help if requested
    if set -q _flag_help
        printf '%s\n' (status function | head -n 1)
        printf '\n'
        functions git-diff-plain | string match -r '^\s*#\s.*' | string replace -r '^\s*#\s?' '' | string replace -r '^\s*#\s*$' ''
        return 0
    end

    # Run git diff with pager disabled
    git -c core.pager=cat diff $argv
    return $status
end
