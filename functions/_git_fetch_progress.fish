function _git_fetch_progress --description "Run git fetch in the background with a spinner and a native timeout"
    # Git Fetch Progress (private helper) - the one fetch runner shared by
    # git-wclean, git-wlist, and git-wrm. Runs 'git fetch' as a background
    # job, animates a spinner with elapsed seconds on a TTY, and enforces the
    # timeout itself, so no timeout/gtimeout utility is needed.
    #
    # SYNOPSIS
    #   _git_fetch_progress --label <text> --timeout <secs> [--quiet] -- <git-fetch-args...>
    #
    # OPTIONS
    #   --label <text>    Text drawn beside the spinner (TTY) or printed once (non-TTY)
    #   --timeout <secs>  Whole seconds (>= 1) before the fetch is killed
    #   -q, --quiet       Draw nothing at all (for prompt hooks)
    #
    # OUTPUT
    #   Indicator only, always on stderr; stdout is never written. The helper
    #   prints no warnings of its own: callers own every user-facing line and
    #   key them off the exit status.
    #
    # EXAMPLES
    #   _git_fetch_progress --label "Fetching from origin" --timeout 30 -- --prune origin
    #   _git_fetch_progress --quiet --label fetch --timeout 30 -- --prune origin
    #
    # EXIT STATUS
    #   0    Fetch succeeded
    #   1    Invalid arguments
    #   2    Fetch failed (also: mktemp failed, or the status file came back empty)
    #   124  Timed out; the fetch process tree was killed
    #   125  Timed out; the fetch could not be confirmed stopped (no ps AND no
    #        pid file). Callers that go on to delete things must abort.
    #
    # NOTES
    #   - GIT_TERMINAL_PROMPT=0 is always set: a background job cannot answer a
    #     credential prompt, so such a fetch fails instead of hanging.
    #   - Ctrl-C / SIGTERM run _git_fetch_progress_abort through the handlers
    #     at the bottom of this file: the fetch tree is killed and both scratch
    #     files are removed. The only global, _git_fetch_progress_job, exists
    #     only while a fetch is in flight.
    argparse --name=_git_fetch_progress 'label=' 'timeout=' q/quiet -- $argv
    or return 1

    if not set -q _flag_label; or not set -q _flag_timeout
        printf 'usage: _git_fetch_progress --label <text> --timeout <secs> [--quiet] -- <git-fetch-args...>\n' >&2
        return 1
    end
    if not string match -qr '^[1-9][0-9]*$' -- $_flag_timeout
        printf '_git_fetch_progress: --timeout must be a whole number of seconds >= 1\n' >&2
        return 1
    end
    if test (count $argv) -eq 0
        printf '_git_fetch_progress: no git fetch arguments given\n' >&2
        return 1
    end

    set -l quiet 0
    set -q _flag_quiet; and set quiet 1
    set -l tty 0
    if test $quiet -eq 0; and isatty stderr
        set tty 1
    end

    # Scratch files: the wrapper writes git's pid to "$0.pid" and git's exit
    # status to "$0". They are passed as the sh script's $0 because fish
    # locals are not exported and would expand to nothing inside the script.
    set -l status_file (mktemp 2>/dev/null)
    or return 2
    set -l pid_file "$status_file.pid"

    # Single external command so fish can background it (fish never forks
    # for blocks or functions). The trailing 2>/dev/null silences sh's own
    # "Terminated" job notice when git is killed on the timeout path.
    sh -c 'GIT_TERMINAL_PROMPT=0 git fetch "$@" >/dev/null 2>&1 &
        echo $! >"$0.pid"; wait $!; echo $? >"$0"' $status_file $argv 2>/dev/null &
    set -l wrapper_pid $last_pid
    set -g _git_fetch_progress_job $status_file $wrapper_pid

    if test $quiet -eq 0; and test $tty -eq 0
        printf '%s…\n' $_flag_label >&2
    end

    set -l frames ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏
    set -l frame 0
    set -l started (date +%s)
    set -l timed_out 0
    while kill -0 $wrapper_pid 2>/dev/null
        set -l elapsed (math (date +%s) - $started)
        if test $elapsed -ge $_flag_timeout
            set timed_out 1
            break
        end
        if test $tty -eq 1
            set frame (math "$frame % 10 + 1")
            printf '\r%s %s… %ds' $frames[$frame] $_flag_label $elapsed >&2
        end
        sleep 0.1
    end
    if test $tty -eq 1
        printf '\r\033[K' >&2
    end

    set -l rc 2
    if test $timed_out -eq 1
        # Task 3 fills this branch in.
        set rc 124
    else
        # Explicit reap on the normal path; the wrapper is already gone so
        # this returns at once, and fish's wait does not carry the status,
        # which is why the status file exists.
        wait $wrapper_pid 2>/dev/null
        set -l fetch_status ''
        if test -r $status_file
            read fetch_status <$status_file
        end
        if test "$fetch_status" = 0
            set rc 0
        end
    end

    rm -f $status_file $pid_file
    set -e _git_fetch_progress_job
    return $rc
end
