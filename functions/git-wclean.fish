#!/usr/bin/env fish

# Signal handling for clean shutdown - shared cleanup logic
function _wclean_cleanup_handler
    # Restore original directory if we're in a different one. Skip the cd
    # entirely when we're already there: fish fires PWD event handlers
    # (zoxide, direnv, user hooks) even on a same-directory cd, and their
    # noise must never reach a --check invocation from fish_greeting.
    if set -q _wclean_original_dir
        and test -d "$_wclean_original_dir"
        and test "$PWD" != "$_wclean_original_dir"
        cd "$_wclean_original_dir" 2>/dev/null
    end

    # Clean up any global variables we set
    set -e _wclean_worktrees_dir
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
    set -e _wclean_count_merged
    set -e _wclean_count_gone
    set -e _wclean_count_pr_closed
    set -e _wclean_count_dirty_kept

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
    # Restore original directory. Skip the cd when we're already there: see
    # the matching comment in _wclean_cleanup_handler for why (PWD hooks).
    if set -q _wclean_original_dir
        and test -d "$_wclean_original_dir"
        and test "$PWD" != "$_wclean_original_dir"
        cd "$_wclean_original_dir" 2>/dev/null
    end

    # Clean up global variables
    set -e _wclean_worktrees_dir
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
    set -e _wclean_count_merged
    set -e _wclean_count_gone
    set -e _wclean_count_pr_closed
    set -e _wclean_count_dirty_kept

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
            if $timeout_cmd $_wclean_config_fetch_timeout git fetch --prune origin >/dev/null 2>&1
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
            if git fetch --prune origin >/dev/null 2>&1
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

# Helper function to bump the per-category summary counter matching a
# classifier state ('gone' or 'pr-closed'; 'merged' and dirty-kept are
# incremented inline since they have only one counter each).
function _wclean_bump_state_count
    set -l state $argv[1]
    if test "$state" = gone
        set -g _wclean_count_gone (math $_wclean_count_gone + 1)
    else
        set -g _wclean_count_pr_closed (math $_wclean_count_pr_closed + 1)
    end
end

# Helper function to process a single worktree, driven by the shared classifier.
# Returns 0 when the worktree was removed (or would be, in dry-run), 1 otherwise.
function _wclean_process_worktree
    set -l worktree_path $argv[1]

    if test -z "$worktree_path"
        printf "Error: No worktree path provided for processing\n" >&2
        return 1
    end

    if not _wclean_validate_path "$worktree_path" "worktree path"
        return 1
    end

    if not test -d "$worktree_path"
        return 1
    end

    if not test -e "$worktree_path/.git"
        printf "Skipping '%s': Not a git repository.\n" (basename $worktree_path)
        return 1
    end

    set -l name (basename $worktree_path)
    printf "Processing: %s\n" $name

    # --force preserves the documented escape hatch by classifying with an
    # empty protected list, so protected worktrees fall through to the normal
    # rules (the basename guard in _wclean_remove_worktree is force-gated too)
    set -l protected_list $_wclean_config_protected_branches
    set -q _wclean_flag_force; and set protected_list

    set -l line (_git_worktree_status "$worktree_path" "$_wclean_default_branch" \
        $_wclean_stale_days $protected_list)
    # Guard against an empty classifier line: string split's implicit-stdin
    # form (no args after --) would otherwise read from stdin and consume a
    # piped y/n confirmation intended for the read -P prompt below.
    test -z "$line"; and set line (printf 'error\t-\t-\t-\t-\t%s' "$worktree_path")
    set -l f (string split \t -- $line)
    set -l state $f[1]
    set -l branch $f[2]
    test "$branch" = -; and set branch ""
    set -l dirty $f[4]
    set -l age $f[5]

    switch $state
        case merged
            if test "$dirty" = dirty
                printf "  ✗ Merged into %s but has uncommitted changes. Keeping worktree.\n" \
                    $_wclean_default_branch
                set -g _wclean_count_dirty_kept (math $_wclean_count_dirty_kept + 1)
                return 1
            end
            printf "  ✓ Merged into %s.\n" $_wclean_default_branch
            if not _wclean_find_main_repo "$worktree_path"
                return 1
            end
            if _wclean_remove_worktree "$worktree_path" "$_wclean_main_repo" "$branch"
                set -g _wclean_count_merged (math $_wclean_count_merged + 1)
                return 0
            end
            return 1
        case gone pr-closed
            set -l reason "upstream gone"
            test $state = pr-closed; and set reason "PR merged/closed"
            if test "$dirty" = dirty
                printf "  ✗ %s but has uncommitted changes. Keeping worktree.\n" $reason
                set -g _wclean_count_dirty_kept (math $_wclean_count_dirty_kept + 1)
                return 1
            end
            # Printed before the prompt: read -P shows nothing on non-tty
            # stdin, so this line is the only visible removal-candidate signal
            printf "  Candidate: %s (%s)\n" $name $reason
            if set -q _wclean_flag_dry_run
                printf "Would remove worktree: %s (needs confirm: %s)\n" $name $reason
                _wclean_bump_state_count $state
                return 0
            end
            if not set -q _wclean_flag_force
                read -l -P "Remove '$name' ($reason)? [y/N] " reply
                if not string match -qi y -- "$reply"
                    printf "  Keeping worktree.\n"
                    return 1
                end
            end
            if not _wclean_find_main_repo "$worktree_path"
                return 1
            end
            if _wclean_remove_worktree "$worktree_path" "$_wclean_main_repo" "$branch"
                _wclean_bump_state_count $state
                return 0
            end
            return 1
        case stale
            printf "  - Stale (%sd, threshold %sd). Review manually; never auto-removed.\n" \
                $age $_wclean_stale_days
            set -ga _wclean_stale_report "$name ($age"d")"
            return 1
        case protected
            printf "  Protected: '%s' worktree will not be removed for safety.\n" $name
            return 1
        case detached
            printf "  - Detached HEAD. Keeping worktree.\n"
            return 1
        case error
            printf "  Error: could not classify worktree. Keeping it.\n" >&2
            return 1
        case '*'
            printf "  - Not merged (state: %s). Keeping worktree.\n" $state
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

    set -l cat_total (math $_wclean_count_merged + $_wclean_count_gone \
        + $_wclean_count_pr_closed + $_wclean_count_dirty_kept)
    if test $cat_total -gt 0
        set -l parts
        if test $_wclean_count_merged -gt 0
            set -a parts (printf '%d merged' $_wclean_count_merged)
        end
        if test $_wclean_count_gone -gt 0
            set -a parts (printf '%d gone' $_wclean_count_gone)
        end
        if test $_wclean_count_pr_closed -gt 0
            set -a parts (printf '%d pr-closed' $_wclean_count_pr_closed)
        end
        set -l breakdown (string join ', ' $parts)
        if test $_wclean_count_dirty_kept -gt 0
            if test -n "$breakdown"
                set breakdown "$breakdown ($_wclean_count_dirty_kept kept dirty)"
            else
                set breakdown "$_wclean_count_dirty_kept kept dirty"
            end
        end
        printf "  By category: %s\n" "$breakdown"
    end

    printf "  Kept/Skipped: %d worktrees\n" $skipped_count

    if set -q _wclean_stale_report[1]
        printf "\nStale — review manually:\n"
        for entry in $_wclean_stale_report
            printf "  %s\n" $entry
        end
    end

    printf "\nWorktree cleanup completed!\n"
end

# --check mode: at most one line on stdout, only when something is reapable.
# Every runtime failure is silent success — a prompt hook must never break
# the shell. Reapable = state in {merged, gone} AND clean; pr-closed is
# impossible here because classification always runs --no-forge (a hung gh
# call must never stall a prompt). Stale is appended only when reapable > 0.
function _wclean_run_check
    git rev-parse --git-dir >/dev/null 2>&1
    or return 0

    # Fetch guard: only fetch when a timeout utility exists — an unbounded
    # fetch is unacceptable in a prompt hook. Otherwise classify against the
    # last-fetched state. GIT_TERMINAL_PROMPT=0 stops git from talking to
    # /dev/tty directly for credentials — the timeout alone only bounds
    # duration, not interactivity, and a stalled or garbled prompt hook is
    # unacceptable.
    set -l timeout_cmd
    command -q timeout; and set timeout_cmd timeout
    test -z "$timeout_cmd"; and command -q gtimeout; and set timeout_cmd gtimeout
    if contains origin (git remote 2>/dev/null); and test -n "$timeout_cmd"
        $timeout_cmd $_wclean_config_fetch_timeout env GIT_TERMINAL_PROMPT=0 \
            git fetch --prune origin >/dev/null 2>&1
    end

    set -l integration_branch (git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
        | string replace 'refs/remotes/' '')
    if test -z "$integration_branch"; and test -n "$_wclean_config_default_upstream"
        set integration_branch $_wclean_config_default_upstream
    end

    # Enumerate registered worktrees, skipping the bare repo entry
    set -l paths
    set -l current_path ""
    set -l is_bare 0
    for line in (git worktree list --porcelain 2>/dev/null)
        if string match -q 'worktree *' -- $line
            if test -n "$current_path"; and test $is_bare -eq 0
                set -a paths $current_path
            end
            set current_path (string replace 'worktree ' '' -- $line)
            set is_bare 0
        else if test "$line" = bare
            set is_bare 1
        end
    end
    if test -n "$current_path"; and test $is_bare -eq 0
        set -a paths $current_path
    end

    set -l merged_count 0
    set -l gone_count 0
    set -l stale_count 0
    for p in $paths
        set -l line (_git_worktree_status --no-forge "$p" "$integration_branch" \
            $_wclean_config_stale_days $_wclean_config_protected_branches)
        set -l f (string split \t -- $line)
        switch $f[1]
            case merged
                test "$f[4]" = clean; and set merged_count (math $merged_count + 1)
            case gone
                test "$f[4]" = clean; and set gone_count (math $gone_count + 1)
            case stale
                set stale_count (math $stale_count + 1)
        end
    end

    set -l reapable (math $merged_count + $gone_count)
    if test $reapable -gt 0
        set -l msg (printf "git-wclean: %d reapable (%d merged, %d gone)" \
            $reapable $merged_count $gone_count)
        if test $stale_count -gt 0
            set msg "$msg, $stale_count stale"
        end
        printf "%s — run 'git wclean'\n" $msg
    end
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

    # Fresh stale report and per-category counters per run: an earlier
    # aborted run in the same shell may have leaked these globals
    set -e _wclean_stale_report
    set -g _wclean_count_merged 0
    set -g _wclean_count_gone 0
    set -g _wclean_count_pr_closed 0
    set -g _wclean_count_dirty_kept 0

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
