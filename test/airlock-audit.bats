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
    ln -s /usr/local/bin/victoria-logs "$R/proc/101/exe"; ln -s /usr/local/bin/vmauth "$R/proc/102/exe"
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
if [ "$post" = 1 ]; then printf '%s\n%s' "${DOOR_BODY-missing route for \"$url\"}" "${DOOR:-400}"; else printf '%s' "${KEYED:-401}"; fi
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
    [ "$(sed -n 1p "$CALLS")" = "systemctl stop airlock-audit-journal.service airlock-audit-vector.service airlock-audit-vl-proxy.socket airlock-audit-vl-proxy.service airlock-audit-vmauth.service airlock-audit-vl.service" ] || return 1
    [ "$(sed -n 2p "$CALLS")" = "systemctl start airlock-audit-vl.service airlock-audit-vmauth.service airlock-audit-vector.service airlock-audit-journal.service airlock-audit-vl-proxy.socket" ] || return 1
}

@test "reset without a terminal or --yes changes nothing" {
    command -v setsid >/dev/null || skip "no setsid"
    run setsid -w "$A" reset </dev/null
    [ "$status" -ne 0 ]; [[ "$output" == *"reset --yes"* ]]
    [ -f "$R/var/lib/airlock-audit/vl/partitions/x" ] && [ -f "$R/var/lib/airlock-audit-journal/cursor" ] || return 1
    [ ! -s "$CALLS" ] || return 1
}

@test "reset asks; no keeps everything" {
    command -v script >/dev/null || skip "no script(1)"
    run script -qec "$A reset" /dev/null <<< $'n\n'
    [ -f "$R/var/lib/airlock-audit/vl/partitions/x" ]; [ ! -s "$CALLS" ] || return 1
    [[ "$output" == *"nothing changed"* ]] || return 1
}

@test "reset --yes: stopped, the store emptied (its directory kept), the cursor gone, started" {
    run "$A" reset --yes
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -d "$R/var/lib/airlock-audit/vl" ] && [ -z "$(ls -A "$R/var/lib/airlock-audit/vl")" ] || return 1
    [ ! -e "$R/var/lib/airlock-audit-journal/cursor" ] || return 1
    [[ "$(sed -n 1p "$CALLS")" == "systemctl stop "* ]] && [[ "$(sed -n 2p "$CALLS")" == "systemctl start "* ]] || return 1
    [[ "$output" == *"The journal"*"not touched"* ]] || return 1
}

@test "check passes when every guarantee holds" {
    run "$A" check
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"==> the audit store holds up"* ]] || return 1
    [ "$(grep -c '^ok ' <<< "$output")" -ge 16 ] || return 1
}

@test "check fails on: a door that lets a write through, an open vmauth endpoint, a host listener, a unit down, no answer" {
    DOOR=204 run "$A" check
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL POST /insert/jsonline got past vmauth's routes (204)"* ]]
    # a 4xx from the store behind vmauth (no "missing route") means vmauth let it through
    DOOR_BODY='cannot parse request' run "$A" check
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL POST /delete/run_task got past vmauth's routes (400)"* ]]
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
    [[ "$output" == *"airlock-audit-vl.service"*"active"* ]] || return 1
    [[ "$output" == *"lines 42, oldest 2026-10-16T00:00:00Z, newest 2026-11-16T00:00:00Z"* ]] || return 1
    [[ "$output" == *'comm="victoria-logs" syscall=27'* ]] || return 1
    run "$A" status
    [[ "$output" == *"seccomp kills since the store started"*"none"* ]] || return 1
}

@test "check fails when ss can't tell what listens" {
    printf '#!/bin/bash\nexit 1\n' > "$T/bin/ss"
    run "$A" check
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL ss failed"* ]]
}

@test "restart --if-stale: nothing when the installed binaries run; a restart when one was replaced" {
    run "$A" restart --if-stale
    [ "$status" -eq 0 ] && [[ "$output" == *"runs the installed binaries: nothing to restart"* ]] || return 1
    [ ! -s "$CALLS" ] || return 1
    rm "$R/proc/102/exe"; ln -s '/usr/local/bin/vmauth (deleted)' "$R/proc/102/exe"
    run "$A" restart --if-stale
    [ "$status" -eq 0 ] && [[ "$output" == *"stale: airlock-audit-vmauth(/usr/local/bin/vmauth (deleted))"* ]] || return 1
    grep -q '^systemctl stop ' "$CALLS" && grep -q '^systemctl start ' "$CALLS" || return 1
}

@test "reset: a failure between stop and start still starts the store again" {
    rm "$R/var/lib/airlock-audit-journal/cursor"; mkdir -p "$R/var/lib/airlock-audit-journal/cursor/x"
    run "$A" reset --yes
    [ "$status" -ne 0 ] || return 1
    [ "$(tail -n 1 "$CALLS")" = "systemctl start airlock-audit-vl.service airlock-audit-vmauth.service airlock-audit-vector.service airlock-audit-journal.service airlock-audit-vl-proxy.socket" ] || return 1
}

@test "check fails with no answer at the door" {
    printf '#!/bin/bash\nexit 7\n' > "$T/bin/curl"
    run "$A" check
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL no answer for POST /insert/jsonline"* ]]
}

@test "check fails when vmauth's endpoints refuse with anything but 401" {
    KEYED=403 run "$A" check
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL vmauth's /metrics answered 403, not 401"* ]]
}

@test "check fails when a store unit runs in another (non-host) namespace" {
    rm "$R/proc/103/ns/net"; ln -s 'net:[555]' "$R/proc/103/ns/net"
    run "$A" check
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL airlock-audit-vector: in net:[555], not the store's net:[999]"* ]]
}
