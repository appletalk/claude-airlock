#!/usr/bin/env bats
# bin/update-victorialogs: VictoriaLogs for the audit store, copied out of an image pinned by
# digest. podman, install and systemctl are stubbed; file paths go under AIRLOCK_VL_ROOT.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    T="$BATS_TEST_TMPDIR"
    export AIRLOCK_VL_ROOT="$T/root" CALLS="$T/calls"
    R="$AIRLOCK_VL_ROOT"
    mkdir -p "$T/bin"
    U="$REPO/bin/update-victorialogs"
    D="$R/usr/local/bin/victoria-logs"
    S="$R/var/lib/claude-airlock/update-victorialogs.state"
    PIN="$(sed -n 's/^IMAGE="\(.*\)"$/\1/p' "$U")"
    # podman: pull/create/rm/rmi logged; inspect answers ENTRY (default /victoria-logs-prod);
    # cp writes BINARY's bytes (default an ELF header and a version) to the destination.
    cat > "$T/bin/podman" <<'EOF'
#!/bin/bash
echo "podman $*" >> "$CALLS"
case "$1" in
    image) printf '%s\n' "${ENTRY-/victoria-logs-prod}" ;;
    create) echo cid123 ;;
    cp) [ "$2" = "cid123:${ENTRY-/victoria-logs-prod}" ] || exit 1; printf '%b' "${BINARY-\x7fELF v1.53.0}" > "$3" ;;
esac
EOF
    # install: no owners under the test root
    cat > "$T/bin/install" <<'EOF'
#!/bin/bash
args=(); while [ $# -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac; done
exec /usr/bin/install "${args[@]}"
EOF
    printf '#!/bin/bash\nexit 1\n' > "$T/bin/systemctl"
    chmod +x "$T"/bin/*
    export PATH="$T/bin:$PATH"
}

@test "the pin is an image by digest, the tag the k8s cluster's VictoriaLogs runs" {
    [[ "$PIN" =~ ^docker\.io/victoriametrics/victoria-logs:v[0-9.]+@sha256:[0-9a-f]{64}$ ]]
}

@test "installs the image's entrypoint binary, 0755, records image and sha256, removes the image" {
    run "$U"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(cat "$D")" = "$(printf '\x7fELF v1.53.0')" ]
    [ "$(stat -c %a "$D")" = 755 ]
    [ "$(cat "$S")" = "$PIN $(sha256sum < "$D" | cut -d' ' -f1)" ]
    grep -qx "podman pull --quiet $PIN" "$CALLS"
    grep -qx "podman rm -f cid123" "$CALLS"
    grep -qx "podman rmi -f $PIN" "$CALLS"
    # a second run: as pinned, nothing pulled
    : > "$CALLS"
    run "$U"
    [ "$status" -eq 0 ]; [[ "$output" == *"as pinned"* ]]; [ ! -s "$CALLS" ]
}

@test "--check and --first: exit 10 for a changed or foreign copy, never replacing it; --first installs only when missing" {
    run "$U" --first
    [ "$status" -eq 0 ]; [ -f "$D" ]
    printf 'tampered' > "$D"
    : > "$CALLS"
    run "$U" --check
    [ "$status" -eq 10 ]; [ "$(cat "$D")" = tampered ]
    run "$U" --first
    [ "$status" -eq 10 ]; [ "$(cat "$D")" = tampered ]; [ ! -s "$CALLS" ]
    # a plain run repairs it
    run "$U"
    [ "$status" -eq 0 ]; [ "$(cat "$D")" = "$(printf '\x7fELF v1.53.0')" ]
    # a copy others can write is not as pinned either
    chmod 0777 "$D"
    run "$U" --check
    [ "$status" -eq 10 ]
}

@test "refuses an odd entrypoint and a binary that isn't ELF; installs nothing" {
    ENTRY='/x/../etc/passwd' run "$U"
    [ "$status" -ne 0 ]; [[ "$output" == *"unexpected entrypoint"* ]]; [ ! -e "$D" ]
    ENTRY='' run "$U"
    [ "$status" -ne 0 ]; [ ! -e "$D" ]
    BINARY='#!/bin/sh\necho hi' run "$U"
    [ "$status" -ne 0 ]; [[ "$output" == *"not an ELF binary"* ]]; [ ! -e "$D" ]
    grep -q "podman rmi -f" "$CALLS"
}
