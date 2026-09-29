#!/usr/bin/env bats
# `airlock socket`: host-only Unix socket grants. A socket is a capability (the box talks to
# the service as you), so the refusals matter more than the happy path.

load helper
setup() {
  setup_airlock_env
  H="$AIRLOCK_HOME"
  SD="$BATS_TEST_TMPDIR/svc"
  mkdir -p "$SD"; chmod 755 "$SD"
  mksock "$SD/p.sock"
}

mksock() { python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"; }
mounted() { engine_args | grep -qx -- "$1:$1:ro"; }

@test "add stores the socket and a launch bind-mounts it READ-ONLY at the same path" {
  p="$(mkproj sk)"
  run _launch "$p" socket add "$SD/p.sock"
  [ "$status" -eq 0 ]
  [[ "$output" == *"as"*"you (uid"* ]]
  _launch "$p" >/dev/null 2>&1 || true
  mounted "$SD/p.sock"
  ! engine_args | grep -q -- "$SD/p.sock:$SD/p.sock:rw"
}

@test "list shows it; rm removes it and the next launch drops it" {
  p="$(mkproj skrm)"
  _launch "$p" socket add "$SD/p.sock"
  run _launch "$p" socket list
  [[ "$output" == *"  $SD/p.sock"* ]]
  _launch "$p" socket rm "$SD/p.sock"
  : > "$ENGINE_ARGS_FILE"
  _launch "$p" >/dev/null 2>&1 || true
  ! mounted "$SD/p.sock"
}

@test "refuses a regular file, a directory, a missing path and a relative path" {
  p="$(mkproj skshape)"
  printf 'x\n' > "$SD/file"
  for s in "$SD/file" "$SD" "$SD/nope.sock" "svc/p.sock"; do
    run _launch "$p" socket add "$s"
    [ "$status" -ne 0 ] || { echo "accepted $s"; false; }
  done
  [ ! -s "$(state_dir "$p")/sockets" ]
}

@test "refuses a path that goes through a symlink, even to an allowed socket" {
  ln -s "$SD/p.sock" "$SD/link.sock"
  mkdir -p "$BATS_TEST_TMPDIR/real"; chmod 755 "$BATS_TEST_TMPDIR/real"
  ln -s "$BATS_TEST_TMPDIR/real" "$BATS_TEST_TMPDIR/viadir"
  mksock "$BATS_TEST_TMPDIR/real/q.sock"
  p="$(mkproj sklink)"
  for s in "$SD/link.sock" "$BATS_TEST_TMPDIR/viadir/q.sock"; do
    run _launch "$p" socket add "$s"
    [ "$status" -ne 0 ] || { echo "accepted $s"; false; }
    [[ "$output" == *"symlink"* ]]
  done
}

@test "refuses a socket whose directory is group- or world-writable, sticky or not" {
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

@test "an ancestor may be world-writable only with the sticky bit" {
  p="$(mkproj skanc)"
  mkdir -p "$BATS_TEST_TMPDIR/ww/inner"; chmod 755 "$BATS_TEST_TMPDIR/ww/inner"
  mksock "$BATS_TEST_TMPDIR/ww/inner/s.sock"
  chmod 777 "$BATS_TEST_TMPDIR/ww"
  run _launch "$p" socket add "$BATS_TEST_TMPDIR/ww/inner/s.sock"
  [ "$status" -ne 0 ]
  [[ "$output" == *"without the sticky bit"* ]]
  chmod 1777 "$BATS_TEST_TMPDIR/ww"
  run _launch "$p" socket add "$BATS_TEST_TMPDIR/ww/inner/s.sock"
  [ "$status" -eq 0 ]
}

@test "refuses a socket in a directory owned by someone else" {
  printf '#!/bin/sh\n[ "$1" = -u ] && { echo 99999; exit 0; }\nexec /usr/bin/id "$@"\n' > "$STUBBIN/id"
  chmod +x "$STUBBIN/id"
  run _launch "$(mkproj skowner)" socket add "$SD/p.sock"
  [ "$status" -ne 0 ]
  [[ "$output" == *"owned by root or you"* ]]
}

@test "refuses well-known dangerous sockets by name (no override)" {
  p="$(mkproj skdeny)"
  mkdir -p "$SD/podman" "$SD/containerd"; chmod 755 "$SD/podman" "$SD/containerd"
  for n in docker.sock podman.sock containerd.sock podman/podman.sock containerd/x.sock \
           S.gpg-agent S.gpg-agent.ssh wayland-0 ssh-agent.sock; do
    mksock "$SD/$n"
    run _launch "$p" socket add "$SD/$n"
    [ "$status" -ne 0 ] || { echo "accepted $n"; false; }
    [[ "$output" == *"no override"* ]]
  done
}

@test "refuses anything in the per-user runtime dir" {
  export TEST_XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/rt"
  mkdir -p "$TEST_XDG_RUNTIME_DIR/app"; chmod 700 "$TEST_XDG_RUNTIME_DIR"; chmod 755 "$TEST_XDG_RUNTIME_DIR/app"
  mksock "$TEST_XDG_RUNTIME_DIR/app/harmless.sock"
  run _launch "$(mkproj skrt)" socket add "$TEST_XDG_RUNTIME_DIR/app/harmless.sock"
  [ "$status" -ne 0 ]
  [[ "$output" == *"runtime dir"* ]]
}

@test "refuses your SSH agent whatever it is called" {
  mksock "$SD/innocuous"
  export TEST_SSH_AUTH_SOCK="$SD/innocuous"
  run _launch "$(mkproj skagent)" socket add "$SD/innocuous"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SSH agent"* ]]
}

@test "refuses sockets inside protected dot-dirs" {
  mkdir -p "$H/.gnupg"; chmod 700 "$H/.gnupg"
  mksock "$H/.gnupg/S.keyboxd"
  run _launch "$(mkproj skdot)" socket add "$H/.gnupg/S.keyboxd"
  [ "$status" -ne 0 ]
  [[ "$output" == *"protected"* ]]
}

@test "launch re-checks: a socket later replaced by a regular file is NOT mounted" {
  p="$(mkproj skswap)"
  _launch "$p" socket add "$SD/p.sock"
  rm "$SD/p.sock"; printf 'x\n' > "$SD/p.sock"
  run _launch "$p"
  [[ "$output" == *"NOT mounting socket"* ]]
  ! mounted "$SD/p.sock"
}

@test "launch re-checks: a directory made world-writable after approval gets it skipped" {
  p="$(mkproj sklate)"
  _launch "$p" socket add "$SD/p.sock"
  chmod 777 "$SD"
  run _launch "$p"
  [[ "$output" == *"NOT mounting socket"* ]]
  ! mounted "$SD/p.sock"
}

@test "a project .airlock/config cannot request a socket" {
  p="$(mkproj skcfg)"
  write_config "$p" "socket = $SD/p.sock"
  _launch "$p" >/dev/null 2>&1 || true
  ! mounted "$SD/p.sock"
}
