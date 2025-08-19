#!/usr/bin/env fish

function git-wclean --description "Clean up git worktrees that have been merged to upstream branch"
    # Git Worktree Clean - Removes worktrees whose commits have been merged to upstream branch
    #
    # SYNOPSIS
    #   git-wclean [OPTIONS] <worktrees-directory>
    #   git wclean [OPTIONS] <worktrees-directory>
    #
    # DESCRIPTION
    #   This command scans a directory containing git worktrees and removes any worktrees
    #   whose current HEAD commit has been merged into the upstream branch (typically
    #   origin/main). This helps keep your worktree directory clean by automatically
    #   removing branches that have been merged.
    #
    #   The command will:
    #   1. Scan each worktree in the specified directory
    #   2. Determine the upstream branch (falls back to origin/main if not set)
    #   3. Fetch the latest changes from the remote
    #   4. Check if the current HEAD commit exists in the upstream branch
    #   5. Remove worktrees only if their commits have been merged
    #
    # OPTIONS
    #   -n, --dry-run        Show what would be removed without actually removing anything
    #   --no-delete-branch   Keep local branches after removing worktrees
    #   -h, --help           Show this help message
    #
    # ARGUMENTS
    #   worktrees-directory    Path to the directory containing git worktrees
    #
    # EXAMPLES
    #   # Clean up worktrees in ~/git/myproject-worktrees
    #   git-wclean ~/git/myproject-worktrees
    #
    #   # See what would be cleaned without actually removing anything
    #   git-wclean --dry-run ~/git/myproject-worktrees
    #
    #   # Clean up worktrees but keep the local branches
    #   git-wclean --no-delete-branch ~/git/myproject-worktrees
    #
    #   # Can also be called as git subcommand
    #   git wclean ~/git/myproject-worktrees
    #
    # EXIT STATUS
    #   0    Success
    #   1    Invalid arguments or directory not found
    #   2    Git command failed

    # Parse command line arguments
    argparse --name=git-wclean h/help n/dry-run no-delete-branch -- $argv
    or return 1

    # Show help if requested
    if set -q _flag_help
        printf '%s\n' (status function | head -n 1)
        printf '\n'
        functions git-wclean | string match -r '^\s*#\s.*' | string replace -r '^\s*#\s?' '' | string replace -r '^\s*#\s*$' ''
        return 0
    end

    # Check if directory path is provided
    if test (count $argv) -eq 0
        printf "Error: Missing required argument <worktrees-directory>\n" >&2
        printf "Usage: git-wclean [OPTIONS] <worktrees-directory>\n" >&2
        printf "Try 'git-wclean --help' for more information.\n" >&2
        return 1
    end

    if test (count $argv) -gt 1
        printf "Error: Too many arguments. Expected one directory path.\n" >&2
        printf "Usage: git-wclean [OPTIONS] <worktrees-directory>\n" >&2
        return 1
    end

    # Validate and resolve the worktrees directory path
    set -l worktrees_dir $argv[1]

    if not test -d "$worktrees_dir"
        printf "Error: Directory '%s' does not exist.\n" $worktrees_dir >&2
        return 1
    end

    # Get absolute path
    set worktrees_dir (realpath "$worktrees_dir")
    or begin
        printf "Error: Failed to resolve path '%s'.\n" $argv[1] >&2
        return 1
    end

    printf "Scanning worktrees in: %s\n" $worktrees_dir

    if set -q _flag_dry_run
        printf "DRY-RUN MODE: No worktrees will actually be removed.\n\n"
    end

    # Track statistics
    set -l processed_count 0
    set -l removed_count 0
    set -l skipped_count 0

    # Iterate through each directory in the worktrees directory
    for subdir in $worktrees_dir/*/
        # Remove trailing slash and check if it's a directory
        set subdir (string trim -r -c '/' -- $subdir)

        if not test -d "$subdir"
            continue
        end

        set processed_count (math $processed_count + 1)

        # Check if it's a Git repository
        if not test -e "$subdir/.git"
            printf "Skipping '%s': Not a git repository.\n" (basename $subdir)
            set skipped_count (math $skipped_count + 1)
            continue
        end

        printf "Processing: %s\n" (basename $subdir)

        # Change to the worktree directory
        pushd "$subdir" >/dev/null
        or begin
            printf "Error: Cannot access directory '%s'.\n" $subdir >&2
            popd >/dev/null 2>&1
            continue
        end

        # Get the current HEAD commit hash
        set -l head_commit (git rev-parse HEAD 2>/dev/null)
        if test $status -ne 0
            printf "Error: Failed to get HEAD commit in '%s'.\n" $subdir >&2
            popd >/dev/null
            set skipped_count (math $skipped_count + 1)
            continue
        end

        # Get the current branch name for potential deletion
        set -l current_branch_name (git rev-parse --abbrev-ref HEAD 2>/dev/null)
        if test $status -ne 0
            set current_branch_name ""
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
            popd >/dev/null
            set skipped_count (math $skipped_count + 1)
            continue
        end

        # Check if the commit exists in the upstream branch
        set -l commit_found false
        set -l branch_commits (git rev-list $head_commit --not $upstream_branch ^-1 2>/dev/null)
        if test -z "$branch_commits"
            set commit_found true
            printf "  ✓ Commit found in upstream branch %s.\n" $upstream_branch
        else
            printf "  ✗ Commit NOT found in upstream branch %s.\n" $upstream_branch
        end

        popd >/dev/null

        if $commit_found
            # Get the main repository path to remove the worktree
            set -l main_repo (git rev-parse --show-toplevel 2>/dev/null)
            if test $status -ne 0
                printf "Error: Failed to find main repository.\n"
                popd >/dev/null
                set skipped_count (math $skipped_count + 1)
                continue
            end

            # Get worktree name for removal
            set -l worktree_name (basename $subdir)

            # Don't remove the main repository itself
            if test "$worktree_name" = (basename $main_repo)
                printf "This is the main repository, cannot remove.\n"
                popd >/dev/null
                set skipped_count (math $skipped_count + 1)
                continue
            end

            popd >/dev/null

            # Change to main repository to run worktree remove
            pushd "$main_repo" >/dev/null
            or begin
                printf "Error: Cannot access main repository '%s'.\n" $main_repo >&2
                continue
            end

            if set -q _flag_dry_run
                printf "Would remove worktree: %s\n" $worktree_name
                # Show branch deletion info
                if test -n "$current_branch_name"; and not set -q _flag_no_delete_branch
                    printf "  Would also delete local branch: %s\n" $current_branch_name
                else if set -q _flag_no_delete_branch
                    printf "  Would keep local branch: %s\n" $current_branch_name
                end
            else
                if git worktree remove --force "$worktree_name" >/dev/null 2>&1
                    printf "Removed worktree: %s\n" $worktree_name
                    set removed_count (math $removed_count + 1)

                    # Remove the associated local branch unless --no-delete-branch is specified
                    if test -n "$current_branch_name"; and not set -q _flag_no_delete_branch
                        printf "  Removing associated local branch '%s'...\n" $current_branch_name

                        # Check if the branch exists locally
                        if git branch --list "$current_branch_name" | string match -q "*$current_branch_name*"
                            if git branch -d "$current_branch_name" >/dev/null 2>&1
                                printf "  ✓ Successfully deleted local branch: %s\n" $current_branch_name
                            else if git branch -D "$current_branch_name" >/dev/null 2>&1
                                printf "  ✓ Force deleted local branch: %s (had unmerged changes)\n" $current_branch_name
                            else
                                printf "  Warning: Failed to delete local branch '%s'.\n" $current_branch_name >&2
                            end
                        else
                            printf "  Local branch '%s' not found, skipping deletion.\n" $current_branch_name
                        end
                    else if test -n "$current_branch_name"
                        printf "  Keeping local branch '%s' as requested.\n" $current_branch_name
                    end
                else
                    printf "Error: Failed to remove worktree '%s'.\n" $worktree_name >&2
                    set skipped_count (math $skipped_count + 1)
                end
            end

            popd >/dev/null
        else
            printf "  - Commit not found on %s. Keeping worktree.\n" $upstream_branch
            popd >/dev/null
            set skipped_count (math $skipped_count + 1)
        end
    end

    # Print summary
    printf "\nSummary:\n"
    printf "  Processed: %d worktrees\n" $processed_count
    if set -q _flag_dry_run
        printf "  Would remove: %d worktrees\n" $removed_count
    else
        printf "  Removed: %d worktrees\n" $removed_count
    end
    printf "  Kept/Skipped: %d worktrees\n" $skipped_count

    printf "\nWorktree cleanup completed!\n"
    return 0
end
