function git-bclean --description "Clean up local branches that have been merged to upstream"
    # Git Branch Clean - Removes local branches that have been merged to upstream branch
    #
    # SYNOPSIS
    #   git-bclean [OPTIONS]
    #   git bclean [OPTIONS]
    #
    # DESCRIPTION
    #   This command finds and removes local branches whose commits have been merged
    #   into the upstream branch (typically origin/main). This helps keep your local
    #   repository clean by removing branches that are no longer needed after merging.
    #
    #   The command will:
    #   1. Determine the upstream branch (falls back to origin/main if not set)
    #   2. Fetch the latest changes from the remote
    #   3. Find local branches that have been merged to upstream
    #   4. Exclude protected branches (current, main, master, develop)
    #   5. Remove only safely merged branches
    #
    # OPTIONS
    #   -n, --dry-run        Show what would be removed without actually removing anything
    #   -f, --force          Also remove branches that aren't fully merged (use with caution)
    #   -s, --skip           Skip branches matching pattern (supports globs, can be used multiple times)
    #   -h, --help           Show this help message
    #
    # EXAMPLES
    #   # Clean up merged branches
    #   git-bclean
    #
    #   # Preview what would be removed
    #   git-bclean --dry-run
    #
    #   # Skip specific branches
    #   git-bclean --skip staging --skip release
    #
    #   # Skip branches matching patterns
    #   git-bclean --skip "feature/*" --skip "*-wip"
    #
    #   # Skip multiple branches with comma-separated list
    #   git-bclean --skip "staging,release,hotfix/*"
    #
    #   # Force removal of unmerged branches too (dangerous!)
    #   git-bclean --force
    #
    #   # Can also be called as git subcommand
    #   git bclean --dry-run --skip staging
    #
    # EXIT STATUS
    #   0    Success
    #   1    Invalid arguments or not in a git repository
    #   2    Git command failed

    # Parse command line arguments
    argparse --name=git-bclean h/help n/dry-run f/force s/skip -- $argv
    or return 1

    # Show help if requested
    if set -q _flag_help
        printf '%s\n' (status function | head -n 1)
        printf '\n%s\n' (functions git-bclean | string match -r '#.*' | string trim -c '# ')
        return 0
    end

    # Check for unexpected arguments
    if test (count $argv) -gt 0
        printf "Error: Unexpected arguments. This command takes no arguments.\n" >&2
        printf "Usage: git-bclean [OPTIONS]\n" >&2
        printf "Try 'git-bclean --help' for more information.\n" >&2
        return 1
    end

    # Process skip patterns
    set -l skip_patterns
    if set -q _flag_skip
        for skip_option in $_flag_skip
            # Split comma-separated patterns and add them to the list
            for pattern in (string split ',' $skip_option)
                set pattern (string trim $pattern)
                if test -n "$pattern"
                    set -a skip_patterns $pattern
                end
            end
        end
    end

    # Check if we're in a git repository
    if not git rev-parse --git-dir >/dev/null 2>&1
        printf "Error: Not in a git repository.\n" >&2
        return 1
    end

    printf "Scanning for merged branches...\n"

    if set -q _flag_dry_run
        printf "DRY-RUN MODE: No branches will actually be removed.\n\n"
    end

    # Get current branch name
    set -l current_branch (git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if test $status -ne 0
        printf "Error: Failed to get current branch name.\n" >&2
        return 2
    end

    printf "Current branch: %s\n" $current_branch

    # Determine the upstream branch
    set -l upstream_branch (git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)
    if test $status -ne 0
        printf "No upstream branch configured, using origin/main as default.\n"
        set upstream_branch origin/main
    else
        printf "Upstream branch: %s\n" $upstream_branch
    end

    # Extract remote name from upstream branch
    set -l remote_name (string split '/' $upstream_branch)[1]
    set -l branch_name (string join '/' (string split '/' $upstream_branch)[2..-1])

    # Fetch latest from the remote
    printf "Fetching latest from %s...\n" $remote_name
    if not git fetch $remote_name $branch_name >/dev/null 2>&1
        printf "Warning: Failed to fetch from %s. Proceeding with local information.\n" $remote_name
    end

    # Show skip patterns if any are specified
    if test (count $skip_patterns) -gt 0
        printf "Active skip patterns: %s\n" (string join ', ' $skip_patterns)
    end

    # Protected branches that should never be deleted
    set -l protected_branches $current_branch main master develop

    # Track statistics
    set -l processed_count 0
    set -l removed_count 0
    set -l skipped_count 0

    # Get list of local branches (excluding current branch indicator)
    set -l all_branches (git branch | string trim | string replace -r '^\* ' '')

    printf "\nAnalyzing branches...\n"

    for branch in $all_branches
        set processed_count (math $processed_count + 1)

        # Check if branch matches any skip patterns
        set -l should_skip false
        for pattern in $skip_patterns
            if string match -q $pattern $branch
                set should_skip true
                break
            end
        end

        if test $should_skip = true
            printf "  Skipping (pattern matched): %s\n" $branch
            set skipped_count (math $skipped_count + 1)
            continue
        end

        # Skip protected branches
        if contains $branch $protected_branches
            printf "  Skipping protected branch: %s\n" $branch
            set skipped_count (math $skipped_count + 1)
            continue
        end

        printf "  Checking: %s " $branch

        # Check if all commits from the branch exist in upstream
        set -l is_merged false
        set -l branch_commits (git rev-list $branch --not $upstream_branch ^-1 2>/dev/null)
        if test -z "$branch_commits"
            set is_merged true
            printf "✓ (merged)\n"
        else
            printf "- (not merged)\n"
        end

        # Decide whether to remove the branch
        if test $is_merged = true -o (set -q _flag_force)
            if set -q _flag_dry_run
                if test $is_merged = true
                    printf "    Would remove: %s (merged)\n" $branch
                else
                    printf "    Would FORCE remove: %s (NOT merged - forced)\n" $branch
                end
                set removed_count (math $removed_count + 1)
            else
                if test $is_merged = false
                    printf "    WARNING: Force removing unmerged branch!\n"
                end

                printf "    Removing branch: %s\n" $branch
                if git branch -d $branch >/dev/null 2>&1
                    printf "    ✓ Successfully removed: %s\n" $branch
                    set removed_count (math $removed_count + 1)
                else if git branch -D $branch >/dev/null 2>&1
                    printf "    ✓ Force removed: %s (had unmerged changes)\n" $branch
                    set removed_count (math $removed_count + 1)
                else
                    printf "    Error: Failed to remove branch '%s'\n" $branch >&2
                    set skipped_count (math $skipped_count + 1)
                end
            end
        else
            printf "    Keeping: %s (not merged to %s)\n" $branch $upstream_branch
            set skipped_count (math $skipped_count + 1)
        end
    end

    # Print summary
    printf "\nSummary:\n"
    printf "  Processed: %d branches\n" $processed_count
    if set -q _flag_dry_run
        printf "  Would remove: %d branches\n" $removed_count
    else
        printf "  Removed: %d branches\n" $removed_count
    end
    printf "  Kept/Skipped: %d branches\n" $skipped_count

    printf "\nBranch cleanup completed!\n"
    return 0
end
