#!/usr/bin/env bats
# Lifetime of the directories a project's boxes SHARE: $AIRLOCK_TMP (the scratch dir)
# and the shadowed artifact mountpoints ($WORKSPACE/.venv, node_modules, ...).
#
# Two boxes on one project is a supported setup, and both of these are one host
# directory mounted into every one of them. Removing such a directory at exit is not a
# tidy-up, it is an attack on the surviving box:
#
#   - scratch dir: it is the mount SOURCE. rmdir leaves the sibling on an orphaned
#     inode - Links: 0, reads empty, writes ENOENT - for the life of that container,
#     and it reads as "the cache is empty" rather than "my mount is dead".
#   - artifact dirs: it is the mount TARGET. vfs_rmdir calls detach_mounts() and tears
#     the sibling's mount down outright, so .venv vanishes mid-session while its
#     contents sit intact and unreachable in $STATE_DIR/artifacts.
#
# The artifact case is the nastier one: the box writes into $store, which is mounted
# OVER the path, so the host view is ALWAYS empty and the "rmdir only removes it if
# empty" reasoning never protects anything. It fires every time, not just sometimes.
#
# So: the LAST session out removes these, nobody else. For the scratch dir the
# empty-only rmdir still applies on top, and that half predates the refcount.

load helper

setup() {
  setup_airlock_env      # exports a hermetic AIRLOCK_TMP_BASE for the whole suite
}

teardown() {
  [ -n "${PEER_PID:-}" ] && kill "$PEER_PID" 2>/dev/null
  return 0
}

scratch_dir() { printf '%s' "$AIRLOCK_TMP_BASE/$(_slug "$1")"; }
sessions_dir() { printf '%s' "$(state_dir "$1")/sessions"; }

# The kernel start-time token the launcher stores, so a test can forge a matching or a
# deliberately WRONG pidfile.
proc_start() { local st; st="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1; st="${st##*') '}"; printf '%s' "$st" | cut -d' ' -f20; }

# Register a pidfile for a LIVE process that is not the launcher, as a sibling box would.
register_live_peer() {
  local sdir; sdir="$(sessions_dir "$1")"
  mkdir -p "$sdir"
  sleep 300 &
  PEER_PID=$!
  proc_start "$PEER_PID" > "$sdir/$PEER_PID"
}

# Register a pidfile whose process is already gone, as a SIGKILLed box would leave.
register_dead_peer() {
  local sdir dead; sdir="$(sessions_dir "$1")"
  mkdir -p "$sdir"
  sleep 300 &
  dead=$!
  kill "$dead" 2>/dev/null
  wait "$dead" 2>/dev/null || true
  echo 999999 > "$sdir/$dead"
  printf '%s' "$dead"
}

# --- the scratch dir (mount source) -----------------------------------------------

@test "a lone session removes its empty scratch dir on exit" {
  proj="$(mkproj lone)"
  _launch "$proj"
  [ ! -d "$(scratch_dir "$proj")" ]
  # and does not leave its own bookkeeping behind
  [ ! -d "$(sessions_dir "$proj")" ]
}

@test "a live sibling session keeps the scratch dir mounted-safe" {
  proj="$(mkproj peer)"
  register_live_peer "$proj"
  _launch "$proj"
  [ -d "$(scratch_dir "$proj")" ]
}

@test "a dead sibling entry does not pin the scratch dir forever" {
  proj="$(mkproj stale)"
  dead="$(register_dead_peer "$proj")"
  _launch "$proj"
  [ ! -d "$(scratch_dir "$proj")" ]
  [ ! -e "$(sessions_dir "$proj")/$dead" ]
}

@test "a RECYCLED pid does not masquerade as a live peer" {
  proj="$(mkproj recycled)"
  sdir="$(sessions_dir "$proj")"
  mkdir -p "$sdir"
  # A live process, but the pidfile records a start time that is not its own - exactly
  # what a pid recycled since the file was written looks like. Without the start-time
  # check this pins the project's cleanup forever, and these files outlive reboots.
  sleep 300 &
  PEER_PID=$!
  echo 999999 > "$sdir/$PEER_PID"
  _launch "$proj"
  [ ! -d "$(scratch_dir "$proj")" ]
  [ ! -e "$sdir/$PEER_PID" ]
}

@test "a NON-EMPTY scratch dir survives even the last session out" {
  proj="$(mkproj kept)"
  mkdir -p "$(scratch_dir "$proj")/pastes"
  touch "$(scratch_dir "$proj")/pastes/20260809-120000000.png"
  _launch "$proj"
  [ -f "$(scratch_dir "$proj")/pastes/20260809-120000000.png" ]
}

# --- the artifact dirs (mount target) ---------------------------------------------

@test "a live sibling keeps the artifact mountpoint from being torn out" {
  proj="$(mkproj artpeer)"
  register_live_peer "$proj"
  _launch "$proj"
  # The launcher created .venv (it did not exist) and registered it for cleanup. The
  # sibling has it mounted; removing it detaches that mount mid-session.
  [ -d "$proj/.venv" ]
}

@test "the last session out still removes the artifact mountpoint it created" {
  proj="$(mkproj artlone)"
  _launch "$proj"
  [ ! -e "$proj/.venv" ]
}

@test "an artifact dir the project already had is never touched" {
  proj="$(mkproj artkept)"
  mkdir -p "$proj/.venv"; touch "$proj/.venv/preexisting"
  _launch "$proj"
  [ -f "$proj/.venv/preexisting" ]
}

# --- registration ------------------------------------------------------------------

@test "a claude session registers itself while it runs" {
  proj="$(mkproj reg)"
  _launch "$proj"
  run live_sessions
  [ -n "$output" ]
}

@test "a shell session registers too - it holds the same mounts" {
  proj="$(mkproj shellreg)"
  _launch "$proj" shell
  # session.lock deliberately skips `shell`; this refcount must NOT, or a shell exit
  # tears down a live claude box. Observed at engine time because cleanup unlinks it.
  run live_sessions
  [ -n "$output" ]
}

# --- the env-file (shared path, carries the OAuth token) ---------------------------

@test "the engine env-file is per session, not per project" {
  proj="$(mkproj envsess)"
  _launch "$proj"
  # Two boxes on one project must not share this path: cleanup rm -f's it, and the
  # engine does not read it until long after it is written.
  run bash -c 'sed -n "/engine-env/p" "$1"' _ "$ENGINE_ARGS_FILE"
  [[ "$output" =~ engine-env\.[0-9]+$ ]]
}

@test "a dead session's env-file is swept, a live peer's is not" {
  proj="$(mkproj envsweep)"
  sdir="$(state_dir "$proj")"; mkdir -p "$sdir"
  sleep 300 & PEER_PID=$!
  echo live > "$sdir/engine-env.$PEER_PID"
  sleep 300 & dead=$!
  kill "$dead" 2>/dev/null; wait "$dead" 2>/dev/null || true
  echo stale > "$sdir/engine-env.$dead"
  _launch "$proj"
  # A SIGKILLed session leaves a token file behind; a live one must keep its own.
  [ ! -e "$sdir/engine-env.$dead" ]
  [ -e "$sdir/engine-env.$PEER_PID" ]
}

# --- failure surfacing --------------------------------------------------------------

@test "an uncreatable scratch base aborts the launch instead of mounting nothing" {
  proj="$(mkproj badbase)"
  touch "$BATS_TEST_TMPDIR/notadir"
  AIRLOCK_TMP_BASE="$BATS_TEST_TMPDIR/notadir/sub" run _launch "$proj"
  [ "$status" -ne 0 ]
  # and crucially it must not have gone on to launch a box with a bind source that
  # does not exist
  run engine_args
  [ -z "$output" ]
}

@test "a session deregisters itself on exit" {
  proj="$(mkproj dereg)"
  register_live_peer "$proj"
  _launch "$proj"
  run bash -c 'ls "$1" | wc -l' _ "$(sessions_dir "$proj")"
  [ "$output" -eq 1 ]
  [ -e "$(sessions_dir "$proj")/$PEER_PID" ]
}
