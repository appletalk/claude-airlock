#!/usr/bin/env bats
# bin/install.sh: the image build must not silently reuse stale layers. The Claude Code
# version already keyed its own layer; the Debian packages had no key at all, so a rebuild
# reused the first build's apt layer forever (an apt layer from July inside an image built
# in September, 17 security updates behind). These pin what fixes that: the base tag is
# re-pulled (as a step that can fail soft), the apt layer is keyed on the ISO week, and a
# forced refresh is remembered so the next install in the same week keeps it.

load helper
setup() { setup_airlock_env; }

# Run install.sh hermetically: isolated HOME, stubbed engine (records argv), a pinned
# Claude Code version so it never curls upstream, and stdin not a TTY so the paste-project
# prompt is skipped. The trailing doctor fails against the stub, so the exit status is not
# asserted - only what the build was asked to do.
_install() {
  env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" \
    AIRLOCK_ENGINE="$ENGINE" CLAUDE_CODE_VERSION=1.2.3 ENGINE_ARGS_FILE="$ENGINE_ARGS_FILE" \
    ${AIRLOCK_APT_REFRESH:+AIRLOCK_APT_REFRESH="$AIRLOCK_APT_REFRESH"} \
    bash "$BATS_TEST_DIRNAME/../bin/install.sh" </dev/null 2>"$BATS_TEST_TMPDIR/install.err" >/dev/null || true
}
week() { date +%G-W%V; }
stamp_file() { printf '%s' "$AIRLOCK_HOME/.config/claude-airlock/apt-refresh"; }

@test "the base tag is pulled as its own step and the apt layer is keyed on the ISO week" {
  _install
  args="$(engine_args)"
  [[ "$args" == *"pull"* ]]
  engine_args | grep -qx -- "debian:trixie-slim"
  [[ "$args" != *"--pull"* ]]                         # not build --pull: that cannot fail soft
  engine_args | grep -qx -- "APT_REFRESH=$(week)"
  engine_args | grep -qx -- "CLAUDE_CODE_VERSION=1.2.3"
  [ "$(cat "$(stamp_file)")" = "$(week)" ]
}

@test "a failed pull warns and the build still runs from the cached tag" {
  cat > "$STUBBIN/$ENGINE" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${ENGINE_ARGS_FILE:-/dev/null}"
[ "${1:-}" = pull ] && exit 1
exit 0
EOF
  chmod +x "$STUBBIN/$ENGINE"
  _install
  grep -q 'could not pull' "$BATS_TEST_TMPDIR/install.err"
  engine_args | grep -qx -- "APT_REFRESH=$(week)"     # the build was still issued
}

@test "AIRLOCK_APT_REFRESH overrides the weekly key (what make refresh sets) and is remembered" {
  AIRLOCK_APT_REFRESH="$(week).2026-09-22-0700" _install
  engine_args | grep -qx -- "APT_REFRESH=$(week).2026-09-22-0700"
  [ "$(cat "$(stamp_file)")" = "$(week).2026-09-22-0700" ]
}

# The regression the first version of this change had: refresh mid-week, then a plain
# install re-tagged :base onto the cached, OLDER week layer and undid the refresh.
@test "a plain install in the same week reuses the forced refresh key" {
  AIRLOCK_APT_REFRESH="$(week).2026-09-22-0700" _install
  : > "$ENGINE_ARGS_FILE"
  _install
  engine_args | grep -qx -- "APT_REFRESH=$(week).2026-09-22-0700"
  ! engine_args | grep -qx -- "APT_REFRESH=$(week)"
}

@test "a remembered key from an earlier week is superseded by this week's" {
  mkdir -p "$(dirname "$(stamp_file)")"
  printf '2020-W01.2020-01-01-0000\n' > "$(stamp_file)"
  _install
  engine_args | grep -qx -- "APT_REFRESH=$(week)"
  [ "$(cat "$(stamp_file)")" = "$(week)" ]
}

@test "the Dockerfile consumes the key before the apt layer and records it as a label" {
  df="$BATS_TEST_DIRNAME/../image/Dockerfile"
  arg_line="$(grep -n '^ARG APT_REFRESH' "$df" | cut -d: -f1)"
  apt_line="$(grep -n 'apt-get update && apt-get upgrade' "$df" | cut -d: -f1)"
  [ -n "$arg_line" ]
  [ -n "$apt_line" ]
  [ "$arg_line" -lt "$apt_line" ]
  grep -q 'LABEL org.claude-airlock.apt-refresh="\$APT_REFRESH"' "$df"
  # The refresh must actually upgrade what the base tag already carries, not just
  # install newer versions of the packages we add.
  grep -q 'apt-get upgrade -y' "$df"
}

@test "make refresh forces a fresh key, prefixed with the week so install can recognise it" {
  grep -qE '^refresh:' "$BATS_TEST_DIRNAME/../Makefile"
  grep -A1 '^refresh:' "$BATS_TEST_DIRNAME/../Makefile" | grep -q 'AIRLOCK_APT_REFRESH="\$\$(date +%G-W%V)\.'
}

# --- supply chain of the non-Debian layers (review F12) ------------------------------
# Everything the images download is pinned so a re-tag, a bad mirror or a changed
# dependency tree fails the build instead of shipping. These pin the pins.

@test "Claude Code is installed from the vendored installer, never piped from the network" {
  df="$BATS_TEST_DIRNAME/../image/Dockerfile"
  ! grep -qE 'curl[^|]*install\.sh[^|]*\|[[:space:]]*bash' "$df"
  grep -q 'COPY .*claude-install.sh' "$df"
  grep -q 'bash /tmp/claude-install.sh' "$df"
  [ -s "$BATS_TEST_DIRNAME/../image/claude-install.sh" ]
  # The vendored script verifies the binary it downloads against the release manifest.
  grep -q 'checksum' "$BATS_TEST_DIRNAME/../image/claude-install.sh"
}

@test "Node is pinned by version and per-arch sha256, not resolved at build time" {
  df="$BATS_TEST_DIRNAME/../image/dev/Dockerfile"
  grep -qE '^ARG NODE_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$df"
  ! grep -q 'nodejs.org/dist/index.json' "$df"
  awk '/ARG NODE_VERSION/{f=1} f&&/sha256sum -c/{ok=1} f&&/node --version/{exit} END{exit !ok}' "$df"
}

@test "the ansible venv installs only hash-pinned packages" {
  df="$BATS_TEST_DIRNAME/../image/dev/Dockerfile"
  req="$BATS_TEST_DIRNAME/../image/dev/ansible-requirements.txt"
  grep -q -- '--require-hashes -r /tmp/ansible-requirements.txt' "$df"
  grep -qE '^ansible-lint==[0-9]+\.[0-9]+\.[0-9]+ ' "$req"
  # every pinned package carries at least one hash
  [ "$(grep -cE '^[A-Za-z0-9_.-]+==' "$req")" -gt 20 ]
  [ "$(grep -c -- '--hash=sha256:' "$req")" -ge "$(grep -cE '^[A-Za-z0-9_.-]+==' "$req")" ]
}
