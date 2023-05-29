function git-show-plain -d "git show without a pager" --wraps git-show
    git -c core.pager=cat show $argv
end
