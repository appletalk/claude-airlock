# Shared by web-worker and guard-worker (docs/agents.md, web research). Sourced, not run.
#
# The host side of the pipeline: it lists queue names, checks them against the id shape,
# keeps its own state, launches boxes with fixed arguments and acts on their exit codes. It
# never opens a file a box or another user wrote, except to copy a run's own transcript (a
# regular, single-link file under a size cap) into the log: every byte from the agent, the web or a
# Claude run is parsed in a box (agents/box/agent_web.py, in the queue's lib/).
# shellcheck shell=bash

# The site's names (rendered by airlock-agents-apply from agents.conf).
# shellcheck source=/dev/null
. "${AIRLOCK_AGENTS_ENV:-/etc/claude-airlock/agents/agents.env}"
# shellcheck disable=SC2034  # these are read by the scripts that source this
QUEUE="${AGENTS_WEB_QUEUE:-$AGENTS_QUEUE}"            # test hooks; never set in use
LIB="${AGENTS_WEB_LIB:-$QUEUE/lib}"
AIRLOCK="${AGENTS_WEB_AIRLOCK:-$HOME/.local/bin/airlock}"
case "${WORKER_ROLE:?}" in web) WORKER="$AGENTS_WEB-worker" ;; guard) WORKER="$AGENTS_GUARD-worker" ;; esac
STATE="$HOME/.local/state/$WORKER"
WS="$HOME/${WORKSPACE_NAME:?}"                      # the one workspace: one Claude login, one state dir
TRIES=3
ID_RE='^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}$'
export PATH=/usr/local/bin:/usr/bin

# Exit codes of agent_web.py (its EXIT_*).
# shellcheck disable=SC2034
EXIT_OK=0 EXIT_ERROR=2 EXIT_HELD=10 EXIT_NO_REPORT=11 EXIT_CHANGED=12 EXIT_HIGH=20 EXIT_QUARANTINE=21

mkdir -p "$STATE" "$WS"

# One JSON line per stage in this user's log dir: the time, id, stage, result and an exit code.
# Every field is ours (ids are checked before they get here), so no quoting is needed.
log_stage() {  # log_stage <id> <stage> <result> [exit]
    printf '{"ts":"%s","user":"%s","id":"%s","stage":"%s","result":"%s","exit":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$USER" "$1" "$2" "$3" "${4:-0}" >> "$LOGD/stages.jsonl"
    echo "$1 $2: $3${4:+ (exit $4)}"
}

state_of() { cat "$STATE/$1" 2>/dev/null || echo new; }
set_state() { printf '%s\n' "$2" > "$STATE/$1.tmp" && mv -f "$STATE/$1.tmp" "$STATE/$1"; }

# A failed attempt. Only a step that ran and failed counts (agent_web.py's EXIT_ERROR): after
# $TRIES the id is given up (the operator sees it in `<command> web ls`). A box that didn't run at all (the
# launcher or the engine failing: any other code) isn't the id's fault and is retried on the
# next pass without counting. The count keeps the flow it belongs to (an approved id stays
# approved).
failed() {  # failed <id> <stage> <exit>
    local st n flow=""
    if [ "$3" != "$EXIT_ERROR" ]; then log_stage "$1" "$2" "box did not run, will retry" "$3"; return 0; fi
    st="$(state_of "$1")"
    case "$st" in approved*) flow=approved- ;; esac
    case "$st" in *tries-[0-9]*) n=$(( ${st##*tries-} + 1 )) ;; *) n=1 ;; esac
    if [ "$n" -ge "$TRIES" ]; then set_state "$1" failed; log_stage "$1" "$2" "failed, gave up" "$3"
    else set_state "$1" "${flow}tries-$n"; log_stage "$1" "$2" "failed, will retry" "$3"; fi
}

# The workspace starts empty for every run: nothing of one question reaches the next. -delete
# never follows a link. If it can't be emptied, nothing runs in it.
clear_ws() {
    find "$WS" -mindepth 1 -delete && [ -z "$(find "$WS" -mindepth 1 -print -quit)" ] \
        || { echo "the workspace $WS could not be emptied; nothing runs until it is" >&2; return 1; }
    # and the box's memory dir for this workspace (AIRLOCK_SHARE_MEMORY=off keeps one per
    # workspace in the launcher's state; the launcher makes it again, empty)
    rm -rf -- "$HOME/.config/claude-airlock/state/$(printf '%s' "$WS" | sed 's#[^a-zA-Z0-9]#-#g; s#^-*##')/box-memory"
}

# A deterministic step in a box: python3 -I on agent_web.py with the given queue dirs mounted.
box_step() {  # box_step "<AIRLOCK_EXTRA_MOUNTS>" <step> <args...>
    local mounts="$1"; shift
    (cd "$WS" && AIRLOCK_EXTRA_MOUNTS="$mounts $LIB:ro" "$AIRLOCK" exec -- python3 -I "$LIB/agent_web.py" "$@") </dev/null
}

# A run's transcript, copied into the log: found by the session id the run was given, in this
# user's ~/.claude/projects/<workspace slug>/ (where the launcher shares a box's history), a regular file with one link (a box could plant a link or a
# hard link to some other file of this user's in its own state), under 50 MB.
copy_transcript() {  # copy_transcript <session-uuid> <id>
    local src dst="$LOGD/transcripts/$2.jsonl"
    src="$(find -P "$HOME/.claude/projects" -mindepth 2 -maxdepth 2 \
        -name "$1.jsonl" -type f -links 1 -size -50M 2>/dev/null | head -1)"
    if [ -z "$src" ]; then log_stage "$2" transcript "not found"; return 0; fi
    cp -- "$src" "$dst.tmp" && chmod 0640 "$dst.tmp" && mv -f -- "$dst.tmp" "$dst"
}

new_uuid() { cat /proc/sys/kernel/random/uuid; }

# The queue's ids: names of the given glob that have the id shape (anything else is skipped and
# logged once by its count, never by name: a name is text its writer chose).
ids_in() {  # ids_in <dir> <suffix>
    local f n bad=0
    for f in "$1"/*"$2"; do
        [ -e "$f" ] || continue
        n="${f%/}"; n="${n##*/}"; [ "$2" = / ] || n="${n%"$2"}"
        if [[ "$n" =~ $ID_RE ]]; then echo "$n"; else bad=$((bad + 1)); fi
    done
    [ "$bad" -eq 0 ] || echo "skipped $bad name(s) that are not ids in ${1##*/}/" >&2
}
