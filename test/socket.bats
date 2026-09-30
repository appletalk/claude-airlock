#!/usr/bin/env bats
# `airlock socket`: host-only Unix socket grants. A socket is a capability (the box talks to
# the service as you), so the refusals matter more than the happy path.
#
# The rule needs a socket owned by a service account in root-owned directories, which the
# suite cannot create without root. A `stat` stub reports owners from $FAKE_OWNERS
# ("uid path" lines) for `stat -c %u` and defers to the real stat for everything else.

load helper
setup() {
  setup_airlock_env
  H="$AIRLOCK_HOME"
  SVC=777
  export FAKE_OWNERS="$BATS_TEST_TMPDIR/owners"
  export FAKE_FSTYPE=tmpfs          # the runner's real /tmp may be overlay; only the FUSE test varies it
  : > "$FAKE_OWNERS"
  cat > "$STUBBIN/stat" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = -f ] && [ -n "${FAKE_FSTYPE:-}" ]; then echo "$FAKE_FSTYPE"; exit 0; fi
if [ "$1" = -c ] && [ "$2" = %u ] && [ -s "${FAKE_OWNERS:-}" ]; then
  u="$(awk -v p="$3" '{ q = $0; sub(/^[^ ]+ /, "", q) } q == p { u = $1 } END { print u }' "$FAKE_OWNERS")"
  [ -n "$u" ] && { echo "$u"; exit 0; }
fi
exec /usr/bin/stat "$@"
STUB
  chmod +x "$STUBBIN/stat"
  SD="$BATS_TEST_TMPDIR/svc"
  mkdir -p "$SD"; chmod 755 "$SD"
  rootdirs "$SD"
  svcsock "$SD/p.sock"
}

mksock() { python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"; }
owns() { printf '%s %s\n' "$1" "$2" >> "$FAKE_OWNERS"; }
# Report DIR and every ancestor as root-owned.
rootdirs() { local d="$1"; while :; do owns 0 "$d"; [ "$d" = / ] && break; d="$(dirname "$d")"; done; }
svcsock() { mksock "$1"; owns "$SVC" "$1"; }
mounted() { engine_args | grep -qx -- "$1:$1:ro"; }
launched() { engine_args | grep -q '^ENGINE_INVOKED='; }

@test "a service-owned socket in root-owned dirs is added and bind-mounted READ-ONLY at its path" {
  p="$(mkproj sk)"
  run _launch "$p" socket add "$SD/p.sock"
  [ "$status" -eq 0 ]
  [[ "$output" == *"as"*"you (uid"* ]]
  _launch "$p" >/dev/null 2>&1 || true
  mounted "$SD/p.sock"
  ! engine_args | grep -q -- "$SD/p.sock:$SD/p.sock:rw" || false
}

@test "list shows it; rm removes it and the next launch drops only that one" {
  p="$(mkproj skrm)"
  svcsock "$SD/q.sock"
  _launch "$p" socket add "$SD/p.sock"
  _launch "$p" socket add "$SD/q.sock"
  run _launch "$p" socket list
  [[ "$output" == *"  $SD/p.sock"* ]]
  _launch "$p" socket rm "$SD/p.sock"
  : > "$ENGINE_ARGS_FILE"
  _launch "$p" >/dev/null 2>&1 || true
  launched
  mounted "$SD/q.sock"
  refute mounted "$SD/p.sock"
}

@test "refuses sockets owned by you or by root, whatever their path" {
  p="$(mkproj skowner)"
  mksock "$SD/mine.sock"
  mksock "$SD/root.sock"; owns 0 "$SD/root.sock"
  run _launch "$p" socket add "$SD/mine.sock"
  [ "$status" -ne 0 ]; [[ "$output" == *"owned by you"* ]]
  run _launch "$p" socket add "$SD/root.sock"
  [ "$status" -ne 0 ]; [[ "$output" == *"owned by root"* ]]
}

@test "refuses nobody and login-account owners: only system accounts count as services" {
  p="$(mkproj skuid)"
  mksock "$SD/nobody.sock"; owns 65534 "$SD/nobody.sock"
  mksock "$SD/human.sock"; owns 1500 "$SD/human.sock"
  for s in "$SD/nobody.sock" "$SD/human.sock"; do
    run _launch "$p" socket add "$s"
    [ "$status" -ne 0 ] || { echo "accepted $s"; false; }
    [[ "$output" == *"not a system service account"* ]]
  done
}

@test "refuses a socket on a filesystem that can lie about owners (FUSE)" {
  export FAKE_FSTYPE=fuseblk
  run _launch "$(mkproj skfuse)" socket add "$SD/p.sock"
  [ "$status" -ne 0 ]
  [[ "$output" == *"fuseblk filesystem"* ]]
  export FAKE_FSTYPE=tmpfs
  run _launch "$(mkproj skfuse2)" socket add "$SD/p.sock"
  [ "$status" -eq 0 ]
}

@test "refuses non-sockets, missing and relative paths, and paths with : , or newlines" {
  p="$(mkproj skshape)"
  printf 'x\n' > "$SD/file"
  svcsock "$SD/a:b.sock"
  svcsock "$SD/a,b.sock"
  nl="$SD/a
b.sock"
  svcsock "$nl"
  for s in "$SD/file" "$SD" "$SD/nope.sock" "svc/p.sock" "$SD/a:b.sock" "$SD/a,b.sock" "$nl"; do
    run _launch "$p" socket add "$s"
    [ "$status" -ne 0 ] || { echo "accepted $s"; false; }
  done
  [ ! -s "$(state_dir "$p")/sockets" ]
}

@test "a non-canonical path is refused as non-canonical, not as a symlink" {
  run _launch "$(mkproj skcanon)" socket add "$SD//p.sock"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a canonical path"* ]]
}

@test "refuses a path that goes through a symlink, even to an allowed socket" {
  ln -s "$SD/p.sock" "$SD/link.sock"
  mkdir -p "$BATS_TEST_TMPDIR/real"; chmod 755 "$BATS_TEST_TMPDIR/real"; owns 0 "$BATS_TEST_TMPDIR/real"
  ln -s "$BATS_TEST_TMPDIR/real" "$BATS_TEST_TMPDIR/viadir"
  svcsock "$BATS_TEST_TMPDIR/real/q.sock"
  p="$(mkproj sklink)"
  for s in "$SD/link.sock" "$BATS_TEST_TMPDIR/viadir/q.sock"; do
    run _launch "$p" socket add "$s"
    [ "$status" -ne 0 ] || { echo "accepted $s"; false; }
    [[ "$output" == *"symlink"* ]]
  done
}

@test "refuses when the socket's directory is group- or world-writable, sticky or not" {
  p="$(mkproj skperm)"
  for m in 775 757 777 1777; do
    chmod "$m" "$SD"
    run _launch "$p" socket add "$SD/p.sock"
    [ "$status" -ne 0 ] || { echo "accepted dir mode $m"; false; }
  done
  chmod 755 "$SD"
  run _launch "$p" socket add "$SD/p.sock"
  [ "$status" -eq 0 ]
}

@test "refuses when the socket's directory or any ancestor is not owned by root" {
  p="$(mkproj skdirowner)"
  owns "$(id -u)" "$SD"
  run _launch "$p" socket add "$SD/p.sock"
  [ "$status" -ne 0 ]; [[ "$output" == *"must be owned by root"* ]]
  owns 0 "$SD"
  owns "$(id -u)" "$(dirname "$SD")"
  run _launch "$p" socket add "$SD/p.sock"
  [ "$status" -ne 0 ]; [[ "$output" == *"must be owned by root"* ]]
  owns 0 "$(dirname "$SD")"
  run _launch "$p" socket add "$SD/p.sock"
  [ "$status" -eq 0 ]
}

@test "an ancestor may be world-writable only with the sticky bit" {
  p="$(mkproj skanc)"
  mkdir -p "$BATS_TEST_TMPDIR/ww/inner"; chmod 755 "$BATS_TEST_TMPDIR/ww/inner"
  rootdirs "$BATS_TEST_TMPDIR/ww/inner"
  svcsock "$BATS_TEST_TMPDIR/ww/inner/s.sock"
  chmod 777 "$BATS_TEST_TMPDIR/ww"
  run _launch "$p" socket add "$BATS_TEST_TMPDIR/ww/inner/s.sock"
  [ "$status" -ne 0 ]
  [[ "$output" == *"without the sticky bit"* ]]
  chmod 1777 "$BATS_TEST_TMPDIR/ww"
  run _launch "$p" socket add "$BATS_TEST_TMPDIR/ww/inner/s.sock"
  [ "$status" -eq 0 ]
}

@test "the deny list still refuses well-known sockets even when service-owned (no override)" {
  p="$(mkproj skdeny)"
  for d in docker podman containerd crio pulse; do mkdir -p "$SD/$d"; chmod 755 "$SD/$d"; owns 0 "$SD/$d"; done
  for n in docker.sock podman.sock containerd.sock crio.sock docker/x podman/x containerd/x crio/x \
           pulse/native pipewire-0 wayland-0 S.gpg-agent S.gpg-agent.ssh S.scdaemon S.dirmngr ssh-agent.sock; do
    svcsock "$SD/$n"
    run _launch "$p" socket add "$SD/$n"
    [ "$status" -ne 0 ] || { echo "accepted $n"; false; }
    [[ "$output" == *"no override"* ]]
  done
}

@test "refuses anything in the per-user runtime dir" {
  export TEST_XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/rt"
  mkdir -p "$TEST_XDG_RUNTIME_DIR/app"; chmod 755 "$TEST_XDG_RUNTIME_DIR" "$TEST_XDG_RUNTIME_DIR/app"
  rootdirs "$TEST_XDG_RUNTIME_DIR/app"
  svcsock "$TEST_XDG_RUNTIME_DIR/app/harmless.sock"
  run _launch "$(mkproj skrt)" socket add "$TEST_XDG_RUNTIME_DIR/app/harmless.sock"
  [ "$status" -ne 0 ]
  [[ "$output" == *"runtime"* ]]
}

@test "refuses your SSH agent by identity, even when SSH_AUTH_SOCK names another path to it" {
  svcsock "$SD/innocuous"
  ln -s "$SD/innocuous" "$BATS_TEST_TMPDIR/agent-link"
  export TEST_SSH_AUTH_SOCK="$BATS_TEST_TMPDIR/agent-link"
  run _launch "$(mkproj skagent)" socket add "$SD/innocuous"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SSH agent"* ]]
}

@test "refuses sockets inside protected dot-dirs" {
  mkdir -p "$H/.gnupg"; chmod 700 "$H/.gnupg"; rootdirs "$H/.gnupg"
  svcsock "$H/.gnupg/S.keyboxd"
  run _launch "$(mkproj skdot)" socket add "$H/.gnupg/S.keyboxd"
  [ "$status" -ne 0 ]
  [[ "$output" == *"protected"* ]]
}

@test "launch re-checks: a socket later replaced by a regular file is NOT mounted, the other still is" {
  p="$(mkproj skswap)"
  svcsock "$SD/q.sock"
  _launch "$p" socket add "$SD/p.sock"
  _launch "$p" socket add "$SD/q.sock"
  rm "$SD/p.sock"; printf 'x\n' > "$SD/p.sock"
  run _launch "$p"
  [[ "$output" == *"NOT mounting socket"* ]]
  launched
  refute mounted "$SD/p.sock"
  mounted "$SD/q.sock"
}

@test "launch re-checks: a directory made world-writable after approval gets it skipped" {
  p="$(mkproj sklate)"
  _launch "$p" socket add "$SD/p.sock"
  chmod 777 "$SD"
  run _launch "$p"
  [[ "$output" == *"NOT mounting socket"* ]]
  refute mounted "$SD/p.sock"
}

@test "a socket swapped between assembly and engine start aborts the launch" {
  p="$(mkproj skpin)"
  _launch "$p" socket add "$SD/p.sock"
  _launch "$p" secret set PIN_TRIGGER pass:x >/dev/null
  # `pass` runs after the mounts are assembled; make it swap the socket for a new inode.
  cat > "$STUBBIN/pass" <<STUB
#!/usr/bin/env bash
rm -f "$SD/p.sock"
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$SD/p.sock"
echo value
STUB
  chmod +x "$STUBBIN/pass"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"changed after it was checked"* ]]
  refute launched
}

@test "a socket changed in place (same inode, new ctime) between assembly and engine start aborts" {
  # Stands in for a replacement that reuses the deleted socket's inode number, which some
  # filesystems do immediately (CI's did): only the change time tells them apart.
  p="$(mkproj skpinctime)"
  _launch "$p" socket add "$SD/p.sock"
  _launch "$p" secret set PIN_TRIGGER pass:x >/dev/null
  printf '#!/usr/bin/env bash\nsleep 0.01; chmod 600 "%s"; chmod 755 "%s"\necho value\n' "$SD/p.sock" "$SD/p.sock" > "$STUBBIN/pass"
  chmod +x "$STUBBIN/pass"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"changed after it was checked"* ]]
  refute launched
}

@test "a directory made writable between assembly and engine start aborts the launch" {
  p="$(mkproj skpindir)"
  _launch "$p" socket add "$SD/p.sock"
  _launch "$p" secret set PIN_TRIGGER pass:x >/dev/null
  printf '#!/usr/bin/env bash\nchmod 777 "%s"\necho value\n' "$SD" > "$STUBBIN/pass"
  chmod +x "$STUBBIN/pass"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"changed after it was checked"* ]]
  refute launched
}

@test "a project .airlock/config cannot request a socket" {
  p="$(mkproj skcfg)"
  svcsock "$SD/q.sock"
  _launch "$p" socket add "$SD/q.sock"
  write_config "$p" "socket = $SD/p.sock"
  _launch "$p" >/dev/null 2>&1 || true
  launched
  mounted "$SD/q.sock"
  refute mounted "$SD/p.sock"
}
