function git-diff-plain -d "git diff without a pager" --wraps git-diff
  git -c core.pager=cat diff $argv
end
