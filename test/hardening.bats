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
