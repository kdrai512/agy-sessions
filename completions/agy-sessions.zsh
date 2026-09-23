#compdef agy-sessions agys

_agy_sessions() {
    local -a subcommands
    subcommands=(
        'list:List conversation sessions in tabular format'
        'ls:Alias for list'
        'active:Show currently running sessions and PIDs'
        'resume:Resume a session directly'
        'open:Alias for resume'
        'mux:Open session in a terminal multiplexer (tmux/zellij/screen)'
        'tmux:Open session specifically in tmux'
        'search:Search transcripts for code or keywords'
        'find:Alias for search'
        'rename:Rename a conversation session title'
        'export:Export session dialogue to Markdown'
        'info:Display session details and transcript'
        'show:Alias for info'
        'kill:Terminate a running session process'
        'delete:Delete a conversation session'
        'rm:Alias for delete'
    )

    _arguments -C \
        '(-w --window)'{-w,--window}'[Launch in a new Omarchy terminal window]' \
        '(-c --current-dir)'{-c,--current-dir}'[Filter sessions to current workspace directory]' \
        '(-m --mux --multiplexer)'{-m,--mux,--multiplexer}'[Open in terminal multiplexer]' \
        '--tmux[Open specifically in tmux]' \
        '(-h --help)'{-h,--help}'[Show help]' \
        '1: :->cmd' \
        '*:: :->args'

    case $state in
        cmd)
            _describe -t subcommands 'agy-sessions subcommands' subcommands
            ;;
        args)
            case $line[1] in
                resume|open)
                    _arguments \
                        '(-u --unsafe)'{-u,--unsafe}'[Launch in unsafe mode (--dangerously-skip-permissions)]' \
                        '(-s --safe)'{-s,--safe}'[Launch in safe mode]' \
                        '(-b --sandbox)'{-b,--sandbox}'[Launch in sandbox mode]' \
                        '(-m --mux --multiplexer)'{-m,--mux,--multiplexer}'[Open in terminal multiplexer]' \
                        '--tmux[Open specifically in tmux]' \
                        '(-w --window)'{-w,--window}'[Launch in a new window]' \
                        '--dry-run[Print command without executing]' \
                        '1:Session ID, index, or title:'
                    ;;
                mux|tmux)
                    _arguments \
                        '(-u --unsafe)'{-u,--unsafe}'[Launch in unsafe mode (--dangerously-skip-permissions)]' \
                        '(-s --safe)'{-s,--safe}'[Launch in safe mode]' \
                        '(-b --sandbox)'{-b,--sandbox}'[Launch in sandbox mode]' \
                        '(-w --window)'{-w,--window}'[Launch multiplexer in a new window]' \
                        '--preferred[Preferred multiplexer]:multiplexer:(tmux zellij screen)' \
                        '--dry-run[Print command without executing]' \
                        '1:Session ID, index, or title:'
                    ;;
                list|ls)
                    _arguments \
                        '(-n --limit)'{-n,--limit}'[Number of sessions to display]:limit:' \
                        '(-c --current-dir)'{-c,--current-dir}'[Filter to current workspace directory]'
                    ;;
                search|find)
                    _arguments \
                        '(-n --limit)'{-n,--limit}'[Maximum number of results]:limit:' \
                        '(-c --current-dir)'{-c,--current-dir}'[Filter search to current workspace directory]' \
                        '(-r --resume)'{-r,--resume}'[Prompt to select and resume a matching session]' \
                        '1:Keyword or search term:'
                    ;;
                rename)
                    _arguments \
                        '1:Session ID, index, or title:' \
                        '2:New title:'
                    ;;
                export)
                    _arguments \
                        '--stdout[Print Markdown directly to stdout]' \
                        '1:Session ID, index, or title:' \
                        '2:Output filepath:'
                    ;;
                info|show|kill|delete|rm)
                    _arguments \
                        '1:Session ID, index, or title:'
                    ;;
            esac
            ;;
    esac
}

_agy_sessions "$@"
