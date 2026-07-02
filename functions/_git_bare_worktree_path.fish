function _git_bare_worktree_path --description "Resolve a worktree path, anchoring to the bare container if inside one"
    # Args: <worktree_name>
    # Prints: the resolved worktree path (container-anchored in bare layout, raw name otherwise)
    # Returns: 1 if the worktree name contains '/' in a bare layout (nothing is printed), 0 otherwise
    #
    # Callers must print their own error message on failure: fish does not propagate a
    # nested command substitution's stderr through the caller's own redirections, so an
    # error printed here would bypass a caller like `(git-wadd foo 2>&1 >/dev/null)`.
    set -l worktree_name $argv[1]
    set -l worktree_path $worktree_name

    set -l _container (_git_bare_container)
    if test $status -eq 0
        if string match -q '*/*' -- $worktree_name
            return 1
        end
        set worktree_path "$_container/$worktree_name"
    end

    echo $worktree_path
    return 0
end
