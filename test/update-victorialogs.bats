#!/usr/bin/env bats
# bin/update-victorialogs: the audit store's binaries (VictoriaLogs, vmauth), each copied out of an
# image pinned by digest. podman, install and systemctl are stubbed; file paths go under
# AIRLOCK_VL_ROOT, and AIRLOCK_VL_PINS stands in for the pins.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    T="$BATS_TEST_TMPDIR"
    export AIRLOCK_VL_ROOT="$T/root" CALLS="$T/calls"
    R="$AIRLOCK_VL_ROOT"
    mkdir -p "$T/bin"
    U="$REPO/bin/update-victorialogs"
    A="docker.io/example/aaa:v1@sha256:$(printf 'a%.0s' $(seq 64))"
    B="docker.io/example/bbb:v2@sha256:$(printf 'b%.0s' $(seq 64))"
    export AIRLOCK_VL_PINS="victoria-logs $A
vmauth $B"
    # podman: pull/create/rm/rmi logged; inspect answers ENTRY (default /app-prod); create names
    # the container after the image; cp writes that image's bytes (an ELF header and its name),
    # or, with CP_LINK, a symlink.
    cat > "$T/bin/podman" <<'EOF'
#!/bin/bash
echo "podman $*" >> "$CALLS"
case "$1" in
    image) e=${ENTRY-/app-prod}; printf '%s\n' "${e%%$'\n'*}"; [ "$e" = "${e#*$'\n'}" ] || { sleep 0.2; printf '%s\n' "${e#*$'\n'}"; } ;;
    create) echo "cid-${2##*/}" | cut -d: -f1 ;;
    cp) src=${2#*:}; e=${ENTRY-/app-prod}; [ "$src" = "${e%%$'\n'*}" ] || exit 1
        if [ -n "${CP_LINK:-}" ]; then ln -s /etc/passwd "$3"; else printf '%b' "${BINARY-\x7fELF ${2%%:*}}" > "$3"; fi ;;
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

@test "the real pins are images by digest; a pin without a digest stops everything" {
    unset AIRLOCK_VL_PINS
    while read -r name image; do
        [[ "$name" =~ ^(victoria-logs|vmauth)$ ]] || return 1
        [[ "$image" =~ ^docker\.io/victoriametrics/(victoria-logs|vmauth):v[0-9.]+@sha256:[0-9a-f]{64}$ ]] || { echo "$image"; return 1; }
    done < <(sed -n 's/^    "\([a-z-]*\) \([^"]*\)"$/\1 \2/p' "$U")
    export AIRLOCK_VL_PINS="vmauth docker.io/example/bbb:v2"
    run "$U"
    [ "$status" -ne 0 ]; [[ "$output" == *"not an image by digest"* ]]; [ ! -e "$CALLS" ]
}

@test "installs each image's entrypoint binary, 0755, records image and sha256, removes the images" {
    run "$U"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(cat "$R/usr/local/bin/victoria-logs")" = "$(printf '\x7fELF cid-aaa')" ]
    [ "$(cat "$R/usr/local/bin/vmauth")" = "$(printf '\x7fELF cid-bbb')" ]
    [ "$(stat -c %a "$R/usr/local/bin/vmauth")" = 755 ]
    [ "$(cat "$R/var/lib/claude-airlock/update-victorialogs.vmauth.state")" = "$B $(sha256sum < "$R/usr/local/bin/vmauth" | cut -d' ' -f1)" ]
    grep -qx "podman pull --quiet $A" "$CALLS"
    grep -qx "podman rmi -f $A" "$CALLS" && grep -qx "podman rmi -f $B" "$CALLS"
    # a second run: both as pinned, nothing pulled
    : > "$CALLS"
    run "$U"
    [ "$status" -eq 0 ]; [[ "$output" == *"victoria-logs: as pinned"*"vmauth: as pinned"* ]]; [ ! -s "$CALLS" ]
}

@test "--first installs only what is missing; --check and --first exit 10 for a changed copy, never replacing it" {
    run "$U" --first
    [ "$status" -eq 0 ]
    rm "$R/usr/local/bin/vmauth"; printf 'tampered' > "$R/usr/local/bin/victoria-logs"
    : > "$CALLS"
    run "$U" --first
    [ "$status" -eq 10 ]; [ "$(cat "$R/usr/local/bin/victoria-logs")" = tampered ]; [ -f "$R/usr/local/bin/vmauth" ]
    ! grep -q "pull --quiet $A" "$CALLS"
    run "$U" --check
    [ "$status" -eq 10 ]
    run "$U"
    [ "$status" -eq 0 ]; [ "$(cat "$R/usr/local/bin/victoria-logs")" = "$(printf '\x7fELF cid-aaa')" ]
}

@test "not as pinned: a new pin for the same bytes, a link in place of the binary, a copy others can write" {
    run "$U"
    [ "$status" -eq 0 ]
    # the pin moved (the state names the old image): not current
    export AIRLOCK_VL_PINS="victoria-logs ${A/v1@/v9@}
vmauth $B"
    run "$U" --check
    [ "$status" -eq 10 ]; [[ "$output" == *"victoria-logs: "*"is not the pinned"* ]]
    export AIRLOCK_VL_PINS="victoria-logs $A
vmauth $B"
    # a link to an identical file is not the installed file
    cp "$R/usr/local/bin/vmauth" "$T/copy"; rm "$R/usr/local/bin/vmauth"; ln -s "$T/copy" "$R/usr/local/bin/vmauth"
    run "$U" --check
    [ "$status" -eq 10 ]
    run "$U"
    [ "$status" -eq 0 ]; [ ! -L "$R/usr/local/bin/vmauth" ]
    chmod 0777 "$R/usr/local/bin/vmauth"
    run "$U" --check
    [ "$status" -eq 10 ]
}

@test "refuses an odd entrypoint, a link out of the image, a binary that isn't ELF; installs nothing" {
    ENTRY='/x/../etc/passwd' run "$U"
    [ "$status" -ne 0 ]; [[ "$output" == *"unexpected entrypoint"* ]]
    ENTRY='' run "$U"
    [ "$status" -ne 0 ]
    CP_LINK=1 run "$U"
    [ "$status" -ne 0 ]; [[ "$output" == *"not a regular file"* ]]
    BINARY='#!/bin/sh\necho hi' run "$U"
    [ "$status" -ne 0 ]; [[ "$output" == *"not an ELF binary"* ]]
    [ ! -e "$R/usr/local/bin/victoria-logs" ] && [ ! -e "$R/usr/local/bin/vmauth" ]
    grep -q "podman rmi -f" "$CALLS"
}

@test "takes the entrypoint's first element, not a later one" {
    ENTRY=$'/app-prod\n/other' run "$U"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -q "podman cp cid-aaa:/app-prod " "$CALLS"
}
