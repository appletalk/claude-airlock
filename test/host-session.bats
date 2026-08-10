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
  _launch "$proj" session register "$PEER_PID" shell
  [ -e "$(sessions_dir "$proj")/$PEER_PID" ]
  # "<starttime> <kind>"
  run bash -c 'read -r st kind _ < "$1"; echo "$st|$kind"' _ "$(sessions_dir "$proj")/$PEER_PID"
  [ "$output" = "$(proc_start "$PEER_PID")|shell" ]
}

@test "session release keeps the scratch dir while another session is live" {
  proj="$(mkproj rel)"
  sleep 60 & PEER_PID=$!
  mkdir -p "$(scratch_dir "$proj")"
  _launch "$proj" session register "$PEER_PID" shell
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
  _launch "$proj" session register "$PEER_PID" shell   # stands in for a live host claude
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
  _launch "$proj" session register "$PEER_PID" shell
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
  # `self` rather than a random string: /proc/self ALWAYS exists and always reports a
  # live start time, so without the numeric guard this wedges the store read-only
  # forever - self never dies. A payload with no /proc entry passes either way.
  printf 'self whatever\n' > "$(state_dir "$proj")/artifacts/.venv.owner"
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
  _launch "$proj" session register "$PEER_PID" shell   # a live host session
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

# --- signals must END the run, not merely interrupt it --------------------------------

@test "SIGTERM at a prompt ENDS the run instead of half-provisioning it" {
  proj="$(mkproj sigterm)"
  # The egress-approval prompt is the one that matters: its fall-through SKIPS the domain
  # and the launch CONTINUES. In bash a signal handler runs and then the script carries on,
  # so the old trap ran cleanup early - which does nothing, having mounted nothing - set the
  # idempotence flag, and then let the run create .venv, the markers and the owner file,
  # none of which were ever removed. The concurrent-session prompt does NOT reproduce this:
  # an interrupted read there falls through to "Aborted." and exits anyway.
  write_config "$proj" "egress = example.com"
  # stdin must stay OPEN, not be /dev/null: the prompt would read EOF instantly and leave
  # no window for the signal. `exec` makes the pid we signal the launcher itself.
  ( cd "$proj" && exec env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" \
      TERM=xterm AIRLOCK_ENGINE="$ENGINE" AIRLOCK_IMAGE="claude-airlock:dev" \
      AIRLOCK_SHARE_BASE="$SHARE_BASE" AIRLOCK_ROOTS="" CLAUDE_CODE_OAUTH_TOKEN="t" \
      ENGINE_ARGS_FILE="$ENGINE_ARGS_FILE" AIRLOCK_TMP_BASE="$AIRLOCK_TMP_BASE" \
      bash "$AIRLOCK" ) < <(sleep 30) >/dev/null 2>&1 &
  LPID=$!
  for _ in $(seq 100); do [ -d "$(sessions_dir "$proj")" ] && break; sleep 0.1; done
  sleep 0.5
  kill -TERM "$LPID" 2>/dev/null
  wait "$LPID" 2>/dev/null || true
  sleep 0.3
  # The signal must END the run: no box launched, and nothing provisioned or left behind.
  run engine_args
  [ -z "$output" ]
  [ ! -e "$proj/.venv" ]
  [ ! -d "$(state_dir "$proj")/artifacts-created" ]
  run bash -c 'ls "$1"/artifacts/*.owner 2>/dev/null | wc -l' _ "$(state_dir "$proj")"
  [ "$output" -eq 0 ]
  # The dir itself may remain - it is only rmdir'd in the last-one-out branch, which needs
  # a mount. What must not remain is this session's pidfile.
  run bash -c 'ls -A "$1" 2>/dev/null | wc -l' _ "$(sessions_dir "$proj")"
  [ "$output" -eq 0 ]
}

@test "a session.lock reading 'self' does not prompt forever" {
  proj="$(mkproj lockself)"
  mkdir -p "$(state_dir "$proj")"
  # /proc/self always exists and always reports a live start time, so without the numeric
  # guard this prompts on every launch - and with non-tty stdin the prompt reads EOF and
  # aborts the run outright. Same shape as the .owner guard.
  # THREE fields, i.e. the legacy shape: with no start time recorded the reader falls back
  # to bare liveness, and that is the only path where the numeric guard is load-bearing.
  # A 4-field lock is caught by the start-time mismatch regardless.
  printf 'self airlock 0\n' > "$(state_dir "$proj")/session.lock"
  run _launch "$proj"
  [ "$status" -eq 0 ]
}

@test "session register works with no container engine on PATH" {
  proj="$(mkproj noengine)"
  # The wrapper calls this on every host session, including on machines that only source
  # the integration for the lock warning. Below the engine check it failed, so every such
  # session printed a warning about a risk that cannot exist without a box.
  cd "$proj" || return 1
  run env -i PATH="/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" \
      AIRLOCK_TMP_BASE="$AIRLOCK_TMP_BASE" bash "$AIRLOCK" session register 4242
  [ "$status" -eq 0 ]
  [ -e "$(sessions_dir "$proj")/4242" ]
}

@test "the wrapper takes no lock when the scratch dir cannot be created" {
  proj="$(mkproj wrapnolock)"
  touch "$BATS_TEST_TMPDIR/notadir"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/claude"; chmod +x "$STUBBIN/claude"
  # That failure path returns BEFORE the always-block that would release anything, so a
  # lock taken ahead of it survives - recording this interactive shell, which lives for
  # days with a matching start time and is therefore unprunable.
  env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" TERM=xterm \
    AIRLOCK_TMP_BASE="$BATS_TEST_TMPDIR/notadir/sub" \
    zsh -c "source '$ZSH_LIB' >/dev/null 2>&1; cd '$proj' || exit 1; claude" </dev/null || true
  [ ! -e "$(state_dir "$proj")/session.lock" ]
}

# --- the concurrent-session warning comes from the registry (S1/S2) -------------------

@test "a live HOST session triggers the concurrent-session warning" {
  proj="$(mkproj warnhost)"
  sleep 60 & PEER_PID=$!
  # S1: a raw host claude took the single-slot lock but was otherwise invisible. It now
  # registers, so the warning sees it like any other participant.
  _launch "$proj" session register "$PEER_PID" host
  run _launch "$proj"
  [ "$status" -ne 0 ]                       # stdin is /dev/null, so the prompt aborts
  [[ "$output" == *"already open"* ]]
  [[ "$output" == *"$PEER_PID"* ]]
}

@test "an airlock shell peer does NOT trigger the history warning" {
  proj="$(mkproj warnshell)"
  sleep 60 & PEER_PID=$!
  # It holds the same mounts, but it runs bash - it cannot corrupt --resume history.
  # Conflating the two populations is what made the registry the wrong source at first.
  _launch "$proj" session register "$PEER_PID" shell
  run _launch "$proj"
  [ "$status" -eq 0 ]
}

@test "the warning names EVERY live peer, not just one" {
  proj="$(mkproj warnmulti)"
  sleep 60 & P1=$!
  sleep 60 & P2=$!
  _launch "$proj" session register "$P1" host
  _launch "$proj" session register "$P2" airlock
  # S2: the single-slot lock could only ever describe one peer, and a second session
  # overwrote the first's record entirely.
  run _launch "$proj"
  [[ "$output" == *"$P1"* ]]
  [[ "$output" == *"$P2"* ]]
  kill "$P1" "$P2" 2>/dev/null || true
}

@test "a dead peer does not trigger the warning" {
  proj="$(mkproj warndead)"
  sleep 60 & dead=$!
  kill "$dead" 2>/dev/null; wait "$dead" 2>/dev/null || true
  _launch "$proj" session register "$dead" host
  run _launch "$proj"
  [ "$status" -eq 0 ]
}

@test "SIGQUIT also ends the run rather than provisioning through it" {
  proj="$(mkproj sigquit)"
  # QUIT and PIPE take bash's run-the-EXIT-trap-then-re-raise path just like HUP, so they
  # need the same treatment; the commit's own reasoning implies it.
  write_config "$proj" "egress = example.com"
  # `set -m` is load-bearing, not tidiness. Without job control bash starts an ASYNC command
  # with SIGINT and SIGQUIT set to SIG_IGN, and a signal ignored on entry cannot be trapped -
  # so the launcher's `trap ... QUIT` was a silent no-op and the signal was never delivered.
  # The test then failed against CORRECT code (a real user's foreground Ctrl-\ does fire it).
  # TERM needs none of this, which is why only the QUIT twin failed.
  set -m
  ( cd "$proj" && exec env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" \
      TERM=xterm AIRLOCK_ENGINE="$ENGINE" AIRLOCK_IMAGE="claude-airlock:dev" \
      AIRLOCK_SHARE_BASE="$SHARE_BASE" AIRLOCK_ROOTS="" CLAUDE_CODE_OAUTH_TOKEN="t" \
      ENGINE_ARGS_FILE="$ENGINE_ARGS_FILE" AIRLOCK_TMP_BASE="$AIRLOCK_TMP_BASE" \
      bash "$AIRLOCK" ) < <(sleep 30) >/dev/null 2>&1 &
  LPID=$!
  set +m
  for _ in $(seq 100); do [ -d "$(sessions_dir "$proj")" ] && break; sleep 0.1; done
  sleep 0.5
  # Guard against the no-op regressing silently: SIGQUIT (bit 3, mask 0x4) must not be
  # ignored, or the kill below is a no-op and the assertions pass/fail for the wrong reason.
  # Checked HERE, not at `&`: the subshell still shows 0x4 until it execs the launcher.
  run bash -c 'read -r _ m < <(grep ^SigIgn: /proc/"$1"/status); echo $(( 0x$m & 0x4 ))' _ "$LPID"
  [ "$output" -eq 0 ]
  kill -QUIT "$LPID" 2>/dev/null
  wait "$LPID" 2>/dev/null || true
  sleep 0.3
  run engine_args
  [ -z "$output" ]
  [ ! -e "$proj/.venv" ]
}

@test "two launches starting together do not collide on a shared temp path" {
  proj="$(mkproj concurrent)"
  # Every jq rewrite used a FIXED $FILE.tmp, so two launches on one project wrote and
  # mv'd the same path; a measured 38 of 80 simultaneous launches died on it. `shell`
  # mode because it takes no lock and raises no history warning - this is about the
  # temp paths, not the concurrent-session guard.
  _launch "$proj" shell >/dev/null 2>&1 & A=$!
  _launch "$proj" shell >/dev/null 2>&1 & B=$!
  # NOT `wait "$A"; rca=$?` - under bats' `set -e` a non-zero wait aborts the test at that
  # line, so rca is never assigned and the assertions below can never fail. It detected
  # the bug, but by a different mechanism than the one written, and a failing A left B's
  # launcher stray.
  rca=0; wait "$A" || rca=$?
  rcb=0; wait "$B" || rcb=$?
  [ "$rca" -eq 0 ]
  [ "$rcb" -eq 0 ]
  # and neither left a temp file behind
  run bash -c 'ls "$1"/*.tmp* "$1"/dot-claude/*.tmp* 2>/dev/null | wc -l' _ "$(state_dir "$proj")"
  [ "$output" -eq 0 ]
}

@test "a malformed host claude.json still yields a valid config for the box" {
  proj="$(mkproj badjson)"
  printf 'this is not json{{{\n' > "$AIRLOCK_HOME/.claude.json"
  # $STATE_DIR/claude.json is bind-mounted into the box; if it does not exist the engine
  # creates a DIRECTORY at that path instead. The `echo '{}'` fallback guarantees it - and
  # was silently unreachable for one commit, because it sat behind `rm -f`, which always
  # exits 0.
  _launch "$proj"
  [ -f "$(state_dir "$proj")/claude.json" ]
  run bash -c 'jq -e . "$1" >/dev/null 2>&1 && echo VALID' _ "$(state_dir "$proj")/claude.json"
  [ "$output" = VALID ]
}

@test "cleanup is deaf to signals while it runs" {
  # Structural, not behavioural: the real check needs a second signal delivered while
  # cleanup is provably mid-pass, which is doable with a blocking stub `rmdir` on a FIFO
  # but is not written yet. This catches removal of the guard, not a subtle weakening of
  # it, and it is non-flaky. Without the guard, a second signal re-enters cleanup, hits
  # the idempotence flag and exits, truncating the pass in flight.
  run bash -c '
    awk "/^_airlock_cleanup\\(\\) \\{/{found=1; next}
         found && !/^ *#/ && NF {print; exit}" "$1"' _ "$AIRLOCK"
  [[ "$output" == *"trap ''"* ]]
  [[ "$output" == *INT* && "$output" == *TERM* && "$output" == *HUP* ]]
  [[ "$output" == *QUIT* && "$output" == *PIPE* ]]
}

@test "the warning names only the peers that actually triggered it" {
  proj="$(mkproj warnnames)"
  sleep 60 & HOSTP=$!
  sleep 60 & SHELLP=$!
  _launch "$proj" session register "$HOSTP" host
  _launch "$proj" session register "$SHELLP" shell
  run _launch "$proj"
  # The shell peer holds the same mounts but writes no history, so naming it would be a
  # lie about why we stopped.
  [[ "$output" == *"$HOSTP"* ]]
  [[ "$output" != *"$SHELLP"* ]]
  kill "$HOSTP" "$SHELLP" 2>/dev/null || true
}

@test "concurrent launches both get the settings baseline" {
  proj="$(mkproj concurrentsettings)"
  # The reset of a corrupt/empty settings.json used to TRUNCATE the shared file in place,
  # so a sibling reading it mid-merge silently lost the airlock baseline - no error, just
  # a box running without the intended permissions and env.
  : > "$(state_dir "$proj")/dot-claude/settings.json" 2>/dev/null || true
  _launch "$proj" shell >/dev/null 2>&1 & A=$!
  _launch "$proj" shell >/dev/null 2>&1 & B=$!
  rca=0; wait "$A" || rca=$?
  rcb=0; wait "$B" || rcb=$?
  [ "$rca" -eq 0 ]
  [ "$rcb" -eq 0 ]
  run bash -c 'jq -e ".permissions.allow | length > 0" "$1" >/dev/null 2>&1 && echo BASELINE' \
      _ "$(state_dir "$proj")/dot-claude/settings.json"
  [ "$output" = BASELINE ]
  run bash -c 'ls "$1"/dot-claude/*.tmp* 2>/dev/null | wc -l' _ "$(state_dir "$proj")"
  [ "$output" -eq 0 ]
}

@test "a lock-only peer (old wrapper, no registry entry) still warns" {
  proj="$(mkproj lockonly)"
  sleep 60 & PEER_PID=$!
  mkdir -p "$(state_dir "$proj")"
  # Exactly what the OLD zsh wrapper writes: a 3-field lock and no pidfile. Not a
  # transient upgrade state - every already-open terminal keeps the old `claude` function
  # until re-sourced, and a wrapper pasted into an rc file never registers at all. main
  # detected this; the registry-only warning did not, which made the branch worse than
  # main for that case.
  printf '%s host 0\n' "$PEER_PID" > "$(state_dir "$proj")/session.lock"
  run _launch "$proj"
  [ "$status" -ne 0 ]                        # stdin is /dev/null, so the prompt aborts
  [[ "$output" == *"already open"* ]]
  [[ "$output" == *"$PEER_PID"* ]]
}

@test "a lock-only peer that is DEAD does not warn" {
  proj="$(mkproj lockonlydead)"
  sleep 60 & dead=$!
  kill "$dead" 2>/dev/null; wait "$dead" 2>/dev/null || true
  mkdir -p "$(state_dir "$proj")"
  printf '%s host 0\n' "$dead" > "$(state_dir "$proj")/session.lock"
  run _launch "$proj"
  [ "$status" -eq 0 ]
}

@test "a registered peer is not counted twice via its lock" {
  proj="$(mkproj nodouble)"
  sleep 60 & PEER_PID=$!
  mkdir -p "$(state_dir "$proj")"
  _launch "$proj" session register "$PEER_PID" host
  printf '%s host 0\n' "$PEER_PID" > "$(state_dir "$proj")/session.lock"
  run _launch "$proj"
  [[ "$output" == *"already open"* ]]
  # named once, not twice
  run bash -c 'grep -o "'"$PEER_PID"'" <<< "$1" | wc -l' _ "$output"
  [ "$output" -eq 1 ]
}
