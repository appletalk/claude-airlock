#!/usr/bin/env bats
# agents/lib/session-run (each session resumes its own conversation, named <project>.<name>) and
# session-stop (stop waits for the panes' processes). Fake home and fake /proc and cgroupfs;
# nothing here touches the real system. The site: agent user agent, operator command agent.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    T="$BATS_TEST_TMPDIR"
    RUN="$REPO/agents/lib/session-run"
    # The site's names, as airlock-agents-apply renders them.
    export AIRLOCK_AGENTS_ENV="$T/agents.env"
    printf '%s\n' AGENTS_OPERATOR=alice AGENTS_COMMAND=agent AGENTS_AGENT=agent AGENTS_AGENT_UID=1100 > "$AIRLOCK_AGENTS_ENV"
    h="$T/home"; mkdir -p "$h/.local/bin" "$h/development/proj" "$h/development/proj2" "$T/sb"
    # airlock records its arguments; sleep ends the loop after one run
    printf '#!/bin/sh\necho "$*" >> "$HOME/calls"\n' > "$h/.local/bin/airlock"
    printf '#!/bin/sh\nkill -TERM "$PPID"\n' > "$T/sb/sleep"
    chmod +x "$h/.local/bin/airlock" "$T/sb/sleep"
}
session() { rm -f "$h/calls"; mkdir -p "$T/run" "$T/cg"; HOME="$h" XDG_RUNTIME_DIR="$T/run" AGENTS_CGROUP_ROOT="$T/cg" PATH="$T/sb:$PATH" run "$RUN" "$1"; }
calls() { cat "$h/calls"; }
convs() { printf '%s/.claude/projects/%s' "$h" "$(printf '%s' "$h/development/$1" | sed 's#[^a-zA-Z0-9]#-#g')"; }  # claude-airlock's HISTSLUG
idof() { cat "$h/.local/state/agent-session/$1.id"; }
UUID='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

@test "a session runs ~/.local/bin/airlock with Remote Control, its name, and a session id of its own" {
    session proj.main
    [[ "$(calls)" =~ ^--remote-control\ --name\ proj\.main\ --session-id\ ($UUID)$ ]]
    [ "${BASH_REMATCH[1]}" = "$(idof proj.main)" ]
    grep -qx 'AIRLOCK_PERSIST_LOGIN=1' "$REPO/agents/templates/agent.conf"
}

@test "once its conversation exists the session resumes it by id; before that a restart starts fresh" {
    session proj.main; first="$(idof proj.main)"
    session proj.main                                  # no transcript yet: a new id
    second="$(idof proj.main)"; [ "$second" != "$first" ]
    mkdir -p "$(convs proj)" && : > "$(convs proj)/$second.jsonl"
    session proj.main
    [ "$(calls)" = "--remote-control --name proj.main --resume $second" ]
    [ "$(idof proj.main)" = "$second" ]
}

@test "two sessions in one project keep their own conversations, whichever is newest" {
    session proj.main; a="$(idof proj.main)"
    session proj.review; b="$(idof proj.review)"
    [ "$a" != "$b" ]
    mkdir -p "$(convs proj)"; : > "$(convs proj)/$a.jsonl"; sleep 0.01 2>/dev/null; touch "$(convs proj)/$b.jsonl"
    session proj.main;   [ "$(calls)" = "--remote-control --name proj.main --resume $a" ]
    session proj.review; [ "$(calls)" = "--remote-control --name proj.review --resume $b" ]
}

@test "the first run with no state at all: main keeps the newest conversation (as --continue did), others start fresh" {
    mkdir -p "$(convs proj)"
    old=11111111-1111-4111-8111-111111111111 new=22222222-2222-4222-8222-222222222222
    : > "$(convs proj)/$old.jsonl"; touch -d '2 days ago' "$(convs proj)/$old.jsonl"; : > "$(convs proj)/$new.jsonl"
    session proj.main
    [ "$(calls)" = "--remote-control --name proj.main --resume $new" ]
    session proj.review
    [[ "$(calls)" == "--remote-control --name proj.review --session-id "* && "$(calls)" != *"$new"* ]]
    # per project: another project's main keeps its own newest
    mkdir -p "$(convs proj2)"; : > "$(convs proj2)/$old.jsonl"
    session proj2.main
    [ "$(calls)" = "--remote-control --name proj2.main --resume $old" ]
}

@test "the adoption is once per project: wiping ~/.local/state doesn't re-arm it to take another session's conversation" {
    session proj.main; a="$(idof proj.main)"
    session proj.review; b="$(idof proj.review)"
    mkdir -p "$(convs proj)"; : > "$(convs proj)/$a.jsonl"; touch -d '1 hour ago' "$(convs proj)/$a.jsonl"; : > "$(convs proj)/$b.jsonl"
    rm -rf "$h/.local/state"
    session proj.main
    [[ "$(calls)" == *"--session-id "* && "$(calls)" != *"$b"* ]] || { echo "main took: $(calls)"; return 1; }
}

@test "adoption skips non-uuid transcripts; once review has run first, main adopts nothing" {
    mkdir -p "$(convs proj)"
    mine=11111111-1111-4111-8111-111111111111
    : > "$(convs proj)/$mine.jsonl"; touch -d '1 hour ago' "$(convs proj)/$mine.jsonl"
    : > "$(convs proj)/agent-x.jsonl"                                   # newest, but not a uuid
    session proj.main
    [ "$(calls)" = "--remote-control --name proj.main --resume $mine" ]
    # another project where review ran first: its id is recorded, so main starts fresh
    mkdir -p "$(convs proj2)"; : > "$(convs proj2)/$mine.jsonl"
    session proj2.review
    session proj2.main
    [[ "$(calls)" == *"--session-id "* && "$(calls)" != *"$mine"* ]]
}

@test "a newer conversation carrying the session's name (after a /clear) is resumed, never one with another name" {
    session proj.main; a="$(idof proj.main)"
    mkdir -p "$(convs proj)"
    printf '{"type":"custom-title","customTitle":"proj.main","sessionId":"%s"}\n' "$a" > "$(convs proj)/$a.jsonl"
    touch -d '1 hour ago' "$(convs proj)/$a.jsonl"
    cleared=33333333-3333-4333-8333-333333333333 other=44444444-4444-4444-8444-444444444444
    printf '{"type":"custom-title","customTitle":"proj.main","sessionId":"%s"}\n' "$cleared" > "$(convs proj)/$cleared.jsonl"
    session proj.main
    [ "$(calls)" = "--remote-control --name proj.main --resume $cleared" ] && [ "$(idof proj.main)" = "$cleared" ]
    # renamed away later: the last title counts; a newer one named for another session is not ours
    printf '{"type":"custom-title","customTitle":"proj.review","sessionId":"%s"}\n' "$other" > "$(convs proj)/$other.jsonl"
    session proj.main
    [ "$(calls)" = "--remote-control --name proj.main --resume $cleared" ]
}

@test "a garbage state id is refused even when a file of that name exists" {
    mkdir -p "$h/.local/state/agent-session" "$(convs proj)"
    echo "not-a-uuid" > "$h/.local/state/agent-session/proj.main.id"; : > "$(convs proj)/not-a-uuid.jsonl"
    : > "$(convs proj)/.agent-session-adopted"
    session proj.main
    [[ "$(calls)" =~ ^--remote-control\ --name\ proj\.main\ --session-id\ $UUID$ ]]
}

@test "a session records its cgroup for stop (in case tmux is gone)" {
    session proj.main
    [ -f "$T/run/agent-proj.main.cg" ]
}

@test "a state file that isn't a uuid (garbage, a path) is never passed on: a fresh id" {
    mkdir -p "$h/.local/state/agent-session" "$(convs proj)"
    for bad in "../../etc/passwd" "x; rm -rf ~" "--settings=/tmp/evil" ""; do
        printf '%s\n' "$bad" > "$h/.local/state/agent-session/proj.main.id"
        session proj.main
        [[ "$(calls)" =~ ^--remote-control\ --name\ proj\.main\ --session-id\ $UUID$ ]] || { echo "with '$bad': $(calls)"; return 1; }
    done
}

@test "bad session names are refused before anything runs" {
    for bad in "proj" "proj." ".main" "proj.a.b" "../x.main" "proj.-x" "p r.main"; do
        session "$bad"
        [ "$status" -eq 2 ] || { echo "accepted: $bad"; return 1; }
        [ ! -e "$h/calls" ]
    done
}

# ---- session-stop ----------------------------------------------------------------------

stop_setup() {
    S="$REPO/agents/lib/session-stop"
    export AGENTS_STOP_ROOT="$T/fake" LOG="$T/tmux.log" KILLED="$T/killed"
    U=/user.slice/user-1100.slice/user@1100.service/app.slice
    C="$T/fake/sys/fs/cgroup$U"
    mkdir -p "$T/fake/proc/self" "$T/fake/proc/100" "$T/fake/proc/200" "$C/svc.service" \
        "$C/tmux-spawn-a.scope" "$C/tmux-spawn-b.scope" "$C/tmux-spawn-c.scope"
    echo "0::$U/svc.service" > "$T/fake/proc/self/cgroup"
    echo "0::$U/tmux-spawn-a.scope" > "$T/fake/proc/100/cgroup"
    echo "0::$U/tmux-spawn-b.scope" > "$T/fake/proc/200/cgroup"
    echo 999 > "$C/svc.service/cgroup.procs"; echo "populated 1" > "$C/svc.service/cgroup.events"                       # the service itself: never waited on
    : > "$C/tmux-spawn-a.scope/cgroup.procs"; echo "populated 0" > "$C/tmux-spawn-a.scope/cgroup.events"; : > "$C/tmux-spawn-b.scope/cgroup.procs"; echo "populated 0" > "$C/tmux-spawn-b.scope/cgroup.events"; : > "$C/tmux-spawn-c.scope/cgroup.procs"; echo "populated 0" > "$C/tmux-spawn-c.scope/cgroup.events"
    # tmux: lists the panes until kill-server, nothing after (a real server is gone then)
    cat > "$T/sb/tmux" <<'X'
#!/bin/sh
echo "tmux $*" >> "$LOG"
case "$*" in
    *kill-server*) : > "$LOG.dead" ;;
    *list-panes*) [ -e "$LOG.dead" ] && exit 1; printf '100\n200\n' ;;
esac
X
    chmod +x "$T/sb/tmux"; rm -f "$T/sb/sleep"
}
stop() { PATH="$T/sb:$PATH" run "$S" "$@"; }

@test "stop asks tmux for the panes before killing it, then waits until every pane's cgroup is empty" {
    stop_setup
    echo 4242 > "$C/tmux-spawn-a.scope/cgroup.procs"; echo "populated 1" > "$C/tmux-spawn-a.scope/cgroup.events"
    ( sleep 1.5; : > "$C/tmux-spawn-a.scope/cgroup.procs"; echo "populated 0" > "$C/tmux-spawn-a.scope/cgroup.events" ) &
    start=$(date +%s%N)
    stop /run/user/1100/agent-proj.main.sock
    took=$(( ($(date +%s%N) - start) / 1000000 ))
    [ "$status" -eq 0 ]
    [ "$(head -1 "$LOG")" = "tmux -S /run/user/1100/agent-proj.main.sock list-panes -a -F #{pane_pid}" ]
    grep -qx "tmux -S /run/user/1100/agent-proj.main.sock kill-server" "$LOG"
    [ "$took" -ge 1400 ] || { echo "returned after $took ms, before the pane's processes exited"; return 1; }
    [ "$took" -lt 5000 ]
}

@test "with tmux already gone, stop still waits on the cgroup the session recorded" {
    stop_setup
    : > "$LOG.dead"
    echo "$U/tmux-spawn-c.scope" > "$T/run.cg"
    echo 4242 > "$C/tmux-spawn-c.scope/cgroup.procs"; echo "populated 1" > "$C/tmux-spawn-c.scope/cgroup.events"
    ( sleep 1.5; : > "$C/tmux-spawn-c.scope/cgroup.procs"; echo "populated 0" > "$C/tmux-spawn-c.scope/cgroup.events" ) &
    start=$(date +%s%N)
    stop /x.sock "$T/run.cg"
    took=$(( ($(date +%s%N) - start) / 1000000 ))
    [ "$status" -eq 0 ] && [ "$took" -ge 1400 ]
}

@test "after the wait stop says what is still running and returns; it kills nothing, its own and non-pane cgroups are never waited on" {
    stop_setup
    echo 4242 > "$C/tmux-spawn-b.scope/cgroup.procs"; echo "populated 1" > "$C/tmux-spawn-b.scope/cgroup.events"
    echo "$U/svc.service" > "$T/bad.cg"                              # recorded path that isn't a pane scope
    echo "0::$U/svc.service" > "$T/fake/proc/100/cgroup"            # a pane in the service's own cgroup
    AGENTS_STOP_WAIT=1 stop /x.sock "$T/bad.cg"
    [ "$status" -eq 0 ]
    [[ "$output" == *"still running after 1 s (the next run waits for it): tmux-spawn-b.scope" ]] || { echo "$output"; return 1; }
    [ -z "$(find "$T/fake" -name cgroup.kill)" ]
}

@test "stop ignores recorded paths that aren't plain pane scopes: .., a sub-cgroup, no leading /" {
    stop_setup
    : > "$LOG.dead"
    mkdir -p "$C/tmux-spawn-x.scope/sub" "$C/a" "$T/fake/sys/fs/cgroup${U#/}/tmux-spawn-x.scope"
    echo "populated 1" > "$T/fake/sys/fs/cgroup${U#/}/tmux-spawn-x.scope/cgroup.events"
    echo 1 > "$C/tmux-spawn-x.scope/cgroup.procs"; echo "populated 1" > "$C/tmux-spawn-x.scope/cgroup.events"; echo 1 > "$C/tmux-spawn-x.scope/sub/cgroup.procs"; echo "populated 1" > "$C/tmux-spawn-x.scope/sub/cgroup.events"
    for bad in "$U/a/../tmux-spawn-x.scope" "$U/tmux-spawn-x.scope/sub" "${U#/}/tmux-spawn-x.scope"; do
        printf '%s\n' "$bad" > "$T/odd.cg"
        AGENTS_STOP_ROOT="$T/fake" AGENTS_STOP_WAIT=1 stop /x.sock "$T/odd.cg"
        [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "waited on $bad: $output"; return 1; }
    done
    printf '%s\n' "$U/tmux-spawn-x.scope" > "$T/odd.cg"              # control: the plain one is waited on
    AGENTS_STOP_WAIT=1 stop /x.sock "$T/odd.cg"
    [[ "$output" == *"tmux-spawn-x.scope"* ]]
}

@test "the unit stops through session-stop, with time for its wait" {
    "$REPO/agents/airlock-agents-apply" --render "$T/render" "$REPO/agents/agents.conf.example" >/dev/null
    u="$T/render/etc/systemd/user/claude-session@.service"
    grep -qx 'ExecStop=/usr/local/lib/airlock-agents/session-stop %t/claude-%i.sock %t/claude-%i.cg' "$u"
    grep -qx 'TimeoutStopSec=90' "$u"
    [ -x "$REPO/agents/lib/session-stop" ]
}

@test "a restart waits until the previous run of the same session is gone; never for another's, never for its own" {
    mkdir -p "$T/run" "$T/cg/x/tmux-spawn-old.scope"
    echo /x/tmux-spawn-old.scope > "$T/run/agent-proj.main.cg"
    echo 4242 > "$T/cg/x/tmux-spawn-old.scope/cgroup.procs"; echo "populated 1" > "$T/cg/x/tmux-spawn-old.scope/cgroup.events"
    # sleep 1 (the wait) ends the old run; sleep 10 (after Claude) ends the loop
    printf '#!/bin/sh\nif [ "$1" = 1 ]; then echo "populated 0" > "%s"; exit 0; fi\nkill -TERM "$PPID"\n' "$T/cg/x/tmux-spawn-old.scope/cgroup.events" > "$T/sb/sleep"
    session proj.main
    [[ "$output" == *"the previous run of proj.main is still finishing (tmux-spawn-old.scope); waiting"* ]] || { echo "$output"; return 1; }
    [ -e "$h/calls" ]                                                # and then it started
    # another session's recorded cgroup, or a path that isn't a pane scope: no wait
    printf '#!/bin/sh\nkill -TERM "$PPID"\n' > "$T/sb/sleep"
    echo 4242 > "$T/cg/x/tmux-spawn-old.scope/cgroup.procs"; echo "populated 1" > "$T/cg/x/tmux-spawn-old.scope/cgroup.events"
    echo /x/tmux-spawn-old.scope > "$T/run/agent-proj.review.cg"
    for bad in /x "/x/a/../tmux-spawn-old.scope" "x/tmux-spawn-old.scope" "/x/tmux-spawn-old.scope/sub"; do
        mkdir -p "$T/cg/x/a" "$T/cgx/tmux-spawn-old.scope" "$T/cg/x/tmux-spawn-old.scope/sub"
        echo "populated 1" > "$T/cgx/tmux-spawn-old.scope/cgroup.events"   # where "x/..." (no leading /) would point
        echo "populated 1" > "$T/cg/x/tmux-spawn-old.scope/sub/cgroup.events"
        printf '%s\n' "$bad" > "$T/run/agent-proj.main.cg"
        session proj.main
        [[ "$output" != *"still finishing"* ]] && [ -e "$h/calls" ] || { echo "waited on $bad"; return 1; }
    done
}

@test "the wait counts a child cgroup of the old scope, and lists what is there, child included, as plain text" {
    mkdir -p "$T/run" "$T/cg/x/tmux-spawn-old.scope/child" "$T/fp/proc/4242"
    echo /x/tmux-spawn-old.scope > "$T/run/agent-proj.main.cg"
    echo "populated 1" > "$T/cg/x/tmux-spawn-old.scope/cgroup.events"
    : > "$T/cg/x/tmux-spawn-old.scope/cgroup.procs"                       # the scope itself: empty
    printf '4242\nnot-a-pid\n' > "$T/cg/x/tmux-spawn-old.scope/child/cgroup.procs"   # only the child holds one
    # its argv: escapes (OSC title, CSI colour, C1 CSI) and more than 100 characters
    printf 'evil\0\033]0;title\007\033[31mred\302\233x\0%s\0' "$(printf 'a%.0s' $(seq 1 150))" > "$T/fp/proc/4242/cmdline"
    printf '#!/bin/sh\nif [ "$1" = 1 ]; then echo "populated 0" > "%s"; exit 0; fi\nkill -TERM "$PPID"\n' "$T/cg/x/tmux-spawn-old.scope/cgroup.events" > "$T/sb/sleep"
    AGENTS_PROC_ROOT="$T/fp" session proj.main
    [[ "$output" == *"still finishing"*"Still there:"*"  4242 evil "*"agent shell, then kill <pid>"* ]] || { echo "$output"; return 1; }
    line="$(grep '^  4242 ' <<<"$output")"
    [[ "$line" != *$'\033'* && "$line" != *$'\007'* && "$line" != *$'\302'* && "$line" != *"not-a-pid"* ]] || { printf '%q\n' "$line"; return 1; }
    [ "${#line}" -le 110 ]
    [[ "$output" != *"No such file"* && "$output" != *"not-a-pid"* ]]
}

@test "the wait prints no shell errors when the old scope vanishes mid-listing" {
    mkdir -p "$T/run" "$T/cg/x/tmux-spawn-old.scope"
    echo /x/tmux-spawn-old.scope > "$T/run/agent-proj.main.cg"
    echo "populated 1" > "$T/cg/x/tmux-spawn-old.scope/cgroup.events"     # no cgroup.procs at all
    printf '#!/bin/sh\nif [ "$1" = 1 ]; then echo "populated 0" > "%s"; exit 0; fi\nkill -TERM "$PPID"\n' "$T/cg/x/tmux-spawn-old.scope/cgroup.events" > "$T/sb/sleep"
    session proj.main
    [[ "$output" == *"still finishing"* && "$output" != *"No such file"* && "$output" != *"line "* ]] || { echo "$output"; return 1; }
}

@test "adoption takes only a conversation from before sessions were named, never one carrying any <project>. name" {
    mkdir -p "$(convs proj)"
    legacy=11111111-1111-4111-8111-111111111111 webs=22222222-2222-4222-8222-222222222222
    printf '{"type":"user"}\n' > "$(convs proj)/$legacy.jsonl"; touch -d '1 hour ago' "$(convs proj)/$legacy.jsonl"
    # web's conversation after a /clear: not yet in web's id file, but it carries web's name
    printf '{"type":"custom-title","customTitle":"proj.web","sessionId":"%s"}\n{"type":"user"}\n' "$webs" > "$(convs proj)/$webs.jsonl"
    session proj.main
    [ "$(calls)" = "--remote-control --name proj.main --resume $legacy" ] || { echo "$(calls)"; return 1; }
}

@test "the last title counts: a conversation renamed away is not this session's, renamed to it is" {
    session proj.main; a="$(idof proj.main)"
    mkdir -p "$(convs proj)"; : > "$(convs proj)/$a.jsonl"; touch -d '1 hour ago' "$(convs proj)/$a.jsonl"
    away=55555555-5555-4555-8555-555555555555 to=66666666-6666-4666-8666-666666666666
    printf '{"customTitle":"proj.main"}\n{"customTitle":"proj.main"}\n{"customTitle":"proj.review"}\n' > "$(convs proj)/$away.jsonl"
    session proj.main
    [ "$(calls)" = "--remote-control --name proj.main --resume $a" ]
    printf '{"customTitle":"proj.review"}\n{"customTitle":"proj.main"}\n' > "$(convs proj)/$to.jsonl"
    session proj.main
    [ "$(calls)" = "--remote-control --name proj.main --resume $to" ]
}

@test "an id another session has recorded is never resumed, even from this session's own id file" {
    mkdir -p "$h/.local/state/agent-session" "$(convs proj)"
    shared=77777777-7777-4777-8777-777777777777
    : > "$(convs proj)/$shared.jsonl"; : > "$(convs proj)/.agent-session-adopted"
    echo "$shared" > "$h/.local/state/agent-session/proj.main.id"; echo "$shared" > "$h/.local/state/agent-session/proj.review.id"
    session proj.main
    [[ "$(calls)" == *"--session-id "* && "$(calls)" != *"$shared"* ]]
}

@test "main never drops its own id for an adoption, even with the marker gone" {
    session proj.main; a="$(idof proj.main)"
    mkdir -p "$(convs proj)"; : > "$(convs proj)/$a.jsonl"; touch -d '1 hour ago' "$(convs proj)/$a.jsonl"
    : > "$(convs proj)/88888888-8888-4888-8888-888888888888.jsonl"
    rm -f "$(convs proj)/.agent-session-adopted"
    session proj.main
    [ "$(calls)" = "--remote-control --name proj.main --resume $a" ]
}

@test "main adopts nothing once any session of the project has recorded an id (a /clear'd, still unnamed conversation of another is never taken)" {
    mkdir -p "$(convs proj)"
    x=11111111-1111-4111-8111-111111111111 y=22222222-2222-4222-8222-222222222222
    printf '{"type":"user"}\n' > "$(convs proj)/$x.jsonl"; touch -d '1 hour ago' "$(convs proj)/$x.jsonl"
    mkdir -p "$h/.local/state/agent-session"; echo "$x" > "$h/.local/state/agent-session/proj.web.id"
    printf '{"type":"user"}\n' > "$(convs proj)/$y.jsonl"             # web's /clear: no title yet
    session proj.main
    [[ "$(calls)" == *"--session-id "* && "$(calls)" != *"$y"* ]] || { echo "$(calls)"; return 1; }
}

@test "a symlink or a directory named like a transcript is never adopted or resumed; ids are matched whole" {
    mkdir -p "$(convs proj)" "$T/elsewhere"
    l=33333333-3333-4333-8333-333333333333 d=44444444-4444-4444-8444-444444444444
    printf '{"type":"user"}\n' > "$T/elsewhere/t"; ln -s "$T/elsewhere/t" "$(convs proj)/$l.jsonl"
    mkdir "$(convs proj)/$d.jsonl"
    : > "$(convs proj)/x$l.jsonl"                                       # not a uuid at the start
    session proj.main
    [[ "$(calls)" == *"--session-id "* && "$(calls)" != *"$l"* && "$(calls)" != *"$d"* ]] || { echo "$(calls)"; return 1; }
    [ "$(idof proj.main)" != "$l" ] && [ "$(idof proj.main)" != "$d" ]   # not even recorded
}

@test "the recorded id stays when an older conversation still carries the session's name" {
    session proj.main; a="$(idof proj.main)"
    mkdir -p "$(convs proj)"; : > "$(convs proj)/$a.jsonl"
    old=55555555-5555-4555-8555-555555555555
    printf '{"customTitle":"proj.main"}\n' > "$(convs proj)/$old.jsonl"; touch -d '1 hour ago' "$(convs proj)/$old.jsonl"
    session proj.main
    [ "$(calls)" = "--remote-control --name proj.main --resume $a" ]
}

@test "stop waits on a pane scope whose only processes are in a child cgroup" {
    stop_setup
    mkdir -p "$C/tmux-spawn-a.scope/child"
    echo "populated 1" > "$C/tmux-spawn-a.scope/cgroup.events"; : > "$C/tmux-spawn-a.scope/cgroup.procs"
    echo 4242 > "$C/tmux-spawn-a.scope/child/cgroup.procs"
    AGENTS_STOP_WAIT=1 stop /x.sock
    [[ "$output" == *"still running after 1 s"*"tmux-spawn-a.scope"* ]] || { echo "$output"; return 1; }
}
