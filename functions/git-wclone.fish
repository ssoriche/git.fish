function git-wclone --description "Clone a repo into a .bare container layout"
    # Git Worktree Clone - Creates a .bare container layout from a git URL
    #
    # SYNOPSIS
    #   git-wclone [OPTIONS] <git-url> [destination]
    #   git wclone [OPTIONS] <git-url> [destination]
    #
    # DESCRIPTION
    #   Clones <git-url> into a .bare container layout: <destination>/.bare holds
    #   the bare repo, <destination>/.git is a gitdir pointer, and a worktree for
    #   the default branch is created as a sibling (e.g., <destination>/main/).
    #
    #   Refuses to operate on a non-empty destination or one containing an existing
    #   .bare/ directory.
    #
    #   On success, changes to the initial worktree (or to the container when
    #   --no-checkout is used).
    #
    # OPTIONS
    #   -h, --help          Show this help message
    #   -n, --dry-run       Print planned actions without performing them
    #       --no-checkout   Skip the initial worktree; leave a bare-only layout
    #
    # ARGUMENTS
    #   git-url        Any git URL (https, ssh, file://, etc.)
    #   destination    Directory to create. Defaults to the repo basename
    #                  (e.g., 'foo' for 'git@host:user/foo.git').
    #
    # EXAMPLES
    #   # Clone into ~/projects/foo/ with initial worktree at ~/projects/foo/main/
    #   cd ~/projects; and git wclone git@github.com:user/foo.git
    #
    #   # Clone into ~/work/myrepo/ with no initial worktree
    #   git wclone --no-checkout git@github.com:user/foo.git ~/work/myrepo
    #
    # EXIT STATUS
    #   0    Success
    #   1    Invalid arguments or destination collision
    #   2    Git command failed, or partial failure (e.g., default branch undetectable)

    argparse --name=git-wclone h/help n/dry-run no-checkout -- $argv
    or return 1

    if set -q _flag_help
        printf '%s\n' (status function | head -n 1)
        printf '\n'
        functions git-wclone | string match -r '^\s*#\s.*' \
            | string replace -r '^\s*#\s?' '' \
            | string replace -r '^\s*#\s*$' ''
        return 0
    end

    if test (count $argv) -lt 1
        printf "Error: Missing required argument <git-url>\n" >&2
        printf "Usage: git-wclone [OPTIONS] <git-url> [destination]\n" >&2
        printf "Try 'git-wclone --help' for more information.\n" >&2
        return 1
    end

    set -l git_url $argv[1]
    set -l dest $argv[2]

    if test -z "$dest"
        set dest (basename $git_url .git)
    end

    # Destination collision checks
    if test -e "$dest"
        if test -d "$dest/.bare"
            printf "Error: %s/.bare already exists.\n" $dest >&2
            return 1
        end
        if test -d "$dest"
            if test (count (ls -A $dest 2>/dev/null)) -gt 0
                printf "Error: %s is not empty. Refusing to clone into a non-empty directory.\n" $dest >&2
                return 1
            end
        else
            printf "Error: %s exists and is not a directory.\n" $dest >&2
            return 1
        end
    end

    if set -q _flag_dry_run
        printf "Would create directory: %s\n" $dest
        printf "Would clone: %s into %s/.bare\n" $git_url $dest
        printf "Would configure: remote.origin.fetch = +refs/heads/*:refs/remotes/origin/*\n"
        if not set -q _flag_no_checkout
            printf "Would create initial worktree for the remote's default branch\n"
        end
        return 0
    end

    mkdir -p $dest
    or begin
        printf "Error: Failed to create destination directory %s\n" $dest >&2
        return 2
    end

    printf "Cloning %s into %s/.bare ...\n" $git_url $dest
    if not git clone --bare $git_url "$dest/.bare"
        printf "Error: git clone failed\n" >&2
        return 2
    end

    printf 'gitdir: ./.bare\n' >"$dest/.git"

    # Reconfigure refspec so origin/* are remote-tracking branches (not local heads).
    # Without this, `git wadd` would not see origin/main as a remote-tracking branch.
    git -C $dest config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
    if not git -C $dest fetch origin
        printf "Error: git fetch failed after clone\n" >&2
        return 2
    end

    if set -q _flag_no_checkout
        printf "✓ Bare layout ready at %s (no initial worktree)\n" $dest
        cd $dest
        return 0
    end

    # Determine the default branch
    set -l default_branch (git -C $dest symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null \
        | string replace 'origin/' '')
    if test -z "$default_branch"
        for b in main master
            if git -C $dest show-ref --verify --quiet refs/remotes/origin/$b
                set default_branch $b
                break
            end
        end
    end

    if test -z "$default_branch"
        printf "Error: Could not determine default branch.\n" >&2
        printf "Re-run with --no-checkout and create a worktree manually.\n" >&2
        return 2
    end

    if string match -q '*/*' -- $default_branch
        printf "Error: default branch '%s' contains '/'.\n" $default_branch >&2
        printf "Re-run with --no-checkout and create a worktree manually.\n" >&2
        return 2
    end

    printf "Creating initial worktree for '%s' ...\n" $default_branch
    if not git -C $dest worktree add $default_branch $default_branch
        printf "Error: Failed to create initial worktree\n" >&2
        return 2
    end

    printf "✓ Bare layout ready at %s\n" $dest
    cd "$dest/$default_branch"
    or printf "Warning: failed to change into initial worktree\n" >&2

    return 0
end
