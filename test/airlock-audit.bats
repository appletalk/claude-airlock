#!/usr/bin/env bats
# agents/airlock-audit: status, restart, reset, check. systemctl, curl, ss and journalctl are
# stubs; file paths (the store, the cursor, /proc) go under AIRLOCK_AUDIT_ROOT. Nothing real is touched.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    T="$BATS_TEST_TMPDIR"
    export AIRLOCK_AUDIT_ROOT="$T/root" CALLS="$T/calls"; : > "$CALLS"
    R="$AIRLOCK_AUDIT_ROOT"
    mkdir -p "$R/var/lib/airlock-audit/vl/partitions" "$R/var/lib/airlock-audit-journal" "$T/bin"
    echo data > "$R/var/lib/airlock-audit/vl/partitions/x"; echo 's=abc' > "$R/var/lib/airlock-audit-journal/cursor"
    # /proc: the host's netns, and pids 101-103 (vl, vmauth, vector) in the store's
    for p in 1 101 102 103; do mkdir -p "$R/proc/$p/ns"; done
    ln -s 'net:[1]' "$R/proc/1/ns/net"
    for p in 101 102 103; do ln -s "net:[${NETNS:-999}]" "$R/proc/$p/ns/net"; done
    # systemctl: start/stop recorded; is-active from INACTIVE (a unit named there is failed);
    # show MainPID: 101/102/103; cat: present
    cat > "$T/bin/systemctl" <<'EOF'
#!/bin/bash
case "$1" in
    cat) exit 0 ;;
    is-active) [[ " ${INACTIVE:-} " == *" ${*: -1} "* ]] && { echo failed; exit 3; }; [ "$2" = --quiet ] || echo active; exit 0 ;;
    show) case "${*: -1}" in airlock-audit-vl.service) echo 101 ;; airlock-audit-vmauth.service) echo 102 ;; airlock-audit-vector.service) echo 103 ;; *) echo ;; esac ;;
    *) echo "systemctl $*" >> "$CALLS" ;;
esac
EOF
    # curl: a POST answers DOOR (default 400); GET of vmauth's own endpoints KEYED (default 401);
    # a query answers QUERY
    cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
url="${*: -1}"; post=0; for a; do [ "$a" = -X ] && post=1; done
for a; do case "$a" in http://x*) url=$a ;; esac; done
if [[ "$url" == */select/logsql/query ]]; then echo "${QUERY-{\"n\":\"42\",\"oldest\":\"2026-10-16T00:00:00Z\",\"newest\":\"2026-11-16T00:00:00Z\"}}"; exit 0; fi
if [ "$post" = 1 ]; then printf '%s' "${DOOR:-400}"; else printf '%s' "${KEYED:-401}"; fi
EOF
    printf '#!/bin/bash\n[ -z "${LISTEN:-}" ] || echo "LISTEN 0 4096 127.0.0.1:9428 0.0.0.0:*"\n' > "$T/bin/ss"
    printf '#!/bin/bash\n[ -z "${KILLS:-}" ] || echo "$KILLS"\n' > "$T/bin/journalctl"
    chmod +x "$T"/bin/*
    export PATH="$T/bin:$PATH"
    A="$REPO/agents/airlock-audit"
}

@test "usage: no command, an unknown one, stray arguments" {
    run "$A"; [ "$status" -eq 2 ]
    run "$A" frobnicate; [ "$status" -ne 0 ]; [[ "$output" == *"unknown command"* ]]
    run "$A" status extra; [ "$status" -ne 0 ]
    run "$A" reset --force; [ "$status" -ne 0 ]
}

@test "restart: stop in order (the reader first, the store last), start in reverse, the socket last" {
    run "$A" restart
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(sed -n 1p "$CALLS")" = "systemctl stop airlock-audit-journal.service airlock-audit-vector.service airlock-audit-vl-proxy.socket airlock-audit-vl-proxy.service airlock-audit-vmauth.service airlock-audit-vl.service" ]
    [ "$(sed -n 2p "$CALLS")" = "systemctl start airlock-audit-vl.service airlock-audit-vmauth.service airlock-audit-vector.service airlock-audit-journal.service airlock-audit-vl-proxy.socket" ]
}

@test "reset without a terminal or --yes changes nothing" {
    command -v setsid >/dev/null || skip "no setsid"
    run setsid -w "$A" reset </dev/null
    [ "$status" -ne 0 ]; [[ "$output" == *"reset --yes"* ]]
    [ -f "$R/var/lib/airlock-audit/vl/partitions/x" ] && [ -f "$R/var/lib/airlock-audit-journal/cursor" ]
    [ ! -s "$CALLS" ]
}

@test "reset asks; no keeps everything" {
    command -v script >/dev/null || skip "no script(1)"
    run script -qec "$A reset" /dev/null <<< $'n\n'
    [ -f "$R/var/lib/airlock-audit/vl/partitions/x" ]; [ ! -s "$CALLS" ]
    [[ "$output" == *"nothing changed"* ]]
}

@test "reset --yes: stopped, the store emptied (its directory kept), the cursor gone, started" {
    run "$A" reset --yes
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -d "$R/var/lib/airlock-audit/vl" ] && [ -z "$(ls -A "$R/var/lib/airlock-audit/vl")" ]
    [ ! -e "$R/var/lib/airlock-audit-journal/cursor" ]
    [[ "$(sed -n 1p "$CALLS")" == "systemctl stop "* ]] && [[ "$(sed -n 2p "$CALLS")" == "systemctl start "* ]]
    [[ "$output" == *"The journal"*"not touched"* ]]
}

@test "check passes when every guarantee holds" {
    run "$A" check
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"==> the audit store holds up"* ]]
    [ "$(grep -c '^ok ' <<< "$output")" -ge 16 ]
}

@test "check fails on: a door that lets a write through, an open vmauth endpoint, a host listener, a unit down, no answer" {
    DOOR=204 run "$A" check
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL the door let POST /insert/jsonline through (204)"* ]]
    KEYED=200 run "$A" check
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL vmauth's /metrics answered 200, not 401"* ]]
    LISTEN=1 run "$A" check
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL something listens on 9428 or 8427"* ]]
    INACTIVE=airlock-audit-journal.service run "$A" check
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL airlock-audit-journal.service is failed"* ]]
    QUERY='' run "$A" check
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL no query answer"* ]]
}

@test "check fails when a store unit shares the host's network namespace" {
    rm "$R/proc/102/ns/net"; ln -s 'net:[1]' "$R/proc/102/ns/net"
    run "$A" check
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL airlock-audit-vmauth: not in a network namespace of its own"* ]]
}

@test "status: units, what the store holds, seccomp kills" {
    KILLS='audit: type=1326 comm="victoria-logs" syscall=27' run "$A" status
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"airlock-audit-vl.service"*"active"* ]]
    [[ "$output" == *"lines 42, oldest 2026-10-16T00:00:00Z, newest 2026-11-16T00:00:00Z"* ]]
    [[ "$output" == *'comm="victoria-logs" syscall=27'* ]]
    run "$A" status
    [[ "$output" == *"seccomp kills since the store started"*"none"* ]]
}
