function git-wpr --description "Create a git worktree from a GitHub pull request"
    # Git Worktree Pull Request - Creates a worktree from a GitHub PR
    #
    # SYNOPSIS
    #   git-wpr [OPTIONS] <pr-number> [worktree-name]
    #   git wpr [OPTIONS] <pr-number> [worktree-name]
    #
    # DESCRIPTION
    #   This command creates a new git worktree from a GitHub pull request. It fetches
    #   the PR's head branch from the origin remote and creates a worktree for it.
    #
    #   After creating the worktree, it will automatically change to the new worktree
    #   directory.
    #
    # OPTIONS
    #   -h, --help       Show this help message
    #   -n, --dry-run    Show what would be done without executing
    #   -r, --remote     Remote name (default: origin)
    #
    # ARGUMENTS
    #   pr-number        GitHub PR number (e.g., 123)
    #   worktree-name    Optional name for the worktree directory
    #                    (default: pr-NUMBER)
    #
    # EXAMPLES
    #   # Create worktree from PR number
    #   git wpr 123
    #
    #   # Create worktree with custom name
    #   git wpr 789 my-feature-branch
    #
    #   # Dry run to see what would happen
    #   git wpr --dry-run 123
    #
    #   # Use different remote
    #   git wpr --remote upstream 123
    #
    # EXIT STATUS
    #   0    Success
    #   1    Invalid arguments
    #   2    Git command failed
    #   3    PR fetch failed

    # Parse command line arguments
    argparse --name=git-wpr h/help n/dry-run r/remote= -- $argv
    or return 1

    # Show help if requested
    if set -q _flag_help
        printf '%s\n' (status function | head -n 1)
        printf '\n'
        functions git-wpr | string match -r '^\s*#\s.*' | string replace -r '^\s*#\s?' '' | string replace -r '^\s*#\s*$' ''
        return 0
    end

    # Check if PR number is provided
    if test (count $argv) -eq 0
        printf "Error: Missing required argument <pr-number>\n" >&2
        printf "Usage: git-wpr [OPTIONS] <pr-number> [worktree-name]\n" >&2
        printf "Try 'git-wpr --help' for more information.\n" >&2
        return 1
    end

    set -l pr_number $argv[1]
    set -l worktree_name $argv[2]
    set -l remote_name $_flag_remote

    # Validate PR number is numeric
    if not string match -qr '^\d+$' -- $pr_number
        printf "Error: Invalid PR number: %s\n" $pr_number >&2
        printf "Expected a number (e.g., 123)\n" >&2
        return 1
    end

    # Default remote to origin if not specified
    if test -z "$remote_name"
        set remote_name origin
    end

    # Default worktree name to pr-NUMBER if not specified
    if test -z "$worktree_name"
        set worktree_name "pr-$pr_number"
    end

    set -l branch_name "pr-$pr_number"

    if set -q _flag_dry_run
        printf "Would fetch: %s pull/%s/head:%s\n" $remote_name $pr_number $branch_name
        printf "Would create worktree: %s (branch: %s)\n" $worktree_name $branch_name
        return 0
    end

    # Fetch the PR branch
    printf "Fetching PR #%s from %s...\n" $pr_number $remote_name
    if not git fetch $remote_name "pull/$pr_number/head:$branch_name"
        printf "Error: Failed to fetch PR #%s from %s\n" $pr_number $remote_name >&2
        printf "Make sure the PR exists and you have access to the repository.\n" >&2
        return 3
    end

    printf "Creating worktree '%s' for PR #%s...\n" $worktree_name $pr_number

    # Create the worktree using the fetched branch
    if git worktree add $worktree_name $branch_name
        printf "✓ Successfully created worktree for PR #%s: %s\n" $pr_number $worktree_name

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
        printf "The branch '%s' was fetched but worktree creation failed.\n" $branch_name >&2
        return 2
    end
end
