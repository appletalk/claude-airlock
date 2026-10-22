# bash completion for the agents' operator command (docs/agents.md). Root's copy, sourced from the
# operator's bashrc:
#   source /usr/local/share/airlock-agents/completion.bash
# The command's name is the site's (agents.env); the names offered come from `<command>
# _complete`, which checks and cleans them.
_airlock_agents_names() {  # _airlock_agents_names <command> <what> [verb]: the names alone
    "$@" 2>/dev/null | while IFS=$'\t' read -r n _; do printf '%s\n' "$n"; done
}
_airlock_agents() {
    local cmd=${COMP_WORDS[0]} cur=${COMP_WORDS[COMP_CWORD]} words=""
    if [ "$COMP_CWORD" = 1 ]; then
        words="ls list new attach stop restart paste update shell reload web help"
    else
        case "${COMP_WORDS[1]}" in
            attach|stop|restart) [ "$COMP_CWORD" = 2 ] && words="$(_airlock_agents_names "$cmd" _complete sessions)" ;;
            web)
                if [ "$COMP_CWORD" = 2 ]; then
                    words="new stop restart ask ls show approve reject release retry login $(_airlock_agents_names "$cmd" _complete web-sessions)"
                elif [ "$COMP_CWORD" = 3 ]; then
                    case "${COMP_WORDS[2]}" in
                        show|approve|reject|release|retry) words="$(_airlock_agents_names "$cmd" _complete ids "${COMP_WORDS[2]}")" ;;
                        stop|restart) words="$(_airlock_agents_names "$cmd" _complete web-sessions)" ;;
                        login) words="research gate chat" ;;
                    esac
                fi ;;
        esac
    fi
    mapfile -t COMPREPLY < <(compgen -W "$words" -- "$cur")
}
_airlock_agents_register() {
    local env=${AIRLOCK_AGENTS_ENV:-/etc/claude-airlock/agents/agents.env} line
    [ -r "$env" ] || return 0
    while IFS= read -r line; do
        [[ $line =~ ^AGENTS_COMMAND=([a-z_][a-z0-9_-]{0,31})$ ]] && complete -F _airlock_agents "${BASH_REMATCH[1]}"
    done < "$env"
}
_airlock_agents_register
unset -f _airlock_agents_register
