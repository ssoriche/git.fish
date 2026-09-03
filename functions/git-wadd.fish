function git-wadd --description "Create a new git worktree and branch"
    # Git Worktree Add - Creates a new worktree with an optional branch
    #
    # SYNOPSIS
    #   git-wadd [OPTIONS] <worktree-name> [branch-name] [git-worktree-options...]
    #   git wadd [OPTIONS] <worktree-name> [branch-name] [git-worktree-options...]
    #
    #   In a canonical .bare layout, <worktree-name> is a container-anchored name,
    #   not a path (see ARGUMENTS for the exact restriction).
    #
    # DESCRIPTION
    #   This command creates a new git worktree and optionally creates a new branch for it.
    #   If no branch name is provided, it will create a new branch based on the current
    #   upstream branch (typically origin/main). If <worktree-name> already exists as a
    #   local branch, that branch is checked out into the new worktree instead of creating
    #   one (passing <branch-name> in that case is an error). After creating the worktree,
    #   it will automatically change to the new worktree directory.
    #
    # OPTIONS
    #   -h, --help       Show this help message
    #
    # ARGUMENTS
    #   worktree-name    Name/path of the new worktree directory. In a canonical .bare
    #                    layout (a directory with a sibling .bare/ directory), this is
    #                    a single name anchored under the container directory, not a
    #                    path: rejected if empty/whitespace-only, contains '/', is '.'
    #                    or '..', or starts with '-'. Outside a .bare layout, used
    #                    as-is (a path).
    #   branch-name      Start point for the new branch <worktree-name> (optional)
    #                   If not provided, creates the branch from upstream. Not allowed
    #                   when <worktree-name> is already an existing local branch.
    #   git-worktree-options  Additional options to pass to git worktree add
    #
    # EXAMPLES
    #   # Create worktree 'feature-123' with new branch from upstream
    #   git-wadd feature-123
    #
    #   # Create worktree 'hotfix' with new branch 'hotfix' started from 'develop'
    #   git-wadd hotfix develop
    #
    #   # Check out the existing local branch 'feature-789' into a worktree
    #   git-wadd feature-789
    #
    #   # Create worktree with additional git worktree options
    #   git-wadd feature-456 origin/main --force
    #
    #   # In a .bare layout, <worktree-name> is a name, not a path: use '-' or '.' as
    #   # a separator instead of '/'
    #   git-wadd feature.123
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
        _git_help_from_doc_comment git-wadd
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

    # Layout-aware path resolution: in a bare layout, the argument is a worktree NAME
    # (anchored to the container directory), not a path.
    set -l worktree_path (_git_bare_worktree_path $worktree_name)
    if test $status -ne 0
        printf "Error: invalid worktree name '%s'.\n" $worktree_name >&2
        printf "In a bare layout, worktree names cannot contain '/', be '.' or '..', or\n" >&2
        printf "start with '-' (try using '.' or '-' as an internal separator).\n" >&2
        return 1
    end

    # A worktree name that matches an existing local branch means "check that branch
    # out here", not "create a branch of that name" (which git would refuse).
    set -l worktree_add_args
    if git show-ref --verify --quiet refs/heads/$worktree_name
        if test -n "$branch_name"
            printf "Error: branch '%s' already exists; cannot create it from '%s'.\n" $worktree_name $branch_name >&2
            printf "Omit <branch-name> to check out the existing branch instead.\n" >&2
            return 1
        end
        printf "Checking out existing branch '%s' into worktree '%s'...\n" $worktree_name $worktree_name
        set worktree_add_args $worktree_path $worktree_name
    else
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
        set worktree_add_args -b $worktree_name $worktree_path $branch_name
    end

    if git worktree add $worktree_add_args $extra_args
        printf "✓ Successfully created worktree: %s\n" $worktree_name

        # Change to the new worktree directory
        if test -d "$worktree_path"
            printf "Changing to worktree directory...\n"
            cd $worktree_path
            or begin
                printf "Warning: Failed to change to worktree directory.\n" >&2
            end
        else
            printf "Warning: Worktree directory not found at expected location.\n" >&2
        end

        return 0
    else
        printf "Error: Failed to create worktree '%s'.\n" $worktree_path >&2
        return 2
    end
end
