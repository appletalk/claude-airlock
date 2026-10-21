#!/usr/bin/env bats
# The launcher runs on the host as the box's user and writes into dot-claude/, which the
# box mounts read-write: the box decides what every name there is. These plant what a
# hostile box would (links at the launcher's temp names, a link or a folder instead of
# settings.json) and check the launcher neither writes through them nor reads through
# them (pentest 2026-10-20, O9/O10).
# Some defences are race-only (the -L precheck, `cp -P`, the copy timeout): a sibling box
# would have to swap a name between check and use, which these single-launch tests can't
# stage. They are commented in the launcher so they aren't "simplified" away.

load helper
setup() {
  setup_airlock_env
  VICTIM="$BATS_TEST_TMPDIR/victim"          # stands for ~/.bash_profile and the like
  printf 'VICTIM-UNCHANGED\n' > "$VICTIM"
  SECRET="$BATS_TEST_TMPDIR/secret.json"     # stands for another project's .credentials.json
  printf '{"claudeAiOauth":{"accessToken":"SECRET-CANARY-1234"}}\n' > "$SECRET"
}

dc() { printf '%s/dot-claude' "$(state_dir "$1")"; }

# A box that read the launcher's PID from its own mounts plants links at every temp name the
# launcher's `$$` produces in dot-claude/, pointing at the victim.
_plant_tmp_links() {
  local d; d="$(dc "$P")"; mkdir -p "$d"
  for n in settings.json CLAUDE.md airlock-statusline.sh; do ln -s "$VICTIM" "$d/$n.tmp.$1"; done
}

@test "links at the launcher's temp names in dot-claude/ are not written through (O9)" {
  P="$(mkproj o9)"
  _launch_planted _plant_tmp_links "$P" >/dev/null 2>&1 || true
  [ "$(cat "$VICTIM")" = VICTIM-UNCHANGED ]
  # the launch still produced the box's files, as regular files
  for n in settings.json CLAUDE.md airlock-statusline.sh; do
    [ -f "$(dc "$P")/$n" ] && [ ! -L "$(dc "$P")/$n" ] || { echo "$n not a regular file"; false; }
  done
  jq -e '.env.DISABLE_TELEMETRY == "1"' "$(dc "$P")/settings.json" >/dev/null
}

@test "a settings.json that links elsewhere is not read into the box (O10)" {
  P="$(mkproj o10)"; mkdir -p "$(dc "$P")"
  ln -s "$SECRET" "$(dc "$P")/settings.json"
  _launch "$P" >/dev/null 2>&1 || true
  ! grep -rq SECRET-CANARY "$(dc "$P")" || { echo "the linked file's content reached dot-claude/"; false; }
  [ -f "$(dc "$P")/settings.json" ] && [ ! -L "$(dc "$P")/settings.json" ]
  jq -e '.env.DISABLE_TELEMETRY == "1"' "$(dc "$P")/settings.json" >/dev/null
  grep -q SECRET-CANARY "$SECRET"                       # the target itself is untouched
}

@test "a folder in place of settings.json stops the launch and says what it found" {
  P="$(mkproj dir)"; mkdir -p "$(dc "$P")/settings.json"
  run _launch "$P"
  [ "$status" -ne 0 ]
  [[ "$output" == *"settings.json is a folder, not a regular file"* ]]
  [[ "$output" == *"was this planted?"* ]]
  [ -d "$(dc "$P")/settings.json" ]                     # left for the user to look at
  ! grep -qx -- "--cap-drop=ALL" "$ENGINE_ARGS_FILE" 2>/dev/null || { echo "the box was started"; false; }
}

@test "a folder in place of a seeded file stops the launch the same way" {
  P="$(mkproj seeddir)"; mkdir -p "$(dc "$P")/CLAUDE.md"
  run _launch "$P"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CLAUDE.md is a folder, not a regular file"* ]]
}

@test "a FIFO in place of settings.json is replaced, not read" {
  P="$(mkproj fifo)"; mkdir -p "$(dc "$P")"
  mkfifo "$(dc "$P")/settings.json"
  ( _launch "$P" >/dev/null 2>&1 ) & lp=$!
  for _ in $(seq 1 60); do kill -0 "$lp" 2>/dev/null || break; sleep 1; done
  if kill -0 "$lp" 2>/dev/null; then kill "$lp"; echo "the launch hung on the FIFO"; false; fi
  [ -f "$(dc "$P")/settings.json" ] && [ ! -p "$(dc "$P")/settings.json" ]
}

@test "a valid settings.json keeps the box's own keys through the private copy" {
  P="$(mkproj keep)"; mkdir -p "$(dc "$P")"
  printf '{"model":"box-choice","env":{"FOO":"bar"}}\n' > "$(dc "$P")/settings.json"
  _launch "$P" >/dev/null 2>&1 || true
  jq -e '.model == "box-choice" and .env.FOO == "bar" and .env.DISABLE_TELEMETRY == "1"' "$(dc "$P")/settings.json" >/dev/null
}

@test "no launcher write in dot-claude/ goes through a name of its own making" {
  # Regression guard for the class: no redirection or cp names a path in dot-claude/.
  ! grep -nE '>[[:space:]]*"?\$(_bs([^[:alnum:]_]|$)|STATE_DIR/dot-claude)' "$AIRLOCK" || false
  ! grep -nE '"\$2\.(tmp|new)\.\$\$"' "$AIRLOCK" || false
}

# mv and cp wrapped to log every call, then run the real ones.
_log_mv_cp() {
  for c in mv cp; do
    printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "%s"\nexec /usr/bin/%s "$@"\n' "$c" "$BATS_TEST_TMPDIR/mvcp.log" "$c" > "$STUBBIN/$c"
    chmod +x "$STUBBIN/$c"
  done
}

@test "every file in dot-claude/ arrives by rename from the private dir, whatever its temp name (T2)" {
  P="$(mkproj t2)"; _log_mv_cp
  _launch "$P" >/dev/null 2>&1 || true
  d="$(dc "$P")"; sd="$(state_dir "$P")"
  [ -s "$BATS_TEST_TMPDIR/mvcp.log" ]
  # cp never writes into dot-claude/
  ! grep -E "^cp .* $d/" "$BATS_TEST_TMPDIR/mvcp.log" || { echo "cp wrote into dot-claude/"; false; }
  # every mv into dot-claude/ comes from the private .write.* dir and names the final file
  grep -E "^mv .* $d/" "$BATS_TEST_TMPDIR/mvcp.log" | while read -r _ _ _ src dst; do
    case "$src" in "$sd"/.write.*) ;; *) echo "mv from $src"; exit 1 ;; esac
    case "${dst##*/}" in settings.json|CLAUDE.md|airlock-statusline.sh) ;; *) echo "mv to $dst"; exit 1 ;; esac
  done
}

@test "a settings.json or seed that links to a folder: the folder stays empty (T1, mv -T)" {
  P="$(mkproj t1)"; mkdir -p "$(dc "$P")" "$BATS_TEST_TMPDIR/d1" "$BATS_TEST_TMPDIR/d2"
  ln -s "$BATS_TEST_TMPDIR/d1" "$(dc "$P")/settings.json"
  ln -s "$BATS_TEST_TMPDIR/d2" "$(dc "$P")/CLAUDE.md"
  _launch "$P" >/dev/null 2>&1 || true
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/d1")" ] && [ -z "$(ls -A "$BATS_TEST_TMPDIR/d2")" ]
  [ -f "$(dc "$P")/settings.json" ] && [ ! -L "$(dc "$P")/settings.json" ]
  [ -f "$(dc "$P")/CLAUDE.md" ] && [ ! -L "$(dc "$P")/CLAUDE.md" ]
}

@test "a planted settings.json link is reported, and the launch goes on" {
  P="$(mkproj warn)"; mkdir -p "$(dc "$P")"
  ln -s "$SECRET" "$(dc "$P")/settings.json"
  run _launch "$P"
  [[ "$output" == *"settings.json was a symlink, not a regular file (was this planted?)"* ]]
}

@test "a read-only dot-claude/ is reported as such, not as a planted file (P3)" {
  P="$(mkproj ro)"; mkdir -p "$(dc "$P")"; chmod 555 "$(dc "$P")"
  run _launch "$P"
  chmod 755 "$(dc "$P")"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not place"* ]]
  [[ "$output" != *"was this planted?"* ]]
}

@test "the git guard creates nothing through a symlinked parent (P2)" {
  P="$(mkproj gg)"; git -C "$P" init -q
  out="$BATS_TEST_TMPDIR/outside"; mkdir -p "$out"
  ln -s "$out" "$P/evil"
  git -C "$P" config core.hooksPath evil/made/by/launcher
  run _launch "$P"
  [ "$status" -ne 0 ]
  [ ! -e "$out/made" ] || { echo "created outside the workspace"; false; }
}

@test "a launch leaves no private temp files behind in the state dir" {
  P="$(mkproj tidy)"
  _launch "$P" >/dev/null 2>&1 || true
  [ -z "$(find "$(state_dir "$P")" -maxdepth 1 -name '.write.*' 2>/dev/null)" ]
}
