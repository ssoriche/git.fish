function _git_bare_container --description "Print the container directory of the current bare layout, or exit non-zero"
    # Walk up from cwd looking for a directory that contains a sibling .bare/
    # directory. On success, print the absolute path of that directory and exit 0.
    # On failure (no .bare ancestor), print nothing and exit 1.

    set -l dir (pwd)

    while test "$dir" != /
        if test -d "$dir/.bare"
            echo $dir
            return 0
        end
        set dir (dirname $dir)
    end

    return 1
end
