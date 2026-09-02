function _git_worktree_status --description "Classify a git worktree's lifecycle state as one TSV line"
    # Git Worktree Status (private helper) - single source of truth for
    # "what state is this worktree in", consumed by git-wlist and git-wclean.
    #
    # SYNOPSIS
    #   _git_worktree_status [--no-forge] <worktree-path> <integration-branch> \
    #       <stale-days> [protected-branch ...]
    #
    # OUTPUT
    #   Exactly one tab-separated line on stdout:
    #     <state> <branch> <upstream> <dirty> <age-days> <path>
    #   state:    protected|detached|merged|pr-closed|gone|stale|active
    #             (first match wins, in that order), or error (see below)
    #   branch:   checked-out branch, or '-' for detached HEAD
    #   upstream: configured upstream ref, or '-' if none
    #   dirty:    clean|dirty (any uncommitted changes, untracked included);
    #             dirty is also reported when the status check itself fails
    #             (fail-safe)
    #   age-days: whole days since HEAD's committer date
    #
    #   If the path is not a resolvable worktree, prints
    #   'error	-	-	-	-	<path>' and returns 1. Callers must treat
    #   'error' as keep-and-report, never as a removal candidate.
    #
    # EXAMPLES
    #   # Classify one worktree against origin/main with a 30-day stale window
    #   _git_worktree_status ~/src/repo/feature-x origin/main 30 main master
    #
    #   # Hook-safe classification: never invoke gh (no pr-closed state)
    #   _git_worktree_status --no-forge ~/src/repo/feature-x origin/main 30
    #
    # NOTES
    #   - Performs no fetch and reads no config: callers run
    #     'git fetch --prune origin' first and pass everything explicitly.
    #   - An empty <integration-branch> skips the merged check (the other
    #     states still classify).
    #   - The only network call is 'gh pr view' for github.com remotes,
    #     disabled entirely by --no-forge; any gh failure falls through.
    argparse --name=_git_worktree_status no-forge -- $argv
    or return 1

    set -l worktree_path $argv[1]
    set -l integration_branch $argv[2]
    set -l stale_days $argv[3]
    set -l protected_branches $argv[4..-1]

    if not string match -qr '^\d+$' -- "$stale_days"
        printf 'error\t-\t-\t-\t-\t%s\n' "$worktree_path"
        return 1
    end

    if test -z "$worktree_path"; or not test -d "$worktree_path"; or not test -e "$worktree_path/.git"
        printf 'error\t-\t-\t-\t-\t%s\n' "$worktree_path"
        return 1
    end

    set -l head_commit (git -C "$worktree_path" rev-parse HEAD 2>/dev/null)
    if test $status -ne 0; or test -z "$head_commit"
        printf 'error\t-\t-\t-\t-\t%s\n' "$worktree_path"
        return 1
    end

    # Branch name; empty on detached HEAD
    set -l branch (git -C "$worktree_path" symbolic-ref --short -q HEAD 2>/dev/null)

    # Dirty: any staged, unstaged, or untracked changes. Fail-safe: if the
    # status check itself fails, report dirty rather than clean.
    set -l dirty clean
    set -l porcelain (git -C "$worktree_path" status --porcelain 2>/dev/null)
    if test $status -ne 0; or test -n "$porcelain"
        set dirty dirty
    end

    # Age in whole days since HEAD's committer date
    set -l age_days 0
    set -l head_epoch (git -C "$worktree_path" log -1 --format=%ct 2>/dev/null)
    if test -n "$head_epoch"
        set -l now (date +%s)
        set age_days (math "floor(($now - $head_epoch) / 86400)")
    end

    # Upstream ref and its tracking status ('[gone]' when the remote-tracking
    # ref has been pruned but the upstream is still configured)
    set -l upstream -
    set -l track ""
    if test -n "$branch"
        set -l up (git -C "$worktree_path" for-each-ref \
            --format='%(upstream:short)' refs/heads/$branch 2>/dev/null)
        test -n "$up"; and set upstream $up
        set track (git -C "$worktree_path" for-each-ref \
            --format='%(upstream:track)' refs/heads/$branch 2>/dev/null)
    end

    set -l branch_display $branch
    test -z "$branch_display"; and set branch_display -

    # State decision: first match wins
    set -l state ""

    if test -n "$branch"; and contains -- $branch $protected_branches
        set state protected
    else if test -z "$branch"
        set state detached
    end

    # merged: HEAD is an ancestor of the integration branch
    if test -z "$state"; and test -n "$integration_branch"
        set -l unmerged (git -C "$worktree_path" rev-list $head_commit \
            --not $integration_branch 2>/dev/null)
        if test $status -eq 0; and test -z "$unmerged"
            set state merged
        end
    end

    # pr-closed: the branch's GitHub PR is merged or closed. The lookup itself
    # (gh present, github.com remote, cwd handling) lives in
    # _git_branch_pr_state so git-wrm applies the identical rules.
    # Caveat (accepted in spec): 'gh pr view <branch>' reports the most recent
    # PR for a reused branch name.
    if test -z "$state"; and not set -q _flag_no_forge; and test -n "$branch"
        set -l remote origin
        if test "$upstream" != -
            # index form instead of -f1: works on fish < 3.4 too
            set remote (string split -- / $upstream)[1]
        end
        set -l pr (_git_branch_pr_state "$worktree_path" $branch $remote)
        set -l pr_state (string split \t -- $pr)[1]
        if contains -- "$pr_state" MERGED CLOSED
            set state pr-closed
        end
    end

    # gone: upstream configured but its remote-tracking ref no longer exists
    if test -z "$state"; and test "$track" = "[gone]"
        set state gone
    end

    # stale: no commits within the staleness window
    if test -z "$state"; and test $age_days -gt $stale_days
        set state stale
    end

    test -z "$state"; and set state active

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' $state $branch_display $upstream $dirty $age_days $worktree_path
    return 0
end
