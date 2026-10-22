# bash completion for the agents' operator command (docs/agents.md). Root's copy, sourced from the
# operator's bashrc:
#   source /usr/local/share/airlock-agents/completion.bash
# The command's name is the site's (agents.env). Names are offered only for the bare command
# name as typed, from the installed operator script (`operator _complete`, which checks and cleans
# them), never from the word typed: `./<command> <Tab>` in a directory an agent can write must not
# run that file. Both paths are fixed here; the script runs in a fresh environment (a short
# allowlist, nothing inherited that could steer bash or it) and through absolute paths, and only
# while it and every directory above it are root's, no links, and writable by no one else (a
# sticky directory above its own excepted). Names are checked again
# here and matched by prefix, never expanded (no compgen -W). The operator's own shell functions
# are trusted (a function named builtin or read is the operator's choice).
_airlock_agents_env=/etc/claude-airlock/agents/agents.env
_airlock_agents_bin=/usr/local/lib/airlock-agents/operator
_airlock_agents_owners=0
_airlock_agents_names() {  # _airlock_agents_names <what> [verb]: the installed script's names
    local bin=$_airlock_agents_bin f owner mode n _
    [ "${COMP_WORDS[0]}" = "$_airlock_agents_cmd" ] && [[ $bin == /* ]] && [ -f "$bin" ] && [ ! -L "$bin" ] && [ -x "$bin" ] || return 0
    f=$bin
    while :; do
        [ ! -L "$f" ] || return 0
        owner=$(/usr/bin/stat -c %u -- "$f" 2>/dev/null) mode=$(/usr/bin/stat -c %a -- "$f" 2>/dev/null)
        [[ " $_airlock_agents_owners " == *" $owner "* && $mode =~ ^[0-7]+$ ]] || return 0
        (( (8#$mode & 8#022) == 0 )) || { [ "$f" != "$bin" ] && [ "$f" != "${bin%/*}" ] && (( 8#$mode & 8#1000 )); } || return 0
        [ "$f" = / ] && break
        f=${f%/*}; f=${f:-/}
    done
    # Bounded in time even if the script ignores TERM or leaves a child holding the pipe (the
    # reader is timed too), and in size; read's own timeout beats a user TMOUT.
    /usr/bin/env -i PATH=/usr/bin:/bin HOME="${HOME-}" USER="${USER-}" LOGNAME="${LOGNAME-}" LANG=C.UTF-8 \
        /usr/bin/timeout -k 1 3 "$bin" _complete "$@" </dev/null 2>/dev/null \
        | /usr/bin/timeout -k 1 4 /usr/bin/head -c 65536 | /usr/bin/head -n 200 | while IFS=$'\t' builtin read -t 5 -r n _; do
        [[ $n =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,128}$ ]] && builtin printf '%s\n' "$n"
    done
}
_airlock_agents() {
    local IFS=$' \t\n' cur=${COMP_WORDS[COMP_CWORD]} w
    local -a words=()
    COMPREPLY=()
    if [ "$COMP_CWORD" = 1 ]; then
        words=(ls list new attach stop restart paste update shell reload web help)
    else
        case "${COMP_WORDS[1]}" in
            attach|stop|restart) [ "$COMP_CWORD" = 2 ] && mapfile -t words < <(_airlock_agents_names sessions) ;;
            web)
                if [ "$COMP_CWORD" = 2 ]; then
                    mapfile -t words < <(_airlock_agents_names web-sessions)
                    words+=(new stop restart ask ls show approve reject release retry login)
                elif [ "$COMP_CWORD" = 3 ]; then
                    case "${COMP_WORDS[2]}" in
                        show|approve|reject|release|retry) mapfile -t words < <(_airlock_agents_names ids "${COMP_WORDS[2]}") ;;
                        stop|restart) mapfile -t words < <(_airlock_agents_names web-sessions) ;;
                        login) words=(research gate chat) ;;
                    esac
                fi ;;
        esac
    fi
    for w in "${words[@]}"; do [[ $w == "$cur"* ]] && COMPREPLY+=("$w"); done
}
_airlock_agents_register() {
    local env=$_airlock_agents_env line v cmd=''
    [ -f "$env" ] && [ -r "$env" ] || return 0
    # (patterns, not =~: the user's BASH_REMATCH stays as it was)
    while IFS= builtin read -r line || [ -n "$line" ]; do
        case $line in AGENTS_COMMAND=*) v=${line#AGENTS_COMMAND=} ;; *) continue ;; esac
        case $v in ''|[!a-z_]*|*[!a-z0-9_-]*) continue ;; esac
        [ "${#v}" -le 32 ] && cmd=$v
    done < "$env"
    [ -n "$cmd" ] || return 0
    _airlock_agents_cmd=$cmd
    complete -F _airlock_agents "$cmd"
}
_airlock_agents_register
unset -f _airlock_agents_register
