#!/usr/bin/env bats
# Container hardening: the assembled `docker run` drops docker's broad default
# capability set and re-adds only what the box needs — NET_ADMIN+NET_RAW (firewall)
# and SETUID+SETGID (gosu drops root -> dev) — plus no-new-privileges. The agent
# itself runs as non-root dev with no caps. (Runtime behaviour is validated against
# a real container separately; here we pin the flags so they can't silently regress.)

load helper
setup() { setup_airlock_env; }

@test "drops all caps, re-adds only firewall + gosu caps" {
  _launch "$(mkproj)"
  args="$(engine_args)"
  [[ "$args" == *"--cap-drop=ALL"* ]]
  [[ "$args" == *"--cap-add=NET_ADMIN"* ]]
  [[ "$args" == *"--cap-add=NET_RAW"* ]]
  [[ "$args" == *"--cap-add=SETUID"* ]]
  [[ "$args" == *"--cap-add=SETGID"* ]]
}

@test "sets no-new-privileges" {
  _launch "$(mkproj)"
  [[ "$(engine_args)" == *"--security-opt=no-new-privileges"* ]]
}

# The OAuth token and injected secrets must NOT ride on the engine command line, where
# they would be visible in the host process table (/proc/<pid>/cmdline, `ps auxe`) for the
# container's whole lifetime. They go in a mode-0600 --env-file instead.
@test "the OAuth token goes in --env-file, never on the command line" {
  _launch "$(mkproj)"
  args="$(engine_args)"
  [[ "$args" == *"--env-file"* ]]                       # sensitive env is file-delivered
  [[ "$args" != *"CLAUDE_CODE_OAUTH_TOKEN="* ]]         # not as -e KEY=VALUE
  [[ "$args" != *"test-token"* ]]                       # and the value never appears in argv
}

@test "injected secrets go in the env-file, not the engine command line" {
  p="$(mkproj)"
  _launch "$p" secret set APIKEY supersecretvalue
  : > "$ENGINE_ARGS_FILE"
  _launch "$p"
  args="$(engine_args)"
  [[ "$args" == *"--env-file"* ]]
  [[ "$args" != *"supersecretvalue"* ]]                 # literal value stays off argv
  [[ "$args" != *"APIKEY=supersecretvalue"* ]]
}

# The env-file itself must be private (0600) and actually carry the token — it holds the
# resolved token + secrets and the launcher deletes it on exit, so a bespoke engine stub
# inspects it mid-"run" (while it still exists) and records what it saw.
# AIRLOCK_PERSIST_LOGIN=1 suppresses token injection so the box runs its own /login.
# The var must be ABSENT from the env-file, not present-and-empty: Claude treats a
# set-but-empty token as a credential and fails auth rather than falling through to the
# login flow, which would look like "persist-login is broken" while the real cause is a
# stray empty assignment. Same bespoke stub as above — the env-file dies on exit.
@test "AIRLOCK_PERSIST_LOGIN omits the token from the env-file entirely" {
  cat > "$STUBBIN/$ENGINE" <<'EOF'
#!/usr/bin/env bash
a=("$@")
for ((i=0; i<${#a[@]}; i++)); do
  if [ "${a[$i]}" = "--env-file" ]; then
    grep -q 'CLAUDE_CODE_OAUTH_TOKEN' "${a[$((i+1))]}" && echo yes > "$ENGINE_ARGS_FILE.hasvar"
  fi
done
EOF
  chmod +x "$STUBBIN/$ENGINE"
  AIRLOCK_PERSIST_LOGIN=1 _launch "$(mkproj)"
  [ ! -f "$ENGINE_ARGS_FILE.hasvar" ]                   # not even as an empty assignment
}

# The credential has to land somewhere that outlives the container, or the one-time login
# becomes a per-launch login. It needs no dedicated mount: Claude writes to $HOME/.claude,
# which is already the persistent per-project state bind-mount. Pin that here, because the
# feature silently degrades to "logs in every time" if this mount is ever made ephemeral.
@test "persist-login relies on the already-persistent .claude mount" {
  p="$(mkproj)"
  AIRLOCK_PERSIST_LOGIN=1 _launch "$p"
  [[ "$(engine_args)" == *"$(state_dir "$p")/dot-claude:/home/dev/.claude:rw"* ]]
}

# The whole point of `airlock login persist` is that ONE project opts out while every
# other keeps the shared token. A global flag would be the wrong shape, so assert the
# per-project split directly: same host, same token, two projects, different modes.
@test "login mode is per-project: persist here does not disturb token there" {
  otto="$(mkproj otto)"; worker="$(mkproj worker)"
  _launch "$otto" login persist
  cat > "$STUBBIN/$ENGINE" <<'EOF'
#!/usr/bin/env bash
a=("$@")
for ((i=0; i<${#a[@]}; i++)); do
  if [ "${a[$i]}" = "--env-file" ]; then
    grep -q 'CLAUDE_CODE_OAUTH_TOKEN' "${a[$((i+1))]}" && echo yes >> "$ENGINE_ARGS_FILE.hasvar"
  fi
done
EOF
  chmod +x "$STUBBIN/$ENGINE"
  _launch "$otto"                                        # opted out -> no token
  [ ! -f "$ENGINE_ARGS_FILE.hasvar" ]
  _launch "$worker"                                      # untouched -> still tokenised
  [ "$(cat "$ENGINE_ARGS_FILE.hasvar" 2>/dev/null)" = "yes" ]
}

# The mode has to SURVIVE, or a restart silently falls back to the token and the
# long-lived session loses the credential-backed features it was switched over for.
@test "persist mode persists across launches, and token switches back" {
  p="$(mkproj)"
  _launch "$p" login persist
  run _launch "$p" login show
  [[ "$output" == *"persist"* ]]
  [ -f "$(state_dir "$p")/persist-login" ]
  _launch "$p" login token
  run _launch "$p" login show
  [[ "$output" == *"token (default)"* ]]
  [ ! -f "$(state_dir "$p")/persist-login" ]
}

# Switching back to the token must not silently delete a stored credential, but it must
# SAY the credential is still there — an account credential lingering on disk after you
# thought you turned the feature off is exactly the kind of thing that should never be
# discovered by accident.
@test "login token leaves the credential but warns that it remains" {
  p="$(mkproj)"; sd="$(state_dir "$p")"
  mkdir -p "$sd/dot-claude"; echo '{"fake":"cred"}' > "$sd/dot-claude/.credentials.json"
  _launch "$p" login persist
  run _launch "$p" login token
  [[ "$output" == *"credential remains"* ]]
  [ -s "$sd/dot-claude/.credentials.json" ]
}

# --- telemetry posture (`airlock telemetry`) ----------------------------------------
# Telemetry is controlled in the BOX'S settings.json, because that is what Claude reads
# for it. Two facts pin the exact shape and are the regressions these tests guard:
#   - Claude checks whether DISABLE_TELEMETRY is SET, not its value — "0" still disables.
#     So "on" must mean the key is ABSENT, never "=0".
#   - The baseline merge only ADDS keys, so a stale DISABLE_TELEMETRY from an old launch
#     is never removed by omission alone; the launcher has to delete it explicitly.
_box_settings() { cat "$(state_dir "$1")/dot-claude/settings.json" 2>/dev/null; }

@test "telemetry is disabled by default, in the box settings.json" {
  p="$(mkproj)"; _launch "$p"
  run jq -r '.env.DISABLE_TELEMETRY' <<<"$(_box_settings "$p")"
  [ "$output" = "1" ]
  run jq -r '.env.DISABLE_ERROR_REPORTING' <<<"$(_box_settings "$p")"
  [ "$output" = "1" ]
}

@test "telemetry on deletes the telemetry key, never sets it to 0" {
  p="$(mkproj)"
  _launch "$p" telemetry on
  _launch "$p"
  run jq -e '.env | has("DISABLE_TELEMETRY")' <<<"$(_box_settings "$p")"
  [ "$status" -ne 0 ]                                     # absent, not present-as-"0"
}

# Least-privilege split: RC needs telemetry, not error reporting, so turning telemetry ON
# must NOT re-enable crash reporting. Error reporting stays off in both states.
@test "telemetry on leaves error reporting disabled" {
  p="$(mkproj)"
  _launch "$p" telemetry on
  _launch "$p"
  run jq -r '.env.DISABLE_ERROR_REPORTING' <<<"$(_box_settings "$p")"
  [ "$output" = "1" ]
}

# The exact bug that shipped: a box provisioned while telemetry was baked into the baseline
# keeps the stale key, and merge-by-omission never clears it. `telemetry on` must actively
# delete it, so an already-provisioned box self-heals on its next launch.
@test "telemetry on clears a stale telemetry key left by an earlier launch" {
  p="$(mkproj)"; sd="$(state_dir "$p")"; mkdir -p "$sd/dot-claude"
  printf '{"env":{"DISABLE_TELEMETRY":"1","DISABLE_ERROR_REPORTING":"1"}}\n' > "$sd/dot-claude/settings.json"
  _launch "$p" telemetry on
  _launch "$p"
  run jq -e '.env | has("DISABLE_TELEMETRY")' <<<"$(_box_settings "$p")"
  [ "$status" -ne 0 ]
}

@test "telemetry is per-project and round-trips through show/off" {
  otto="$(mkproj otto)"; worker="$(mkproj worker)"
  _launch "$otto" telemetry on
  run _launch "$otto" telemetry show
  [[ "$output" == *"ON"* ]]
  _launch "$worker"                                       # untouched project stays off
  run jq -r '.env.DISABLE_TELEMETRY' <<<"$(_box_settings "$worker")"
  [ "$output" = "1" ]
  _launch "$otto" telemetry off                           # back to default
  _launch "$otto"
  run jq -r '.env.DISABLE_TELEMETRY' <<<"$(_box_settings "$otto")"
  [ "$output" = "1" ]
}

# The baseline must not hardcode these keys — a key here would be re-added by the merge on
# every launch and no per-project `telemetry on` could keep it out.
@test "box-settings.json does not hardcode the telemetry vars" {
  run jq -e '.env | has("DISABLE_TELEMETRY") or has("DISABLE_ERROR_REPORTING")' \
    "$BATS_TEST_DIRNAME/../config/box-settings.json"
  [ "$status" -ne 0 ]
}

# --- starting permission mode (`airlock mode`) --------------------------------------
# Same per-project shape as login/egress: one long-lived box can start in `auto` without
# every disposable box inheriting it.
@test "airlock mode sets a per-project starting permission mode" {
  otto="$(mkproj otto)"; worker="$(mkproj worker)"
  _launch "$otto" mode auto
  _launch "$otto"
  [[ "$(engine_args)" == *"--permission-mode"* ]]
  [[ "$(engine_args)" == *"auto"* ]]
  : > "$ENGINE_ARGS_FILE"
  _launch "$worker"                                      # untouched project
  [[ "$(engine_args)" != *"--permission-mode"* ]]
}

@test "mode show and reset roundtrip" {
  p="$(mkproj)"
  _launch "$p" mode auto
  run _launch "$p" mode show
  [[ "$output" == *"auto"* ]]
  _launch "$p" mode reset
  run _launch "$p" mode show
  [[ "$output" == *"unset"* ]]
  : > "$ENGINE_ARGS_FILE"
  _launch "$p"
  [[ "$(engine_args)" != *"--permission-mode"* ]]
}

@test "an invalid mode is rejected and nothing is stored" {
  p="$(mkproj)"
  run _launch "$p" mode turbo
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown permission mode"* ]]
  [ ! -f "$(state_dir "$p")/permission-mode" ]
}

# An explicitly typed flag must beat the stored default, or the setting would silently
# swallow what you just asked for — the most confusing possible failure.
@test "an explicit --permission-mode on the command line wins over the stored mode" {
  p="$(mkproj)"
  _launch "$p" mode auto
  _launch "$p" --permission-mode plan
  args="$(engine_args)"
  [[ "$args" == *"plan"* ]]
  [ "$(grep -c -- '--permission-mode' <<<"$args")" -eq 1 ]   # ours was not also appended
}

# `claude <subcommand>` does not accept --permission-mode: injecting it turns the mode
# value into a stray positional and the subcommand dies ("Unknown argument: auto"), which
# looks like the subcommand is broken rather than the launcher adding an untyped flag.
@test "the stored mode is not injected into claude subcommands" {
  p="$(mkproj)"
  _launch "$p" mode auto
  # Only subcommands airlock passes THROUGH; `doctor` is airlock's own and never reaches claude.
  for sub in remote-control mcp setup-token; do
    : > "$ENGINE_ARGS_FILE"
    _launch "$p" "$sub"
    [[ "$(engine_args)" == *"$sub"* ]]
    [[ "$(engine_args)" != *"--permission-mode"* ]]
  done
}

# ...but a flag-led invocation is still a session and must keep the stored mode.
@test "the stored mode still applies to a flag-led session" {
  p="$(mkproj)"
  _launch "$p" mode auto
  _launch "$p" --continue
  args="$(engine_args)"
  [[ "$args" == *"--permission-mode"* ]]
  [[ "$args" == *"--continue"* ]]
}

# A hand-edited or stale state file must not launch a box that dies on an invalid flag.
@test "an invalid stored mode is ignored with a warning, not passed through" {
  p="$(mkproj)"; sd="$(state_dir "$p")"; mkdir -p "$sd"
  printf 'turbo\n' > "$sd/permission-mode"
  run _launch "$p"
  [[ "$output" == *"ignoring invalid permission mode"* ]]
  [[ "$(engine_args)" != *"turbo"* ]]
}

@test "an unknown login verb is rejected" {
  p="$(mkproj)"
  run _launch "$p" login bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage: airlock login"* ]]
}

# Without the flag, a host with no token must still fail loudly rather than silently
# dropping into an interactive login — that would turn a misconfigured host into a
# surprise credential prompt on an ephemeral box.
@test "no token and no persist-login is still a hard error" {
  p="$(mkproj)"; cd "$p"
  run env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" TERM=xterm \
    AIRLOCK_ENGINE="$ENGINE" AIRLOCK_IMAGE="claude-airlock:dev" \
    AIRLOCK_SHARE_BASE="$SHARE_BASE" AIRLOCK_ROOTS="" \
    ENGINE_ARGS_FILE="$ENGINE_ARGS_FILE" \
    bash "$AIRLOCK" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"no auth token found"* ]]
}

@test "the engine env-file is created mode 0600 and carries the token" {
  cat > "$STUBBIN/$ENGINE" <<'EOF'
#!/usr/bin/env bash
a=("$@")
for ((i=0; i<${#a[@]}; i++)); do
  if [ "${a[$i]}" = "--env-file" ]; then
    f="${a[$((i+1))]}"
    stat -c '%a' "$f" > "$ENGINE_ARGS_FILE.mode"
    grep -qx 'CLAUDE_CODE_OAUTH_TOKEN=test-token' "$f" && echo yes > "$ENGINE_ARGS_FILE.hastoken"
  fi
done
EOF
  chmod +x "$STUBBIN/$ENGINE"
  _launch "$(mkproj)"
  [ "$(cat "$ENGINE_ARGS_FILE.mode")" = "600" ]
  [ "$(cat "$ENGINE_ARGS_FILE.hastoken" 2>/dev/null)" = "yes" ]
}

# A fork-bomb guard: an explicit pids-limit is passed so a runaway box can't exhaust host
# PIDs (Docker's default is unlimited). Overridable, and 0/unset falls back to the engine.
@test "a default --pids-limit is passed" {
  _launch "$(mkproj)"
  [[ "$(engine_args)" == *"--pids-limit"* ]]
}

@test "AIRLOCK_PIDS_LIMIT=0 disables the explicit pids-limit (engine default)" {
  mkdir -p "$AIRLOCK_HOME/.config/claude-airlock"
  echo 'AIRLOCK_PIDS_LIMIT=0' > "$AIRLOCK_HOME/.config/claude-airlock/config"
  _launch "$(mkproj)"
  [[ "$(engine_args)" != *"--pids-limit"* ]]
}

@test "AIRLOCK_MEMORY is opt-in: absent by default, passed when set" {
  _launch "$(mkproj)"
  [[ "$(engine_args)" != *"--memory"* ]]
  : > "$ENGINE_ARGS_FILE"
  mkdir -p "$AIRLOCK_HOME/.config/claude-airlock"
  echo 'AIRLOCK_MEMORY=6g' > "$AIRLOCK_HOME/.config/claude-airlock/config"
  _launch "$(mkproj)"
  args="$(engine_args)"
  [[ "$args" == *"--memory"* ]]
  [[ "$args" == *"6g"* ]]
}
