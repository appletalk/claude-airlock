#!/usr/bin/env bash
#
# Install the claude-airlock launcher and build the base image.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_TARGET="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/claude-airlock"

# Build with the SAME engine the launcher will run with — images live in the engine's
# own store, so building under Docker and launching under podman would "lose" them.
# Honor an existing config so a re-run doesn't silently switch engines.
AIRLOCK_ENGINE="${AIRLOCK_ENGINE:-}"
if [ -z "$AIRLOCK_ENGINE" ] && [ -f "$CONFIG_DIR/config" ]; then
  AIRLOCK_ENGINE="$(sed -n 's/^[[:space:]]*AIRLOCK_ENGINE=//p' "$CONFIG_DIR/config" | tr -d '"'\''[:space:]' | tail -1)"
fi
AIRLOCK_ENGINE="${AIRLOCK_ENGINE:-podman}"

case "$AIRLOCK_ENGINE" in
  podman|docker) ;;
  *) echo "claude-airlock: AIRLOCK_ENGINE must be 'podman' or 'docker' (got '$AIRLOCK_ENGINE')." >&2; exit 1 ;;
esac

if ! command -v "$AIRLOCK_ENGINE" >/dev/null 2>&1; then
  echo "claude-airlock: '$AIRLOCK_ENGINE' not found on PATH." >&2
  if [ "$AIRLOCK_ENGINE" = podman ]; then
    echo "  Rootless podman is the recommended engine (no root-equivalent daemon)." >&2
    echo "  Install it, or fall back to Docker with:  AIRLOCK_ENGINE=docker $0" >&2
  fi
  exit 1
fi
echo "==> Engine: $AIRLOCK_ENGINE"
if [ "$AIRLOCK_ENGINE" = docker ]; then
  echo "    NOTE: the 'docker' group is root-equivalent on this host. Rootless podman"
  echo "          is the safer engine — see README ('Why rootless Podman')."
fi

echo "==> Installing launcher -> $BIN_TARGET/claude-airlock"
mkdir -p "$BIN_TARGET" "$CONFIG_DIR"
ln -sf "$REPO_DIR/bin/claude-airlock" "$BIN_TARGET/claude-airlock"

if [ ! -f "$CONFIG_DIR/config" ]; then
  cp "$REPO_DIR/config/config.example" "$CONFIG_DIR/config"
  echo "    wrote default config -> $CONFIG_DIR/config"
fi

# `airlock paste` needs ONE project to write clipboard images into — see README
# ("Pasting images into a box"). There is no safe default: it is typed from whatever
# terminal is free, so keying it off $PWD would silently write pastes into a directory
# the running box never mounts. Ask once, here, rather than failing at first use.
# Skipped when stdin is not a TTY, so CI and scripted installs stay non-interactive.
if [ -t 0 ] && ! grep -q '^[[:space:]]*AIRLOCK_PASTE_PROJECT=' "$CONFIG_DIR/config"; then
  echo
  echo "==> Which project should 'airlock paste' write clipboard images into?"
  echo "    They land in that project's \$AIRLOCK_TMP/pastes/, where its box can read them."
  echo "    Leave blank to skip — paste will then tell you how to set it."
  printf '    project path: '
  read -r PASTE_PROJECT || PASTE_PROJECT=""
  # `read` does not expand anything, so a typed ~ or $HOME arrives literally. Both are
  # natural to type (config.example itself shows "$HOME/..."), so handle the leading
  # forms explicitly — never with eval, which would run whatever was pasted in.
  PASTE_PROJECT="${PASTE_PROJECT%\"}"; PASTE_PROJECT="${PASTE_PROJECT#\"}"
  PASTE_PROJECT="${PASTE_PROJECT%\'}"; PASTE_PROJECT="${PASTE_PROJECT#\'}"
  # These patterns are LITERAL on purpose — they match the characters the user typed, so
  # "does not expand in single quotes / tilde does not expand" is the intent, not a bug.
  # shellcheck disable=SC2016,SC2088
  case "$PASTE_PROJECT" in
    '~')          PASTE_PROJECT="$HOME" ;;
    '~/'*)        PASTE_PROJECT="$HOME/${PASTE_PROJECT#\~/}" ;;
    '$HOME')      PASTE_PROJECT="$HOME" ;;
    '$HOME/'*)    PASTE_PROJECT="$HOME/${PASTE_PROJECT#\$HOME/}" ;;
    '${HOME}')    PASTE_PROJECT="$HOME" ;;
    '${HOME}/'*)  PASTE_PROJECT="$HOME/${PASTE_PROJECT#\$\{HOME\}/}" ;;
  esac
  if [ -n "$PASTE_PROJECT" ] && [ ! -d "$PASTE_PROJECT" ]; then
    echo "    not a directory: $PASTE_PROJECT — skipping." >&2
    echo "    Set it later in $CONFIG_DIR/config, e.g.:" >&2
    echo "        AIRLOCK_PASTE_PROJECT=\"\$HOME/development/myproject\"" >&2
    PASTE_PROJECT=""
  fi
  if [ -n "$PASTE_PROJECT" ]; then
    printf '\n# Project that "airlock paste" writes clipboard images into (set at install).\nAIRLOCK_PASTE_PROJECT=%q\n' \
      "$PASTE_PROJECT" >> "$CONFIG_DIR/config"
    echo "    set AIRLOCK_PASTE_PROJECT=$PASTE_PROJECT"
  fi
fi

# Claude Code must be CURRENT after every install run, not whatever version the
# image happened to cache. The install layer sits at the end of the base image
# with no changing inputs of its own, so a plain rebuild always hits the cache.
# Resolving the concrete current version here and passing it as a build arg makes
# the version itself the cache key: unchanged upstream -> instant cache hit;
# new release -> the layer (and the dev image on top of it) rebuilds.
#
# 'latest' is the channel the upstream installer uses when given no target, so
# resolving it keeps the image on exactly the version it has always tracked.
# Override with CLAUDE_CODE_VERSION=stable, or a specific x.y.z, to pin.
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-}"
if [ -z "$CLAUDE_CODE_VERSION" ]; then
  CLAUDE_CODE_VERSION="$(curl -fsSL https://downloads.claude.ai/claude-code-releases/latest || true)"
  if [[ ! "$CLAUDE_CODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    echo "    WARNING: could not resolve the current Claude Code version from" >&2
    echo "             downloads.claude.ai - falling back to the 'latest' channel." >&2
    echo "             The build may reuse a cached (older) Claude Code layer." >&2
    CLAUDE_CODE_VERSION=latest
  fi
fi

echo "==> Building base image (claude-airlock:base) - Claude Code $CLAUDE_CODE_VERSION"
"$AIRLOCK_ENGINE" build --build-arg "CLAUDE_CODE_VERSION=$CLAUDE_CODE_VERSION" \
  -t claude-airlock:base "$REPO_DIR/image"
echo "==> Building dev image (claude-airlock:dev) — Python, Node 24, build tools"
echo "    (a new Claude Code version moves the base, so this layer rebuilds too)"
"$AIRLOCK_ENGINE" build -t claude-airlock:dev "$REPO_DIR/image/dev"
echo "==> (optional) Playwright stack for browser E2E (~3GB) — build if you need it:"
echo "      $AIRLOCK_ENGINE build -t claude-airlock:playwright \"$REPO_DIR/image/playwright\""

echo "==> Verifying the host can actually contain a box (airlock doctor)"
if ! AIRLOCK_ENGINE="$AIRLOCK_ENGINE" AIRLOCK_IMAGE=claude-airlock:base "$REPO_DIR/scripts/airlock-doctor.sh"; then
  echo
  echo "claude-airlock: the install completed, but the host FAILED its containment check." >&2
  echo "  Fix the items above before trusting the sandbox — see README (Setup, step 1:" >&2
  echo "  'Rootless Podman prerequisites')." >&2
  exit 1
fi

cat <<EOF

==> Almost done. Add this line to your ~/.zshrc (or ~/.zshrc.local), then reload:

    source "$REPO_DIR/shell/claude-airlock.zsh"

That gives you:
    airlock   -> Claude Code in the sandbox (use this for a project)
    claude    -> normal host Claude, warns if an airlock session is already open
    (command claude ... always bypasses the guard)

==> One-time auth: generate a long-lived (~1yr) token on the host and save it:

    command claude setup-token          # copy the printed sk-ant-oat... value
    printf %s 'PASTE_TOKEN' > "$CONFIG_DIR/token" && chmod 600 "$CONFIG_DIR/token"

Then: cd into any project and run 'airlock'.

Contributing? Install the git hook + test tools:  make hooks && make bootstrap
EOF
