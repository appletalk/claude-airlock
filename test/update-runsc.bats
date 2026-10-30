#!/usr/bin/env bats
# bin/update-runsc: install and update gVisor's runsc from the release bucket. curl, tar and setpriv
# are stubbed, and /proc is a tree of this test's own (the "bucket" is two files here); file paths go under AIRLOCK_RUNSC_ROOT.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    T="$BATS_TEST_TMPDIR"
    export AIRLOCK_RUNSC_ROOT="$T/root" CALLS="$T/calls" BUCKET="$T/bucket" RAN="$T/ran"
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
# a box started meanwhile (during the download), when asked
[ -z "${BOX_DURING:-}" ] || { mkdir -p "$BOX_DURING" && ln -sfn "$AIRLOCK_RUNSC_ROOT/usr/local/bin/gvisor-bin/gvisor_sentry" "$BOX_DURING/exe"; }
EOF
    # /proc: unrelated processes (a shell, a kernel thread without an exe)
    mkdir -p "$R/proc/1" "$R/proc/2"
    ln -s /usr/bin/bash "$R/proc/1/exe"
    # setpriv OPTIONS... CMD...: records its options, runs CMD (as the caller: no root here)
    cat > "$T/bin/setpriv" <<'EOF'
#!/bin/bash
o=(); while [[ "${1:-}" == --* ]]; do o+=("$1"); shift; done
echo "setpriv ${o[*]}" >> "$CALLS"
[ ! -e /proc/self/fd/9 ] || echo "setpriv: fd 9 inherited" >> "$CALLS"
v=$(dirname "$1"); t=$(dirname "$v")
echo "modes cwd=$PWD work=$(stat -c %a "$t") ver=$(ls "$v" | tr '\n' ' ')$(stat -c %a "$v") new=$(stat -c %a "$t/new") new-writable=$(find "$t/new" -perm /022 | wc -l)" >> "$CALLS"
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
proc() {  # proc <pid> <exe target>: a process running that file
    mkdir -p "$R/proc/$1"; ln -sfn "$2" "$R/proc/$1/exe"
}

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
    ! grep -q 'fd 9 inherited' "$CALLS" || return 1
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

@test "running gVisor boxes, known by the file they run (any name): refused before the download; --force goes ahead with a warning" {
    release release-20261019.0
    "$U" >/dev/null
    release release-20261026.0
    proc 4001 "$R/usr/local/bin/gvisor-bin/gvisor_sentry"
    proc 4002 "$R/usr/local/bin/runsc"
    proc 4003 "$R/usr/local/bin/runsc (deleted)"          # one an earlier update replaced
    proc 4004 /usr/bin/podman; proc 4005 "$T/elsewhere/runsc"
    : > "$CALLS"
    run "$U"
    [ "$status" -eq 1 ]
    [[ "$output" == *"3 gVisor box process(es) running"*"stop"*"--force"* ]]
    ! tar_fetched || return 1
    grep -qx 'release release-20261019.0' "$S"
    run "$U" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: 3 gVisor box process(es) running"*"installed runsc release-20261026.0"* ]]
}

@test "a box started during the download stops the update before anything is replaced" {
    release release-20261019.0
    "$U" >/dev/null
    release release-20261026.0
    export BOX_DURING="$R/proc/4100"
    run "$U"
    [ "$status" -eq 1 ]; [[ "$output" == *"1 gVisor box process(es) running"* ]]
    tar_fetched
    grep -qx 'release release-20261019.0' "$S"
    [ "$(cat "$R/usr/local/bin/containerd-shim-runsc-v1")" = "shim release-20261019.0" ]
}

@test "no /proc to read is a stop, not 'no boxes'" {
    release release-20261019.0
    rm -rf "$R/proc"
    run "$U"
    [ "$status" -eq 1 ]; [[ "$output" == *"can't read $R/proc"* ]]
    [ ! -e "$R/usr/local/bin/runsc" ]
}

@test "--check with boxes running still reports (it replaces nothing)" {
    release release-20261019.0
    "$U" >/dev/null
    release release-20261026.0
    proc 4001 "$R/usr/local/bin/runsc"
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
    [[ "$output" == *"installed runsc release-20261026.0 (was release-20261019.0) (reinstalled: the files no longer matched the record)"* ]]
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

@test "the version run: as nobody, from /, in a work dir only root can list, seeing a copy of runsc alone" {
    release release-20261019.0
    "$U" >/dev/null
    grep -qx 'modes cwd=/ work=711 ver=runsc 755 new=700 new-writable=0' "$CALLS"
    case "$(dirname "$S")" in "$R"/var/lib/claude-airlock) ;; *) return 1 ;; esac
    run find "$R/var/lib/claude-airlock" -maxdepth 1 -name 'tmp.*'
    [ -z "$output" ]
}

@test "what a killed run left (its work dir, staged files) is swept; a second run at once is refused" {
    mkdir -p "$R/var/lib/claude-airlock/tmp.old1" && echo big > "$R/var/lib/claude-airlock/tmp.old1/gvisor.tar.zstd"
    echo x > "$R/usr/local/bin/runsc.update-runsc.4242"
    release release-20261019.0
    run "$U"
    [ "$status" -eq 0 ]
    [ ! -e "$R/var/lib/claude-airlock/tmp.old1" ] && [ ! -e "$R/usr/local/bin/runsc.update-runsc.4242" ]
    exec 8> "$R/var/lib/claude-airlock/update-runsc.lock"; flock 8
    run "$U"
    exec 8>&-
    [ "$status" -eq 1 ]; [[ "$output" == *"another update-runsc is running"* ]]
    ! grep -q 'fd 9 inherited' "$CALLS" || return 1
}

@test "replacing a runsc that has no record is logged as such" {
    printf '#!/bin/sh\necho mine\n' > "$R/usr/local/bin/runsc"; chmod 0755 "$R/usr/local/bin/runsc"
    release release-20261019.0
    run "$U"
    [[ "$output" == *"(was none) (replaced a runsc with no record)"* ]]
    grep -q '  none -> release-20261019.0 (replaced a runsc with no record)$' "$R/var/log/update-runsc.log"
}

@test "the downloaded runsc's error text reaches the terminal as printable characters only" {
    release release-20261019.0
    cat > "$T/bin/tar" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -C) d=$2; shift ;; esac; shift; done
printf '#!/bin/sh\nprintf "bad\\033[2J\\007end\\n" >&2\nexit 1\n' > "$d/runsc"; chmod 0700 "$d/runsc"
EOF
    run "$U"
    [ "$status" -eq 1 ]; [[ "$output" == *"reports no version (bad[2Jend)"* ]] || { echo "$output" | od -c | head; return 1; }
}

@test "a helper directory others can write counts as not installed" {
    release release-20261019.0
    "$U" >/dev/null
    chmod 0777 "$R/usr/local/bin/gvisor-bin"
    run "$U" --check
    [ "$status" -eq 10 ]
    "$U" >/dev/null
    [ "$(stat -c %a "$R/usr/local/bin/gvisor-bin")" = 755 ]
}

@test "--check writes nothing: no state dir, no lock, no sweep" {
    release release-20261019.0
    mkdir -p "$R/usr/local/bin/sub"; echo keep > "$R/usr/local/bin/sub/notes.update-runsc.bak"
    run "$U" --check
    [ "$status" -eq 10 ]
    [ ! -e "$R/var/lib/claude-airlock" ]
    [ -f "$R/usr/local/bin/sub/notes.update-runsc.bak" ]
}

@test "a refused file name reaches the terminal quoted, control characters included" {
    release release-20261026.0 "$(printf 'evil\033[2Jname')"
    run "$U"
    [ "$status" -eq 1 ]
    [[ "$output" == *"holds \$'evil\\E[2Jname'"* ]] || { echo "$output" | od -c | head -4; return 1; }
}

@test "nested helper directories are checked at every level" {
    release release-20261019.0 gvisor-bin/sub/x
    "$U" >/dev/null
    run "$U" --check
    [ "$status" -eq 0 ]
    # only the nested helper left under gvisor-bin/: its top is checked through it
    sed -i '/ gvisor-bin\/helper$/d' "$S"; rm "$R/usr/local/bin/gvisor-bin/helper"
    run "$U" --check
    [ "$status" -eq 0 ]
    chmod 0777 "$R/usr/local/bin/gvisor-bin"
    run "$U" --check
    [ "$status" -eq 10 ]
}

@test "a runsc whose error text is only blank lines still gets a message" {
    release release-20261019.0
    cat > "$T/bin/tar" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -C) d=$2; shift ;; esac; shift; done
printf '#!/bin/sh\necho >&2\necho "  " >&2\nexit 1\n' > "$d/runsc"; chmod 0700 "$d/runsc"
EOF
    run "$U"
    [ "$status" -eq 1 ]; [[ "$output" == *"reports no version; nothing installed"* ]] || { echo "$output"; return 1; }
}
