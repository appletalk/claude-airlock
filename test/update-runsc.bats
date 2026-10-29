#!/usr/bin/env bats
# bin/update-runsc: install and update gVisor's runsc from the release bucket. curl, tar and pgrep
# are stubbed (the "bucket" is two files here); file paths go under AIRLOCK_RUNSC_ROOT.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    T="$BATS_TEST_TMPDIR"
    export AIRLOCK_RUNSC_ROOT="$T/root" CALLS="$T/calls" BUCKET="$T/bucket" BOXES=0 RAN="$T/ran"
    R="$AIRLOCK_RUNSC_ROOT"
    mkdir -p "$R/usr/local/bin" "$BUCKET" "$T/bin"
    U="$REPO/bin/update-runsc"
    S="$R/var/lib/claude-airlock/update-runsc.state"
    # curl ... -o FILE URL: the bucket's file of that name
    cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$CALLS"
while [ $# -gt 1 ]; do [ "$1" = -o ] && out=$2; shift; done
cp "$BUCKET/${1##*/}" "$out"
EOF
    # tar --zstd -xf TARBALL -C DIR: the tarball's first line is the release, any further lines
    # are extra files it holds. Its runsc prints that release (and notes each run in $RAN).
    cat > "$T/bin/tar" <<'EOF'
#!/bin/bash
echo "tar $*" >> "$CALLS"
while [ $# -gt 0 ]; do case "$1" in -xf) tb=$2; shift ;; -C) d=$2; shift ;; esac; shift; done
v="$(head -n 1 "$tb")"
mkdir -p "$d/gvisor-bin"
printf '#!/bin/sh\necho ran >> "%s"\nexit ${VERSION_RC:-0}\n' "$RAN" > "$d/runsc"
[ -z "$v" ] || printf 'echo "runsc version %s"\necho spec: 1.2\n' "$v" >> "$d/runsc"
sed -i '3{h;d};${G}' "$d/runsc"    # the exit last
echo "shim $v" > "$d/containerd-shim-runsc-v1"
echo "helper $v" > "$d/gvisor-bin/helper"
tail -n +2 "$tb" | while read -r f; do [ -n "$f" ] && mkdir -p "$d/$(dirname "$f")" && echo x > "$d/$f"; done
chmod 0700 "$d/runsc"
EOF
    # pgrep: the pattern it was given goes to $CALLS; BOXES boxes (a file: one count per call);
    # PGREP_RC: fail like pgrep does on an error
    cat > "$T/bin/pgrep" <<'EOF'
#!/bin/bash
echo "pgrep $*" >> "$CALLS"
[ -z "${PGREP_RC:-}" ] || { echo "pgrep: some error" >&2; exit "$PGREP_RC"; }
n=$BOXES
if [ -f "$BOXES" ]; then n="$(head -n 1 "$BOXES")"; sed -i 1d "$BOXES"; fi
echo "${n:-0}"; [ "${n:-0}" -gt 0 ]
EOF
    # setpriv OPTIONS... CMD...: records its options, runs CMD (as the caller: no root here)
    cat > "$T/bin/setpriv" <<'EOF'
#!/bin/bash
o=(); while [[ "${1:-}" == --* ]]; do o+=("$1"); shift; done
echo "setpriv ${o[*]}" >> "$CALLS"
exec "$@"
EOF
    chmod +x "$T/bin/"*
    export PATH="$T/bin:$PATH"
}
release() {  # release <name> [extra file...]: what the bucket serves now
    printf '%s\n' "$@" > "$BUCKET/gvisor.tar.zstd"
    (cd "$BUCKET" && sha512sum gvisor.tar.zstd > gvisor.tar.zstd.sha512)
}
tar_fetched() { grep -q 'gvisor.tar.zstd ' "$CALLS"; }

@test "a first install: the allowed files, 0755, the record (tarball, release, each file's sha256) and the log" {
    release release-20261019.0
    run "$U"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"installed runsc release-20261019.0 (was none)"* ]]
    for f in runsc containerd-shim-runsc-v1 gvisor-bin/helper; do
        [ "$(stat -c %a "$R/usr/local/bin/$f")" = 755 ] || { echo "$f: $(stat -c %a "$R/usr/local/bin/$f")"; return 1; }
        grep -qx "file $(sha256sum < "$R/usr/local/bin/$f" | cut -d' ' -f1) $f" "$S"
    done
    grep -qx "tarball $(cut -d' ' -f1 "$BUCKET/gvisor.tar.zstd.sha512")" "$S"
    grep -qx 'release release-20261019.0' "$S"
    grep -q '  none -> release-20261019.0$' "$R/var/log/update-runsc.log"
    run find "$R/usr/local/bin" -name '*.update-runsc.*'
    [ -z "$output" ]
    grep -q -- "--proto =https --proto-redir =https" "$CALLS"
    grep -qx 'setpriv --reuid=65534 --regid=65534 --clear-groups --no-new-privs' "$CALLS"
}

@test "up to date: only the checksum is fetched, and the installed runsc is never run" {
    release release-20261019.0
    "$U" >/dev/null
    : > "$CALLS"; rm -f "$RAN"
    run "$U"
    [ "$status" -eq 0 ]
    [[ "$output" == *"up to date"* ]]
    [ "$(grep -c '^curl' "$CALLS")" = 1 ] && grep -q 'gvisor.tar.zstd.sha512$' "$CALLS"
    [ ! -e "$RAN" ]
}

@test "the installed runsc is never run as part of an update or a check, whatever it is" {
    release release-20261019.0
    "$U" >/dev/null
    printf '#!/bin/sh\ntouch "%s/pwned"\necho "runsc version release-20261019.0"\n' "$T" > "$R/usr/local/bin/runsc"
    chmod 0755 "$R/usr/local/bin/runsc"
    "$U" --check >/dev/null || true
    "$U" >/dev/null
    [ ! -e "$T/pwned" ]
}

@test "--check: exit 10 with a waiting update or nothing installed, 0 without; never downloads or installs" {
    release release-20261019.0
    run "$U" --check
    [ "$status" -eq 10 ]; [[ "$output" == *"not installed"* ]]
    [ ! -e "$R/usr/local/bin/runsc" ]
    "$U" >/dev/null
    release release-20261026.0
    : > "$CALLS"
    run "$U" --check
    [ "$status" -eq 10 ]
    [[ "$output" == *"update available"* ]]
    ! tar_fetched || return 1
    grep -qx 'release release-20261019.0' "$S"
    "$U" >/dev/null
    run "$U" --check
    [ "$status" -eq 0 ]
}

@test "--first: installs when there is none, otherwise only checks (a waiting update is exit 10, nothing replaced)" {
    release release-20261019.0
    run "$U" --first
    [ "$status" -eq 0 ]; [[ "$output" == *"installed runsc release-20261019.0"* ]]
    release release-20261026.0
    : > "$CALLS"
    run "$U" --first
    [ "$status" -eq 10 ]
    ! tar_fetched || return 1
    grep -qx 'release release-20261019.0' "$S"
}

@test "an update: the new release in place, logged as old -> new, through a rename (a new inode)" {
    release release-20261019.0
    "$U" >/dev/null
    ino="$(stat -c %i "$R/usr/local/bin/runsc")"
    release release-20261026.0
    run "$U"
    [ "$status" -eq 0 ]
    [[ "$output" == *"installed runsc release-20261026.0 (was release-20261019.0)"* ]]
    grep -q '  release-20261019.0 -> release-20261026.0$' "$R/var/log/update-runsc.log"
    [ "$(stat -c %i "$R/usr/local/bin/runsc")" != "$ino" ]
    grep -qx 'release release-20261026.0' "$S"
}

@test "a rebuilt tarball with the same files: the new checksum recorded, the files left alone" {
    release release-20261019.0
    "$U" >/dev/null
    ino="$(stat -c %i "$R/usr/local/bin/runsc")"
    release release-20261019.0 ""            # a different tarball, the same files
    run "$U"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already on release-20261019.0"* ]]
    [ "$(stat -c %i "$R/usr/local/bin/runsc")" = "$ino" ]
    grep -qx "tarball $(cut -d' ' -f1 "$BUCKET/gvisor.tar.zstd.sha512")" "$S"
    [ "$(wc -l < "$R/var/log/update-runsc.log")" = 2 ]
}

@test "an installed copy that no longer matches its record (changed, or writable by others) is reinstalled, even with upstream unchanged" {
    release release-20261019.0
    "$U" >/dev/null
    good="$(sha256sum < "$R/usr/local/bin/runsc")"
    chmod 0777 "$R/usr/local/bin/runsc"
    run "$U" --check
    [ "$status" -eq 10 ]
    run "$U"
    [ "$status" -eq 0 ]; [[ "$output" == *"no longer match the record"*"installed runsc release-20261019.0"* ]]
    [ "$(stat -c %a "$R/usr/local/bin/runsc")" = 755 ]
    echo '# changed' >> "$R/usr/local/bin/gvisor-bin/helper"
    run "$U"
    [ "$status" -eq 0 ]; [[ "$output" == *"no longer match the record"* ]]
    [ "$(cat "$R/usr/local/bin/gvisor-bin/helper")" = "helper release-20261019.0" ]
    [ "$(sha256sum < "$R/usr/local/bin/runsc")" = "$good" ]
}

@test "running gVisor boxes: refused before the download; the pattern is runsc's sandbox and gofer; --force goes ahead with a warning" {
    release release-20261019.0
    "$U" >/dev/null
    release release-20261026.0
    export BOXES=2
    : > "$CALLS"
    run "$U"
    [ "$status" -eq 1 ]
    [[ "$output" == *"2 gVisor box process(es) running"*"stop"*"--force"* ]]
    grep -qxF 'pgrep -c -f ^runsc-(sandbox|gofer)( |$)' "$CALLS"
    ! tar_fetched || return 1
    grep -qx 'release release-20261019.0' "$S"
    run "$U" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: 2 gVisor box process(es) running"*"installed runsc release-20261026.0"* ]]
}

@test "a box started during the download stops the update before anything is replaced" {
    release release-20261019.0
    "$U" >/dev/null
    release release-20261026.0
    printf '0\n1\n' > "$T/boxes"; export BOXES="$T/boxes"
    run "$U"
    [ "$status" -eq 1 ]; [[ "$output" == *"1 gVisor box process(es) running"* ]]
    tar_fetched
    grep -qx 'release release-20261019.0' "$S"
    [ "$(cat "$R/usr/local/bin/containerd-shim-runsc-v1")" = "shim release-20261019.0" ]
}

@test "pgrep failing is a stop, not 'no boxes'" {
    release release-20261019.0
    export PGREP_RC=3
    run "$U"
    [ "$status" -eq 1 ]; [[ "$output" == *"pgrep failed (exit 3)"* ]]
    [ ! -e "$R/usr/local/bin/runsc" ]
}

@test "--check with boxes running still reports (it replaces nothing)" {
    release release-20261019.0
    "$U" >/dev/null
    release release-20261026.0
    export BOXES=1
    run "$U" --check
    [ "$status" -eq 10 ]
}

@test "the tarball itself is checked: a mismatch, or a checksum file naming another file, installs nothing" {
    release release-20261026.0
    echo tampered > "$BUCKET/gvisor.tar.zstd"
    run "$U"
    [ "$status" -eq 1 ]; [[ "$output" == *"does not match its checksum"* ]]
    [ ! -e "$R/usr/local/bin/runsc" ]
    echo something > "$T/other"
    echo "$(sha512sum < "$T/other" | cut -d' ' -f1)  $T/other" > "$BUCKET/gvisor.tar.zstd.sha512"
    run "$U"
    [ "$status" -eq 1 ]; [[ "$output" == *"does not match its checksum"* ]]
    [ ! -e "$R/usr/local/bin/runsc" ] && [ ! -e "$S" ]
}

@test "a tarball holding anything but runsc, its shim and gvisor-bin/ helpers installs nothing" {
    release release-20261026.0 ls
    run "$U"
    [ "$status" -eq 1 ]; [[ "$output" == *"holds ls, which isn't runsc"* ]]
    [ ! -e "$R/usr/local/bin/runsc" ] && [ ! -e "$R/usr/local/bin/ls" ]
    release release-20261026.0 lib/x
    run "$U"
    [ "$status" -eq 1 ]; [[ "$output" == *"holds lib/x"* ]]
    release release-20261026.0 gvisor-bin/extra
    run "$U"
    [ "$status" -eq 0 ]; [ -f "$R/usr/local/bin/gvisor-bin/extra" ]
}

@test "a checksum file that isn't a sha512: refused before any download" {
    release release-20261026.0
    echo 'not-a-sum  gvisor.tar.zstd' > "$BUCKET/gvisor.tar.zstd.sha512"
    run "$U"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a sha512"* ]]
    ! tar_fetched || return 1
}

@test "an unpacked runsc that reports no version, or fails to run, is refused with a message" {
    release ""
    run "$U"
    [ "$status" -eq 1 ]; [[ "$output" == *"reports no version"* ]]
    release release-20261026.0
    VERSION_RC=1 run "$U"
    [ "$status" -eq 1 ]; [[ "$output" == *"reports no version"* ]]
    [ ! -e "$R/usr/local/bin/runsc" ]
}

@test "a failed fetch says so and installs nothing" {
    run "$U"
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not fetch gvisor.tar.zstd.sha512"* ]]
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

@test "--first never replaces a runsc that is there: put there by hand, or changed since it was installed" {
    printf '#!/bin/sh\necho mine\n' > "$R/usr/local/bin/runsc"; chmod 0755 "$R/usr/local/bin/runsc"
    release release-20261026.0
    run "$U" --first
    [ "$status" -eq 10 ]; [[ "$output" == *"doesn't match this script's record"* ]]
    [ "$(sed -n 2p "$R/usr/local/bin/runsc")" = "echo mine" ]
    rm "$R/usr/local/bin/runsc"
    release release-20261019.0
    "$U" >/dev/null
    chmod 0775 "$R/usr/local/bin/runsc"
    release release-20261026.0
    run "$U" --first
    [ "$status" -eq 10 ]
    grep -qx 'release release-20261019.0' "$S"
    [ "$(stat -c %a "$R/usr/local/bin/runsc")" = 775 ]
}

@test "the log: every change, a repair with the release it had, a record-only change too" {
    release release-20261019.0
    "$U" >/dev/null
    chmod 0777 "$R/usr/local/bin/runsc"
    release release-20261026.0
    run "$U"
    [[ "$output" == *"installed runsc release-20261026.0 (was release-20261019.0, reinstalled)"* ]]
    grep -q '  release-20261019.0 -> release-20261026.0 (reinstalled: the files no longer matched the record)$' "$R/var/log/update-runsc.log"
    release release-20261026.0 ""
    "$U" >/dev/null
    grep -q '  release-20261026.0: a new tarball with the same files, its checksum recorded$' "$R/var/log/update-runsc.log"
    [ "$(wc -l < "$R/var/log/update-runsc.log")" = 3 ]
}

@test "a tarball of the same release with different files is installed, not just recorded" {
    release release-20261019.0
    "$U" >/dev/null
    sed -i 's/^echo "helper /echo "helper2 /' "$T/bin/tar"
    release release-20261019.0 ""
    run "$U"
    [ "$status" -eq 0 ]; [[ "$output" == *"installed runsc release-20261019.0"* ]]
    [ "$(cat "$R/usr/local/bin/gvisor-bin/helper")" = "helper2 release-20261019.0" ]
}

@test "the record is checked whole: a symlinked runsc, a record with no files, or a path outside the allowlist" {
    release release-20261019.0
    "$U" >/dev/null
    cp "$R/usr/local/bin/runsc" "$T/real"; ln -sf "$T/real" "$R/usr/local/bin/runsc"
    run "$U" --check
    [ "$status" -eq 10 ]
    "$U" >/dev/null
    [ ! -L "$R/usr/local/bin/runsc" ]
    sed -i '/^file /d' "$S"
    run "$U" --check
    [ "$status" -eq 10 ]
    "$U" >/dev/null
    cp "$R/usr/local/bin/runsc" "$R/usr/local/bin/other"
    sed -i 's#^\(file [0-9a-f]*\) runsc$#\1 other#' "$S"
    run "$U" --check
    [ "$status" -eq 10 ]
}

@test "a runsc that fails to run says why" {
    release release-20261019.0
    sed -i 's#exit ${VERSION_RC:-0}#echo "exec format error" >\&2; exit 1#' "$T/bin/tar"
    run "$U"
    [ "$status" -eq 1 ]; [[ "$output" == *"reports no version (exec format error)"* ]]
}
