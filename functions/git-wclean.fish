#!/usr/bin/env fish

# Signal handling for clean shutdown
function _wclean_cleanup --on-signal INT TERM
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

    # Clean up config variables
    set -e _wclean_config_protected_branches
    set -e _wclean_config_default_upstream
    set -e _wclean_config_system_dirs
    set -e _wclean_config_max_path_length
    set -e _wclean_config_fetch_timeout

    printf "\n\n🚫 Operation interrupted by user. Cleanup completed.\n" >&2
    exit 130 # Standard exit code for Ctrl+C
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

    # Clean up config variables
    set -e _wclean_config_protected_branches
    set -e _wclean_config_default_upstream
    set -e _wclean_config_system_dirs
    set -e _wclean_config_max_path_length
    set -e _wclean_config_fetch_timeout
end

# Configuration defaults and loading
function _wclean_load_config
    # Set default configuration values
    set -g _wclean_config_protected_branches main master develop trunk
    set -g _wclean_config_default_upstream origin/main
    set -g _wclean_config_system_dirs /etc /bin /usr/bin /sbin /usr/sbin
    set -g _wclean_config_max_path_length 4096
    set -g _wclean_config_fetch_timeout 30

    # Look for configuration files in order of preference
    set -l config_files ~/.config/git-wclean/config ~/.git-wclean-config ./.git-wclean-config

    for config_file in $config_files
        if test -f "$config_file"; and test -r "$config_file"
            printf "Loading configuration from: %s\n" $config_file
            source "$config_file"
            break
        end
    end
end

# Security validation helper function
function _wclean_validate_path
    set -l path $argv[1]
    set -l path_type $argv[2] # Optional description for error messages

    if test -z "$path_type"
        set path_type path
    end

    # Check for path traversal attempts
    if string match -q '*/..*' "$path"
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

    # Security validation: Prevent operations on system directories
    for system_dir in $_wclean_config_system_dirs
        if string match -q "$system_dir/*" "$_wclean_worktrees_dir"
            printf "Error: Operation not allowed on system directory '%s'.\n" $system_dir >&2
            return 1
        end
    end

    # Security validation: Ensure we have write permissions if not in dry-run mode
    if not set -q _flag_dry_run; and not test -w "$_wclean_worktrees_dir"
        printf "Error: No write permission for directory '%s'. Use --dry-run to preview.\n" $_wclean_worktrees_dir >&2
        return 1
    end

    printf "Scanning worktrees in: %s\n" $_wclean_worktrees_dir

    if set -q _flag_dry_run
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

    # Try to fetch from origin if it exists (with timeout)
    if contains origin $_wclean_remotes
        printf "Fetching from origin (timeout: %ds)...\n" $_wclean_config_fetch_timeout
        if timeout $_wclean_config_fetch_timeout git fetch origin >/dev/null 2>&1
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
        printf "⚠️  Note: No 'origin' remote found.\n"
    end

    # Cache default branch information for better performance
    set -g _wclean_default_branch (git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | string replace 'refs/remotes/' '')
    if test $status -ne 0; or test -z "$_wclean_default_branch"
        set -g _wclean_default_branch $_wclean_config_default_upstream
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

    # Determine the upstream branch
    set -l upstream_branch (git -C "$worktree_path" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)
    if test $status -ne 0
        # Use cached default branch instead of hardcoded origin/main
        set upstream_branch $_wclean_default_branch
        printf "  No upstream branch configured, using %s as default.\n" $upstream_branch
    else
        printf "  Upstream branch: %s\n" $upstream_branch
    end

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
    if contains "$worktree_name" $_wclean_config_protected_branches; and not set -q _flag_force
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
    #   # Default upstream branch when none is configured
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

    # Load configuration first
    _wclean_load_config

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
