function git-wrm --description "Remove a git worktree after verifying commits are merged upstream"
    # Git Worktree Remove - Safely removes a worktree after checking if commits are merged
    #
    # SYNOPSIS
    #   git-wrm [OPTIONS] <worktree-path>
    #   git wrm [OPTIONS] <worktree-path>
    #
    #   In a canonical .bare layout, <worktree-path> is interpreted as a container-
    #   anchored worktree name, not a path (see ARGUMENTS for the exact restriction).
    #
    # DESCRIPTION
    #   This command removes a git worktree after verifying that its current HEAD commit
    #   has been merged into the upstream project's default branch (origin/HEAD, e.g.
    #   origin/main or origin/master). This provides a safe way to remove worktrees
    #   without losing any unmerged work.
    #
    #   The command will:
    #   1. Verify the worktree exists and is a valid git repository
    #   2. Determine the integration branch from origin/HEAD (errors if it is unset;
    #      run 'git remote set-head origin --auto' to set it)
    #   3. Fetch the latest changes from the remote
    #   4. Check if the current HEAD commit is merged into the integration branch
    #   5. Remove the worktree only if the commit has been merged
    #
    # OPTIONS
    #   -n, --dry-run        Show what would be removed without actually removing anything
    #   -f, --force          Remove worktree even if commits are not merged upstream
    #   --no-delete-branch   Keep the local branch after removing worktree
    #   -h, --help           Show this help message
    #
    # ARGUMENTS
    #   worktree-path    Path to the worktree directory to remove. In a canonical .bare
    #                    layout (a directory with a sibling .bare/ directory), this is
    #                    instead a single name anchored under the container directory,
    #                    not a path: rejected if empty/whitespace-only, contains '/',
    #                    is '.' or '..', or starts with '-'. Outside a .bare layout,
    #                    used as-is (a path).
    #
    # EXAMPLES
    #   # Remove a worktree after verifying it's merged
    #   git-wrm ~/worktrees/feature-branch
    #
    #   # See what would happen without actually removing
    #   git-wrm --dry-run ~/worktrees/feature-branch
    #
    #   # Force removal even if not merged (use with caution!)
    #   git-wrm --force ~/worktrees/experimental
    #
    #   # Remove worktree but keep the local branch
    #   git-wrm --no-delete-branch ~/worktrees/feature-branch
    #
    #   # In a .bare layout, <worktree-path> is a name, not a path: pass the
    #   # worktree's name as it appears alongside .bare/, e.g.
    #   git-wrm feature-branch
    #
    #   # Can also be called as git subcommand
    #   git wrm ~/worktrees/feature-branch
    #
    # EXIT STATUS
    #   0    Success - worktree was removed or would be removed (dry-run)
    #   1    Invalid arguments or worktree not found
    #   2    Git command failed
    #   3    Commits not merged upstream (use --force to override)

    # Parse command line arguments
    argparse --name=git-wrm h/help n/dry-run f/force no-delete-branch -- $argv
    or return 1

    # Show help if requested
    if set -q _flag_help
        _git_help_from_doc_comment git-wrm
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
    set -l worktree_arg $argv[1]

    # Layout-aware: in a .bare layout, treat the arg as a worktree NAME, anchored to the
    # container directory via the shared resolver (see _git_bare_worktree_path).
    set -l worktree_path (_git_bare_worktree_path $worktree_arg)
    if test $status -ne 0
        printf "Error: invalid worktree name '%s'.\n" $worktree_arg >&2
        printf "In a bare layout, worktree names cannot contain '/', be '.' or '..', or\n" >&2
        printf "start with '-' (try using '.' or '-' as an internal separator).\n" >&2
        return 1
    end

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

    # Check if it's a Git repository (worktrees have .git as a file, not directory)
    if not test -e "$worktree_path/.git"
        printf "Error: '%s' is not a git repository.\n" $worktree_path >&2
        return 1
    end

    printf "Checking worktree: %s\n" (basename $worktree_path)

    if set -q _flag_dry_run
        printf "DRY-RUN MODE: Worktree will not actually be removed.\n\n"
    end

    # Note: Fish shell signal handling is different from bash
    # Ctrl-C will naturally interrupt the script

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
    # For worktrees, we need to find the actual main repository, not just the current toplevel
    set -l git_common_dir (git rev-parse --git-common-dir 2>/dev/null)
    if test $status -ne 0
        printf "Error: Failed to find git directory.\n" >&2
        popd >/dev/null
        return 2
    end

    # If git-common-dir is relative, make it absolute from the current worktree
    if not string match -q '/*' "$git_common_dir"
        set git_common_dir "$worktree_path/$git_common_dir"
    end

    # The main repository is the parent of the .git directory
    set -l main_repo (dirname "$git_common_dir")

    # Validate that we found a reasonable main repository path
    if not test -d "$main_repo"
        printf "Error: Could not determine main repository path.\n" >&2
        popd >/dev/null
        return 2
    end

    # Get worktree name for removal
    set -l worktree_name (basename $worktree_path)

    # Get the current branch name in the worktree for potential deletion
    set -l current_branch_name (git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if test $status -ne 0
        set current_branch_name ""
    end

    # Protect main worktrees from accidental removal (unless --force is used)
    set -l worktree_name (basename "$worktree_path")
    if contains "$worktree_name" main master develop trunk; and not set -q _flag_force
        printf "Error: Protected worktree '%s' will not be removed for safety.\n" $worktree_name >&2
        printf "Tip: Use --force to override protection (not recommended).\n" >&2
        popd >/dev/null
        return 1
    end

    # Don't remove the main repository itself
    if test "$worktree_path" = "$main_repo"
        printf "Error: Cannot remove the main repository. Use a worktree path instead.\n" >&2
        popd >/dev/null
        return 1
    end

    # Determine the integration branch to verify against: the upstream
    # project's default branch (origin/HEAD, e.g. origin/main or origin/master).
    # This is deliberately NOT the worktree branch's own remote-tracking branch
    # (@{upstream}) — a feature branch pushed to origin/<feature> would always
    # "match" itself and defeat the merge check.
    #
    # Require origin/HEAD rather than silently assuming origin/main: guessing
    # the wrong branch would make the merge check meaningless and risk deleting
    # unmerged work.
    set -l upstream_branch (git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | string replace 'refs/remotes/' '')
    if test -z "$upstream_branch"
        printf "Error: Cannot determine the default branch — 'origin/HEAD' is not set.\n" >&2
        printf "Set it (and retry) with:\n" >&2
        printf "    git remote set-head origin --auto\n" >&2
        popd >/dev/null
        return 2
    end
    printf "  Integration branch: %s\n" $upstream_branch

    # Extract remote name from the integration branch
    set -l remote_name (string split '/' $upstream_branch)[1]
    set -l branch_name (string join '/' (string split '/' $upstream_branch)[2..-1])

    # Fetch latest from the remote so the merge check uses up-to-date refs.
    # Guard against a slow, unreachable, or interactive remote with a timeout
    # utility when available (`timeout` on Linux, `gtimeout` from GNU coreutils
    # on macOS); otherwise fetch without a guard rather than failing.
    set -l fetch_timeout 30
    set -l timeout_cmd
    if command -q timeout
        set timeout_cmd timeout
    else if command -q gtimeout
        set timeout_cmd gtimeout
    end
    printf "  Fetching latest from %s...\n" $remote_name
    if test -n "$timeout_cmd"
        if not $timeout_cmd $fetch_timeout git fetch $remote_name $branch_name >/dev/null 2>&1
            printf "  Warning: Failed to fetch from %s. Proceeding with local information.\n" $remote_name
        end
    else
        if not git fetch $remote_name $branch_name >/dev/null 2>&1
            printf "  Warning: Failed to fetch from %s. Proceeding with local information.\n" $remote_name
        end
    end

    # Check whether HEAD is already contained in the integration branch.
    # rev-list lists commits reachable from HEAD but not from the integration
    # branch; empty output means HEAD is fully merged. A rev-list error must
    # NOT be treated as "merged", or the safety check becomes a no-op.
    set -l commit_found false
    set -l branch_commits (git rev-list $head_commit --not $upstream_branch 2>/dev/null)
    if test $status -ne 0
        printf "  ✗ Failed to check merge status against %s.\n" $upstream_branch >&2
    else if test -z "$branch_commits"
        set commit_found true
        printf "  ✓ Commit is merged into %s.\n" $upstream_branch
    else
        printf "  ✗ Commit NOT merged into %s.\n" $upstream_branch
    end

    popd >/dev/null

    # Decide whether to remove the worktree
    if test $commit_found = true; or set -q _flag_force
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

            # Show branch deletion info
            if test -n "$current_branch_name"; and not set -q _flag_no_delete_branch
                printf "Would also delete local branch: %s\n" $current_branch_name
            else if set -q _flag_no_delete_branch
                printf "Would keep local branch: %s\n" $current_branch_name
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

                # Remove the associated local branch unless --no-delete-branch is specified
                if test -n "$current_branch_name"; and not set -q _flag_no_delete_branch
                    printf "Removing associated local branch '%s'...\n" $current_branch_name

                    # Check if the branch exists locally
                    if git branch --list "$current_branch_name" | string match -q "*$current_branch_name*"
                        if git branch -d "$current_branch_name" >/dev/null 2>&1
                            printf "✓ Successfully deleted local branch: %s\n" $current_branch_name
                        else if git branch -D "$current_branch_name" >/dev/null 2>&1
                            printf "✓ Force deleted local branch: %s (had unmerged changes)\n" $current_branch_name
                        else
                            printf "Warning: Failed to delete local branch '%s'. You may need to delete it manually.\n" $current_branch_name >&2
                        end
                    else
                        printf "Local branch '%s' not found, skipping deletion.\n" $current_branch_name
                    end
                else if test -n "$current_branch_name"
                    printf "Keeping local branch '%s' as requested.\n" $current_branch_name
                end

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
