function g -d "short cut for accessing git" --wraps git
  set -l git_func "git-$argv[1]"
  if functions -d -- $git_func &> /dev/null
    $git_func $argv[2..-1] 
  else
    git $argv
  end
end
