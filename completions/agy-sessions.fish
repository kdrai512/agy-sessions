# Fish completion for agy-sessions and agys

function __agy_sessions_needs_command
    set -l cmd (commandline -opc)
    test (count $cmd) -eq 1
end

for c in agy-sessions agys
    complete -c $c -f -n "__agy_sessions_needs_command" -a "list" -d "List conversation sessions"
    complete -c $c -f -n "__agy_sessions_needs_command" -a "ls" -d "List conversation sessions (alias)"
    complete -c $c -f -n "__agy_sessions_needs_command" -a "active" -d "Show running sessions and PIDs"
    complete -c $c -f -n "__agy_sessions_needs_command" -a "resume" -d "Resume a session directly"
    complete -c $c -f -n "__agy_sessions_needs_command" -a "open" -d "Resume a session (alias)"
    complete -c $c -f -n "__agy_sessions_needs_command" -a "info" -d "Show session details and transcript"
    complete -c $c -f -n "__agy_sessions_needs_command" -a "show" -d "Show session details (alias)"
    complete -c $c -f -n "__agy_sessions_needs_command" -a "kill" -d "Terminate running session process"
    complete -c $c -f -n "__agy_sessions_needs_command" -a "delete" -d "Delete a conversation session"
    complete -c $c -f -n "__agy_sessions_needs_command" -a "rm" -d "Delete a session (alias)"

    complete -c $c -s w -l window -d "Launch session in a new Omarchy terminal window"
    complete -c $c -s h -l help -d "Show help message"

    # resume subcommands
    complete -c $c -n "__fish_seen_subcommand_from resume open" -s u -l unsafe -d "Launch in unsafe mode (--dangerously-skip-permissions)"
    complete -c $c -n "__fish_seen_subcommand_from resume open" -s s -l safe -d "Launch in safe mode"
    complete -c $c -n "__fish_seen_subcommand_from resume open" -s b -l sandbox -d "Launch in sandbox mode"
    complete -c $c -n "__fish_seen_subcommand_from resume open" -s w -l window -d "Launch in a new terminal window"
    complete -c $c -n "__fish_seen_subcommand_from resume open" -l dry-run -d "Print command without executing"
end
