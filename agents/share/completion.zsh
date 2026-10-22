# zsh completion for the agents' operator command (docs/agents.md). Root's copy, sourced from the
# operator's zshrc after compinit:
#   source /usr/local/share/airlock-agents/completion.zsh
# The command's name is the site's (agents.env). Names are offered only for the bare command
# name as typed, from the installed command (<bindir>/<command> _complete, which checks and cleans
# them), never from the word typed: `./<command> <Tab>` in a directory an agent can write must not run
# that file. Each name is checked again here, descriptions stripped of control characters.
() {
    emulate -L zsh
    local env=${AIRLOCK_AGENTS_ENV:-/etc/claude-airlock/agents/agents.env} line cmd=
    local -a match mbegin mend
    [[ -f $env && -r $env ]] || return 0
    for line in "${(@f)$(<$env)}"; do
        [[ $line =~ '^AGENTS_COMMAND=([a-z_][a-z0-9_-]{0,31})$' ]] && cmd=${match[1]}
    done
    [[ -n $cmd ]] || return 0
    typeset -g _airlock_agents_cmd=$cmd
    (( ${+functions[compdef]} )) && compdef _airlock_agents "$cmd"
}

# _airlock_agents_items <what> [verb]: the installed command's names as name:description
_airlock_agents_items() {
    # (no emulate here: compsys has set its own options, and _describe needs them)
    local bin=${AIRLOCK_AGENTS_BINDIR:-/usr/local/bin}/$_airlock_agents_cmd line n d owner mode
    local -a items
    # only the bare name, and only a program root's or the operator's own that no one else can write
    [[ $words[1] == $_airlock_agents_cmd && -f $bin && -x $bin ]] || return 1
    owner=$(command stat -Lc %u -- $bin 2>/dev/null) mode=$(command stat -Lc %a -- $bin 2>/dev/null)
    [[ ( $owner == 0 || $owner == $UID ) && $mode == <-> && $(( 8#$mode & 8#022 )) -eq 0 ]] || return 1
    for line in "${(@f)$(command timeout 5 $bin _complete "$@" </dev/null 2>/dev/null | command head -n 200)}"; do
        n=${line%%$'\t'*} d=${line#*$'\t'}
        [[ $line == *$'\t'* && $n =~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,128}$' ]] || continue
        items+=("$n:${${d//[[:cntrl:]]/}[1,60]}")
    done
    _describe -t names "${1//-/ }" items
}

_airlock_agents() {
    local -a cmds webcmds
    cmds=(
        'ls:sessions and their state' 'list:sessions and their state' 'new:start a session' 'attach:join a session'
        'stop:stop a session' 'restart:restart a session' 'paste:the clipboard image into the inbox'
        'update:give the agent users your claude-airlock' 'shell:a shell as the agent'
        'reload:reload the agents'"'"' user units' 'web:web research' 'help:usage'
    )
    webcmds=(
        'new:start another interactive session' 'stop:end an interactive session'
        'restart:a fresh interactive session' 'ask:queue a question' 'ls:every question and its state'
        'show:an answer, quarantine findings or a held question' 'approve:a held question'
        'reject:a held question' 'release:a quarantined answer' 'retry:an id a worker gave up on'
        'login:/login in the web boxes'
    )
    if (( CURRENT == 2 )); then _describe -t commands command cmds; return; fi
    case ${words[2]} in
        attach|stop|restart) (( CURRENT == 3 )) && _airlock_agents_items sessions ;;
        new) (( CURRENT == 3 )) && _message 'project (a folder in the agent'"'"'s ~/development)' ;;
        web)
            if (( CURRENT == 3 )); then
                _describe -t commands 'web command' webcmds
                _airlock_agents_items web-sessions
            elif (( CURRENT == 4 )); then
                case ${words[3]} in
                    show|approve|reject|release|retry) _airlock_agents_items ids "${words[3]}" ;;
                    stop|restart) _airlock_agents_items web-sessions ;;
                    login) _values 'workspace' research gate chat ;;
                    ask) _message 'question (quoted)' ;;
                    new) _message 'session name' ;;
                esac
            fi ;;
    esac
}
