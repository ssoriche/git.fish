function git-wc -d "create a new worktree and branch" --wraps git-worktree
  git worktree add {-b,}$argv[1] $argv[2..-1]
  cd $argv[1]
end
