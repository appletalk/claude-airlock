# Shared bats helpers for the claude-airlock launcher.
#
# Every test runs the REAL launcher in a hermetic environment: an isolated $HOME (so real
# ~/.config state is never touched), a stubbed container engine that records its argv
# instead of running a container, and a stubbed `pass`. Host-side subcommands
# (egress/secret/share) exit before the engine ever runs; a full launch hits the stub,
# letting us assert on the assembled `<engine> run` arguments.
#
# BOTH engines are stubbed, and the suite runs under whichever $ENGINE names (default
# podman, the launcher's default). CI runs the whole suite twice — once per engine — so
# the Docker path cannot rot just because nobody uses it day to day.

AIRLOCK="${AIRLOCK:-$BATS_TEST_DIRNAME/../bin/claude-airlock}"

# Engine under test. Overridable so CI can matrix the same suite across both.
ENGINE="${ENGINE:-podman}"

setup_airlock_env() {
  export AIRLOCK_HOME="$BATS_TEST_TMPDIR/home"
  export STUBBIN="$BATS_TEST_TMPDIR/bin"
  export SHARE_BASE="$BATS_TEST_TMPDIR/base"
  export ENGINE_ARGS_FILE="$BATS_TEST_TMPDIR/engine-args"
  mkdir -p "$AIRLOCK_HOME" "$STUBBIN" "$SHARE_BASE"

  # Seed ~/.claude.json so the launcher's jq theme-read doesn't trip `set -e`.
  printf '{"theme":"dark"}\n' > "$AIRLOCK_HOME/.claude.json"

  # Stub both engines: append each argv token (one per line) to ENGINE_ARGS_FILE. Both
  # exist on PATH so a test can assert WHICH engine the launcher chose, not merely that
  # some engine ran — the launcher's `command -v` check must find the one it selected.
  for _e in docker podman; do
    cat > "$STUBBIN/$_e" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "\${ENGINE_ARGS_FILE:-/dev/null}"
printf '%s\n' "ENGINE_INVOKED=$_e" >> "\${ENGINE_ARGS_FILE:-/dev/null}"
EOF
    chmod +x "$STUBBIN/$_e"
  done

  # Stub pass: return a deterministic fake secret for any `pass show PATH`.
  cat > "$STUBBIN/pass" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = show ] && echo "stub-secret-for-${2:-}"
exit 0
EOF
  chmod +x "$STUBBIN/pass"
}

# Path-slug a project dir the same way the launcher does.
_slug() { printf '%s' "$1" | sed 's#[^a-zA-Z0-9]#-#g; s#^-*##'; }

# Host-side state dir for a project (under the isolated HOME).
state_dir() { printf '%s' "$AIRLOCK_HOME/.config/claude-airlock/state/$(_slug "$1")"; }

# Create a throwaway project dir; echoes its path.
mkproj() {
  local d="$BATS_TEST_TMPDIR/proj-${1:-p}"
  mkdir -p "$d/.airlock"
  printf '%s' "$d"
}

# Write a project's .airlock/config.
write_config() { mkdir -p "$1/.airlock"; printf '%s\n' "$2" > "$1/.airlock/config"; }

# Run the launcher for project $1 with the remaining args, hermetically.
# AIRLOCK_ENGINE is passed explicitly so a test can pin the engine; it defaults to
# $ENGINE, which itself defaults to the launcher's own default (podman).
_launch() {
  local proj="$1"; shift
  cd "$proj" || return 1
  env -i \
    PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" \
    HOME="$AIRLOCK_HOME" \
    TERM=xterm \
    AIRLOCK_ENGINE="${AIRLOCK_ENGINE_OVERRIDE:-$ENGINE}" \
    AIRLOCK_IMAGE="claude-airlock:dev" \
    AIRLOCK_SHARE_BASE="$SHARE_BASE" \
    AIRLOCK_ROOTS="" \
    CLAUDE_CODE_OAUTH_TOKEN="test-token" \
    ENGINE_ARGS_FILE="$ENGINE_ARGS_FILE" \
    ${AIRLOCK_PODMAN_NETWORK:+AIRLOCK_PODMAN_NETWORK="$AIRLOCK_PODMAN_NETWORK"} \
    ${AIRLOCK_SHARE_MEMORY:+AIRLOCK_SHARE_MEMORY="$AIRLOCK_SHARE_MEMORY"} \
    ${AIRLOCK_PERSIST_LOGIN:+AIRLOCK_PERSIST_LOGIN="$AIRLOCK_PERSIST_LOGIN"} \
    bash "$AIRLOCK" "$@" </dev/null
}

# Run the launcher with NO AIRLOCK_ENGINE set at all, to exercise the built-in default.
_launch_default_engine() {
  local proj="$1"; shift
  cd "$proj" || return 1
  env -i \
    PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" \
    HOME="$AIRLOCK_HOME" \
    TERM=xterm \
    AIRLOCK_IMAGE="claude-airlock:dev" \
    AIRLOCK_SHARE_BASE="$SHARE_BASE" \
    AIRLOCK_ROOTS="" \
    CLAUDE_CODE_OAUTH_TOKEN="test-token" \
    ENGINE_ARGS_FILE="$ENGINE_ARGS_FILE" \
    bash "$AIRLOCK" "$@" </dev/null
}

# Just the "active groups" value from `egress show` for project $1.
active_groups() { _launch "$1" egress show | sed -n 's/^  active groups: //p'; }

# The recorded engine argv (one token per line) from the last full launch.
engine_args() { cat "$ENGINE_ARGS_FILE" 2>/dev/null; }

# Which engine binary the launcher actually invoked.
invoked_engine() { sed -n 's/^ENGINE_INVOKED=//p' "$ENGINE_ARGS_FILE" 2>/dev/null | tail -1; }
