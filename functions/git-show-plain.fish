function git-show-plain --description "Run git show without a pager for plain text output"
    # Git Show Plain - Git show without pager output
    #
    # SYNOPSIS
    #   git-show-plain [OPTIONS] [git-show-options...]
    #   git show-plain [OPTIONS] [git-show-options...]
    #
    # DESCRIPTION
    #   This command runs 'git show' with the pager disabled, providing plain text
    #   output that can be easily processed by other tools or scripts. This is
    #   particularly useful for scripting, piping output to other commands, or
    #   when you want to see the full commit information without pagination.
    #
    # OPTIONS
    #   -h, --help       Show this help message
    #
    # ARGUMENTS
    #   git-show-options  All standard git show options and arguments
    #
    # EXAMPLES
    #   # Show latest commit without pager
    #   git-show-plain
    #
    #   # Show specific commit
    #   git-show-plain abc123
    #
    #   # Show only commit message
    #   git-show-plain --format="%s" HEAD
    #
    #   # Pipe to other tools
    #   git-show-plain HEAD | grep "function"
    #
    #   # Can also be called as git subcommand
    #   git show-plain --stat HEAD~1
    #
    # EXIT STATUS
    #   Returns the exit status of the git show command

    # Parse command line arguments
    argparse --name=git-show-plain h/help -- $argv
    or return 1

    # Show help if requested
    if set -q _flag_help
        printf '%s\n' (status function | head -n 1)
        printf '\n'
        functions git-show-plain | string match -r '^\s*#\s.*' | string replace -r '^\s*#\s?' '' | string replace -r '^\s*#\s*$' ''
        return 0
    end

    # Run git show with pager disabled
    git -c core.pager=cat show $argv
    return $status
end
