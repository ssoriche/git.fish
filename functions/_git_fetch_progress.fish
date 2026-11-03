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
    #   2    Fetch failed (also: mktemp failed under both TMPDIR and /tmp, or the
    #        status file came back empty)
    #   124  Timed out; the fetch process tree was killed and the wrapper
    #        (which exits only once git has) was seen gone
    #   125  Timed out; the fetch could not be confirmed stopped (no ps AND no
    #        pid file, or the wrapper still alive ~2s after the kill).
    #        Callers that go on to delete things must abort.
    #   130  Interrupted (SIGINT/SIGTERM reached fish); the fetch was killed
    #
    # NOTES
    #   - A background job cannot answer a credential prompt, so prompting is
    #     disabled: GIT_TERMINAL_PROMPT=0 stops terminal prompts, and an empty
    #     GIT_ASKPASS and SSH_ASKPASS stop askpass helpers and dialogs (git
    #     skips askpass when GIT_ASKPASS is set but empty, which also overrides
    #     core.askPass). Such a fetch fails instead of hanging or popping up.
    #   - Interruption. _git_fetch_progress_abort kills the fetch tree and
    #     removes both scratch files; it is reached two ways:
    #     * Interactive Ctrl-C goes to the foreground external command (the
    #       spinner's sleep), not to fish, so the INT handler never runs and
    #       fish abandons this function. The fish_postexec hook at the bottom
    #       of this file runs the abort after that cancelled command line.
    #     * When fish itself receives SIGINT/SIGTERM (scripts, CI, kill), the
    #       signal handlers run the abort, but fish does not cancel the
    #       function: the loop sees _git_fetch_progress_interrupted, and the
    #       helper returns 130.
    #     _git_fetch_progress_job exists only while a fetch is in flight.
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

    # A job still registered here was cancelled before any fish_postexec ran
    # (Ctrl-C inside a prompt hook); no live job can be in flight in this
    # process now, so abort it rather than orphan it. Then drop the stale flag
    # (an abort with no loop to consume it) so it cannot cut this fetch short.
    _git_fetch_progress_abort
    set -e _git_fetch_progress_interrupted

    set -l quiet 0
    set -q _flag_quiet; and set quiet 1
    set -l tty 0
    if test $quiet -eq 0; and isatty stderr
        set tty 1
    end

    # Scratch files: the wrapper writes git's pid to "$0.pid" and git's exit
    # status to "$0". They are passed as the sh script's $0 because fish
    # locals are not exported and would expand to nothing inside the script.
    set -l tmp_base /tmp
    # BSD mktemp ignores $TMPDIR without a template, so build the path here.
    if test -n "$TMPDIR"
        set tmp_base (string replace -r '/+$' '' -- $TMPDIR)
        # TMPDIR=/ trims to nothing
        test -n "$tmp_base"; or set tmp_base /tmp
    end
    # An unusable TMPDIR (missing, unwritable) falls back to /tmp.
    set -l status_file (mktemp "$tmp_base/git-fish-fetch.XXXXXX" 2>/dev/null)
    or set status_file (mktemp /tmp/git-fish-fetch.XXXXXX 2>/dev/null)
    or return 2
    set -l pid_file "$status_file.pid"

    # Single external command so fish can background it (fish never forks
    # for blocks or functions). The trailing 2>/dev/null silences sh's own
    # "Terminated" job notice when git is killed on the timeout path.
    sh -c (_git_fetch_progress_wrapper_script | string collect) $status_file $argv 2>/dev/null &
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
        # The INT/TERM handler has already killed the fetch and cleaned up;
        # fish resumes this loop afterwards, so stop here and report 130.
        set -q _git_fetch_progress_interrupted; and break
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
    if set -q _git_fetch_progress_interrupted
        set -e _git_fetch_progress_interrupted
        rm -f $status_file $pid_file
        set -e _git_fetch_progress_job
        return 130
    end

    set -l rc 2
    if test $timed_out -eq 1
        # Kill git (and its transport) rather than the wrapper: the wrapper
        # then exits on its own after writing git's signal status, which
        # avoids fish's "Job terminated" notice. 125 = both kill sources were
        # unavailable; the helper prints nothing either way (callers own the
        # warning, and --quiet must stay literal).
        set -l git_pid ''
        if test -r $pid_file
            read git_pid <$pid_file
        end
        if _git_fetch_progress_kill_tree $wrapper_pid $git_pid
            set rc 124
        else
            kill -TERM $wrapper_pid 2>/dev/null
            set rc 125
        end
        # Let the wrapper finish its trailing 'echo $? >"$0"' before the
        # scratch files go, or it would recreate the status file afterwards.
        # The wrapper only exits once git does, so one still alive after
        # ~2s means the fetch is not confirmed stopped: report 125.
        if not _git_fetch_progress_wait_gone $wrapper_pid
            set rc 125
        end
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

    # A signal that arrived during the timeout branch's wait wins over 124/125.
    if set -q _git_fetch_progress_interrupted
        set -e _git_fetch_progress_interrupted
        set rc 130
    end
    rm -f $status_file $pid_file
    set -e _git_fetch_progress_job
    return $rc
end

function _git_fetch_progress_wrapper_script --description "Print the sh script that runs the fetch"
    # Run as: sh -c <script> <status-file> <git-fetch-args...>. Its $0 is the
    # status file: git's pid goes to "$0.pid", git's exit status to "$0".
    # Kept in one function so the tests drive the exact script the helper runs.
    # "$0" comes from mktemp but "$0.pid" is predictable, so the pid write is
    # under noclobber (set -C, scoped to a subshell): a path planted there
    # (file or symlink, dangling or not) is refused and the pid file is just
    # absent. The kill never relies on the pid file alone (the ps walk).
    printf '%s\n' \
        'GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS= git fetch "$@" >/dev/null 2>&1 &' \
        '(set -C; echo $! >"$0.pid") 2>/dev/null; wait $!; echo $? >"$0"'
end

function _git_fetch_progress_kill_tree --description "SIGTERM wrapper descendants and/or git pid"
    # Two independent sources, union of targets, never the wrapper itself
    # (killing the wrapper by signal would make interactive fish print a
    # "Job terminated" notice; the wrapper exits on its own once git dies):
    #   1. every descendant of <wrapper-pid> by a breadth-first walk of
    #      'ps -eo pid=,ppid=' - reaches git AND its ssh/remote-helper
    #      children, which git does not signal itself;
    #   2. <git-pid> from the pid file - reaches git even without ps.
    # Returns 0 when at least one source contributed, 1 when neither did.
    set -l wrapper_pid $argv[1]
    set -l git_pid $argv[2]
    set -l targets
    set -l have_source 0

    if command -q ps
        set -l table (command ps -eo pid=,ppid= 2>/dev/null)
        if test $status -eq 0
            set have_source 1
            set -l frontier $wrapper_pid
            while test (count $frontier) -gt 0
                set -l next
                for line in $table
                    set -l fields (string split -n ' ' -- (string trim -- $line))
                    if contains -- $fields[2] $frontier
                        set -a targets $fields[1]
                        set -a next $fields[1]
                    end
                end
                set frontier $next
            end
        end
    end

    if test -n "$git_pid"
        set have_source 1
        contains -- $git_pid $targets
        or set -a targets $git_pid
    end

    if test $have_source -eq 0
        return 1
    end
    for pid in $targets
        kill -TERM $pid 2>/dev/null
    end
    return 0
end

function _git_fetch_progress_wait_gone --description "Wait up to ~2s for a pid to disappear"
    set -l tries 0
    while test $tries -lt 20
        kill -0 $argv[1] 2>/dev/null
        or return 0
        sleep 0.1
        set tries (math $tries + 1)
    end
    return 1
end

function _git_fetch_progress_abort --description "Ctrl-C/SIGTERM cleanup for an in-flight _git_fetch_progress job"
    # When fish itself receives the signal, the handler runs this and the
    # helper then sees the interrupted flag and returns 130. Interactively the
    # signal goes to the foreground command, fish abandons the function, and
    # fish_postexec runs this. Without it the fetch would outlive the command
    # and both scratch files would leak. No-op when nothing is in flight.
    set -q _git_fetch_progress_job
    or return 0
    set -l status_file $_git_fetch_progress_job[1]
    set -l wrapper_pid $_git_fetch_progress_job[2]
    set -e _git_fetch_progress_job
    # Tells a still-running helper loop (non-interactive SIGINT/SIGTERM:
    # fish does not cancel the function) to return 130 instead of resuming.
    set -g _git_fetch_progress_interrupted 1

    set -l git_pid ''
    if test -r "$status_file.pid"
        read git_pid <"$status_file.pid"
    end
    _git_fetch_progress_kill_tree $wrapper_pid $git_pid
    or kill -TERM $wrapper_pid 2>/dev/null
    _git_fetch_progress_wait_gone $wrapper_pid
    if isatty stderr
        printf '\r\033[K' >&2
    end
    rm -f $status_file "$status_file.pid"
end

# fish accepts one signal per handler, so two thin handlers share the abort
# (same pattern as git-wclean's own cleanup handlers).
function _git_fetch_progress_on_int --on-signal INT
    _git_fetch_progress_abort
end

function _git_fetch_progress_on_term --on-signal TERM
    _git_fetch_progress_abort
end

# Interactively, Ctrl-C goes to the foreground external command (sleep), not
# to fish, so the INT handler above never runs; fish just abandons the
# function. fish_postexec fires after that cancelled command line, and the
# abort is a no-op unless a job is still registered. No helper loop is left
# to consume the interrupted flag here, so clear it too.
function _git_fetch_progress_on_postexec --on-event fish_postexec
    _git_fetch_progress_abort
    set -e _git_fetch_progress_interrupted
end
