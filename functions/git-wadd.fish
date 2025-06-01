function git-wadd --description "Create a new git worktree and branch"
    # Git Worktree Add - Creates a new worktree with an optional branch
    #
    # SYNOPSIS
    #   git-wadd [OPTIONS] <worktree-name> [branch-name] [git-worktree-options...]
    #   git wadd [OPTIONS] <worktree-name> [branch-name] [git-worktree-options...]
    #
    # DESCRIPTION
    #   This command creates a new git worktree and optionally creates a new branch for it.
    #   If no branch name is provided, it will create a new branch based on the current
    #   upstream branch (typically origin/main). After creating the worktree, it will
    #   automatically change to the new worktree directory.
    #
    # OPTIONS
    #   -h, --help       Show this help message
    #
    # ARGUMENTS
    #   worktree-name    Name/path of the new worktree directory
    #   branch-name      Name of the branch to create or check out (optional)
    #                   If not provided, creates a branch from upstream
    #   git-worktree-options  Additional options to pass to git worktree add
    #
    # EXAMPLES
    #   # Create worktree 'feature-123' with new branch from upstream
    #   git-wadd feature-123
    #
    #   # Create worktree 'hotfix' based on existing branch 'develop'
    #   git-wadd hotfix develop
    #
    #   # Create worktree with additional git worktree options
    #   git-wadd feature-456 origin/main --force
    #
    #   # Can also be called as git subcommand
    #   git wadd my-feature
    #
    # EXIT STATUS
    #   0    Success
    #   1    Invalid arguments
    #   2    Git command failed

    # Parse command line arguments
    argparse --name=git-wadd h/help -- $argv
    or return 1

    # Show help if requested
    if set -q _flag_help
        printf '%s\n' (status function | head -n 1)
        printf '\n%s\n' (functions git-wadd | string match -r '#.*' | string trim -c '# ')
        return 0
    end

    # Check if worktree name is provided
    if test (count $argv) -eq 0
        printf "Error: Missing required argument <worktree-name>\n" >&2
        printf "Usage: git-wadd [OPTIONS] <worktree-name> [branch-name] [git-worktree-options...]\n" >&2
        printf "Try 'git-wadd --help' for more information.\n" >&2
        return 1
    end

    set -l worktree_name $argv[1]
    set -l branch_name $argv[2]
    set -l extra_args $argv[3..-1]

    # If no branch name provided, determine upstream branch
    if test -z "$branch_name"
        set -l upstream_branch (git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)
        if test $status -eq 0
            set branch_name $upstream_branch
            printf "No branch specified, using upstream branch: %s\n" $branch_name
        else
            set branch_name origin/main
            printf "No branch specified and no upstream configured, using: %s\n" $branch_name
        end
    end

    printf "Creating worktree '%s' from branch '%s'...\n" $worktree_name $branch_name

    # Create the worktree with new branch
    if git worktree add -b $worktree_name $worktree_name $branch_name $extra_args
        printf "✓ Successfully created worktree: %s\n" $worktree_name

        # Change to the new worktree directory
        if test -d "$worktree_name"
            printf "Changing to worktree directory...\n"
            cd $worktree_name
            or begin
                printf "Warning: Failed to change to worktree directory.\n" >&2
            end
        else
            printf "Warning: Worktree directory not found at expected location.\n" >&2
        end

        return 0
    else
        printf "Error: Failed to create worktree '%s'.\n" $worktree_name >&2
        return 2
    end
end
