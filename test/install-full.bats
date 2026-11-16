#!/usr/bin/env bats
# bin/install-full.sh (make install): the steps in order, YES=1 without questions, no terminal and
# no YES refused, the agents' steps only for their operator, the audit store restarted only when
# a binary changed. The script runs from a copy of the repo whose own installers are stubs; sudo,
# the operator command and the toolkit's sbin tools are stubs too. Nothing real is touched.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    T="$BATS_TEST_TMPDIR"
    export CALLS="$T/calls"; : > "$CALLS"
    # the repo copy: the real script, stub installers
    mkdir -p "$T/repo/bin" "$T/repo/agents" "$T/bin" "$T/sbin"
    cp "$REPO/bin/install-full.sh" "$T/repo/bin/"
    printf '#!/bin/bash\necho "install.sh" >> "$CALLS"\n' > "$T/repo/bin/install.sh"
    printf '#!/bin/bash\necho "agents/install.sh (uid $(id -u))" >> "$CALLS"\n' > "$T/repo/agents/install.sh"
    # sudo runs the command (recording it); the operator command and sbin tools record theirs
    printf '#!/bin/bash\necho "sudo $*" >> "$CALLS"\nexec "$@"\n' > "$T/bin/sudo"
    printf '#!/bin/bash\necho "agent $*" >> "$CALLS"\n' > "$T/bin/agent"
    printf '#!/bin/bash\necho "update-victorialogs" >> "$CALLS"\necho "${VL_OUT:-victoria-logs: as pinned}"\n' > "$T/sbin/update-victorialogs"
    printf '#!/bin/bash\necho "airlock-audit $*" >> "$CALLS"\n' > "$T/sbin/airlock-audit"
    printf '#!/bin/bash\necho "update-runsc $*" >> "$CALLS"\nexit ${RUNSC_RC:-0}\n' > "$T/sbin/update-runsc"
    chmod +x "$T"/repo/bin/* "$T"/repo/agents/* "$T"/bin/* "$T"/sbin/*
    export PATH="$T/bin:$PATH" AIRLOCK_SBIN="$T/sbin" AIRLOCK_AGENTS_ENV="$T/agents.env"
    S="$T/repo/bin/install-full.sh"
}
agents_env() {  # agents_env <operator> <audit on|off>
    printf 'AGENTS_OPERATOR=%s\nAGENTS_COMMAND=agent\nAGENTS_AUDIT=%s\n' "$1" "$2" > "$AIRLOCK_AGENTS_ENV"
}

@test "make install runs bin/install-full.sh, passing YES" {
    grep -qE '^install: ##' "$REPO/Makefile" || return 1
    grep -A1 -E '^install: ##' "$REPO/Makefile" | grep -q 'YES="$(YES)" bash bin/install-full.sh' || return 1
}

@test "YES=1, no agents here: the launcher alone, then done" {
    YES=1 run bash "$S" </dev/null
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(cat "$CALLS")" = "install.sh" ] || return 1
    [[ "$output" == *"==> make install: done"* ]] || return 1
}

@test "YES=1 with agents and the audit store: every step in order; a changed binary restarts the store" {
    agents_env "$(id -un)" on
    VL_OUT='==> installed /usr/local/bin/vmauth (x)' YES=1 run bash "$S" </dev/null
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    want="install.sh
sudo bash $T/repo/agents/install.sh
agents/install.sh (uid $(id -u))
sudo $T/sbin/update-victorialogs
update-victorialogs
sudo $T/sbin/airlock-audit restart --if-stale
airlock-audit restart --if-stale
agent update
agent reload
sudo $T/sbin/airlock-audit check
airlock-audit check
sudo $T/sbin/update-runsc --check
update-runsc --check"
    [ "$(cat "$CALLS")" = "$want" ] || { diff <(echo "$want") "$CALLS"; return 1; }
}

@test "the store's restart is left to airlock-audit (--if-stale: it restarts only an older binary)" {
    agents_env "$(id -un)" on
    YES=1 run bash "$S" </dev/null
    [ "$status" -eq 0 ]
    grep -qx 'airlock-audit restart --if-stale' "$CALLS" || return 1
    ! grep -qx 'airlock-audit restart' "$CALLS" || return 1
}

@test "a checkout with local changes stops before the first root step" {
    agents_env "$(id -un)" off
    git -C "$T/repo" init -q && git -C "$T/repo" add -A && git -C "$T/repo" -c user.email=t@example.org -c user.name=t commit -qm x
    echo '# edited' >> "$T/repo/agents/install.sh"
    YES=1 run bash "$S" </dev/null
    [ "$status" -ne 0 ] || return 1
    [[ "$output" == *"has local changes; the root steps would run them"* ]] || return 1
    ! grep -q '^sudo ' "$CALLS" || return 1
    git -C "$T/repo" checkout -q agents/install.sh
    : > "$CALLS"; YES=1 run bash "$S" </dev/null
    [ "$status" -eq 0 ] && grep -q 'agents/install.sh' "$CALLS" || return 1
    [[ "$output" == *"use a clone no airlock box mounts"* ]] || return 1
}

@test "audit off: no store steps" {
    agents_env "$(id -un)" off
    YES=1 run bash "$S" </dev/null
    [ "$status" -eq 0 ]
    ! grep -qE 'update-victorialogs|airlock-audit' "$CALLS" || return 1
    grep -qx 'agent update' "$CALLS" && grep -qx 'agent reload' "$CALLS" || return 1
}

@test "another operator: the agents' steps are named for them, never run" {
    agents_env someone-else on
    YES=1 run bash "$S" </dev/null
    [ "$status" -eq 0 ]
    ! grep -q '^agent ' "$CALLS" || return 1
    [[ "$output" == *"the agents' own steps are someone-else's: as someone-else, agent update, then agent reload"* ]] || return 1
}

@test "a waiting runsc update is reported, never applied" {
    agents_env "$(id -un)" off
    RUNSC_RC=10 YES=1 run bash "$S" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"a gVisor (runsc) update is waiting"* ]] || return 1
    ! grep -qx 'update-runsc' "$CALLS" || return 1
}

@test "no terminal and no YES: refused before anything runs" {
    command -v setsid >/dev/null || skip "no setsid"
    run setsid -w bash "$S" </dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"rerun with YES=1"* ]] || return 1
    [ ! -s "$CALLS" ] || return 1
}

@test "asks before each step: n skips it, q stops" {
    command -v script >/dev/null || skip "no script(1) for a terminal"
    agents_env "$(id -un)" off
    # answers: launcher n, agents toolkit y, agent update q
    run script -qec "bash $S" /dev/null <<< $'n\ny\nq\n'
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    ! grep -qx 'install.sh' "$CALLS" || return 1
    grep -q 'agents/install.sh' "$CALLS" || return 1
    ! grep -q '^agent ' "$CALLS" || return 1
    [[ "$output" == *"stopped; rerun make install to go on"* ]] || return 1
}

@test "refuses to run as root" {
    grep -q 'run it as yourself' "$S" || return 1
}

@test "the first-time agents question checks the clone too before its root step" {
    command -v script >/dev/null || skip "no script(1)"
    rm -f "$AIRLOCK_AGENTS_ENV"
    git -C "$T/repo" init -q && git -C "$T/repo" add -A && git -C "$T/repo" -c user.email=t@example.org -c user.name=t commit -qm x
    echo stray > "$T/repo/agents/new-file"
    # answers: launcher n, set up agents y
    run script -qec "bash $T/repo/bin/install-full.sh" /dev/null <<< $'n\ny\n'
    [[ "$output" == *"has local changes"* ]] || { echo "$output"; return 1; }
    ! grep -q 'agents/install.sh' "$CALLS" || return 1
}

@test "not a git checkout: said, then on (nothing to compare against)" {
    agents_env "$(id -un)" off
    YES=1 run bash "$S" </dev/null
    [ "$status" -eq 0 ] && [[ "$output" == *"not a git checkout: local changes can't be checked"* ]] || return 1
}
