#!/usr/bin/env fish

# Helper function to parse and validate arguments
function _wclean_parse_args
    argparse --name=git-wclean h/help n/dry-run f/force no-delete-branch -- $argv
    or return 1

    # Show help if requested
    if set -q _flag_help
        _wclean_show_help
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

    # Set the global worktrees directory
    set -g _wclean_worktrees_dir $argv[1]
    return 0
end

# Helper function to show help
function _wclean_show_help
    printf '%s\n' (status function | head -n 1)
    printf '\n'
    string match -rg '^\s*#\s*(.*)' (functions git-wclean)
end

# Helper function to validate and setup the worktrees directory
function _wclean_setup_directory
    if not test -d "$_wclean_worktrees_dir"
        printf "Error: Directory '%s' does not exist.\n" $_wclean_worktrees_dir >&2
        return 1
    end

    # Get absolute path
    set _wclean_worktrees_dir (realpath "$_wclean_worktrees_dir")
    or begin
        printf "Error: Failed to resolve path '%s'.\n" $_wclean_worktrees_dir >&2
        return 1
    end

    printf "Scanning worktrees in: %s\n" $_wclean_worktrees_dir

    if set -q _flag_dry_run
        printf "DRY-RUN MODE: No worktrees will actually be removed.\n\n"
    end
    return 0
end

# Helper function to fetch remote updates
function _wclean_fetch_remotes
    printf "Fetching latest changes from remotes...\n"
    if git fetch origin >/dev/null 2>&1
        printf "✓ Fetched from origin\n"
    else
        printf "⚠️  Warning: Failed to fetch from origin. Proceeding with local information.\n"
    end
    printf "\n"
end

# Helper function to check if a commit is merged into upstream
function _wclean_check_merge_status
    set -l worktree_path $argv[1]
    set -l head_commit $argv[2]
    set -l upstream_branch $argv[3]

    # Check if the commit exists in the upstream branch
    set -l branch_commits (git rev-list $head_commit --not $upstream_branch 2>/dev/null)
    if test -z "$branch_commits"
        printf "  ✓ Commit found in upstream branch %s.\n" $upstream_branch
        return 0
    else
        printf "  ✗ Commit NOT found in upstream branch %s.\n" $upstream_branch
        return 1
    end
end

# Helper function to get worktree information
function _wclean_get_worktree_info
    set -l worktree_path $argv[1]
    
    pushd "$worktree_path" >/dev/null
    or return 1

    # Get the current HEAD commit hash
    set -l head_commit (git rev-parse HEAD 2>/dev/null)
    if test $status -ne 0
        popd >/dev/null
        return 1
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

    popd >/dev/null

    # Export results as global variables for the caller
    set -g _wclean_head_commit $head_commit
    set -g _wclean_current_branch $current_branch_name
    set -g _wclean_upstream_branch $upstream_branch
    return 0
end

# Helper function to find the main repository path
function _wclean_find_main_repo
    set -l worktree_path $argv[1]
    
    pushd "$worktree_path" >/dev/null
    or return 1

    # For worktrees, we need to find the main repository, not just the worktree toplevel
    set -l git_common_dir (git rev-parse --git-common-dir 2>/dev/null)
    if test $status -ne 0
        popd >/dev/null
        return 1
    end

    # If git-common-dir is relative, make it absolute from the current worktree
    if not string match -q '/*' "$git_common_dir"
        set git_common_dir "$worktree_path/$git_common_dir"
    end

    # The main repository is the parent of the .git directory
    set -g _wclean_main_repo (dirname "$git_common_dir")
    popd >/dev/null
    return 0
end

# Helper function to remove a worktree and optionally its branch
function _wclean_remove_worktree
    set -l worktree_path $argv[1]
    set -l worktree_name (basename $worktree_path)
    set -l main_repo $argv[2]
    set -l current_branch_name $argv[3]

    # Protect main worktrees from accidental removal (unless --force is used)
    if contains "$worktree_name" main master develop trunk; and not set -q _flag_force
        printf "  Protected: '%s' worktree will not be removed for safety.\n" $worktree_name
        return 1
    end

    # Don't remove the main repository itself
    set -l subdir_real (realpath "$worktree_path" 2>/dev/null || echo "$worktree_path")
    set -l main_repo_real (realpath "$main_repo" 2>/dev/null || echo "$main_repo")

    if test "$subdir_real" = "$main_repo_real"
        printf "  This is the main repository, cannot remove.\n"
        return 1
    end

    # Change to main repository to run worktree remove
    pushd "$main_repo" >/dev/null
    or begin
        printf "  Error: Cannot access main repository '%s'.\n" $main_repo >&2
        return 1
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

            # Remove the associated local branch unless --no-delete-branch is specified
            if test -n "$current_branch_name"; and not set -q _flag_no_delete_branch
                _wclean_remove_branch "$current_branch_name"
            else if test -n "$current_branch_name"
                printf "  Keeping local branch '%s' as requested.\n" $current_branch_name
            end
        else
            printf "Error: Failed to remove worktree '%s'.\n" $worktree_name >&2
            popd >/dev/null
            return 1
        end
    end

    popd >/dev/null
    return 0
end

# Helper function to remove a branch
function _wclean_remove_branch
    set -l branch_name $argv[1]
    
    printf "  Removing associated local branch '%s'...\n" $branch_name

    # Check if the branch exists locally
    if git branch --list "$branch_name" | string match -q "*$branch_name*"
        if git branch -d "$branch_name" >/dev/null 2>&1
            printf "  ✓ Successfully deleted local branch: %s\n" $branch_name
        else if git branch -D "$branch_name" >/dev/null 2>&1
            printf "  ✓ Force deleted local branch: %s (had unmerged changes)\n" $branch_name
        else
            printf "  Warning: Failed to delete local branch '%s'.\n" $branch_name >&2
        end
    else
        printf "  Local branch '%s' not found, skipping deletion.\n" $branch_name
    end
end

# Helper function to process a single worktree
function _wclean_process_worktree
    set -l worktree_path $argv[1]
    
    if not test -d "$worktree_path"
        return 1
    end

    # Check if it's a Git repository
    if not test -e "$worktree_path/.git"
        printf "Skipping '%s': Not a git repository.\n" (basename $worktree_path)
        return 1
    end

    printf "Processing: %s\n" (basename $worktree_path)

    # Get worktree information
    if not _wclean_get_worktree_info "$worktree_path"
        printf "Error: Failed to get worktree info for '%s'.\n" $worktree_path >&2
        return 1
    end

    # Check merge status
    pushd "$worktree_path" >/dev/null
    if _wclean_check_merge_status "$worktree_path" "$_wclean_head_commit" "$_wclean_upstream_branch"
        popd >/dev/null
        
        # Find main repository
        if not _wclean_find_main_repo "$worktree_path"
            printf "  Error: Failed to find git common directory from worktree.\n" >&2
            return 1
        end

        # Remove the worktree
        if _wclean_remove_worktree "$worktree_path" "$_wclean_main_repo" "$_wclean_current_branch"
            return 0  # Successfully removed
        else
            return 1  # Skipped or failed
        end
    else
        popd >/dev/null
        printf "  - Commit not found on %s. Keeping worktree.\n" $_wclean_upstream_branch
        return 1  # Not merged, keep worktree
    end
end

# Helper function to show summary
function _wclean_show_summary
    set -l processed_count $argv[1]
    set -l removed_count $argv[2]
    set -l skipped_count $argv[3]
    
    printf "\nSummary:\n"
    printf "  Processed: %d worktrees\n" $processed_count
    if set -q _flag_dry_run
        printf "  Would remove: %d worktrees\n" $removed_count
    else
        printf "  Removed: %d worktrees\n" $removed_count
    end
    printf "  Kept/Skipped: %d worktrees\n" $skipped_count

    printf "\nWorktree cleanup completed!\n"
end

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
    #   -f, --force          Force removal including protected worktrees (use with caution)
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

    # Parse and validate arguments
    if not _wclean_parse_args $argv
        return 1
    end

    # Setup and validate directory
    if not _wclean_setup_directory
        return 1
    end

    # Fetch remote updates
    _wclean_fetch_remotes

    # Track statistics
    set -l processed_count 0
    set -l removed_count 0
    set -l skipped_count 0

    # Iterate through each directory in the worktrees directory
    for subdir in $_wclean_worktrees_dir/*/
        # Remove trailing slash
        set subdir (string trim -r -c '/' -- $subdir)

        set processed_count (math $processed_count + 1)

        # Process the worktree
        if _wclean_process_worktree "$subdir"
            set removed_count (math $removed_count + 1)
        else
            set skipped_count (math $skipped_count + 1)
        end
    end

    # Show summary
    _wclean_show_summary $processed_count $removed_count $skipped_count
    return 0
end
