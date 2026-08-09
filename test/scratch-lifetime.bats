#!/usr/bin/env bats
# Lifetime of $AIRLOCK_TMP, the per-project scratch dir.
#
# One host dir is bind-mounted into EVERY box on a project. Removing it at exit while a
# sibling box still has it mounted does not just delete a directory - it unlinks the
# inode out from under that live mount, and the sibling spends the rest of its life on
# an orphan: reads empty, writes ENOENT. The box cannot tell that from "cache is empty",
# which is what makes it dangerous rather than merely annoying.
#
# So the rule these tests pin is: the LAST session out removes the dir, and only if the
# session left it empty. Both halves matter, and the second half predates the refcount.

load helper

setup() {
  setup_airlock_env
  # Never the real /tmp/airlock: the suite must not disturb a live session's scratch.
  export AIRLOCK_TMP_BASE="$BATS_TEST_TMPDIR/airlock-tmp"
  mkdir -p "$AIRLOCK_TMP_BASE"
}

teardown() {
  [ -n "${PEER_PID:-}" ] && kill "$PEER_PID" 2>/dev/null
  return 0
}

# Path of the scratch dir the launcher will use for project $1.
scratch_dir() { printf '%s' "$AIRLOCK_TMP_BASE/$(_slug "$1")"; }

# Register a pidfile for a LIVE process that is not the launcher, as a sibling box would.
register_live_peer() {
  local sdir="$(state_dir "$1")/sessions"
  mkdir -p "$sdir"
  sleep 300 &
  PEER_PID=$!
  : > "$sdir/$PEER_PID"
}

# Register a pidfile whose process is already gone, as a SIGKILLed box would leave.
register_dead_peer() {
  local sdir="$(state_dir "$1")/sessions" dead
  mkdir -p "$sdir"
  sleep 300 &
  dead=$!
  kill "$dead" 2>/dev/null
  wait "$dead" 2>/dev/null || true
  : > "$sdir/$dead"
  printf '%s' "$dead"
}

@test "a lone session removes its empty scratch dir on exit" {
  proj="$(mkproj lone)"
  _launch "$proj"
  [ ! -d "$(scratch_dir "$proj")" ]
}

@test "a live sibling session keeps the scratch dir mounted-safe" {
  proj="$(mkproj peer)"
  register_live_peer "$proj"
  _launch "$proj"
  # The sibling still has this bind-mounted; unlinking it would orphan that mount.
  [ -d "$(scratch_dir "$proj")" ]
}

@test "a dead sibling entry does not pin the scratch dir forever" {
  proj="$(mkproj stale)"
  dead="$(register_dead_peer "$proj")"
  _launch "$proj"
  [ ! -d "$(scratch_dir "$proj")" ]
  # The stale pidfile is pruned, not left to accumulate.
  [ ! -e "$(state_dir "$proj")/sessions/$dead" ]
}

@test "a NON-EMPTY scratch dir survives even the last session out" {
  proj="$(mkproj kept)"
  mkdir -p "$(scratch_dir "$proj")/pastes"
  touch "$(scratch_dir "$proj")/pastes/20260809-120000000.png"
  _launch "$proj"
  # rmdir refuses a non-empty dir: a kept artifact is never collateral.
  [ -f "$(scratch_dir "$proj")/pastes/20260809-120000000.png" ]
}

@test "a session deregisters itself on exit" {
  proj="$(mkproj dereg)"
  register_live_peer "$proj"
  _launch "$proj"
  # Exactly the peer's entry remains - the launcher left nothing of its own behind.
  run bash -c 'ls "$1" | wc -l' _ "$(state_dir "$proj")/sessions"
  [ "$output" -eq 1 ]
  [ -e "$(state_dir "$proj")/sessions/$PEER_PID" ]
}

@test "a shell session counts too - it holds the same mount" {
  proj="$(mkproj shellsess)"
  register_live_peer "$proj"
  _launch "$proj" shell
  # session.lock deliberately skips `shell`; the scratch refcount must not, or a shell
  # exit orphans a live claude box.
  [ -d "$(scratch_dir "$proj")" ]
}
