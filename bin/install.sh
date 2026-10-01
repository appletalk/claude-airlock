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

# The launcher runs from an installed copy of one commit, never from this working tree:
# a checkout changes whenever someone switches branch or edits a file, and the launcher is
# what sets the box's limits. The rule: an install builds a complete version (export and
# images) first, and only then makes it live in one step; everything, open shells
# included, follows `current`. The host containment check runs after, against the live
# version. So: export HEAD (never uncommitted edits) to a stage, verify it,
# move it to versions/<commit>, build the images from THAT directory, and only when the
# build succeeds flip `current`, relink the launcher and prune.
INSTALL_ROOT="${AIRLOCK_INSTALL_ROOT:-$HOME/.local/share/claude-airlock}"
case "$INSTALL_ROOT" in
  /*) ;;
  *) echo "claude-airlock: AIRLOCK_INSTALL_ROOT must be an absolute path (got '$INSTALL_ROOT')." >&2; exit 1 ;;
esac
mkdir -p "$INSTALL_ROOT/versions"
chmod go-w "$INSTALL_ROOT" "$INSTALL_ROOT/versions"
# One install at a time: export, build, flip and prune all touch shared state.
exec 9>"$INSTALL_ROOT/.lock"
if ! flock -n 9; then
  echo "==> Another install is running; waiting up to 10 minutes for it to finish"
  if ! flock -w 600 9; then
    echo "claude-airlock: $INSTALL_ROOT/.lock is still held; see who has it: fuser -v $INSTALL_ROOT/.lock" >&2
    exit 1
  fi
fi
_stage=""; _fresh=""; _live=""; DEST=""; REV=""
_prev="$(readlink "$INSTALL_ROOT/current" 2>/dev/null || true)"
# On any exit before this version goes live: drop a half-made stage, a version this run
# exported (it never activated, so it must not outrank older live ones in the prune) and
# its per-commit image tags. Never remove whatever `current` points at.
_cleanup() {
  [ -n "$_stage" ] && rm -rf -- "$_stage"
  [ -n "$_live" ] && return 0
  if [ -n "$_fresh" ] && [ "$(readlink "$INSTALL_ROOT/current" 2>/dev/null)" != "versions/$REV" ]; then
    rm -rf -- "$DEST"
  fi
  if [ -n "$REV" ] && [ -n "${AIRLOCK_ENGINE:-}" ]; then
    "$AIRLOCK_ENGINE" rmi "claude-airlock:base-$REV" "claude-airlock:os-$REV" "claude-airlock:dev-$REV" >/dev/null 2>&1 || true
  fi
}
trap _cleanup EXIT
# Stage dirs left by a hard kill (the trap never ran).
find "$INSTALL_ROOT/versions" -mindepth 1 -maxdepth 1 -type d -name '.stage.*' -mmin +60 -exec rm -rf -- {} + 2>/dev/null || true
if [ "$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$REPO_DIR" && pwd -P)" ]; then
  REV="$(git -C "$REPO_DIR" rev-parse --short=12 HEAD)"
  BRANCH="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"
  if [ -n "$(git -C "$REPO_DIR" status --porcelain --untracked-files=no)" ]; then
    echo "    NOTE: uncommitted changes in $REPO_DIR are NOT installed; installing commit $REV." >&2
  fi
  _export() { git -C "$REPO_DIR" archive --format=tar HEAD | tar -x -C "$1"; }
elif [ -e "$REPO_DIR/.git" ]; then
  # A checkout git would not read: git missing, or its "dubious ownership" refusal (a
  # checkout under /mnt/c, say). Copying the tree would install uncommitted edits.
  echo "claude-airlock: $REPO_DIR is a git checkout, but git cannot read it:" >&2
  git -C "$REPO_DIR" rev-parse --show-toplevel 2>&1 | sed 's/^/    /' >&2 || true
  echo "  Fix that (install git, or 'git config --global --add safe.directory $REPO_DIR'); nothing was changed." >&2
  exit 1
else
  # Not a checkout (a release tarball, or a directory inside some other repo).
  REV="nogit-$(date +%Y%m%d%H%M%S)"; BRANCH="-"
  echo "    WARNING: $REPO_DIR is not a git checkout; installing the whole tree as it is." >&2
  _export() { tar -C "$REPO_DIR" --exclude=.git --exclude=.tooling -cf - . | tar -x -C "$1"; }
fi
DEST="$INSTALL_ROOT/versions/$REV"
echo "==> Installing commit $REV ($BRANCH) -> $DEST"
if [ ! -d "$DEST" ]; then
  _stage="$(mktemp -d "$INSTALL_ROOT/versions/.stage.XXXXXX")"
  _export "$_stage"
  if [ ! -x "$_stage/bin/claude-airlock" ] || [ ! -f "$_stage/image/Dockerfile" ]; then
    echo "claude-airlock: the export of $REPO_DIR has no launcher or Dockerfile; nothing was changed." >&2
    exit 1
  fi
  printf 'commit %s\nbranch %s\ninstalled %s\nfrom %s\n' "$REV" "$BRANCH" "$(date -u +%FT%TZ)" "$REPO_DIR" \
    > "$_stage/VERSION"
  chmod -R go-w "$_stage"
  chmod 755 "$_stage"
  # Another install of the same commit may have won the race; theirs is identical.
  if mv -T "$_stage" "$DEST" 2>"$_stage.err"; then
    _fresh=1
  elif [ ! -d "$DEST" ]; then
    echo "claude-airlock: could not move the export into place:" >&2; sed 's/^/    /' "$_stage.err" >&2
    rm -f "$_stage.err"; exit 1
  fi
  rm -f "$_stage.err"; rm -rf -- "$_stage"; _stage=""
fi
# Corporate CA certs are a deliberate LOCAL, untracked drop-in (.gitignore), so the export
# never carries them. Sync them into this version's build context on every install.
find "$DEST/image/certs" -maxdepth 1 -name '*.crt' -delete
_certs=0
for _c in "$REPO_DIR"/image/certs/*.crt; do
  [ -f "$_c" ] || continue
  install -m 0644 "$_c" "$DEST/image/certs/"
  echo "    local CA cert -> image: $(basename "$_c")"
  _certs=$((_certs + 1))
done
[ "$_certs" -gt 0 ] || echo "    no local CA certs in $REPO_DIR/image/certs/"
SRC_DIR="$DEST"

mkdir -p "$BIN_TARGET" "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/config" ]; then
  cp "$SRC_DIR/config/config.example" "$CONFIG_DIR/config"
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
# The image of the first FROM, without its `AS <stage>` suffix.
BASE_IMAGE="$(awk '$1 == "FROM" { print $2; exit }' "$SRC_DIR/image/Dockerfile")"
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
  if [ "$upstream" = "$(cat "$SRC_DIR/image/claude-install.sh")" ]; then
    echo "    image/claude-install.sh matches upstream"
  else
    # `|| true` twice over: diff exits 1 when the files differ (always, here) and grep -c
    # exits 1 on zero matches; under pipefail + errexit either would end the install
    # silently at the very line that exists to make the drift loud.
    drift="$(diff <(printf '%s\n' "$upstream") "$SRC_DIR/image/claude-install.sh" 2>/dev/null | grep -c '^[<>]' || true)"
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
# Built under this commit's own tags; :base and :dev move only when both builds succeed.
"$AIRLOCK_ENGINE" build \
  --build-arg "CLAUDE_CODE_VERSION=$CLAUDE_CODE_VERSION" \
  --build-arg "APT_REFRESH=$APT_REFRESH" \
  -t "claude-airlock:base-$REV" "$SRC_DIR/image"
# The base's `os` stage (everything but Claude Code) under its own tag: the dev image
# builds on it and copies Claude Code from the base last. A cache hit - the build above
# just produced every one of its layers.
"$AIRLOCK_ENGINE" build --target os \
  --build-arg "APT_REFRESH=$APT_REFRESH" \
  -t "claude-airlock:os-$REV" "$SRC_DIR/image"
# That cache hit is what makes dev's OS layers the ones the base (and doctor) has. A pull
# of the Debian tag by a concurrent install, or cache eviction, would quietly break it,
# so check it: the os image's layers must be exactly the base image's lowest layers.
_layers() { "$AIRLOCK_ENGINE" image inspect --format '{{range .RootFS.Layers}}{{.}} {{end}}' "$1"; }
_os_layers="$(_layers "claude-airlock:os-$REV")"
_base_layers="$(_layers "claude-airlock:base-$REV")"
if [ -z "$_os_layers" ] || [ "${_base_layers#"$_os_layers"}" = "$_base_layers" ]; then
  echo "claude-airlock: the os image built for the dev image is not the base image's os stage" >&2
  echo "  (another build moved its inputs in between?). Nothing went live; run make install again." >&2
  exit 1
fi
echo "==> Building dev image (claude-airlock:dev) — Python, Node 24, build tools"
echo "    (a package refresh rebuilds it; a new Claude Code version only replaces its last layer)"
"$AIRLOCK_ENGINE" build --build-arg "BASE_IMAGE=claude-airlock:base-$REV" \
  --build-arg "OS_IMAGE=claude-airlock:os-$REV" \
  -t "claude-airlock:dev-$REV" "$SRC_DIR/image/dev"
echo "==> (optional) Playwright stack for browser E2E (~3GB) — build if you need it:"
echo "      $AIRLOCK_ENGINE build -t claude-airlock:playwright \"$SRC_DIR/image/playwright\""

# Both images built: make this version live. The image tags and `current` move together;
# `current` flips in one rename (a unique temp name, so concurrent installs cannot trip over
# each other), and the launcher link and every shell follow it. Touching DEST records
# activation time, which the prune orders by.
"$AIRLOCK_ENGINE" tag "claude-airlock:base-$REV" claude-airlock:base
"$AIRLOCK_ENGINE" tag "claude-airlock:os-$REV" claude-airlock:os
"$AIRLOCK_ENGINE" tag "claude-airlock:dev-$REV" claude-airlock:dev
"$AIRLOCK_ENGINE" rmi "claude-airlock:base-$REV" "claude-airlock:os-$REV" "claude-airlock:dev-$REV" >/dev/null 2>&1 || true
printf '%s\n' "$APT_REFRESH" > "$REFRESH_STAMP"
touch "$DEST"
_cur_tmp="$INSTALL_ROOT/.current.$$"
ln -sfn "versions/$REV" "$_cur_tmp"
mv -Tf "$_cur_tmp" "$INSTALL_ROOT/current"
_live=1
echo "==> Live: $INSTALL_ROOT/current -> versions/$REV"
echo "==> Installing launcher -> $BIN_TARGET/claude-airlock"
ln -sfn "$INSTALL_ROOT/current/bin/claude-airlock" "$BIN_TARGET/claude-airlock"
# Keep the live version and the two most recently activated others.
find "$INSTALL_ROOT/versions" -mindepth 1 -maxdepth 1 -type d ! -name '.stage.*' ! -name "$REV" \
    -printf '%T@ %p\n' | sort -rn | tail -n +3 | cut -d' ' -f2- | while IFS= read -r _old; do
  rm -rf -- "$_old"
done

# An rc file that still sources the zsh file (or calls the launcher) from this checkout
# keeps the live launcher in the working tree: its alias beats the ~/.local/bin link.
# Matched by shape, not by this checkout's path, so $HOME/..., ~/... and symlinked
# spellings are caught too; lines that already go through the install root are fine.
for _rc in "$HOME/.zshrc" "$HOME/.zshrc.local" "$HOME/.zshenv" "$HOME/.zprofile"; do
  [ -f "$_rc" ] || continue
  _old="$(grep -nE '(shell/claude-airlock\.zsh|bin/claude-airlock)' "$_rc" \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    | grep -vF -e "$INSTALL_ROOT/current" -e 'claude-airlock/current/' -e '.local/bin/claude-airlock' || true)"
  if [ -n "$_old" ]; then
    echo "" >&2
    echo "claude-airlock: WARNING: $_rc runs the launcher from somewhere other than the install:" >&2
    printf '%s\n' "$_old" | sed 's/^/    /' >&2
    echo "  Change it to use $INSTALL_ROOT/current (see the source line below), then open a new shell." >&2
  fi
done

echo "==> Verifying the host can actually contain a box (airlock doctor)"
if ! AIRLOCK_ENGINE="$AIRLOCK_ENGINE" AIRLOCK_IMAGE=claude-airlock:base "$SRC_DIR/scripts/airlock-doctor.sh"; then
  echo
  echo "claude-airlock: commit $REV is now live, but it FAILED the containment check." >&2
  echo "  The cause may be the host (see README, Setup, step 1: 'Rootless Podman" >&2
  echo "  prerequisites') or this version (its seccomp profile and image are what ran)." >&2
  if [ -n "$_prev" ] && [ "$_prev" != "versions/$REV" ] && [ -d "$INSTALL_ROOT/$_prev" ] \
      && [ "${_prev#versions/nogit-}" = "$_prev" ]; then
    echo "  To roll back, reinstall the previous commit: git checkout ${_prev#versions/} && make install" >&2
  fi
  exit 1
fi

echo "==> Checking the dev image's tools work offline (image smoke)"
if ! AIRLOCK_ENGINE="$AIRLOCK_ENGINE" AIRLOCK_IMAGE=claude-airlock:dev "$SRC_DIR/scripts/image-smoke.sh"; then
  echo
  echo "claude-airlock: commit $REV is now live, but its dev image FAILED the smoke test above." >&2
  echo "  Boxes still start; a tool listed as FAIL will not work inside them." >&2
  if [ -n "$_prev" ] && [ "$_prev" != "versions/$REV" ] && [ -d "$INSTALL_ROOT/$_prev" ] \
      && [ "${_prev#versions/nogit-}" = "$_prev" ]; then
    echo "  To roll back, reinstall the previous commit: git checkout ${_prev#versions/} && make install" >&2
  fi
  exit 1
fi

# The closing steps, minus the ones already done. Shell integration counts as done when an
# rc file sources the zsh file through the install root (the same lines the rc warning
# above accepts); auth when the launcher would find a token (CLAUDE_CODE_OAUTH_TOKEN in
# this shell, or a token file with something other than whitespace, which the launcher
# strips). grep -q only tests the file; the token is never printed or stored.
_rc_done=""
for _rc in "$HOME/.zshrc" "$HOME/.zshrc.local" "$HOME/.zshenv" "$HOME/.zprofile"; do
  [ -f "$_rc" ] || continue
  if grep -vE '^[[:space:]]*#' "$_rc" | grep -E 'shell/claude-airlock\.zsh' \
      | grep -qF -e "$INSTALL_ROOT/current" -e 'claude-airlock/current/'; then
    _rc_done=1
  fi
done
_token_file="${AIRLOCK_TOKEN_FILE:-$CONFIG_DIR/token}"

echo
if [ -z "$_rc_done" ]; then
  cat <<EOF
==> Almost done. Add this line to your ~/.zshrc (or ~/.zshrc.local), then reload:

    source "$INSTALL_ROOT/current/shell/claude-airlock.zsh"

That gives you:
    airlock   -> Claude Code in the sandbox (use this for a project)
    claude    -> normal host Claude, warns if an airlock session is already open
    (command claude ... always bypasses the guard)

EOF
fi
_token_done=""
{ [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] \
  || { [ -f "$_token_file" ] && grep -q '[^[:space:]]' "$_token_file" 2>/dev/null; }; } && _token_done=1
if [ -z "$_token_done" ]; then
  cat <<EOF
==> One-time auth: generate a long-lived (~1yr) token on the host and save it:

    command claude setup-token          # copy the printed sk-ant-oat... value
    printf %s 'PASTE_TOKEN' > "$_token_file" && chmod 600 "$_token_file"

EOF
fi
if [ -n "$_rc_done" ] && [ -n "$_token_done" ]; then
  echo "==> Done. Shell integration and token are already set up; open a new shell to pick up this version."
  echo
fi
cat <<EOF
Then: cd into any project and run 'airlock'.

Contributing? Install the git hook + test tools:  make hooks && make bootstrap
EOF
