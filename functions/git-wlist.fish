function git-wlist --description "List git worktrees with lifecycle state"
    # Git Worktree List - Dashboard of every registered worktree's lifecycle state
    #
    # SYNOPSIS
    #   git-wlist [OPTIONS]
    #   git wlist [OPTIONS]
    #
    # DESCRIPTION
    #   Lists every worktree registered in the current repository (via
    #   'git worktree list --porcelain') with its branch, lifecycle state,
    #   dirty flag, and age in days since the last commit. States:
    #
    #     merged      HEAD is contained in the integration branch (origin/HEAD)
    #     pr-closed   The branch's GitHub PR is merged or closed (needs gh)
    #     gone        The branch's upstream was deleted on the remote
    #     stale       No commits within the staleness window (default 30 days)
    #     error       The worktree could not be classified
    #     detached    Detached HEAD
    #     active      None of the above
    #     protected   Branch is in the protected set (main master develop trunk
    #                 plus config)
    #
    #   Rows are sorted in that state order, oldest first within each state.
    #   Git's own locked/prunable annotations are appended to the NAME column.
    #   Runs one 'git fetch --prune origin' up front (bounded by the
    #   _wclean_config_fetch_timeout setting when a timeout utility exists).
    #
    #   Reads the same config as git-wclean (~/.config/git-wclean/config or
    #   ~/.git-wclean-config) but never the repo-local ./.git-wclean-config.
    #
    # OPTIONS
    #   -h, --help            Show this help message
    #   -s, --stale-days N    Staleness threshold in days (default: 30, or
    #                         _wclean_config_stale_days from config)
    #
    # EXAMPLES
    #   # List all worktrees in the current repo/container
    #   git wlist
    #
    #   # Use a tighter staleness window
    #   git wlist --stale-days 7
    #
    # DEPENDENCIES
    #   - gh (optional): enables pr-closed detection for github.com remotes
    #
    # EXIT STATUS
    #   0    Success
    #   1    Invalid arguments
    #   2    Git command failed or not inside a git repository
    argparse --name=git-wlist h/help 's/stale-days=' -- $argv
    or return 1

    if set -q _flag_help
        _git_help_from_doc_comment git-wlist
        return 0
    end

    if test (count $argv) -gt 0
        printf "Error: git-wlist takes no arguments\n" >&2
        printf "Usage: git-wlist [OPTIONS]\n" >&2
        return 1
    end

    if not git rev-parse --git-dir >/dev/null 2>&1
        printf "Error: not inside a git repository\n" >&2
        return 2
    end

    # Shared config; repo-local config is deliberately not honored here
    _git_wclean_config

    set -l stale_days $_wclean_config_stale_days
    if set -q _flag_stale_days
        if not string match -qr '^\d+$' -- $_flag_stale_days
            printf "Error: --stale-days requires a non-negative integer\n" >&2
            return 1
        end
        set stale_days $_flag_stale_days
    end

    # One fetch --prune, timeout-guarded (mirrors _wclean_fetch_remotes; kept
    # inline because wclean's helper prints progress and sets wclean globals)
    if contains origin (git remote 2>/dev/null)
        set -l timeout_cmd
        command -q timeout; and set timeout_cmd timeout
        test -z "$timeout_cmd"; and command -q gtimeout; and set timeout_cmd gtimeout
        if test -n "$timeout_cmd"
            $timeout_cmd $_wclean_config_fetch_timeout git fetch --prune origin >/dev/null 2>&1
            or printf "warning: fetch failed; results may be stale\n" >&2
        else
            git fetch --prune origin >/dev/null 2>&1
            or printf "warning: fetch failed; results may be stale\n" >&2
        end
    end

    # Integration branch from origin/HEAD; config override wins. Empty is
    # tolerated: the classifier then skips the merged check.
    set -l integration_branch (git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
        | string replace 'refs/remotes/' '')
    if test -z "$integration_branch"; and test -n "$_wclean_config_default_upstream"
        set integration_branch $_wclean_config_default_upstream
    end

    # Enumerate registered worktrees (skip the bare repo entry); collect
    # locked/prunable annotations per path
    set -l wt_paths
    set -l wt_notes
    set -l current_path ""
    set -l current_notes ""
    set -l is_bare 0
    for line in (git worktree list --porcelain 2>/dev/null)
        if string match -q 'worktree *' -- $line
            if test -n "$current_path"; and test $is_bare -eq 0
                set -a wt_paths $current_path
                set -a wt_notes "$current_notes"
            end
            set current_path (string replace 'worktree ' '' -- $line)
            set current_notes ""
            set is_bare 0
        else if test "$line" = bare
            set is_bare 1
        else if string match -q 'locked*' -- $line
            set current_notes (string trim -- "$current_notes locked")
        else if string match -q 'prunable*' -- $line
            set current_notes (string trim -- "$current_notes prunable")
        end
    end
    if test -n "$current_path"; and test $is_bare -eq 0
        set -a wt_paths $current_path
        set -a wt_notes "$current_notes"
    end

    if test (count $wt_paths) -eq 0
        printf "No worktrees found.\n"
        return 0
    end

    # Classify each worktree; build sortable rows
    set -l state_order merged pr-closed gone stale error detached active protected
    set -l rows
    for i in (seq (count $wt_paths))
        set -l line (_git_worktree_status $wt_paths[$i] "$integration_branch" \
            $stale_days $_wclean_config_protected_branches)
        set -l f (string split \t -- $line)
        set -l order (contains -i -- $f[1] $state_order)
        or set order 9
        set -l name (basename $f[6])
        if test -n "$wt_notes[$i]"
            set name "$name [$wt_notes[$i]]"
        end
        # error rows carry '-' for age; render it bare, not '-d' (spec)
        set -l age_disp "$f[5]"d
        test "$f[5]" = -; and set age_disp -
        set -a rows (printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
            $order $f[5] $name $f[2] $f[1] $f[4] $age_disp)
    end

    # Sort by state order, then oldest first; render aligned
    begin
        printf 'NAME\tBRANCH\tSTATE\tDIRTY\tAGE\n'
        printf '%s\n' $rows | sort -t \t -k1,1n -k2,2nr | cut -f3-
    end | column -t -s \t
    return 0
end
