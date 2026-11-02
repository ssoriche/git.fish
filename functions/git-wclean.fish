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
    set -e _wclean_plan_rows
    set -e _wclean_exec_counts

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
    set -e _wclean_plan_rows
    set -e _wclean_exec_counts

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
        printf "Dry run: nothing will be removed.\n"
    end
    return 0
end

# Helper function to fetch remote updates and cache remote info
function _wclean_fetch_remotes

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

    # Determine the integration branch. An explicit config override takes
    # precedence; otherwise require origin/HEAD rather than silently assuming
    # origin/main, which could delete unmerged work.
    if test -n "$_wclean_config_default_upstream"
        set -g _wclean_default_branch $_wclean_config_default_upstream
    else
        set -g _wclean_default_branch (git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | string replace 'refs/remotes/' '')
        if test -z "$_wclean_default_branch"
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

# Remove one worktree from the main repository. Quiet: the caller prints the
# result line. Returns 0 on success, 3 for a protected name, 4 when the path
# is the main repository itself, 1 for any other failure.
function _wclean_remove_worktree
    set -l worktree_path $argv[1]
    set -l main_repo $argv[2]

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
        return 3
    end

    # Don't remove the main repository itself
    set -l subdir_real (realpath "$worktree_path" 2>/dev/null || echo "$worktree_path")
    set -l main_repo_real (realpath "$main_repo" 2>/dev/null || echo "$main_repo")

    if test "$subdir_real" = "$main_repo_real"
        return 4
    end

    # Change to main repository to run worktree remove
    pushd "$main_repo" >/dev/null
    or begin
        printf "  Error: Cannot access main repository '%s' for worktree removal.\n" $main_repo >&2
        return 1
    end

    git worktree remove --force "$worktree_name" >/dev/null 2>&1
    set -l rc $status
    popd >/dev/null
    test $rc -eq 0; or return 1
    return 0
end

# Delete a local branch from the main repository. Prints a short phrase for
# the caller's result line ("branch X deleted", "branch X not found", ...)
# and returns 0 unless the deletion was attempted and failed.
function _wclean_remove_branch
    set -l main_repo $argv[1]
    set -l branch_name $argv[2]

    if test -z "$branch_name"
        printf "no branch to delete"
        return 1
    end

    if not git -C "$main_repo" rev-parse --verify "refs/heads/$branch_name" >/dev/null 2>&1
        printf "branch %s not found" $branch_name
        return 0
    end
    if git -C "$main_repo" branch -d "$branch_name" >/dev/null 2>&1
        printf "branch %s deleted" $branch_name
        return 0
    end
    if git -C "$main_repo" branch -D "$branch_name" >/dev/null 2>&1
        printf "branch %s force-deleted" $branch_name
        return 0
    end
    printf "failed to delete branch %s" $branch_name
    return 1
end

# Plan one worktree: classify it with the shared classifier and append a
# tab-separated row to _wclean_plan_rows describing what wclean will do.
# Row fields: order, age_key, verdict, state, age, name, branch, text, path.
#   verdict  remove  — removed without asking
#            confirm — removed after a y/N prompt (--force skips it)
#            keep    — never removed; text is the reason
#   text     the ACTION (remove/confirm) or REASON (keep) column
function _wclean_plan_worktree
    set -l worktree_path $argv[1]

    if test -z "$worktree_path"
        printf "Error: No worktree path provided for processing\n" >&2
        return 1
    end

    if not _wclean_validate_path "$worktree_path" "worktree path"
        return 1
    end

    if not test -d "$worktree_path"; or not test -e "$worktree_path/.git"
        return 1
    end

    set -l name (basename $worktree_path)

    # --force preserves the documented escape hatch by classifying with an
    # empty protected list, so protected worktrees fall through to the normal
    # rules (the basename guard in _wclean_remove_worktree is force-gated too)
    set -l protected_list $_wclean_config_protected_branches
    set -q _wclean_flag_force; and set protected_list

    set -l line (_git_worktree_status "$worktree_path" "$_wclean_default_branch" \
        $_wclean_stale_days $protected_list)
    # Guard against an empty classifier line: string split's implicit-stdin
    # form (no args after --) would otherwise read from stdin and consume a
    # piped y/n confirmation intended for the read -P prompt later.
    test -z "$line"; and set line (printf 'error\t-\t-\t-\t-\t%s' "$worktree_path")
    set -l f (string split \t -- $line)
    set -l state $f[1]
    set -l branch $f[2]
    set -l dirty $f[4]
    set -l age $f[5]

    # What removal would do to the branch, shared by every removable state
    set -l remove_action remove
    if test -n "$branch"; and test "$branch" != -
        set remove_action "remove, delete branch"
        set -q _wclean_flag_no_delete_branch; and set remove_action "remove, keep branch"
    end

    set -l verdict keep
    set -l text
    switch $state
        case merged
            if test "$dirty" = dirty
                set text "uncommitted changes"
            else
                set verdict remove
                set text $remove_action
            end
        case gone pr-closed
            if test "$dirty" = dirty
                set text "uncommitted changes"
            else if set -q _wclean_flag_force
                set verdict remove
                set text $remove_action
            else
                set verdict confirm
                set text "remove after confirm"
            end
        case stale
            set text "stale, review manually"
        case protected
            set text protected
        case detached
            set text "detached HEAD"
        case error
            set text "could not classify"
        case '*'
            set text "not merged"
    end

    # Sort keys: wlist's state order, then oldest first; error rows carry '-'
    set -l state_order merged pr-closed gone stale error detached active protected
    set -l order (contains -i -- $state $state_order)
    or set order 9
    set -l age_key $age
    set -l age_disp "$age"d
    if test "$age" = -
        set age_key 0
        set age_disp -
    end

    set -ga _wclean_plan_rows (printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        $order $age_key $verdict $state $age_disp $name $branch $text $worktree_path)
    return 0
end

# Print the plan rows whose verdict is in $argv, sorted by state order then
# oldest first — the single ordering shared by the tables and the execution
# pass, so results appear in the same order the plan listed them.
function _wclean_plan_rows_for
    set -l verdicts $argv
    for row in $_wclean_plan_rows
        set -l f (string split \t -- $row)
        contains -- $f[3] $verdicts; and printf '%s\n' $row
    end | sort -t \t -k1,1n -k2,2nr
end

# Render one aligned table (NAME BRANCH STATE AGE <last_col>) from plan rows
function _wclean_render_table
    set -l heading $argv[1]
    set -l last_col $argv[2]
    set -l rows $argv[3..]

    printf '%s\n' $heading
    begin
        printf 'NAME\tBRANCH\tSTATE\tAGE\t%s\n' $last_col
        for row in $rows
            set -l f (string split \t -- $row)
            printf '%s\t%s\t%s\t%s\t%s\n' $f[6] $f[7] $f[4] $f[5] $f[8]
        end
    end | column -t -s \t
end

# Render the plan: the removal table (or a one-line "nothing") and the kept
# table. Identical in dry-run and real runs apart from the heading verb.
function _wclean_render_plan
    set -l remove_rows (_wclean_plan_rows_for remove confirm)
    set -l keep_rows (_wclean_plan_rows_for keep)

    if test (count $remove_rows) -gt 0
        set -l verb Removing
        set -q _wclean_flag_dry_run; and set verb "Would remove"
        _wclean_render_table "$verb ("(count $remove_rows)")" ACTION $remove_rows
    else
        printf "Nothing to remove.\n"
    end

    if test (count $keep_rows) -gt 0
        printf '\n'
        _wclean_render_table "Kept ("(count $keep_rows)")" REASON $keep_rows
    end
end

# Execute the plan: one result line per planned removal, prompting inline for
# confirm rows. Outcomes accumulate in _wclean_exec_counts as
# merged gone pr-closed declined failed.
function _wclean_execute_plan
    set -g _wclean_exec_counts 0 0 0 0 0
    set -l rows (_wclean_plan_rows_for remove confirm)
    test (count $rows) -gt 0; or return 0

    printf '\n'
    for row in $rows
        set -l f (string split \t -- $row)
        set -l verdict $f[3]
        set -l state $f[4]
        set -l name $f[6]
        set -l branch $f[7]
        set -l path $f[9]
        test "$branch" = -; and set branch ""

        if test $verdict = confirm
            set -l reason "upstream gone"
            test $state = pr-closed; and set reason "PR merged/closed"
            read -l -P "Remove '$name' ($reason)? [y/N] " reply
            if not string match -qi y -- "$reply"
                printf "%s kept (declined)\n" "- $name"
                set _wclean_exec_counts[4] (math $_wclean_exec_counts[4] + 1)
                continue
            end
        end

        if not _wclean_find_main_repo "$path"
            printf "✗ %s not removed (cannot locate the main repository)\n" $name
            set _wclean_exec_counts[5] (math $_wclean_exec_counts[5] + 1)
            continue
        end

        _wclean_remove_worktree "$path" "$_wclean_main_repo"
        set -l rc $status
        if test $rc -ne 0
            set -l why "git worktree remove failed"
            test $rc -eq 3; and set why "protected name"
            test $rc -eq 4; and set why "this is the main repository"
            printf "✗ %s not removed (%s)\n" $name $why
            set _wclean_exec_counts[5] (math $_wclean_exec_counts[5] + 1)
            continue
        end

        set -l detail removed
        if test -n "$branch"
            if set -q _wclean_flag_no_delete_branch
                set detail "removed, branch $branch kept"
            else
                set detail "removed, "(_wclean_remove_branch "$_wclean_main_repo" "$branch")
            end
        end
        printf "✓ %s %s\n" $name $detail

        switch $state
            case merged
                set _wclean_exec_counts[1] (math $_wclean_exec_counts[1] + 1)
            case gone
                set _wclean_exec_counts[2] (math $_wclean_exec_counts[2] + 1)
            case pr-closed
                set _wclean_exec_counts[3] (math $_wclean_exec_counts[3] + 1)
        end
    end
end

# Join "<n> <label>" parts for the non-zero counts, in the given label order
function _wclean_breakdown
    set -l parts
    for pair in $argv
        set -l p (string split -m1 ' ' -- $pair)
        if test $p[1] -gt 0
            set -a parts "$p[1] $p[2]"
        end
    end
    string join ', ' $parts
end

# Two-line summary: what was (or would be) removed, and why the rest stayed
function _wclean_show_summary
    set -l total $argv[1]
    set -l remove_rows (_wclean_plan_rows_for remove confirm)
    set -l planned (count $remove_rows)

    # Planned removals by state
    set -l n_merged 0
    set -l n_gone 0
    set -l n_pr 0
    set -l n_confirm 0
    for row in $remove_rows
        set -l f (string split \t -- $row)
        test $f[3] = confirm; and set n_confirm (math $n_confirm + 1)
        switch $f[4]
            case merged
                set n_merged (math $n_merged + 1)
            case gone
                set n_gone (math $n_gone + 1)
            case pr-closed
                set n_pr (math $n_pr + 1)
        end
    end

    # Kept rows by reason text
    set -l n_dirty 0
    set -l n_stale 0
    set -l n_active 0
    set -l n_protected 0
    set -l n_detached 0
    set -l n_error 0
    for row in (_wclean_plan_rows_for keep)
        set -l f (string split \t -- $row)
        switch $f[8]
            case 'uncommitted changes'
                set n_dirty (math $n_dirty + 1)
            case 'stale, review manually'
                set n_stale (math $n_stale + 1)
            case protected
                set n_protected (math $n_protected + 1)
            case 'detached HEAD'
                set n_detached (math $n_detached + 1)
            case 'could not classify'
                set n_error (math $n_error + 1)
            case '*'
                set n_active (math $n_active + 1)
        end
    end

    printf '\n'
    set -l n_declined 0
    set -l n_failed 0
    if set -q _wclean_flag_dry_run
        if test $planned -gt 0
            set -l breakdown (_wclean_breakdown "$n_merged merged" "$n_gone gone" \
                "$n_pr pr-closed")
            test $n_confirm -gt 0; and set breakdown "$breakdown (confirm each)"
            printf "Would remove %d of %d: %s.\n" $planned $total $breakdown
        else
            printf "Nothing to remove.\n"
        end
    else
        set -l c $_wclean_exec_counts
        set -q c[5]; or set c 0 0 0 0 0
        set n_declined $c[4]
        set n_failed $c[5]
        set -l removed (math $c[1] + $c[2] + $c[3])
        if test $planned -gt 0
            set -l breakdown (_wclean_breakdown "$c[1] merged" "$c[2] gone" "$c[3] pr-closed")
            test -n "$breakdown"; and set breakdown ": $breakdown"
            printf "Removed %d of %d%s.\n" $removed $planned "$breakdown"
        else
            printf "Nothing to remove.\n"
        end
    end

    set -l kept (math $total - $planned + $n_declined + $n_failed)
    if test $kept -gt 0
        printf "Kept %d: %s.\n" $kept (_wclean_breakdown "$n_dirty uncommitted changes" \
            "$n_stale stale" "$n_active active" "$n_protected protected" \
            "$n_detached detached" "$n_error unclassified" "$n_declined declined" \
            "$n_failed failed")
    end
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

    # Integration branch: config override wins; otherwise origin/HEAD
    set -l integration_branch $_wclean_config_default_upstream
    if test -z "$integration_branch"
        set integration_branch (git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
            | string replace 'refs/remotes/' '')
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
    #   Beyond ancestry-merged worktrees, wclean also detects worktrees whose
    #   upstream branch was deleted on the remote ('gone', the usual squash-merge
    #   aftermath) and, for github.com remotes with gh installed, worktrees whose
    #   PR is merged or closed. Both are removed only after a per-worktree y/N
    #   confirmation (--force skips the prompt). Worktrees with uncommitted
    #   changes are never removed, in any state, even with --force. Worktrees
    #   older than the staleness window are reported for manual review and never
    #   auto-removed.
    #
    #   Output is a plan, in the same table layout as git-wlist: a "Removing"
    #   (or, with --dry-run, "Would remove") table with an ACTION column, then a
    #   "Kept" table with a REASON column, both sorted by state and oldest
    #   first. A real run then prints one result line per removal (✓ removed,
    #   - kept (declined), ✗ not removed) and a two-line summary.
    #
    # OPTIONS
    #   -n, --dry-run        Show what would be removed without actually removing anything
    #   -f, --force          Force removal including protected worktrees (use with caution)
    #   --no-delete-branch   Keep local branches after removing worktrees
    #   -s, --stale-days N   Staleness window in days (default 30)
    #   --check              Print a one-line summary of reapable worktrees and
    #                        exit 0; silent when there is nothing to reap. For
    #                        fish_greeting/prompt hooks. Cannot be combined with
    #                        other options or arguments.
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
    #   Configuration files are loaded from (first match wins):
    #   1. ~/.config/git-wclean/config
    #   2. ~/.git-wclean-config
    #   3. ./.git-wclean-config   (full runs only; git-wlist and --check never
    #      source repo-local config)
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
    #   # Staleness window in days for the 'stale' state
    #   set -g _wclean_config_stale_days 30
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
    #
    #   Under --check, runtime conditions (not a repo, fetch failure) always
    #   exit 0; only invalid flag combinations exit 1.

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

    # Fresh plan per run: an earlier aborted run in the same shell may have
    # leaked these globals
    set -g _wclean_plan_rows
    set -e _wclean_exec_counts

    # Setup and validate directory
    if not _wclean_setup_directory
        return 1
    end

    # Fetch remote updates and determine the integration branch
    if not _wclean_fetch_remotes
        _wclean_normal_cleanup
        return 2
    end

    # Pre-scan: only directories that look like worktrees are planned
    set -l worktree_dirs
    for subdir in $_wclean_worktrees_dir/*/
        set subdir (string trim -r -c '/' -- $subdir)
        if test -d "$subdir"; and test -e "$subdir/.git"
            set -a worktree_dirs $subdir
        end
    end

    # Plan everything first (read-only), show the plan, then act on it
    for subdir in $worktree_dirs
        _wclean_plan_worktree "$subdir"
    end
    _wclean_render_plan
    if not set -q _wclean_flag_dry_run
        _wclean_execute_plan
    end
    _wclean_show_summary (count $worktree_dirs)

    # Clean up before exit
    _wclean_normal_cleanup
    return 0
end
