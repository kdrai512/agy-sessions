# Bash completion for agy-sessions and agys

_agy_sessions() {
    local cur prev words cword
    _init_completion || return

    local commands="list ls active resume open search find rename export info show preview kill delete rm"
    local flags="-h --help -w --window -c --current-dir"

    if [[ $cword -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "$commands $flags" -- "$cur") )
        return 0
    fi

    case "${words[1]}" in
        resume|open)
            local resume_flags="-u --unsafe -s --safe -b --sandbox -w --window --dry-run"
            COMPREPLY=( $(compgen -W "$resume_flags" -- "$cur") )
            return 0
            ;;
        list|ls)
            COMPREPLY=( $(compgen -W "-n --limit -c --current-dir" -- "$cur") )
            return 0
            ;;
        search|find)
            COMPREPLY=( $(compgen -W "-n --limit -c --current-dir -r --resume" -- "$cur") )
            return 0
            ;;
        export)
            COMPREPLY=( $(compgen -W "--stdout" -- "$cur") )
            return 0
            ;;
        *)
            ;;
    esac
}

complete -F _agy_sessions agy-sessions
complete -F _agy_sessions agys
