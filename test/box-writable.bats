#!/usr/bin/env bats
# The launcher runs on the host as the box's user and writes into dot-claude/, which the
# box mounts read-write: the box decides what every name there is. These plant what a
# hostile box would (links at the launcher's temp names, a link or a folder instead of
# settings.json) and check the launcher neither writes through them nor reads through
# them (pentest 2026-10-20, O9/O10).

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
  # Regression guard for the class: content is built in $STATE_DIR and renamed in.
  ! grep -nE '(>|cp [^|;]*) *"(\$_bs|\$STATE_DIR/dot-claude[^"]*)\.tmp' "$AIRLOCK" || false
  ! grep -nE '"\$2\.tmp\.\$\$"' "$AIRLOCK" || false
}

@test "a launch leaves no private temp files behind in the state dir" {
  P="$(mkproj tidy)"
  _launch "$P" >/dev/null 2>&1 || true
  [ -z "$(find "$(state_dir "$P")" -maxdepth 1 -name '.write.*' 2>/dev/null)" ]
}
