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
  # "<starttime> <kind>". `shell` = holds the MOUNTS but writes no history, which is what
  # every mount-protection test needs: a history-writing peer would make the launcher
  # stop at the concurrent-session prompt instead of exercising the refcount.
  printf '%s shell\n' "$(proc_start "$PEER_PID")" > "$sdir/$PEER_PID"
}

# A peer that DOES write history, so the concurrent-session warning fires.
register_history_peer() {
  local sdir; sdir="$(sessions_dir "$1")"
  mkdir -p "$sdir"
  sleep 300 &
  PEER_PID=$!
  printf '%s host\n' "$(proc_start "$PEER_PID")" > "$sdir/$PEER_PID"
}

# Register a pidfile whose process is already gone, as a SIGKILLed box would leave.
register_dead_peer() {
  local sdir dead; sdir="$(sessions_dir "$1")"
  mkdir -p "$sdir"
  sleep 300 &
  dead=$!
  kill "$dead" 2>/dev/null
  wait "$dead" 2>/dev/null || true
  printf '999999 shell\n' > "$sdir/$dead"
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
  printf '999999 shell\n' > "$sdir/$PEER_PID"
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

@test "an artifact dir the HOST populated during the session survives" {
  proj="$(mkproj hostwriter)"
  # The engine stub stands in for the box being up; meanwhile something on the host
  # writes into .venv - the user's other terminal running `python -m venv .venv`, an
  # LSP, direnv, a host-side build. The launcher created the dir, so it is registered,
  # and this is a LONE session, so the peer check does not protect it. Only rmdir's
  # refusal to remove a non-empty dir stands between that work and deletion.
  cat > "$STUBBIN/podman" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$PWD/.venv/bin" && : > "$PWD/.venv/pyvenv.cfg"
exit 0
EOF
  cp "$STUBBIN/podman" "$STUBBIN/docker"
  chmod +x "$STUBBIN/podman" "$STUBBIN/docker"
  _launch "$proj"
  [ -f "$proj/.venv/pyvenv.cfg" ]
}

@test "an artifact dir is not leaked when its creator exits first" {
  proj="$(mkproj artorder)"
  # Session A creates and records .venv, then a peer (B) is live when A exits, so A
  # removes nothing. B is then the last one out and must still clean up A's directory:
  # the record has to outlive A, or the empty .venv is left forever - and its mere
  # existence stops every future session from registering it too.
  register_live_peer "$proj"
  _launch "$proj"
  [ -d "$proj/.venv" ]                       # A left it alone: B still has it mounted
  kill "$PEER_PID" 2>/dev/null; wait "$PEER_PID" 2>/dev/null || true
  _launch "$proj"                            # a later session is now the last one out
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
  # THIS launcher's pid under THIS project's slug - not merely "some pidfile existed",
  # which any peer registered by another test would satisfy.
  launcher_registered "$proj"
}

@test "a shell session registers too - it holds the same mounts" {
  proj="$(mkproj shellreg)"
  register_live_peer "$proj"          # a peer is present, so a loose assertion would pass
  _launch "$proj" shell
  # session.lock deliberately skips `shell`; this refcount must NOT, or a shell exit
  # tears down a live claude box. Observed at engine time because cleanup unlinks it.
  launcher_registered "$proj"
}

# --- the env-file (shared path, carries the OAuth token) ---------------------------

@test "the engine env-file is per session, not per project" {
  proj="$(mkproj envsess)"
  _launch "$proj"
  # Two boxes on one project must not share this path: cleanup rm -f's it, and the
  # engine does not read it until long after it is written.
  run bash -c 'sed -n "/engine-env/p" "$1"' _ "$ENGINE_ARGS_FILE"
  # <pid>.<starttime>: the start time is what stops a recycled pid from making a stale
  # token file look owned.
  [[ "$output" =~ engine-env\.[0-9]+\.[0-9]+$ ]]
}

@test "a dead session's env-file is swept, a live peer's is not" {
  proj="$(mkproj envsweep)"
  sdir="$(state_dir "$proj")"; mkdir -p "$sdir"
  sleep 300 & PEER_PID=$!
  echo live > "$sdir/engine-env.$PEER_PID.$(proc_start "$PEER_PID")"
  sleep 300 & dead=$!
  kill "$dead" 2>/dev/null; wait "$dead" 2>/dev/null || true
  echo stale > "$sdir/engine-env.$dead.999999"
  _launch "$proj"
  # A SIGKILLed session leaves a token file behind; a live one must keep its own.
  [ ! -e "$sdir/engine-env.$dead.999999" ]
  [ -e "$sdir/engine-env.$PEER_PID.$(proc_start "$PEER_PID")" ]
}

@test "an env-file whose pid was RECYCLED is swept - it holds a token" {
  proj="$(mkproj envrecycle)"
  sdir="$(state_dir "$proj")"; mkdir -p "$sdir"
  sleep 300 & PEER_PID=$!
  # Live pid, wrong start time: what a recycled pid looks like. Sweeping on bare pid
  # existence keeps this forever, and it is strictly worse than the old fixed path,
  # which the next launch truncated unconditionally.
  echo 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-SECRET' > "$sdir/engine-env.$PEER_PID.999999"
  _launch "$proj"
  [ ! -e "$sdir/engine-env.$PEER_PID.999999" ]
}

@test "a legacy env-file with no owner is swept" {
  proj="$(mkproj envlegacy)"
  sdir="$(state_dir "$proj")"; mkdir -p "$sdir"
  echo 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-SECRET' > "$sdir/engine-env"
  _launch "$proj"
  [ ! -e "$sdir/engine-env" ]
}

@test "a legacy env-file belonging to a LIVE session is not swept" {
  proj="$(mkproj envlegacylive)"
  sdir="$(state_dir "$proj")"; mkdir -p "$sdir"
  sleep 300 & PEER_PID=$!
  # engine-env.<pid> with no start time is the shape written by the previous version.
  # Upgrading airlock and then opening a second box must not delete the running
  # session's env-file - it would die reading a missing --env-file, which is exactly
  # the failure per-session naming was introduced to prevent.
  echo live > "$sdir/engine-env.$PEER_PID"
  _launch "$proj"
  [ -e "$sdir/engine-env.$PEER_PID" ]
}

@test "a legacy env-file whose owner is gone is still swept" {
  proj="$(mkproj envlegacydead)"
  sdir="$(state_dir "$proj")"; mkdir -p "$sdir"
  sleep 300 & dead=$!
  kill "$dead" 2>/dev/null; wait "$dead" 2>/dev/null || true
  echo 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-SECRET' > "$sdir/engine-env.$dead"
  _launch "$proj"
  [ ! -e "$sdir/engine-env.$dead" ]
}

# --- the abort path -----------------------------------------------------------------

@test "declining the concurrent-session prompt leaves nothing behind" {
  proj="$(mkproj abort)"
  # A HISTORY-writing peer: the warning is answered from the registry now, and only a
  # session that can corrupt --resume history triggers it. A `shell` peer holds the same
  # mounts and deliberately does not.
  register_history_peer "$proj"
  # The lock is ALSO read as an additive fallback, for peers that register nothing.
  printf '%s airlock 0\n' "$PEER_PID" > "$(state_dir "$proj")/session.lock"
  # _launch feeds /dev/null on stdin, so the prompt reads EOF and takes the abort branch.
  run _launch "$proj"
  [ "$status" -ne 0 ]
  # The peer's lock must survive - this session never took it.
  [ -e "$(state_dir "$proj")/session.lock" ]
  # and no pidfile or token-bearing env-file may be left by the aborted session
  run bash -c 'ls "$1" 2>/dev/null | wc -l' _ "$(sessions_dir "$proj")"
  [ "$output" -eq 1 ]
  run bash -c 'ls "$1"/engine-env.* 2>/dev/null | wc -l' _ "$(state_dir "$proj")"
  [ "$output" -eq 0 ]
}

# --- lock ownership -----------------------------------------------------------------

@test "a session does not delete a lock another session took over" {
  proj="$(mkproj lockown)"
  # The engine stub stands in for this session being up; meanwhile a SECOND session
  # prompts, the user answers y, and it overwrites the lock with its own pid. That is
  # the normal path when two boxes on one project is the design - so the first to exit
  # must not delete the live session's lock.
  cat > "$STUBBIN/podman" <<'EOF'
#!/usr/bin/env bash
for l in "$HOME"/.config/claude-airlock/state/*/session.lock; do
  [ -e "$l" ] && printf '999001 airlock 0\n' > "$l"
done
exit 0
EOF
  cp "$STUBBIN/podman" "$STUBBIN/docker"; chmod +x "$STUBBIN/podman" "$STUBBIN/docker"
  _launch "$proj"
  [ -e "$(state_dir "$proj")/session.lock" ]
  run cat "$(state_dir "$proj")/session.lock"
  [[ "$output" == 999001* ]]
}

@test "a session does remove its own lock" {
  proj="$(mkproj lockmine)"
  _launch "$proj"
  [ ! -e "$(state_dir "$proj")/session.lock" ]
}

# --- a run that mounted nothing -----------------------------------------------------

@test "a declined run does not clean up after a NON-airlock session" {
  proj="$(mkproj declined)"
  # A raw host `claude` shares the lock format and uses $AIRLOCK_TMP under the same
  # name, but registers no pidfile - so "no registered peers" is not "nobody there".
  mkdir -p "$(scratch_dir "$proj")" "$(sessions_dir "$proj")"
  sleep 300 & PEER_PID=$!
  # A history-writing peer in the REGISTRY - that is what the warning reads now. The lock
  # is still written for cross-tool compatibility but nothing consults it.
  printf '%s host\n' "$(proc_start "$PEER_PID")" > "$(sessions_dir "$proj")/$PEER_PID"
  printf '%s claude 0\n' "$PEER_PID" > "$(state_dir "$proj")/session.lock"
  run _launch "$proj"                  # stdin is /dev/null -> prompt reads EOF -> abort
  [ "$status" -ne 0 ]
  # This run mounted nothing, so it has no business removing that session's scratch dir.
  [ -d "$(scratch_dir "$proj")" ]
  [ -e "$(state_dir "$proj")/session.lock" ]
}

# --- marker identity ----------------------------------------------------------------

@test "a marker does not authorise deleting a DIFFERENT dir at the same path" {
  proj="$(mkproj markerid)"
  mkdir -p "$(state_dir "$proj")/artifacts-created"
  mkdir -p "$proj/.venv"
  # A marker recording the path but an identity that no longer matches: what you get
  # after the user empties and rebuilds .venv, or deletes and recreates it. The path is
  # not a standing licence to delete whatever later occupies it.
  printf '%s\n%s\n' "$proj/.venv" "999999:999999" \
    > "$(state_dir "$proj")/artifacts-created/path-.venv"
  _launch "$proj"
  [ -d "$proj/.venv" ]
}

@test "a marker whose dir still matches is honoured" {
  proj="$(mkproj markermatch)"
  _launch "$proj"
  # created and recorded by this same run, identity intact -> removed as before
  [ ! -e "$proj/.venv" ]
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

@test "the cleanup sweep reaches per-process temps under artifacts/" {
  proj="$(mkproj artitmp)"
  # Force an orphan in the create->mv window, which normal operation never leaves: a stub
  # `mv` that COPIES owner files instead of renaming, so the .tmp.<pid> source survives
  # carrying the launcher's own pid - the only pid the sweep will ever match.
  cat > "$STUBBIN/mv" <<EOF
#!/usr/bin/env bash
args=(); for a in "\$@"; do [ "\$a" = "-f" ] || args+=("\$a"); done
if [ "\${#args[@]}" -eq 2 ] && case "\${args[1]}" in *.owner) true ;; *) false ;; esac; then
  printf '%s\n' "\${args[0]}" >> "$BATS_TEST_TMPDIR/mvfired"
  cp "\${args[0]}" "\${args[1]}"; exit \$?
fi
exec /usr/bin/mv "\$@"
EOF
  chmod +x "$STUBBIN/mv"
  _launch "$proj"
  rm -f "$STUBBIN/mv"
  # The stub must actually have fired, or "no temps remain" holds because none was ever
  # made and this test proves nothing. The owner file itself is released at exit, so its
  # absence says nothing - the stub's own log is the only durable evidence.
  run bash -c 'wc -l < "$1/mvfired" 2>/dev/null || echo 0' _ "$BATS_TEST_TMPDIR"
  [ "$output" -gt 0 ]
  # .venv is dot-prefixed and node_modules is not; a bare `*` glob only ever caught one.
  run bash -c 'ls -A "$1"/artifacts 2>/dev/null | grep -c "\.tmp\." || true' _ "$(state_dir "$proj")"
  [ "$output" -eq 0 ]
}
