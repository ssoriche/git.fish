function _git_help_from_doc_comment --description "Print a command's name and its leading doc-comment block as help text"
    # Args: <command_name>
    # Prints: <command_name>, a blank line, then the stripped leading doc-comment
    #   block from that command's function body
    # Returns: 0
    #
    # Takes the command's name as an argument rather than calling `status
    # function` itself: callers that delegate help rendering to a shared
    # helper (rather than printing inline) would otherwise have `status
    # function` report the helper's own name, not the caller's.
    #
    # `functions <command_name>` prefixes its output with a "# Defined in ...
    # @ line N" header and the `function <command_name> ...` declaration line
    # before the docstring, so skip past those first, then stop at the first
    # non-comment line so implementation comments later in the function body
    # do not leak into user-facing help.
    set -l command_name $argv[1]

    printf '%s\n' $command_name
    printf '\n'

    set -l body (functions $command_name)
    set -l doc_lines
    set -l past_declaration 0
    for line in $body
        if test $past_declaration -eq 0
            if string match -qr '^function\s' -- $line
                set past_declaration 1
            end
            continue
        end
        if string match -qr '^\s*#' -- $line
            set -a doc_lines $line
        else
            break
        end
    end
    string match -rg '^\s*#\s*(.*)' -- $doc_lines
end
