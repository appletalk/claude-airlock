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

# --- artifact store ownership ---------------------------------------------------------
# Two boxes on one project mount the SAME store. Concurrent installs into one venv
# corrupt it with no signature - no error, just a half-written package tree. Cleanup
# ordering cannot fix that, so ownership is advisory: one writer, everyone else reads.

@test "a lone session takes the artifact store read-write" {
  proj="$(mkproj storerw)"
  _launch "$proj"
  run engine_args
  [[ "$output" == *"artifacts/.venv:$proj/.venv:rw"* ]]
}

@test "a store held by a LIVE session is mounted read-only, with a reason" {
  proj="$(mkproj storero)"
  sleep 60 & PEER_PID=$!
  mkdir -p "$(state_dir "$proj")/artifacts"
  printf '%s %s\n' "$PEER_PID" "$(proc_start "$PEER_PID")" \
    > "$(state_dir "$proj")/artifacts/.venv.owner"
  run _launch "$proj"
  [[ "$output" == *"READ-ONLY"* ]]
  [[ "$output" == *"corrupts it silently"* ]]
  run engine_args
  [[ "$output" == *"artifacts/.venv:$proj/.venv:ro"* ]]
  [[ "$output" != *"artifacts/.venv:$proj/.venv:rw"* ]]
}

@test "a STALE owner does not lock every later session out" {
  proj="$(mkproj storestale)"
  sleep 60 & dead=$!
  kill "$dead" 2>/dev/null; wait "$dead" 2>/dev/null || true
  mkdir -p "$(state_dir "$proj")/artifacts"
  printf '%s 999999\n' "$dead" > "$(state_dir "$proj")/artifacts/.venv.owner"
  _launch "$proj"
  run engine_args
  # A SIGKILLed session must not leave the store read-only forever.
  [[ "$output" == *"artifacts/.venv:$proj/.venv:rw"* ]]
}

@test "an owner whose pid was RECYCLED does not hold the store" {
  proj="$(mkproj storerecycle)"
  sleep 60 & PEER_PID=$!
  mkdir -p "$(state_dir "$proj")/artifacts"
  # live pid, wrong start time - the recycled-pid shape
  printf '%s 999999\n' "$PEER_PID" > "$(state_dir "$proj")/artifacts/.venv.owner"
  _launch "$proj"
  run engine_args
  [[ "$output" == *"artifacts/.venv:$proj/.venv:rw"* ]]
}

@test "the store is released on exit so the next session gets it rw" {
  proj="$(mkproj storerelease)"
  _launch "$proj"
  [ ! -e "$(state_dir "$proj")/artifacts/.venv.owner" ]
}

@test "a legacy owner file with no start time still holds the store while alive" {
  proj="$(mkproj storelegacylive)"
  sleep 60 & PEER_PID=$!
  mkdir -p "$(state_dir "$proj")/artifacts"
  printf '%s\n' "$PEER_PID" > "$(state_dir "$proj")/artifacts/.venv.owner"
  _launch "$proj"
  run engine_args
  [[ "$output" == *"artifacts/.venv:$proj/.venv:ro"* ]]
}

@test "a legacy owner file whose pid is DEAD does not hold the store forever" {
  proj="$(mkproj storelegacydead)"
  sleep 60 & dead=$!
  kill "$dead" 2>/dev/null; wait "$dead" 2>/dev/null || true
  mkdir -p "$(state_dir "$proj")/artifacts"
  # No start time to compare, so bare liveness is the ONLY thing standing between this
  # and a store that is read-only for every future session.
  printf '%s\n' "$dead" > "$(state_dir "$proj")/artifacts/.venv.owner"
  _launch "$proj"
  run engine_args
  [[ "$output" == *"artifacts/.venv:$proj/.venv:rw"* ]]
}

# --- .owner file robustness (a malformed one must never kill the launch) --------------

@test "a ZERO-BYTE owner file does not make the project unlaunchable" {
  proj="$(mkproj ownerempty)"
  mkdir -p "$(state_dir "$proj")/artifacts"
  : > "$(state_dir "$proj")/artifacts/.venv.owner"
  # read returns 1 at EOF, and under `set -e` as the last command of an && list that was
  # FATAL: exit 1, no output at all, engine never invoked. Reachable by design, because
  # the writer truncates at open - so the race this ownership exists to prevent was
  # killing launches instead.
  run _launch "$proj"
  [ "$status" -eq 0 ]
  run engine_args
  [ -n "$output" ]
  [[ "$output" == *"artifacts/.venv:$proj/.venv:rw"* ]]
}

@test "an owner file with no trailing newline is read, not fatal" {
  proj="$(mkproj ownernonl)"
  sleep 60 & PEER_PID=$!
  mkdir -p "$(state_dir "$proj")/artifacts"
  printf '%s %s' "$PEER_PID" "$(proc_start "$PEER_PID")" \
    > "$(state_dir "$proj")/artifacts/.venv.owner"
  run _launch "$proj"
  [ "$status" -eq 0 ]
  run engine_args
  [[ "$output" == *"artifacts/.venv:$proj/.venv:ro"* ]]
}

@test "a garbage owner file is ignored rather than trusted" {
  proj="$(mkproj ownergarbage)"
  mkdir -p "$(state_dir "$proj")/artifacts"
  printf 'not-a-pid whatever\n' > "$(state_dir "$proj")/artifacts/.venv.owner"
  _launch "$proj"
  run engine_args
  [[ "$output" == *"artifacts/.venv:$proj/.venv:rw"* ]]
}

@test "the owner file is written atomically - no window where it reads empty" {
  proj="$(mkproj owneratomic)"
  _launch "$proj"
  run bash -c 'ls "$1"/artifacts/.venv.owner.tmp.* 2>/dev/null | wc -l' _ "$(state_dir "$proj")"
  [ "$output" -eq 0 ]
}

@test "a stale lock whose pid was RECYCLED does not prompt forever" {
  proj="$(mkproj lockrecycled)"
  sleep 60 & PEER_PID=$!
  mkdir -p "$(state_dir "$proj")"
  # Live pid, wrong start time. Under a bare kill -0 this prompts on every launch, and
  # _launch feeds /dev/null, so the prompt reads EOF and aborts the run.
  printf '%s airlock 0 999999\n' "$PEER_PID" > "$(state_dir "$proj")/session.lock"
  run _launch "$proj"
  [ "$status" -eq 0 ]
}

@test "the launcher writes a 4-field lock carrying its start time" {
  proj="$(mkproj launcherlock)"
  LOCKCOPY="$BATS_TEST_TMPDIR/lockcopy"
  # Observed mid-run: cleanup removes the lock on the way out.
  printf '#!/usr/bin/env bash\ncp "%s/session.lock" "%s" 2>/dev/null\nexit 0\n' \
    "$(state_dir "$proj")" "$LOCKCOPY" > "$STUBBIN/podman"
  cp "$STUBBIN/podman" "$STUBBIN/docker"; chmod +x "$STUBBIN/podman" "$STUBBIN/docker"
  _launch "$proj"
  run cat "$LOCKCOPY"
  [[ "$output" =~ ^[0-9]+\ airlock\ [0-9]+\ [0-9]+$ ]]
}

@test "a store owner taken over mid-session is not released by the old holder" {
  proj="$(mkproj ownersteal)"
  OWNER="$(state_dir "$proj")/artifacts/.venv.owner"
  # The stub stands in for the box running while ANOTHER session takes the owner file -
  # the shape a repeated cleanup pass produces, since the trap fires twice on SIGTERM.
  # Releasing it then would let a third session take rw alongside the new holder, which
  # is the corruption this ownership exists to prevent.
  printf '#!/usr/bin/env bash\nprintf "999001 555\\n" > "%s"\nexit 0\n' "$OWNER" > "$STUBBIN/podman"
  cp "$STUBBIN/podman" "$STUBBIN/docker"; chmod +x "$STUBBIN/podman" "$STUBBIN/docker"
  _launch "$proj"
  [ -e "$OWNER" ]
  run cat "$OWNER"
  [[ "$output" == 999001* ]]
}

@test "a HOST session that is last out cleans up what a box created" {
  proj="$(mkproj hostlastartifact)"
  sleep 60 & PEER_PID=$!
  _launch "$proj" session register "$PEER_PID"   # a live host session
  _launch "$proj"                                 # a box runs, creates .venv, exits
  [ -d "$proj/.venv" ]                            # kept: the host session still holds it
  # The host session is now the last one out, so IT owes the artifact cleanup. Skipping
  # this left an empty .venv behind forever, and its existence stops any future session
  # from re-registering it. Caught against real containers, not by the stubbed suite.
  kill "$PEER_PID" 2>/dev/null; wait "$PEER_PID" 2>/dev/null || true
  _launch "$proj" session release "$PEER_PID"
  [ ! -e "$proj/.venv" ]
  [ ! -d "$(state_dir "$proj")/artifacts-created" ]
}
