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
    complete -c $c -f -n "__agy_sessions_needs_command" -a "mux" -d "Open session in terminal multiplexer"
    complete -c $c -f -n "__agy_sessions_needs_command" -a "tmux" -d "Open session specifically in tmux"
    complete -c $c -f -n "__agy_sessions_needs_command" -a "search" -d "Search transcripts for keywords"
    complete -c $c -f -n "__agy_sessions_needs_command" -a "find" -d "Search transcripts (alias)"
    complete -c $c -f -n "__agy_sessions_needs_command" -a "rename" -d "Rename conversation session title"
    complete -c $c -f -n "__agy_sessions_needs_command" -a "export" -d "Export session dialogue to Markdown"
    complete -c $c -f -n "__agy_sessions_needs_command" -a "info" -d "Show session details and transcript"
    complete -c $c -f -n "__agy_sessions_needs_command" -a "show" -d "Show session details (alias)"
    complete -c $c -f -n "__agy_sessions_needs_command" -a "kill" -d "Terminate running session process"
    complete -c $c -f -n "__agy_sessions_needs_command" -a "delete" -d "Delete a conversation session"
    complete -c $c -f -n "__agy_sessions_needs_command" -a "rm" -d "Delete a session (alias)"

    complete -c $c -s w -l window -d "Launch session in a new Omarchy terminal window"
    complete -c $c -s c -l current-dir -d "Filter sessions to current workspace directory"
    complete -c $c -s m -l mux -l multiplexer -d "Open session in terminal multiplexer"
    complete -c $c -l tmux -d "Open session specifically in tmux"
    complete -c $c -s h -l help -d "Show help message"

    # resume subcommands
    complete -c $c -n "__fish_seen_subcommand_from resume open" -s u -l unsafe -d "Launch in unsafe mode (--dangerously-skip-permissions)"
    complete -c $c -n "__fish_seen_subcommand_from resume open" -s s -l safe -d "Launch in safe mode"
    complete -c $c -n "__fish_seen_subcommand_from resume open" -s b -l sandbox -d "Launch in sandbox mode"
    complete -c $c -n "__fish_seen_subcommand_from resume open" -s m -l mux -l multiplexer -d "Open in terminal multiplexer"
    complete -c $c -n "__fish_seen_subcommand_from resume open" -l tmux -d "Open specifically in tmux"
    complete -c $c -n "__fish_seen_subcommand_from resume open" -s w -l window -d "Launch in a new terminal window"
    complete -c $c -n "__fish_seen_subcommand_from resume open" -l dry-run -d "Print command without executing"

    # mux / tmux subcommands
    complete -c $c -n "__fish_seen_subcommand_from mux tmux" -s u -l unsafe -d "Launch in unsafe mode"
    complete -c $c -n "__fish_seen_subcommand_from mux tmux" -s s -l safe -d "Launch in safe mode"
    complete -c $c -n "__fish_seen_subcommand_from mux tmux" -s b -l sandbox -d "Launch in sandbox mode"
    complete -c $c -n "__fish_seen_subcommand_from mux tmux" -s w -l window -d "Launch in a new terminal window"
    complete -c $c -n "__fish_seen_subcommand_from mux tmux" -l preferred -d "Preferred multiplexer (tmux, zellij, screen)"
    complete -c $c -n "__fish_seen_subcommand_from mux tmux" -l dry-run -d "Print command without executing"

    # list subcommands
    complete -c $c -n "__fish_seen_subcommand_from list ls" -s n -l limit -d "Number of sessions to display"
    complete -c $c -n "__fish_seen_subcommand_from list ls" -s c -l current-dir -d "Filter to current workspace directory"

    # search subcommands
    complete -c $c -n "__fish_seen_subcommand_from search find" -s n -l limit -d "Maximum number of results"
    complete -c $c -n "__fish_seen_subcommand_from search find" -s c -l current-dir -d "Filter to current workspace directory"
    complete -c $c -n "__fish_seen_subcommand_from search find" -s r -l resume -d "Prompt to select and resume matching session"

    # export subcommands
    complete -c $c -n "__fish_seen_subcommand_from export" -l stdout -d "Print Markdown directly to stdout"
end
