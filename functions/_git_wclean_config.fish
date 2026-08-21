function _git_wclean_config --description "Load git-wclean config: defaults, then first existing config file"
    # Shared configuration loader for git-wclean, git-wlist, and git wclean --check.
    #
    # SYNOPSIS
    #   _git_wclean_config [--allow-local] [--quiet]
    #
    # DESCRIPTION
    #   Sets the _wclean_config_* globals to their defaults, then sources the
    #   FIRST existing config file (first-match-wins) from:
    #     1. ~/.config/git-wclean/config
    #     2. ~/.git-wclean-config
    #     3. ./.git-wclean-config   (only when --allow-local is passed)
    #
    #   The repo-local file is gated behind --allow-local because sourcing an
    #   arbitrary file from the current directory is code execution: only an
    #   explicit, interactive `git wclean` run may opt in. Hook-driven callers
    #   (git wclean --check) and read-only callers (git-wlist) must not pass it.
    #
    # OPTIONS
    #   --allow-local   Include ./.git-wclean-config as the last-resort fallback
    #   --quiet         Suppress the "Loading configuration from" stderr message
    #
    # EXAMPLES
    #   # Load defaults + user-level config (read-only callers like git-wlist)
    #   _git_wclean_config
    #
    #   # Hook-driven caller: no repo-local config, no loading message
    #   _git_wclean_config --quiet
    #
    #   # Explicit full git-wclean run: repo-local config may participate
    #   _git_wclean_config --allow-local
    #
    # EXIT STATUS
    #   0    Success (a missing config file is not an error)
    #   1    Usage error (unknown flag)
    argparse --name=_git_wclean_config allow-local quiet -- $argv
    or return 1

    # Defaults
    set -g _wclean_config_protected_branches main master develop trunk
    # Empty by default: the integration branch is auto-detected from origin/HEAD.
    # Set this in a config file ONLY to override that detection explicitly.
    set -g _wclean_config_default_upstream ""
    set -g _wclean_config_system_dirs /etc /bin /usr/bin /sbin /usr/sbin
    set -g _wclean_config_max_path_length 4096
    set -g _wclean_config_fetch_timeout 30
    set -g _wclean_config_stale_days 30

    set -l config_files ~/.config/git-wclean/config ~/.git-wclean-config
    if set -q _flag_allow_local
        set -a config_files ./.git-wclean-config
    end

    for config_file in $config_files
        if test -f "$config_file"; and test -r "$config_file"
            if not set -q _flag_quiet
                printf "Loading configuration from: %s\n" $config_file >&2
            end
            source "$config_file"
            break
        end
    end
    return 0
end
