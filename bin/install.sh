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
if [ -t 0 ] && ! grep -qE '^[[:space:]]*(export[[:space:]]+)?AIRLOCK_PASTE_PROJECT=' "$CONFIG_DIR/config"; then
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
  # Absolutise. A relative path would be stored verbatim and later resolved against
  # whatever directory `airlock paste` is run from - reintroducing the exact $PWD
  # dependence this setting exists to remove, and writing to the wrong project silently.
  if [ -n "$PASTE_PROJECT" ] && [ -d "$PASTE_PROJECT" ]; then
    PASTE_PROJECT="$(cd "$PASTE_PROJECT" && pwd)"
  fi
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

# The Claude Code arg keeps that ONE layer current. Nothing kept the layers below it
# current: `build` never re-pulls a base tag it already has, and never re-runs an
# unchanged apt RUN, so the Debian packages in the box were frozen at the first build
# (measured: an apt layer from July inside an image built in September, 17 security
# updates behind, while SECURITY.md promised a rebuild would pick them up).
#
# Two things fix that. The base tag is re-pulled so an upstream rebuild is picked up -
# as its own step, not `build --pull`, because a bare `--pull` is "always" on both
# engines and turns an offline `make install` (a launcher update, every layer cached)
# into a hard failure; here it degrades to a warning, like the version lookup above.
# APT_REFRESH is the cache key of the base apt layer (see image/Dockerfile): the current
# ISO week, so the base is rebuilt at most weekly and `make install` is a cache hit the
# rest of the week. Everything above the apt layer rebuilds with it, which is why the
# default is a week and not a day.
#
# `make refresh` forces a rebuild now by passing "<week>.<timestamp>". The key that was
# used is remembered in the config dir, and a later `make install` in the SAME week reuses
# it: with the bare week key it would re-tag :base onto the cached, older week layer and
# silently undo the refresh, with doctor reporting the week as if nothing had happened.
BASE_IMAGE="$(sed -n 's/^FROM[[:space:]]\{1,\}//p' "$REPO_DIR/image/Dockerfile" | head -1)"
REFRESH_STAMP="$CONFIG_DIR/apt-refresh"
APT_WEEK="$(date +%G-W%V)"
APT_REFRESH="${AIRLOCK_APT_REFRESH:-}"
if [ -z "$APT_REFRESH" ]; then
  APT_REFRESH="$(cat "$REFRESH_STAMP" 2>/dev/null || true)"
  case "$APT_REFRESH" in
    "$APT_WEEK"|"$APT_WEEK".*) ;;          # this week's key, possibly a forced refresh
    *) APT_REFRESH="$APT_WEEK" ;;          # a new week, or no record yet
  esac
fi

# The Claude Code installer is VENDORED (image/claude-install.sh): the build runs the
# copy in the repo, never a script piped from the network, so a build is deterministic
# and an upstream change is something you read before you take it. The price is that
# the copy goes stale, and stale means it may one day stop matching the release layout
# it fetches. So every build compares it with upstream and says so, loudly, when they
# differ. It does not fail the build: drift is a review item, not a broken image, and
# an offline install must still work. Update with `make claude-installer-update` after
# reading the diff (`make claude-installer-diff`).
echo "==> Checking the vendored Claude Code installer against upstream"
if upstream="$(curl -fsSL --max-time 20 https://claude.ai/install.sh 2>/dev/null)" && [ -n "$upstream" ]; then
  if [ "$upstream" = "$(cat "$REPO_DIR/image/claude-install.sh")" ]; then
    echo "    image/claude-install.sh matches upstream"
  else
    # `|| true` twice over: diff exits 1 when the files differ (always, here) and grep -c
    # exits 1 on zero matches; under pipefail + errexit either would end the install
    # silently at the very line that exists to make the drift loud.
    drift="$(diff <(printf '%s\n' "$upstream") "$REPO_DIR/image/claude-install.sh" 2>/dev/null | grep -c '^[<>]' || true)"
    echo >&2
    echo "    !!! INSTALLER DRIFT: image/claude-install.sh no longer matches https://claude.ai/install.sh" >&2
    echo "    !!! ($drift changed line(s)). This build still uses the vendored copy. Review and update:" >&2
    echo "    !!!     make claude-installer-diff      # read what changed" >&2
    echo "    !!!     make claude-installer-update    # take it, then commit image/claude-install.sh" >&2
    echo >&2
  fi
else
  echo "    WARNING: could not fetch https://claude.ai/install.sh to compare - drift unknown." >&2
fi

echo "==> Refreshing the base tag ($BASE_IMAGE)"
if ! "$AIRLOCK_ENGINE" pull -q "$BASE_IMAGE" >/dev/null; then
  echo "    WARNING: could not pull $BASE_IMAGE - building from the cached copy." >&2
  echo "             Debian's own rebuilds of the tag are missed until a pull succeeds;" >&2
  echo "             the apt layer below still upgrades what the cached tag carries." >&2
fi

echo "==> Building base image (claude-airlock:base) - Claude Code $CLAUDE_CODE_VERSION, packages as of $APT_REFRESH"
"$AIRLOCK_ENGINE" build \
  --build-arg "CLAUDE_CODE_VERSION=$CLAUDE_CODE_VERSION" \
  --build-arg "APT_REFRESH=$APT_REFRESH" \
  -t claude-airlock:base "$REPO_DIR/image"
printf '%s\n' "$APT_REFRESH" > "$REFRESH_STAMP"
echo "==> Building dev image (claude-airlock:dev) — Python, Node 24, build tools"
echo "    (a new Claude Code version or package refresh moves the base, so this layer rebuilds too)"
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
