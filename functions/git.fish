function git -d "function to access fish git functions" --wraps git
  set -l git_func "git-$argv[1]"
  set -l git_cmd (command -v git)
  if functions -d -- $git_func &> /dev/null
    $git_func $argv[2..-1] 
  else
    $git_cmd $argv
  end
end
