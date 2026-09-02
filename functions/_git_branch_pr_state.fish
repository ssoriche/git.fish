function _git_branch_pr_state --description "Look up a branch's GitHub PR state via gh (private helper)"
    # Git Branch PR State (private helper) - single source of truth for "what
    # does the forge say about this branch's pull request", consumed by
    # _git_worktree_status (pr-closed classification) and git-wrm (accepting
    # squash- or rebase-merged branches whose commits are not ancestors of the
    # integration branch).
    #
    # SYNOPSIS
    #   _git_branch_pr_state <worktree-path> <branch> [remote]
    #
    # OUTPUT
    #   Exactly one tab-separated line on stdout when a PR is found:
    #     <state> <number> <head-sha>
    #   state:     MERGED|CLOSED|OPEN (as reported by 'gh pr view --json state')
    #   number:    the PR number, or empty if gh did not report one
    #   head-sha:  the PR's head commit (headRefOid). 'gh pr view <branch>'
    #              reports the most recent PR for that branch NAME, so callers
    #              must apply the verdict only when this commit covers the
    #              worktree HEAD (HEAD is it, or an ancestor of it):
    #                git merge-base --is-ancestor <HEAD> <head-sha>
    #              A reused branch name with new commits otherwise inherits an
    #              old PR's MERGED verdict and loses unmerged work.
    #
    #   Prints nothing and returns 1 when the lookup does not apply or fails:
    #   gh is not installed, <remote> (default 'origin') is not a github.com
    #   remote, or 'gh pr view' fails (no PR, not authenticated, offline).
    #   Callers must treat "no output" as "unknown", never as "not merged".
    #
    # EXAMPLES
    #   set -l pr (_git_branch_pr_state ~/src/repo/feature-x feature-x origin)
    #   if test -n "$pr"
    #       set -l pr_fields (string split \t -- $pr)
    #       # $pr_fields[1] = state, [2] = number, [3] = head sha
    #   end
    #
    # NOTES
    #   - gh runs with the worktree as cwd so it resolves the repository from
    #     that worktree's remotes.
    #   - 'gh pr view <branch>' reports the most recent PR for a reused branch
    #     name; the head-sha field exists so callers can detect that case.
    #   - Performs no fetch and no timeout guard: gh fails fast when
    #     unauthenticated or offline.
    set -l worktree_path $argv[1]
    set -l branch $argv[2]
    set -l remote $argv[3]
    if test -z "$remote"
        set remote origin
    end

    test -n "$worktree_path"; and test -n "$branch"
    or return 1

    command -q gh
    or return 1

    set -l remote_url (git -C "$worktree_path" remote get-url $remote 2>/dev/null)
    string match -q '*github.com*' -- "$remote_url"
    or return 1

    pushd "$worktree_path" >/dev/null 2>&1
    or return 1
    set -l pr (gh pr view $branch --json state,number,headRefOid \
        --jq '"\(.state)\t\(.number)\t\(.headRefOid)"' 2>/dev/null)
    set -l gh_status $status
    popd >/dev/null

    test $gh_status -eq 0; and test -n "$pr"
    or return 1

    printf '%s\n' $pr[1]
    return 0
end
