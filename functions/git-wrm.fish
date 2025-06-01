function git-wrm --description "Remove a git worktree after verifying commits are merged upstream"
    # Git Worktree Remove - Safely removes a worktree after checking if commits are merged
    #
    # SYNOPSIS
    #   git-wrm [OPTIONS] <worktree-path>
    #   git wrm [OPTIONS] <worktree-path>
    #
    # DESCRIPTION
    #   This command removes a git worktree after verifying that its current HEAD commit
    #   has been merged into the upstream branch (typically origin/main). This provides
    #   a safe way to remove worktrees without losing any unmerged work.
    #
    #   The command will:
    #   1. Verify the worktree exists and is a valid git repository
    #   2. Determine the upstream branch (falls back to origin/main if not set)
    #   3. Fetch the latest changes from the remote
    #   4. Check if the current HEAD commit exists in the upstream branch
    #   5. Remove the worktree only if the commit has been merged
    #
    # OPTIONS
    #   -n, --dry-run    Show what would be removed without actually removing anything
    #   -f, --force      Remove worktree even if commits are not merged upstream
    #   -h, --help       Show this help message
    #
    # ARGUMENTS
    #   worktree-path    Path to the worktree directory to remove
    #
    # EXAMPLES
    #   # Remove a worktree after verifying it's merged
    #   git-wrm ~/git/myproject-worktrees/feature-branch
    #
    #   # See what would happen without actually removing
    #   git-wrm --dry-run ~/git/myproject-worktrees/feature-branch
    #
    #   # Force removal even if not merged (use with caution!)
    #   git-wrm --force ~/git/myproject-worktrees/feature-branch
    #
    #   # Can also be called as git subcommand
    #   git wrm ~/git/myproject-worktrees/feature-branch
    #
    # EXIT STATUS
    #   0    Success - worktree was removed or would be removed (dry-run)
    #   1    Invalid arguments or worktree not found
    #   2    Git command failed
    #   3    Commits not merged upstream (use --force to override)

    # Parse command line arguments
    argparse --name=git-wrm 'h/help' 'n/dry-run' 'f/force' -- $argv
    or return 1

    # Show help if requested
    if set -q _flag_help
        printf '%s\n' (status function | head -n 1)
        printf '\n%s\n' (functions git-wrm | string match -r '#.*' | string trim -c '# ')
        return 0
    end

    # Check if worktree path is provided
    if test (count $argv) -eq 0
        printf "Error: Missing required argument <worktree-path>\n" >&2
        printf "Usage: git-wrm [OPTIONS] <worktree-path>\n" >&2
        printf "Try 'git-wrm --help' for more information.\n" >&2
        return 1
    end

    if test (count $argv) -gt 1
        printf "Error: Too many arguments. Expected one worktree path.\n" >&2
        printf "Usage: git-wrm [OPTIONS] <worktree-path>\n" >&2
        return 1
    end

    # Validate and resolve the worktree path
    set -l worktree_path $argv[1]

    if not test -d "$worktree_path"
        printf "Error: Worktree directory '%s' does not exist.\n" $worktree_path >&2
        return 1
    end

    # Get absolute path
    set worktree_path (realpath "$worktree_path")
    or begin
        printf "Error: Failed to resolve path '%s'.\n" $argv[1] >&2
        return 1
    end

    # Check if it's a Git repository
    if not test -d "$worktree_path/.git"
        printf "Error: '%s' is not a git repository.\n" $worktree_path >&2
        return 1
    end

    printf "Checking worktree: %s\n" (basename $worktree_path)

    if set -q _flag_dry_run
        printf "DRY-RUN MODE: Worktree will not actually be removed.\n\n"
    end

    # Change to the worktree directory
    pushd "$worktree_path" >/dev/null
    or begin
        printf "Error: Cannot access worktree directory '%s'.\n" $worktree_path >&2
        return 2
    end

    # Get the current HEAD commit hash
    set -l head_commit (git rev-parse HEAD 2>/dev/null)
    if test $status -ne 0
        printf "Error: Failed to get HEAD commit in worktree.\n" >&2
        popd >/dev/null
        return 2
    end

    printf "  Current HEAD: %s\n" (string sub -l 8 $head_commit)

    # Get the main repository path
    set -l main_repo (git rev-parse --show-toplevel 2>/dev/null)
    if test $status -ne 0
        printf "Error: Failed to find main repository.\n" >&2
        popd >/dev/null
        return 2
    end

    # Get worktree name for removal
    set -l worktree_name (basename $worktree_path)

    # Don't remove the main repository itself
    if test "$worktree_path" = "$main_repo"
        printf "Error: Cannot remove the main repository. Use a worktree path instead.\n" >&2
        popd >/dev/null
        return 1
    end

    # Determine the upstream branch
    set -l upstream_branch (git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)
    if test $status -ne 0
        printf "  No upstream branch configured, using origin/main as default.\n"
        set upstream_branch origin/main
    else
        printf "  Upstream branch: %s\n" $upstream_branch
    end

    # Extract remote name from upstream branch
    set -l remote_name (string split '/' $upstream_branch)[1]
    set -l branch_name (string join '/' (string split '/' $upstream_branch)[2..-1])

    # Fetch latest from the remote
    printf "  Fetching latest from %s...\n" $remote_name
    if not git fetch $remote_name $branch_name >/dev/null 2>&1
        printf "  Warning: Failed to fetch from %s. Proceeding with local information.\n" $remote_name
    end

    # Check if the commit exists in the upstream branch
    set -l commit_found false
    if git branch -r --contains $head_commit 2>/dev/null | string match -q "*/$upstream_branch"
        set commit_found true
        printf "  ✓ Commit found in upstream branch %s.\n" $upstream_branch
    else
        printf "  ✗ Commit NOT found in upstream branch %s.\n" $upstream_branch
    end

    popd >/dev/null

    # Decide whether to remove the worktree
    if test $commit_found = true -o (set -q _flag_force)
        # Change to main repository to run worktree remove
        pushd "$main_repo" >/dev/null
        or begin
            printf "Error: Cannot access main repository '%s'.\n" $main_repo >&2
            return 2
        end

        if set -q _flag_dry_run
            if test $commit_found = true
                printf "\nWould remove worktree '%s' (commits are merged).\n" $worktree_name
            else
                printf "\nWould FORCE remove worktree '%s' (commits NOT merged - forced).\n" $worktree_name
            end
            popd >/dev/null
            return 0
        else
            if test $commit_found = false
                printf "\nWARNING: Forcing removal of worktree with unmerged commits!\n"
            end

            printf "Removing worktree '%s'...\n" $worktree_name
            if git worktree remove --force "$worktree_name" >/dev/null 2>&1
                printf "✓ Successfully removed worktree: %s\n" $worktree_name
                popd >/dev/null
                return 0
            else
                printf "Error: Failed to remove worktree '%s'.\n" $worktree_name >&2
                printf "You may need to remove it manually with: git worktree remove --force %s\n" $worktree_name >&2
                popd >/dev/null
                return 2
            end
        end
    else
        printf "\nRefusing to remove worktree: commits are not merged upstream.\n"
        printf "Options:\n"
        printf "  1. Merge your changes to %s first\n" $upstream_branch
        printf "  2. Use --force to remove anyway (DANGER: will lose unmerged work)\n"
        printf "  3. Use --dry-run to see what would happen\n"
        return 3
    end
end
