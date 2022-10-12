function git-wjump -d "fzf search worktree lists"
  set -f out (
    git worktree list |
    grep -v '/[.]' |
    fzf --preview='git log --oneline -n10 {2}' --query "$argv" -1 |
    awk '{print $1}'
  )

  if test -n "$out"
    cd $out
  end
end
