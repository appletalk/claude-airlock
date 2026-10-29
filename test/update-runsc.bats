#!/usr/bin/env bats
# bin/update-runsc: install and update gVisor's runsc from the release bucket. curl, tar and pgrep
# are stubbed (the "bucket" is two files here); file paths go under AIRLOCK_RUNSC_ROOT.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    T="$BATS_TEST_TMPDIR"
    export AIRLOCK_RUNSC_ROOT="$T/root" CALLS="$T/calls" BUCKET="$T/bucket" BOXES=0
    R="$AIRLOCK_RUNSC_ROOT"
    mkdir -p "$R/usr/local/bin" "$BUCKET" "$T/bin"
    U="$REPO/bin/update-runsc"
    # curl -fsSL --retry 3 -o FILE URL: the bucket's file of that name
    cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
echo "curl ${*: -1}" >> "$CALLS"
while [ $# -gt 1 ]; do [ "$1" = -o ] && out=$2; shift; done
cp "$BUCKET/${1##*/}" "$out"
EOF
    # tar --zstd -xf TARBALL -C DIR: the tarball holds the release name; unpack a runsc that says it
    cat > "$T/bin/tar" <<'EOF'
#!/bin/bash
echo "tar $*" >> "$CALLS"
while [ $# -gt 0 ]; do case "$1" in -xf) tb=$2; shift ;; -C) d=$2; shift ;; esac; shift; done
v="$(cat "$tb")"
mkdir -p "$d/gvisor-bin"
printf '#!/bin/sh\n[ -n "%s" ] && echo "runsc version %s"\necho spec: 1.2\n' "$v" "$v" > "$d/runsc"
echo shim > "$d/containerd-shim-runsc-v1"
echo helper > "$d/gvisor-bin/helper"
chmod 0700 "$d/runsc"
EOF
    printf '#!/bin/bash\necho "${BOXES:-0}"; [ "${BOXES:-0}" -gt 0 ]\n' > "$T/bin/pgrep"
    chmod +x "$T/bin/"*
    export PATH="$T/bin:$PATH"
}
release() {  # release <name>: the bucket now serves this release (empty name: a runsc with no version)
    printf '%s' "$1" > "$BUCKET/gvisor.tar.zstd"
    (cd "$BUCKET" && sha512sum gvisor.tar.zstd > gvisor.tar.zstd.sha512)
}
installed() {  # installed <name>: a runsc of that release in place
    printf '#!/bin/sh\necho "runsc version %s"\n' "$1" > "$R/usr/local/bin/runsc"
    chmod 0755 "$R/usr/local/bin/runsc"
}

@test "a first install: every file of the release, 0755, the checksum recorded and the change logged" {
    release release-20261019.0
    run "$U"
    [ "$status" -eq 0 ]
    [[ "$output" == *"installed runsc release-20261019.0 (was none)"* ]]
    [ "$("$R/usr/local/bin/runsc" --version | head -n 1)" = "runsc version release-20261019.0" ]
    for f in runsc containerd-shim-runsc-v1 gvisor-bin/helper; do
        [ "$(stat -c %a "$R/usr/local/bin/$f")" = 755 ] || { echo "$f: $(stat -c %a "$R/usr/local/bin/$f")"; return 1; }
    done
    [ "$(cat "$R/var/lib/claude-airlock/update-runsc.sha512")" = "$(cut -d' ' -f1 "$BUCKET/gvisor.tar.zstd.sha512")" ]
    grep -q '  none -> release-20261019.0$' "$R/var/log/update-runsc.log"
    run find "$R/usr/local/bin" -name '*.update-runsc.*'
    [ -z "$output" ]
}

@test "up to date: only the checksum is fetched; nothing changes" {
    release release-20261019.0
    "$U" >/dev/null
    : > "$CALLS"
    run "$U"
    [ "$status" -eq 0 ]
    [[ "$output" == *"up to date"* ]]
    [ "$(cat "$CALLS")" = "curl https://storage.googleapis.com/gvisor/releases/release/latest/$(uname -m)/gvisor.tar.zstd.sha512" ]
}

@test "--check: exit 10 with a waiting update, 0 without; never downloads or installs" {
    release release-20261019.0
    "$U" >/dev/null
    release release-20261026.0
    : > "$CALLS"
    run "$U" --check
    [ "$status" -eq 10 ]
    [[ "$output" == *"update available"* ]]
    ! grep -q 'gvisor.tar.zstd$' "$CALLS" || return 1
    [ "$("$R/usr/local/bin/runsc" --version | head -n 1)" = "runsc version release-20261019.0" ]
    "$U" >/dev/null
    run "$U" --check
    [ "$status" -eq 0 ]
}

@test "an update: the new release in place, logged as old -> new" {
    installed release-20261019.0
    release release-20261026.0
    run "$U"
    [ "$status" -eq 0 ]
    [[ "$output" == *"installed runsc release-20261026.0 (was release-20261019.0)"* ]]
    grep -q '  release-20261019.0 -> release-20261026.0$' "$R/var/log/update-runsc.log"
}

@test "a rebuilt tarball of the installed release: checksum recorded, binaries left alone" {
    installed release-20261019.0
    before="$(sha256sum < "$R/usr/local/bin/runsc")"
    release release-20261019.0
    run "$U"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already on release-20261019.0"* ]]
    [ "$(sha256sum < "$R/usr/local/bin/runsc")" = "$before" ]
    [ -s "$R/var/lib/claude-airlock/update-runsc.sha512" ]
    [ ! -e "$R/var/log/update-runsc.log" ]
}

@test "running gVisor boxes: refused, nothing downloaded or replaced; --force replaces it with a warning" {
    installed release-20261019.0
    release release-20261026.0
    export BOXES=2
    : > "$CALLS"
    run "$U"
    [ "$status" -eq 1 ]
    [[ "$output" == *"2 gVisor box process(es) running"*"--force"* ]]
    ! grep -q 'gvisor.tar.zstd$' "$CALLS" || return 1
    [ "$("$R/usr/local/bin/runsc" --version)" = "runsc version release-20261019.0" ]
    run "$U" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: 2 gVisor box process(es) running"* ]]
    [[ "$output" == *"installed runsc release-20261026.0"* ]]
}

@test "--check with boxes running still reports (it replaces nothing)" {
    installed release-20261019.0
    release release-20261026.0
    export BOXES=1
    run "$U" --check
    [ "$status" -eq 10 ]
}

@test "a tarball that doesn't match its checksum: refused, nothing installed or recorded" {
    release release-20261026.0
    echo tampered > "$BUCKET/gvisor.tar.zstd"
    run "$U"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not match its checksum"* ]]
    [ ! -e "$R/usr/local/bin/runsc" ]
    [ ! -e "$R/var/lib/claude-airlock/update-runsc.sha512" ]
}

@test "a checksum file that isn't a sha512: refused before any download" {
    release release-20261026.0
    echo 'not-a-sum  gvisor.tar.zstd' > "$BUCKET/gvisor.tar.zstd.sha512"
    run "$U"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a sha512"* ]]
    ! grep -q 'gvisor.tar.zstd$' "$CALLS" || return 1
}

@test "an unpacked runsc that reports no version: refused, nothing installed" {
    release ""
    run "$U"
    [ "$status" -eq 1 ]
    [[ "$output" == *"reports no version"* ]]
    [ ! -e "$R/usr/local/bin/runsc" ]
}

@test "a failed fetch says so and installs nothing" {
    run "$U"
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not fetch the checksum"* ]]
}

@test "not root and no test root: refused; unknown arguments: usage, exit 2" {
    [ "$(id -u)" != 0 ] || skip "running as root"
    run env -u AIRLOCK_RUNSC_ROOT "$U" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"run as root"* ]]
    run "$U" --bogus
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage:"* ]]
}
