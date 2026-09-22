#!/usr/bin/env bats
# `airlock mount`: host-only, read-only extra directories. The point of these tests is the
# refusals - the feature exists to hand a box a scoped credential, so the ways it could
# hand over the WRONG credential matter more than the happy path.

load helper
setup() {
  setup_airlock_env
  H="$AIRLOCK_HOME"
  mkdir -p "$H/.kube-claude" "$H/.ssh" "$H/.kube" "$H/.config/sops/age" "$H/.config/other"
  printf 'k\n' > "$H/.ssh/id_ed25519"
  printf 'cfg\n' > "$H/.kube-claude/config"
}

mounted() { engine_args | grep -qx -- "$1:$1:ro"; }

@test "add stores the canonical path and a launch mounts it READ-ONLY at the same path" {
  p="$(mkproj mnt)"
  run _launch "$p" mount add "$H/.kube-claude/"
  [ "$status" -eq 0 ]
  _launch "$p" >/dev/null 2>&1 || true
  mounted "$H/.kube-claude"
  ! engine_args | grep -q -- "$H/.kube-claude:$H/.kube-claude:rw"
}

@test "list shows the mount; rm removes it and the next launch drops it" {
  p="$(mkproj mntrm)"
  _launch "$p" mount add "$H/.kube-claude"
  run _launch "$p" mount list
  [[ "$output" == *"$H/.kube-claude  (ro)"* ]]
  _launch "$p" mount rm "$H/.kube-claude"
  run _launch "$p" mount list
  [[ "$output" == *"(none)"* ]] || [[ "$output" != *".kube-claude  (ro)"* ]]
  : > "$ENGINE_ARGS_FILE"
  _launch "$p" >/dev/null 2>&1 || true
  ! mounted "$H/.kube-claude"
}

@test "refuses protected directories and anything inside them (no override)" {
  p="$(mkproj mntdeny)"
  mkdir -p "$H/.config/rclone" "$H/.config/helm" "$H/.terraform.d" "$H/.config/git" "$H/.m2"
  for d in "$H/.ssh" "$H/.kube" "$H/.config/sops" "$H/.config/sops/age" \
           "$H/.config/rclone" "$H/.config/helm" "$H/.terraform.d" "$H/.config/git" "$H/.m2"; do
    run _launch "$p" mount add "$d"
    [ "$status" -ne 0 ] || { echo "accepted $d"; false; }
    [[ "$output" == *"protected"* ]]
  done
  [ ! -s "$(state_dir "$p")/mounts" ]
}

@test "refuses an ancestor of a protected directory (~/.config holds sops keys)" {
  run _launch "$(mkproj mntanc)" mount add "$H/.config"
  [ "$status" -ne 0 ]
  [[ "$output" == *"contains protected"* ]]
}

@test "refuses \$HOME itself, paths outside \$HOME, files, and missing paths" {
  p="$(mkproj mntshape)"
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  for d in "$H" "$BATS_TEST_TMPDIR/outside" "$H/.kube-claude/config" "$H/nope"; do
    run _launch "$p" mount add "$d"
    [ "$status" -ne 0 ] || { echo "accepted $d"; false; }
  done
}

@test "a symlink is judged by its target: a link into ~/.ssh is refused" {
  ln -s "$H/.ssh" "$H/innocent"
  run _launch "$(mkproj mntlink)" mount add "$H/innocent"
  [ "$status" -ne 0 ]
  [[ "$output" == *"protected"* ]]
}

@test "refuses a directory holding a hard-linked file (same inode as a key elsewhere)" {
  mkdir -p "$H/looks-fine"
  ln "$H/.ssh/id_ed25519" "$H/looks-fine/notes"
  run _launch "$(mkproj mnthard)" mount add "$H/looks-fine"
  [ "$status" -ne 0 ]
  [[ "$output" == *"hard-linked"* ]]
}

@test "refuses a group- or world-writable directory" {
  p="$(mkproj mntperm)"
  for m in 770 707 777; do
    chmod "$m" "$H/.kube-claude"
    run _launch "$p" mount add "$H/.kube-claude"
    [ "$status" -ne 0 ] || { echo "accepted mode $m"; false; }
    [[ "$output" == *"not group/world-writable"* ]]
  done
  chmod 700 "$H/.kube-claude"
  run _launch "$p" mount add "$H/.kube-claude"
  [ "$status" -eq 0 ]
}

@test "refuses a directory owned by someone else" {
  # No root in the suite to chown with, so make the launcher see a different uid instead.
  printf '#!/bin/sh\n[ "$1" = -u ] && { echo 99999; exit 0; }\nexec /usr/bin/id "$@"\n' > "$STUBBIN/id"
  chmod +x "$STUBBIN/id"
  run _launch "$(mkproj mntowner)" mount add "$H/.kube-claude"
  [ "$status" -ne 0 ]
  [[ "$output" == *"owned by you"* ]]
}

@test "refuses the workspace and anything overlapping it" {
  p="$(mkproj mntws)"
  run _launch "$p" mount add "$p"
  [ "$status" -ne 0 ]
}

@test "launch re-checks: an approved dir later swapped for a symlink into ~/.ssh is NOT mounted" {
  p="$(mkproj mntswap)"
  _launch "$p" mount add "$H/.kube-claude"
  rm -rf "$H/.kube-claude"; ln -s "$H/.ssh" "$H/.kube-claude"
  run _launch "$p"
  [[ "$output" == *"NOT mounting"* ]]
  ! engine_args | grep -q -- "$H/.ssh"
  ! engine_args | grep -q -- "$H/.kube-claude:"
}

@test "launch re-checks: an approved path that now resolves ELSEWHERE (even somewhere allowed) is not mounted" {
  p="$(mkproj mntmoved)"
  mkdir -p "$H/elsewhere"
  _launch "$p" mount add "$H/.kube-claude"
  rm -rf "$H/.kube-claude"; ln -s "$H/elsewhere" "$H/.kube-claude"
  run _launch "$p"
  [[ "$output" == *"now resolves to"* ]]
  ! engine_args | grep -q -- "$H/elsewhere"
}

@test "launch re-checks: a hard link added after approval gets the dir skipped" {
  p="$(mkproj mntlate)"
  _launch "$p" mount add "$H/.kube-claude"
  ln "$H/.ssh/id_ed25519" "$H/.kube-claude/token"
  run _launch "$p"
  [[ "$output" == *"NOT mounting"* ]]
  ! mounted "$H/.kube-claude"
}

@test "a project .airlock/config cannot request a mount" {
  p="$(mkproj mntcfg)"
  write_config "$p" "mount = $H/.kube-claude"
  _launch "$p" >/dev/null 2>&1 || true
  ! mounted "$H/.kube-claude"
}

# The hard-link scan is -xdev and the engine's bind is recursive, so a mount point nested
# inside the directory (a FUSE mount, a bind) would be handed to the box unscanned. No
# root in the suite to mount with, so findmnt is stubbed to report one.
@test "refuses a directory with a mount point inside it, at add and again at launch" {
  p="$(mkproj mntnested)"
  _launch "$p" mount add "$H/.kube-claude" >/dev/null           # approved while clean
  printf '#!/bin/sh\nprintf "%%s\\n" / /proc "%s/nested"\n' "$H/.kube-claude" > "$STUBBIN/findmnt"
  chmod +x "$STUBBIN/findmnt"
  run _launch "$p" mount add "$H/.kube-claude"
  [ "$status" -ne 0 ]
  [[ "$output" == *"contains a mount point"* ]]
  run _launch "$p"
  [[ "$output" == *"NOT mounting"* ]]
  ! mounted "$H/.kube-claude"
}

@test "a mount point elsewhere does not trip the check (prefix match on the target only)" {
  p="$(mkproj mntother)"
  printf '#!/bin/sh\nprintf "%%s\\n" / /proc "%s/.kube-claude-other"\n' "$H" > "$STUBBIN/findmnt"
  chmod +x "$STUBBIN/findmnt"
  run _launch "$p" mount add "$H/.kube-claude"
  [ "$status" -eq 0 ]
}

@test "mount add shows what the box will be able to read" {
  p="$(mkproj mntlist)"
  printf 't\n' > "$H/.kube-claude/token"
  run _launch "$p" mount add "$H/.kube-claude"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 file(s)"* ]]
  [[ "$output" == *"    config"* ]]
  [[ "$output" == *"    token"* ]]
}
