#!/usr/bin/env fish

# Signal handling for clean shutdown - shared cleanup logic
function _wclean_cleanup_handler
    # Restore original directory if we're in a different one
    if set -q _wclean_original_dir; and test -d "$_wclean_original_dir"
        cd "$_wclean_original_dir" 2>/dev/null
    end

    # Clean up any global variables we set
    set -e _wclean_worktrees_dir
    set -e _wclean_head_commit
    set -e _wclean_current_branch
    set -e _wclean_upstream_branch
    set -e _wclean_main_repo
    set -e _wclean_remotes
    set -e _wclean_default_branch
    set -e _wclean_original_dir

    # Clean up promoted argparse flags
    set -e _wclean_flag_help
    set -e _wclean_flag_dry_run
    set -e _wclean_flag_force
    set -e _wclean_flag_no_delete_branch
    set -e _wclean_flag_check
    set -e _wclean_stale_days
    set -e _wclean_stale_report

    # Clean up config variables
    set -e _wclean_config_protected_branches
    set -e _wclean_config_default_upstream
    set -e _wclean_config_system_dirs
    set -e _wclean_config_max_path_length
    set -e _wclean_config_fetch_timeout
    set -e _wclean_config_stale_days

    printf "\n\n🚫 Operation interrupted by user. Cleanup completed.\n" >&2
    exit 130 # Standard exit code for Ctrl+C
end

# Signal handler for INT (Ctrl+C)
function _wclean_cleanup_int --on-signal INT
    _wclean_cleanup_handler
end

# Signal handler for TERM
function _wclean_cleanup_term --on-signal TERM
    _wclean_cleanup_handler
end

# Clean up function for normal exit
function _wclean_normal_cleanup
    # Restore original directory
    if set -q _wclean_original_dir; and test -d "$_wclean_original_dir"
        cd "$_wclean_original_dir" 2>/dev/null
    end

    # Clean up global variables
    set -e _wclean_worktrees_dir
    set -e _wclean_head_commit
    set -e _wclean_current_branch
    set -e _wclean_upstream_branch
    set -e _wclean_main_repo
    set -e _wclean_remotes
    set -e _wclean_default_branch
    set -e _wclean_original_dir

    # Clean up promoted argparse flags
    set -e _wclean_flag_help
    set -e _wclean_flag_dry_run
    set -e _wclean_flag_force
    set -e _wclean_flag_no_delete_branch
    set -e _wclean_flag_check
    set -e _wclean_stale_days
    set -e _wclean_stale_report

    # Clean up config variables
    set -e _wclean_config_protected_branches
    set -e _wclean_config_default_upstream
    set -e _wclean_config_system_dirs
    set -e _wclean_config_max_path_length
    set -e _wclean_config_fetch_timeout
    set -e _wclean_config_stale_days
end

# Security validation helper function
function _wclean_validate_path
    set -l path $argv[1]
    set -l path_type $argv[2] # Optional description for error messages

    if test -z "$path_type"
        set path_type path
    end

    # Check for path traversal attempts. Split on '/' and look for a literal
    # '..' component so a bare '..', a leading '../sibling', and an embedded
    # 'a/../b' are all caught -- while a component that merely contains '..'
    # as part of a longer name (e.g. 'foo..bar') is correctly left alone.
    if contains -- .. (string split / -- "$path")
        printf "Error: Path traversal detected in %s. '..' not allowed.\n" $path_type >&2
        return 1
    end

    # Check for suspicious patterns that could be used for injection
    if string match -q '*|*' "$path"; or string match -q '*;*' "$path"; or string match -q '*&*' "$path"; or string match -q '*\$(*' "$path"
        printf "Error: Potentially unsafe characters detected in %s.\n" $path_type >&2
        return 1
    end

    # Check path length to prevent buffer overflow attacks
    if test (string length "$path") -gt $_wclean_config_max_path_length
        printf "Error: %s length exceeds maximum allowed (%d characters).\n" $path_type $_wclean_config_max_path_length >&2
        return 1
    end

    # Check for null bytes (should not exist in valid paths)
    if string match -q '*\0*' "$path"
        printf "Error: Null byte detected in %s.\n" $path_type >&2
        return 1
    end

    return 0
end

# Helper function to parse and validate arguments
function _wclean_parse_args
    # Reset globals promoted by a previous parse BEFORE argparse or any
    # validation can early-return: a failed parse (e.g. too many arguments)
    # must never leave a stale value behind for a later call in the same
    # shell to silently pick up.
    set -e _wclean_flag_help
    set -e _wclean_flag_check
    set -e _wclean_stale_days

    argparse --name=git-wclean h/help n/dry-run f/force no-delete-branch check 's/stale-days=' -- $argv
    or return 1

    # Show help if requested. argparse populates _flag_help only in this
    # function's local scope, so promote it to a global (cleaned up in the
    # cleanup handlers) so the caller in git-wclean can detect it and stop
    # cleanly instead of falling through into directory setup.
    if set -q _flag_help
        _git_help_from_doc_comment git-wclean
        set -g _wclean_flag_help
        return 0
    end

    # --check is a standalone mode: any other flag or a positional argument is
    # a misconfigured hook and must fail loudly (runtime conditions inside the
    # check itself stay silent instead)
    if set -q _flag_check
        if set -q _flag_dry_run; or set -q _flag_force
            or set -q _flag_no_delete_branch; or set -q _flag_stale_days
            or test (count $argv) -gt 0
            printf "Error: --check cannot be combined with other options or arguments\n" >&2
            return 1
        end
        set -g _wclean_flag_check
        return 0
    end

    # Validate and promote --stale-days (flag overrides config later)
    if set -q _flag_stale_days
        if not string match -qr '^\d+$' -- $_flag_stale_days
            printf "Error: --stale-days requires a non-negative integer\n" >&2
            return 1
        end
        set -g _wclean_stale_days $_flag_stale_days
    end

    # Layout-aware default: in a .bare layout, if no path was given, use the container
    if test (count $argv) -eq 0
        set -l _container (_git_bare_container)
        if test $status -eq 0
            set argv $_container
        end
    end

    # Check if directory path is provided
    if test (count $argv) -eq 0
        printf "Error: Missing required argument <worktrees-directory>\n" >&2
        printf "Usage: git-wclean [OPTIONS] <worktrees-directory>\n" >&2
        printf "(No argument needed inside a canonical .bare layout.)\n" >&2
        printf "Try 'git-wclean --help' for more information.\n" >&2
        return 1
    end

    if test (count $argv) -gt 1
        printf "Error: Too many arguments. Expected one directory path.\n" >&2
        printf "Usage: git-wclean [OPTIONS] <worktrees-directory>\n" >&2
        return 1
    end

    # argparse populates _flag_* only in THIS function's local scope. The helper
    # functions run in separate scopes and cannot see those locals, so promote
    # the flags they need to globals (cleaned up in the cleanup handlers).
    set -e _wclean_flag_dry_run
    set -e _wclean_flag_force
    set -e _wclean_flag_no_delete_branch
    set -q _flag_dry_run; and set -g _wclean_flag_dry_run
    set -q _flag_force; and set -g _wclean_flag_force
    set -q _flag_no_delete_branch; and set -g _wclean_flag_no_delete_branch

    # Set the global worktrees directory
    set -g _wclean_worktrees_dir $argv[1]
    return 0
end

# Helper function to validate and setup the worktrees directory
function _wclean_setup_directory
    # Security validation using helper function
    if not _wclean_validate_path "$_wclean_worktrees_dir" "worktrees directory"
        return 1
    end

    if not test -d "$_wclean_worktrees_dir"
        printf "Error: Directory '%s' does not exist.\n" $_wclean_worktrees_dir >&2
        return 1
    end

    # Security validation: Ensure directory is readable and accessible
    if not test -r "$_wclean_worktrees_dir"
        printf "Error: Directory '%s' is not readable.\n" $_wclean_worktrees_dir >&2
        return 1
    end

    # Get absolute path
    set _wclean_worktrees_dir (realpath "$_wclean_worktrees_dir")
    or begin
        printf "Error: Failed to resolve path '%s'.\n" $_wclean_worktrees_dir >&2
        return 1
    end

    # Security validation: Ensure resolved path is still within reasonable bounds
    if not string match -q '/*' "$_wclean_worktrees_dir"
        printf "Error: Resolved path is not absolute.\n" >&2
        return 1
    end

    # Security validation: Prevent operations on system directories.
    # $_wclean_worktrees_dir was just canonicalized via realpath above (no
    # trailing slash), but $system_dir comes straight from config and may be
    # non-canonical (e.g. a trailing slash). Normalize the trailing slash
    # before comparing so the system directory itself is rejected too, not
    # just its descendants (a plain "$system_dir/*" glob only ever matched
    # descendants).
    for system_dir in $_wclean_config_system_dirs
        set -l system_dir_norm (string replace -r '/+$' '' -- $system_dir)
        if test -z "$system_dir_norm"
            set system_dir_norm /
        end

        set -l is_system_dir 0
        if test "$_wclean_worktrees_dir" = "$system_dir_norm"
            set is_system_dir 1
        else if string match -q -- "$system_dir_norm/*" "$_wclean_worktrees_dir"
            set is_system_dir 1
        end

        if test $is_system_dir -eq 1
            printf "Error: Operation not allowed on system directory '%s'.\n" $system_dir >&2
            return 1
        end
    end

    # Security validation: Ensure we have write permissions if not in dry-run mode
    if not set -q _wclean_flag_dry_run; and not test -w "$_wclean_worktrees_dir"
        printf "Error: No write permission for directory '%s'. Use --dry-run to preview.\n" $_wclean_worktrees_dir >&2
        return 1
    end

    printf "Scanning worktrees in: %s\n" $_wclean_worktrees_dir

    if set -q _wclean_flag_dry_run
        printf "DRY-RUN MODE: No worktrees will actually be removed.\n\n"
    end
    return 0
end

# Helper function to fetch remote updates and cache remote info
function _wclean_fetch_remotes
    printf "Fetching latest changes from remotes...\n"

    # Cache remote information to avoid repeated git calls
    set -g _wclean_remotes (git remote 2>/dev/null)
    if test $status -ne 0
        printf "⚠️  Warning: Failed to get remote list. Proceeding with local information.\n"
        set -g _wclean_remotes ""
    end

    # Try to fetch from origin if it exists. Guard the fetch with a timeout
    # utility when one is available (`timeout` on Linux, `gtimeout` from GNU
    # coreutils on macOS); otherwise fetch without a timeout rather than failing
    # on the missing command.
    if contains origin $_wclean_remotes
        set -l timeout_cmd
        if command -q timeout
            set timeout_cmd timeout
        else if command -q gtimeout
            set timeout_cmd gtimeout
        end

        if test -n "$timeout_cmd"
            printf "Fetching from origin (timeout: %ds)...\n" $_wclean_config_fetch_timeout
            if $timeout_cmd $_wclean_config_fetch_timeout git fetch origin >/dev/null 2>&1
                printf "✓ Fetched from origin\n"
            else
                set -l fetch_status $status
                if test $fetch_status -eq 124 # timeout exit code
                    printf "⚠️  Warning: Fetch from origin timed out after %ds. Proceeding with local information.\n" $_wclean_config_fetch_timeout
                else
                    printf "⚠️  Warning: Failed to fetch from origin. Proceeding with local information.\n"
                end
            end
        else
            printf "Fetching from origin (no timeout utility found)...\n"
            if git fetch origin >/dev/null 2>&1
                printf "✓ Fetched from origin\n"
            else
                printf "⚠️  Warning: Failed to fetch from origin. Proceeding with local information.\n"
            end
        end
    else
        printf "⚠️  Note: No 'origin' remote found.\n"
    end

    # Determine the integration branch from origin/HEAD. An explicit config
    # override takes precedence; otherwise require origin/HEAD rather than
    # silently assuming origin/main, which could delete unmerged work.
    set -g _wclean_default_branch (git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | string replace 'refs/remotes/' '')
    if test -z "$_wclean_default_branch"
        if test -n "$_wclean_config_default_upstream"
            set -g _wclean_default_branch $_wclean_config_default_upstream
        else
            printf "Error: Cannot determine the default branch — 'origin/HEAD' is not set.\n" >&2
            printf "Set it (and retry) with:\n" >&2
            printf "    git remote set-head origin --auto\n" >&2
            printf "Or set _wclean_config_default_upstream in your git-wclean config.\n" >&2
            return 1
        end
    end

    printf "\n"
end

# Helper function to check if a commit is merged into upstream
function _wclean_check_merge_status
    set -l worktree_path $argv[1]
    set -l head_commit $argv[2]
    set -l upstream_branch $argv[3]

    # Validate inputs
    if test -z "$head_commit"
        printf "  Error: Invalid head commit provided\n" >&2
        return 2
    end

    if test -z "$upstream_branch"
        printf "  Error: Invalid upstream branch provided\n" >&2
        return 2
    end

    # Check if the commit exists in the upstream branch
    set -l branch_commits (git rev-list $head_commit --not $upstream_branch 2>/dev/null)
    if test $status -ne 0
        printf "  Error: Failed to check merge status against %s\n" $upstream_branch >&2
        return 2
    end

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

    # Validate input
    if test -z "$worktree_path"
        printf "  Error: No worktree path provided\n" >&2
        return 1
    end

    # Security validation
    if not _wclean_validate_path "$worktree_path" "worktree path"
        return 1
    end

    if not test -d "$worktree_path"
        printf "  Error: Worktree path '%s' is not a directory\n" $worktree_path >&2
        return 1
    end

    # Performance optimization: use git -C to avoid directory changes
    # Get the current HEAD commit hash
    set -l head_commit (git -C "$worktree_path" rev-parse HEAD 2>/dev/null)
    if test $status -ne 0
        printf "  Error: Failed to get HEAD commit in '%s'\n" $worktree_path >&2
        return 1
    end

    # Get the current branch name for potential deletion
    set -l current_branch_name (git -C "$worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if test $status -ne 0
        set current_branch_name ""
    end

    # Verify against the upstream project's default branch (origin/HEAD, cached
    # in _wclean_default_branch), NOT the worktree branch's own remote-tracking
    # branch (@{upstream}) — a feature branch pushed to origin/<feature> would
    # always "match" itself and defeat the merge check.
    set -l upstream_branch $_wclean_default_branch
    printf "  Integration branch: %s\n" $upstream_branch

    # Export results as global variables for the caller
    set -g _wclean_head_commit $head_commit
    set -g _wclean_current_branch $current_branch_name
    set -g _wclean_upstream_branch $upstream_branch
    return 0
end

# Helper function to find the main repository path
function _wclean_find_main_repo
    set -l worktree_path $argv[1]

    # Validate input
    if test -z "$worktree_path"
        printf "  Error: No worktree path provided to find main repo\n" >&2
        return 1
    end

    # Security validation
    if not _wclean_validate_path "$worktree_path" "worktree path"
        return 1
    end

    if not test -d "$worktree_path"
        printf "  Error: Worktree path '%s' is not a directory\n" $worktree_path >&2
        return 1
    end

    # Performance optimization: use git -C to avoid directory changes
    # For worktrees, we need to find the main repository, not just the worktree toplevel
    set -l git_common_dir (git -C "$worktree_path" rev-parse --git-common-dir 2>/dev/null)
    if test $status -ne 0
        printf "  Error: Failed to find git common directory from worktree '%s'\n" $worktree_path >&2
        return 1
    end

    # If git-common-dir is relative, make it absolute from the current worktree
    if not string match -q '/*' "$git_common_dir"
        set git_common_dir "$worktree_path/$git_common_dir"
    end

    # The main repository is the parent of the .git directory
    set -l main_repo (dirname "$git_common_dir")

    # Validate that the main repo exists and is accessible
    if not test -d "$main_repo"
        printf "  Error: Main repository directory '%s' does not exist\n" $main_repo >&2
        return 1
    end

    set -g _wclean_main_repo $main_repo
    return 0
end

# Helper function to remove a worktree and optionally its branch
function _wclean_remove_worktree
    set -l worktree_path $argv[1]
    set -l main_repo $argv[2]
    set -l current_branch_name $argv[3]

    # Validate inputs
    if test -z "$worktree_path"
        printf "  Error: No worktree path provided for removal\n" >&2
        return 1
    end

    if test -z "$main_repo"
        printf "  Error: No main repository path provided for removal\n" >&2
        return 1
    end

    if not test -d "$worktree_path"
        printf "  Error: Worktree path '%s' is not a directory\n" $worktree_path >&2
        return 1
    end

    if not test -d "$main_repo"
        printf "  Error: Main repository path '%s' is not a directory\n" $main_repo >&2
        return 1
    end

    set -l worktree_name (basename $worktree_path)

    # Protect main worktrees from accidental removal (unless --force is used)
    if contains "$worktree_name" $_wclean_config_protected_branches; and not set -q _wclean_flag_force
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
        printf "  Error: Cannot access main repository '%s' for worktree removal.\n" $main_repo >&2
        return 1
    end

    if set -q _wclean_flag_dry_run
        printf "Would remove worktree: %s\n" $worktree_name
        # Show branch deletion info (only when the worktree has a branch, i.e.
        # not a detached HEAD).
        if test -n "$current_branch_name"
            if not set -q _wclean_flag_no_delete_branch
                printf "  Would also delete local branch: %s\n" $current_branch_name
            else
                printf "  Would keep local branch: %s\n" $current_branch_name
            end
        end
    else
        if git worktree remove --force "$worktree_name" >/dev/null 2>&1
            printf "Removed worktree: %s\n" $worktree_name

            # Remove the associated local branch unless --no-delete-branch is specified
            if test -n "$current_branch_name"; and not set -q _wclean_flag_no_delete_branch
                _wclean_remove_branch "$current_branch_name"
            else if test -n "$current_branch_name"
                printf "  Keeping local branch '%s' as requested.\n" $current_branch_name
            end
        else
            printf "  Error: Failed to remove worktree '%s'. Check if it exists and is not in use.\n" $worktree_name >&2
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

    # Validate input
    if test -z "$branch_name"
        printf "  Error: No branch name provided for deletion\n" >&2
        return 1
    end

    printf "  Removing associated local branch '%s'...\n" $branch_name

    # Performance optimization: use git rev-parse to check existence more efficiently
    if git rev-parse --verify "refs/heads/$branch_name" >/dev/null 2>&1
        if git branch -d "$branch_name" >/dev/null 2>&1
            printf "  ✓ Successfully deleted local branch: %s\n" $branch_name
            return 0
        else if git branch -D "$branch_name" >/dev/null 2>&1
            printf "  ✓ Force deleted local branch: %s (had unmerged changes)\n" $branch_name
            return 0
        else
            printf "  Warning: Failed to delete local branch '%s'.\n" $branch_name >&2
            return 1
        end
    else
        printf "  Local branch '%s' not found, skipping deletion.\n" $branch_name
        return 0
    end
end

# Helper function to process a single worktree
function _wclean_process_worktree
    set -l worktree_path $argv[1]

    # Validate input
    if test -z "$worktree_path"
        printf "Error: No worktree path provided for processing\n" >&2
        return 1
    end

    # Security validation
    if not _wclean_validate_path "$worktree_path" "worktree path"
        return 1
    end

    if not test -d "$worktree_path"
        return 1
    end

    # Performance optimization: quick git repo check without changing directories
    if not test -e "$worktree_path/.git"
        printf "Skipping '%s': Not a git repository.\n" (basename $worktree_path)
        return 1
    end

    printf "Processing: %s\n" (basename $worktree_path)

    # Get worktree information (this function handles directory changes internally)
    if not _wclean_get_worktree_info "$worktree_path"
        # Error message already printed by the helper function
        return 1
    end

    # Performance optimization: use git -C to avoid repeated pushd/popd
    set -l merge_check_status 2
    set -l branch_commits (git -C "$worktree_path" rev-list $_wclean_head_commit --not $_wclean_upstream_branch 2>/dev/null)
    if test $status -eq 0
        if test -z "$branch_commits"
            set merge_check_status 0 # Merged
            printf "  ✓ Commit found in upstream branch %s.\n" $_wclean_upstream_branch
        else
            set merge_check_status 1 # Not merged
            printf "  ✗ Commit NOT found in upstream branch %s.\n" $_wclean_upstream_branch
        end
    else
        printf "  Error: Failed to check merge status against %s\n" $_wclean_upstream_branch >&2
        set merge_check_status 2 # Error
    end

    switch $merge_check_status
        case 0
            # Commit is merged, proceed with removal

            # Find main repository
            if not _wclean_find_main_repo "$worktree_path"
                # Error message already printed by the helper function
                return 1
            end

            # Remove the worktree
            if _wclean_remove_worktree "$worktree_path" "$_wclean_main_repo" "$_wclean_current_branch"
                return 0 # Successfully removed
            else
                return 1 # Skipped or failed
            end
        case 1
            # Commit not merged, keep worktree
            printf "  - Commit not found on %s. Keeping worktree.\n" $_wclean_upstream_branch
            return 1
        case 2
            # Error occurred during merge status check
            printf "  Error: Failed to check merge status, skipping worktree.\n" >&2
            return 1
        case '*'
            # Unexpected return value
            printf "  Error: Unexpected result from merge status check, skipping worktree.\n" >&2
            return 1
    end
end

# Helper function to show summary
function _wclean_show_summary
    set -l processed_count $argv[1]
    set -l removed_count $argv[2]
    set -l skipped_count $argv[3]

    printf "\nSummary:\n"
    printf "  Processed: %d worktrees\n" $processed_count
    if set -q _wclean_flag_dry_run
        printf "  Would remove: %d worktrees\n" $removed_count
    else
        printf "  Removed: %d worktrees\n" $removed_count
    end
    printf "  Kept/Skipped: %d worktrees\n" $skipped_count

    printf "\nWorktree cleanup completed!\n"
end

# Placeholder until the real check mode lands (Task 7): silent success.
function _wclean_run_check
    return 0
end

function git-wclean --description "Clean up git worktrees that have been merged to upstream branch"
    # Git Worktree Clean - Removes worktrees whose commits have been merged to upstream branch
    #
    # SYNOPSIS
    #   git-wclean [OPTIONS] <worktrees-directory>
    #   git-wclean [OPTIONS]
    #   git wclean [OPTIONS] <worktrees-directory>
    #   git wclean [OPTIONS]
    #
    # DESCRIPTION
    #   This command scans a directory containing git worktrees and removes any worktrees
    #   whose current HEAD commit has been merged into the upstream project's default
    #   branch (origin/HEAD, e.g. origin/main or origin/master). This helps keep your
    #   worktree directory clean by automatically removing branches that have been merged.
    #
    #   The command will:
    #   1. Scan each worktree in the specified directory
    #   2. Determine the integration branch from origin/HEAD (errors if it is unset,
    #      unless overridden via _wclean_config_default_upstream)
    #   3. Fetch the latest changes from the remote
    #   4. Check if the current HEAD commit is merged into the integration branch
    #   5. Remove worktrees only if their commits have been merged
    #
    # OPTIONS
    #   -n, --dry-run        Show what would be removed without actually removing anything
    #   -f, --force          Force removal including protected worktrees (use with caution)
    #   --no-delete-branch   Keep local branches after removing worktrees
    #   -h, --help           Show this help message
    #
    # ARGUMENTS
    #   worktrees-directory    Path to the directory containing git worktrees. Optional in a
    #                          canonical .bare layout (a directory with a sibling .bare/
    #                          directory), where it defaults to that layout's container
    #                          directory. Required otherwise.
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
    #   # In a canonical .bare layout, no path is needed; defaults to the container directory
    #   git wclean --dry-run
    #
    # CONFIGURATION
    #   Configuration files are loaded from (in order):
    #   1. ~/.config/git-wclean/config
    #   2. ~/.git-wclean-config
    #   3. ./.git-wclean-config
    #
    #   Example configuration file:
    #   # Protected branch names (space-separated)
    #   set -g _wclean_config_protected_branches main master develop staging trunk
    #
    #   # Override the integration branch (default: auto-detect from origin/HEAD).
    #   # Only set this if origin/HEAD cannot be used.
    #   set -g _wclean_config_default_upstream origin/main
    #
    #   # System directories to protect (space-separated)
    #   set -g _wclean_config_system_dirs /etc /bin /usr/bin /sbin /usr/sbin
    #
    #   # Maximum path length allowed
    #   set -g _wclean_config_max_path_length 4096
    #
    #   # Fetch timeout in seconds
    #   set -g _wclean_config_fetch_timeout 30
    #
    # SIGNAL HANDLING
    #   The script handles interruption signals (Ctrl+C, SIGTERM) gracefully:
    #   - Restores original working directory
    #   - Cleans up temporary global variables
    #   - Exits with appropriate status code (130 for SIGINT)
    #
    # EXIT STATUS
    #   0    Success
    #   1    Invalid arguments or directory not found
    #   2    Git command failed
    #   130  Interrupted by user (Ctrl+C)

    # Store original directory for cleanup
    set -g _wclean_original_dir (pwd)

    # Parse and validate arguments first: --check changes how config loads
    if not _wclean_parse_args $argv
        return 1
    end

    # --help is handled inside _wclean_parse_args (prints help, returns 0),
    # but argparse's _flag_help is local to that function's scope, so it
    # promotes _wclean_flag_help to a global (see the other _wclean_flag_*
    # promotions below) so we can detect it here and stop cleanly instead
    # of falling through into directory setup.
    if set -q _wclean_flag_help
        _wclean_normal_cleanup
        return 0
    end

    # --check: silent one-line nudge mode; never sources repo-local config
    if set -q _wclean_flag_check
        _git_wclean_config --quiet
        _wclean_run_check
        _wclean_normal_cleanup
        return 0
    end

    # Load configuration (full runs may opt into repo-local config)
    _git_wclean_config --allow-local

    # Staleness window: --stale-days flag beats config
    set -q _wclean_stale_days
    or set -g _wclean_stale_days $_wclean_config_stale_days

    # Fresh stale report per run: an earlier aborted run in the same shell
    # may have leaked the global, and set -ga would append across runs
    set -e _wclean_stale_report

    # Setup and validate directory
    if not _wclean_setup_directory
        return 1
    end

    # Fetch remote updates and determine the integration branch
    if not _wclean_fetch_remotes
        _wclean_normal_cleanup
        return 2
    end

    # Track statistics
    set -l processed_count 0
    set -l removed_count 0
    set -l skipped_count 0

    # Performance optimization: pre-scan and filter valid worktree directories
    set -l worktree_dirs
    for subdir in $_wclean_worktrees_dir/*/
        # Remove trailing slash
        set subdir (string trim -r -c '/' -- $subdir)
        # Quick validation to avoid processing invalid directories
        if test -d "$subdir"; and test -e "$subdir/.git"
            set -a worktree_dirs $subdir
        end
    end

    printf "Found %d potential worktrees to process.\n\n" (count $worktree_dirs)

    # Iterate through validated worktree directories
    for subdir in $worktree_dirs
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

    # Clean up before exit
    _wclean_normal_cleanup
    return 0
end
