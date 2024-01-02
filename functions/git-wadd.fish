function git-wadd -d "create a new worktree and branch" --wraps git-worktree
    set -l branch $argv[2]
    if test (count $argv) -lt 2
        set branch origin/main
    end

    git worktree add {-b ,}$argv[1] $branch $argv[3..-1]
    cd $argv[1]
end
