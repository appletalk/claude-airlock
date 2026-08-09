#!/usr/bin/env bats
# The host `claude` wrapper as a participant in the shared-mount refcount.
#
# A raw host session mounts nothing, but it USES $AIRLOCK_TMP under the same name as
# every box on that project. Before this it registered nothing and rmdir'd that
# directory on exit unconditionally - so a host session ending stranded every live box
# on an orphaned inode, and no box's cleanup could see the host session at all.
#
# The wrapper is zsh and the launcher is bash, so the refcount logic lives in ONE place
# (`airlock session register|release|peers`) and the wrapper delegates. These tests cover
# both the subcommand and the wrapper that calls it.

load helper

setup() {
  setup_airlock_env
  ZSH_LIB="$BATS_TEST_DIRNAME/../shell/claude-airlock.zsh"
  command -v zsh >/dev/null || skip "zsh not installed"
}

teardown() {
  [ -n "${PEER_PID:-}" ] && kill "$PEER_PID" 2>/dev/null
  return 0
}

scratch_dir() { printf '%s' "$AIRLOCK_TMP_BASE/$(_slug "$1")"; }
sessions_dir() { printf '%s' "$(state_dir "$1")/sessions"; }
proc_start() { local st; st="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1; st="${st##*') '}"; printf '%s' "$st" | cut -d' ' -f20; }

# Run the host wrapper's claude() for project $1, with a stub `claude` on PATH so
# `command claude` finds it. The stub records the sessions dir AS IT IS MID-SESSION,
# which is the only moment registration can be observed.
_host_claude() {
  local proj="$1"; shift
  cat > "$STUBBIN/claude" <<EOF
#!/usr/bin/env bash
for f in "\$HOME"/.config/claude-airlock/state/*/sessions/*; do
  [ -e "\$f" ] && printf 'MID=%s\n' "\${f##*/}" >> "$BATS_TEST_TMPDIR/midrun"
done
printf 'LOCK=%s\n' "\$(cat "\$HOME"/.config/claude-airlock/state/*/session.lock 2>/dev/null)" >> "$BATS_TEST_TMPDIR/midrun"
exit 0
EOF
  chmod +x "$STUBBIN/claude"
  env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" TERM=xterm \
    AIRLOCK_TMP_BASE="$AIRLOCK_TMP_BASE" \
    zsh -c "source '$ZSH_LIB' >/dev/null 2>&1; cd '$proj' || exit 1; claude $*" </dev/null
}

midrun() { cat "$BATS_TEST_TMPDIR/midrun" 2>/dev/null; }

# --- the session subcommand ---------------------------------------------------------

@test "session register writes a pidfile carrying the process start time" {
  proj="$(mkproj reg)"
  sleep 60 & PEER_PID=$!
  _launch "$proj" session register "$PEER_PID"
  [ -e "$(sessions_dir "$proj")/$PEER_PID" ]
  run cat "$(sessions_dir "$proj")/$PEER_PID"
  [ "$output" = "$(proc_start "$PEER_PID")" ]
}

@test "session release keeps the scratch dir while another session is live" {
  proj="$(mkproj rel)"
  sleep 60 & PEER_PID=$!
  mkdir -p "$(scratch_dir "$proj")"
  _launch "$proj" session register "$PEER_PID"
  _launch "$proj" session release 99999          # some other session leaving
  [ -d "$(scratch_dir "$proj")" ]
}

@test "session release cleans up when it is the last one out" {
  proj="$(mkproj rellast)"
  mkdir -p "$(scratch_dir "$proj")"
  _launch "$proj" session register 99999
  _launch "$proj" session release 99999
  [ ! -d "$(scratch_dir "$proj")" ]
  [ ! -d "$(sessions_dir "$proj")" ]
}

@test "session rejects a bad verb and a missing pid" {
  proj="$(mkproj badargs)"
  run _launch "$proj" session bogus 123
  [ "$status" -ne 0 ]
  run _launch "$proj" session register
  [ "$status" -ne 0 ]
}

# --- the integration that matters ----------------------------------------------------

@test "a registered HOST session stops a box from removing the shared dirs" {
  proj="$(mkproj hostpeer)"
  sleep 60 & PEER_PID=$!
  _launch "$proj" session register "$PEER_PID"   # stands in for a live host claude
  mkdir -p "$(scratch_dir "$proj")"
  ino_before="$(stat -c %i "$(scratch_dir "$proj")")"
  _launch "$proj"                                 # a full box launch, which then exits
  ino_after="$(stat -c %i "$(scratch_dir "$proj")" 2>/dev/null || echo GONE)"
  # This is the case that had no coverage at all: the box's cleanup must count the host
  # session, which mounts nothing but holds the same directory.
  [ "$ino_after" = "$ino_before" ]
  [ -d "$proj/.venv" ]
}

# --- the host wrapper itself ----------------------------------------------------------

@test "the host wrapper registers itself while it runs" {
  proj="$(mkproj hostreg)"
  _host_claude "$proj"
  run midrun
  [[ "$output" == *MID=* ]]
}

@test "the host wrapper records pid, kind and start time in the lock" {
  proj="$(mkproj hostlock)"
  _host_claude "$proj"
  run midrun
  # "<pid> host <epoch> <starttime>" - the 4th field is what stops a recycled pid from
  # prompting forever.
  [[ "$output" =~ LOCK=[0-9]+\ host\ [0-9]+\ [0-9]+ ]]
}

@test "the host wrapper does NOT remove a scratch dir another session still holds" {
  proj="$(mkproj hostkeep)"
  sleep 60 & PEER_PID=$!
  _launch "$proj" session register "$PEER_PID"
  mkdir -p "$(scratch_dir "$proj")"
  ino_before="$(stat -c %i "$(scratch_dir "$proj")")"
  _host_claude "$proj"
  ino_after="$(stat -c %i "$(scratch_dir "$proj")" 2>/dev/null || echo GONE)"
  # The original bug, in the wrapper: an unconditional rmdir here strands every live box
  # on an orphaned inode - reads empty, writes ENOENT, for the life of the container.
  [ "$ino_after" = "$ino_before" ]
}

@test "the host wrapper DOES clean up when it is the last one out" {
  proj="$(mkproj hostlast)"
  _host_claude "$proj"
  [ ! -d "$(scratch_dir "$proj")" ]
  [ ! -e "$(state_dir "$proj")/session.lock" ]
}

@test "the host wrapper leaves a lock that a later session took over" {
  proj="$(mkproj hostlockown)"
  mkdir -p "$(state_dir "$proj")"
  # A stub that overwrites the lock mid-run, exactly as a second session starting would.
  cat > "$STUBBIN/claude" <<EOF
#!/usr/bin/env bash
printf '999001 airlock 0 12345\n' > "$(state_dir "$proj")/session.lock"
exit 0
EOF
  chmod +x "$STUBBIN/claude"
  env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" TERM=xterm \
    AIRLOCK_TMP_BASE="$AIRLOCK_TMP_BASE" \
    zsh -c "source '$ZSH_LIB' >/dev/null 2>&1; cd '$proj' || exit 1; claude" </dev/null
  [ -e "$(state_dir "$proj")/session.lock" ]
  run cat "$(state_dir "$proj")/session.lock"
  [[ "$output" == 999001* ]]
}
