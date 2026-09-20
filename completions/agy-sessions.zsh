#compdef agy-sessions agys

_agy_sessions() {
    local -a subcommands
    subcommands=(
        'list:List conversation sessions in tabular format'
        'ls:Alias for list'
        'active:Show currently running sessions and PIDs'
        'resume:Resume a session directly'
        'open:Alias for resume'
        'info:Display session details and transcript'
        'show:Alias for info'
        'kill:Terminate a running session process'
        'delete:Delete a conversation session'
        'rm:Alias for delete'
    )

    _arguments -C \
        '(-w --window)'{-w,--window}'[Launch in a new Omarchy terminal window]' \
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
                        '(-w --window)'{-w,--window}'[Launch in a new window]' \
                        '--dry-run[Print command without executing]' \
                        '1:Session ID, index, or title:'
                    ;;
                list|ls)
                    _arguments \
                        '(-n --limit)'{-n,--limit}'[Number of sessions to display]:limit:'
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
