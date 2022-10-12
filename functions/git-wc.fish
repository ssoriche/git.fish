function git-wc -d "create a new worktree and branch" --wraps git-worktree
  set -q branch $argv[2] || set branch origin/main
  git worktree add {-b,}$argv[1] $branch $argv[3..-1]
  cd $argv[1]
end
