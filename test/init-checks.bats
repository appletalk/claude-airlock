#!/usr/bin/env bats
# scripts/init-checks.sh: the image smoke test's proof that a box runs under its own init and that
# nothing kept root. It runs for real only in a box (image-smoke.sh); here it reads made-up
# /proc trees, so each check is seen to pass on a good box and to fail on the box it guards
# against (no init, a root process, a capability left, the init's session mode switched off).

setup() {
  CHECK="$BATS_TEST_DIRNAME/../scripts/init-checks.sh"
  P="$BATS_TEST_TMPDIR/proc"
  mkdir -p "$P"
  # the tree searched for setuid/setgid files: a clean one with an ordinary binary in it
  R="$BATS_TEST_TMPDIR/rootfs"
  mkdir -p "$R/usr/bin" && : > "$R/usr/bin/tool" && chmod 0755 "$R/usr/bin/tool"
  printf '%s\n' '#!/bin/bash' 'for f in "$@"; do [ "$f" != "${STUB_CAPS:-}" ] || echo "$f cap_net_raw=ep"; done' > "$BATS_TEST_TMPDIR/getcap"
  chmod +x "$BATS_TEST_TMPDIR/getcap"
  # pid 1: dumb-init as dev; pid 7: the command, its own session leader
  mkproc 1 dumb-init 1000 0000000000000000 "S 0 1 1"
  mkproc 7 bash 1000 0000000000000000 "S 1 7 7"
}

# mkproc <pid> <comm> <uid> <caps> <state ppid pgrp session> [field=value ...]
#   <uid> fills all four Uid and Gid slots, <caps> CapInh/CapPrm/CapEff/CapAmb; an override such
#   as Uid="1000 0 0 1000", CapAmb=00000000000000c0 or NoNewPrivs=0 replaces one line; DROP
#   leaves the line out.
mkproc() {
  local pid=$1 c=$2 u=$3 caps=$4 st=$5; shift 5
  local -A f=( [Uid]="$u $u $u $u" [Gid]="$u $u $u $u" [Groups]="$u" [CapInh]=$caps [CapPrm]=$caps
               [CapEff]=$caps [CapBnd]=00000000000000c0 [CapAmb]=$caps [NoNewPrivs]=1 )
  local kv; for kv in "$@"; do f[${kv%%=*}]="${kv#*=}"; done
  mkdir -p "$P/$pid"
  printf '%s\n' "$c" > "$P/$pid/comm"
  { printf 'Name:\t%s\n' "$c"
    local k; for k in Uid Gid Groups CapInh CapPrm CapEff CapBnd CapAmb NoNewPrivs; do
      [ "${f[$k]}" = DROP ] || printf '%s:\t%s\n' "$k" "${f[$k]// /$'\t'}"; done; } > "$P/$pid/status"
  printf '%s (%s) %s 0 0\n' "$pid" "$c" "$st" > "$P/$pid/stat"
}

# getcap is stubbed: setting a real file capability needs root. STUB_CAPS names the file to
# report, as getcap does for a file that carries some.
check() { run env -u DUMB_INIT_SETSID -u DUMB_INIT_DEBUG PROC="$P" ROOTFS="$R" GETCAP="$BATS_TEST_TMPDIR/getcap" SELF_PID=7 bash "$CHECK" "$@"; }

@test "a box under dumb-init as dev, nothing root, no capabilities: every check passes" {
  check
  [ "$status" -eq 0 ]
  [[ "$output" != *FAIL* ]]
  [[ "$output" == *"PID 1 is dumb-init"* ]]
  [[ "$output" == *"no process has uid or gid 0 (2 seen)"* ]]
}

@test "the command as PID 1 (no init): fails" {
  mkproc 1 claude 1000 0000000000000000 "S 0 1 1"
  check
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL  PID 1 is 'claude', not dumb-init"* ]]
}

@test "an init running as root (the engine's --init): fails twice, uid and root process" {
  mkproc 1 dumb-init 0 000001ffffffffff "S 0 1 1"
  check
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL  PID 1's uids are '0 0 0 0'"* ]]
  [[ "$output" == *"FAIL  1 process(es) with uid or gid 0"* ]]
  [[ "$output" == *"FAIL  1 process(es) hold capabilities"* ]]
}

@test "a leftover root process elsewhere in the box: fails" {
  mkproc 3 socat 0 0000000000000000 "S 1 3 3"
  check
  [ "$status" -ne 0 ]
  [[ "$output" == *"root: pid 3 (socat)"* ]]
}

@test "a dev process holding a capability: fails" {
  mkproc 4 helper 1000 0000000000001000 "S 1 4 4"
  check
  [ "$status" -ne 0 ]
  [[ "$output" == *"caps: pid 4 (helper)"* ]]
}

@test "the command in the init's session (DUMB_INIT_SETSID=0 took effect, or -c): fails" {
  mkproc 7 bash 1000 0000000000000000 "S 1 1 1"
  check
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL  the command's session is '1', not its own (7)"* ]]
}

@test "a DUMB_INIT_* variable reaching the command: fails" {
  run env DUMB_INIT_SETSID=0 PROC="$P" ROOTFS="$R" GETCAP="$BATS_TEST_TMPDIR/getcap" SELF_PID=7 bash "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL  the command sees DUMB_INIT_* variables"* ]]
}

@test "an empty or unreadable tree: fails, never passes on nothing" {
  rm -rf "$P"; mkdir -p "$P"
  check
  [ "$status" -ne 0 ]
  [[ "$output" == *"no process readable"* ]]
}

@test "real uid 1000 but effective or saved uid 0: fails (every slot is checked)" {
  mkproc 4 helper 1000 0000000000000000 "S 1 4 4" Uid="1000 0 0 0"
  mkproc 1 dumb-init 1000 0000000000000000 "S 0 1 1" Uid="1000 1000 0 1000"
  check
  [ "$status" -ne 0 ]
  [[ "$output" == *"root: pid 4 (helper)"* ]]
  [[ "$output" == *"FAIL  PID 1's uids are '1000 1000 0 1000'"* ]]
}

@test "gid 0 in any slot: fails" {
  mkproc 4 helper 1000 0000000000000000 "S 1 4 4" Gid="1000 1000 0 1000"
  check
  [ "$status" -ne 0 ]
  [[ "$output" == *"root: pid 4 (helper)"* ]]
}

@test "an inheritable or ambient capability alone: fails" {
  mkproc 4 inh 1000 0000000000000000 "S 1 4 4" CapInh=00000000000000c0
  mkproc 5 amb 1000 0000000000000000 "S 1 5 5" CapAmb=00000000000000c0
  check
  [ "$status" -ne 0 ]
  [[ "$output" == *"caps: pid 4 (inh) CapInh 00000000000000c0"* ]]
  [[ "$output" == *"caps: pid 5 (amb) CapAmb 00000000000000c0"* ]]
  [[ "$output" == *"FAIL  2 process(es) hold capabilities"* ]]
}

@test "the bounding set alone does not count (inert under no_new_privs)" {
  check
  [ "$status" -eq 0 ]
}

@test "a process without no_new_privs: fails" {
  mkproc 4 helper 1000 0000000000000000 "S 1 4 4" NoNewPrivs=0
  check
  [ "$status" -ne 0 ]
  [[ "$output" == *"no_new_privs off: pid 4 (helper)"* ]]
}

@test "a process whose status can't be read: fails, never skipped" {
  [ "$(id -u)" != 0 ] || skip "root reads a mode-000 file"
  mkproc 4 hidden 0 0000000000000000 "S 1 4 4"
  chmod 000 "$P/4/status"
  check
  chmod 644 "$P/4/status"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unreadable: pid 4"* ]]
}

@test "a supplementary group 0: fails" {
  mkproc 4 helper 1000 0000000000000000 "S 1 4 4" Groups="1000 0"
  check
  [ "$status" -ne 0 ]
  [[ "$output" == *"root: pid 4 (helper)"* ]]
}

@test "a status without its Uid or Gid line: fails (nothing to trust)" {
  mkproc 4 nouid 1000 0000000000000000 "S 1 4 4" Uid=DROP
  mkproc 5 nogid 1000 0000000000000000 "S 1 5 5" Gid=DROP
  check
  [ "$status" -ne 0 ]
  [[ "$output" == *"root: pid 4 (nouid)"* ]]
  [[ "$output" == *"root: pid 5 (nogid)"* ]]
}

@test "a setuid file on the root filesystem: fails, and names it" {
  chmod u+s "$R/usr/bin/tool"
  check
  [ "$status" -ne 0 ]
  [[ "$output" == *"setuid/setgid: $R/usr/bin/tool"* ]]
  [[ "$output" == *"FAIL  1 setuid or setgid file(s) on the root filesystem"* ]]
}

@test "a setgid file counts too" {
  chmod g+s "$R/usr/bin/tool"
  check
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL  1 setuid or setgid file(s)"* ]]
}

@test "a file with file capabilities: fails, and names it" {
  STUB_CAPS="$R/usr/bin/tool" check
  [ "$status" -ne 0 ]
  [[ "$output" == *"file capabilities: $R/usr/bin/tool cap_net_raw=ep"* ]]
  [[ "$output" == *"FAIL  1 file(s) carry file capabilities"* ]]
}

@test "no getcap to ask: fails rather than vouching for it" {
  run env PROC="$P" ROOTFS="$R" GETCAP="$BATS_TEST_TMPDIR/no-such-getcap" SELF_PID=7 bash "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL  getcap is not available"* ]]
}

# PROC=/proc/ (trailing slashes) is the real /proc: the orphan step runs (it compared the
# literal). The file walk stays on the made-up tree with the stub getcap.
@test "PROC with trailing slashes still runs the orphan step" {
  run env PROC=/proc// ROOTFS="$R" GETCAP="$BATS_TEST_TMPDIR/getcap" bash "$CHECK"
  [[ "$output" == *"orphan"* ]] || [[ "$output" == *"zombie"* ]] || { echo "$output"; false; }
}
