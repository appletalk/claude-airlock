#!/usr/bin/env bash
#
# Install the claude-airlock launcher and build the base image.
#   bin/install.sh                     from this checkout: export HEAD, build, go live
#   bin/install.sh --from-bundle DIR   from a bundle another account wrote (make bundle):
#                                      its images are loaded, nothing is built or fetched.
#                                      Run by the bundle's install-bundle.sh, from the
#                                      bundle's own source tree.
set -euo pipefail

FROM_BUNDLE=""
case "${1:-}" in
  --from-bundle) FROM_BUNDLE="${2:?usage: install.sh --from-bundle DIR}"; FROM_BUNDLE="$(cd "$FROM_BUNDLE" && pwd)" ;;
  "") ;;
  *) echo "usage: install.sh [--from-bundle DIR]" >&2; exit 1 ;;
esac

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_TARGET="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/claude-airlock"

# Build with the SAME engine the launcher will run with — images live in the engine's
# own store, so building under Docker and launching under podman would "lose" them.
# Honor an existing config so a re-run doesn't silently switch engines.
# The config the launcher reads: AIRLOCK_CONFIG if set (a config kept elsewhere, say one root
# owns for an agent's account), else the usual one.
CONFIG_FILE="${AIRLOCK_CONFIG:-$CONFIG_DIR/config}"
# A setting as the launcher sees it: the environment, then the config sourced over it (the
# config wins). Sourced, not parsed, so the install and the launcher can't read it differently.
_cfg_get() {  # _cfg_get NAME
  # shellcheck disable=SC1090
  ( set +eu; [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" </dev/null >/dev/null 2>&1; printf '%s' "${!1:-}" ) || true
}
AIRLOCK_ENGINE="$(_cfg_get AIRLOCK_ENGINE)"
AIRLOCK_ENGINE="${AIRLOCK_ENGINE:-podman}"
# The image this account's boxes run: from a bundle, an account on claude-airlock:base loads
# no dev image at all (its layers are a few GB never used).
ACCOUNT_IMAGE="$(_cfg_get AIRLOCK_IMAGE)"
ACCOUNT_IMAGE="${ACCOUNT_IMAGE#localhost/}"

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
# Corporate CA certs for the images (docs/images.md). From the host's own, root-owned
# /etc/claude-airlock/ca/ (deployed with the host's config; AIRLOCK_CA_DIR names another) when it
# exists, else the clone's untracked image/certs/. Every image trusts them, so the host's are
# refused if a link, or not root's, or writable by group or others (a writable one is anyone's
# way into every box's trust), and every file must be CA certificates and nothing else.
# AIRLOCK_CA_REQUIRED=1: no install without at least one. A bundle's images carry their own.
CA_FILES=() CA_INFO=() CA_FROM=""
_ca_die() { echo "claude-airlock: $*; nothing was installed" >&2; exit 1; }
_ca_safe() {  # _ca_safe PATH: root's, no link, no group/other write
  local m
  [ ! -L "$1" ] || _ca_die "$1 is a link"
  m="$(stat -c %u:%a -- "$1" 2>/dev/null)" || _ca_die "cannot stat $1"
  [ "${m%%:*}" = 0 ] || _ca_die "$1 is not root's (every image would trust what its owner puts there)"
  [ $(( 8#${m#*:} & 8#022 )) = 0 ] || _ca_die "$1 is writable by group or others"
}
_ca_check() {  # _ca_check FILE: PEM CA certificates only; their subjects and fingerprints into CA_INFO
  local pem b cur="" line blocks=()
  [ -f "$1" ] || _ca_die "$1 is not a regular file"
  [ "$(stat -c %s -- "$1")" -le 65536 ] || _ca_die "$1 is over 64 KiB: not a CA certificate or two"
  command -v openssl >/dev/null || _ca_die "openssl is needed to check $1"
  pem="$(tr -d '\r' < "$1" | sed '/^[[:blank:]]*$/d')"
  awk '/^-----BEGIN CERTIFICATE-----$/ { if (inb) exit 1; inb = 1; n++; next }
       /^-----END CERTIFICATE-----$/ { if (!inb) exit 1; inb = 0; next }
       inb && /^[A-Za-z0-9+\/=]+$/ { next }
       { exit 1 }
       END { if (inb || n == 0) exit 1 }' <<< "$pem" \
    || _ca_die "$1 is not PEM certificates only (BEGIN/END CERTIFICATE blocks, nothing else, no key)"
  while IFS= read -r line; do
    cur+="$line"$'\n'
    [ "$line" != "-----END CERTIFICATE-----" ] || { blocks+=("$cur"); cur=""; }
  done <<< "$pem"
  for b in "${blocks[@]}"; do
    openssl x509 -noout -ext basicConstraints <<< "$b" 2>/dev/null | grep -q 'CA:TRUE' \
      || _ca_die "$1: a certificate does not parse, or is not a CA (basicConstraints CA:TRUE)"
    CA_INFO+=("$(basename "$1"): $(openssl x509 -noout -subject <<< "$b" | sed 's/^subject=[[:space:]]*//'), $(openssl x509 -noout -fingerprint -sha256 <<< "$b" | sed 's/^.*=//')")
  done
}
if [ -z "$FROM_BUNDLE" ]; then
  _ca_dir="$(_cfg_get AIRLOCK_CA_DIR)"; _ca_dir="${_ca_dir:-/etc/claude-airlock/ca}"
  case "$_ca_dir" in /*) ;; *) _ca_die "AIRLOCK_CA_DIR must be an absolute path ($_ca_dir)" ;; esac
  if [ -e "$_ca_dir" ] || [ -L "$_ca_dir" ]; then
    CA_FROM="$_ca_dir"
    _ca_safe "$_ca_dir"
    [ -d "$_ca_dir" ] || _ca_die "$_ca_dir is not a directory"
    for _c in "$_ca_dir"/*.crt; do
      [ -e "$_c" ] || [ -L "$_c" ] || continue
      _ca_safe "$_c"; _ca_check "$_c"; CA_FILES+=("$_c")
    done
    for _c in "$REPO_DIR"/image/certs/*.crt; do
      [ -e "$_c" ] && { echo "    (the clone's image/certs/ is ignored: the host's $_ca_dir is used)"; break; }
    done
  else
    CA_FROM="$REPO_DIR/image/certs"
    for _c in "$REPO_DIR"/image/certs/*.crt; do
      [ -e "$_c" ] || [ -L "$_c" ] || continue
      [ ! -L "$_c" ] || _ca_die "$_c is a link"
      _ca_check "$_c"; CA_FILES+=("$_c")
    done
  fi
  _ca_req="$(_cfg_get AIRLOCK_CA_REQUIRED)"
  if [ "$_ca_req" = 1 ] && [ "${#CA_FILES[@]}" = 0 ]; then
    _ca_die "AIRLOCK_CA_REQUIRED=1, but there are no CA certs in $CA_FROM"
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
    for _t in base os dev; do "$AIRLOCK_ENGINE" rmi "claude-airlock:$_t-$REV" >/dev/null 2>&1 || true; done
  fi
}
trap _cleanup EXIT
# Stage dirs left by a hard kill (the trap never ran).
find "$INSTALL_ROOT/versions" -mindepth 1 -maxdepth 1 -type d -name '.stage.*' -mmin +60 -exec rm -rf -- {} + 2>/dev/null || true
if [ -n "$FROM_BUNDLE" ]; then
  # The commit the bundle names, and a source tree that is that commit's install.
  REV="$(sed -n 's/^commit \([0-9a-f]\{12\}\)$/\1/p' "$FROM_BUNDLE/MANIFEST" 2>/dev/null | head -1)"
  [ -n "$REV" ] || { echo "claude-airlock: $FROM_BUNDLE/MANIFEST names no commit; nothing was changed." >&2; exit 1; }
  if ! grep -qx "commit $REV" "$REPO_DIR/VERSION" 2>/dev/null; then
    echo "claude-airlock: this source tree is not commit $REV's (the bundle's); nothing was changed." >&2; exit 1
  fi
  BRANCH="$(sed -n 's/^branch //p' "$REPO_DIR/VERSION" | head -1)"
  _export() { tar -C "$REPO_DIR" -cf - . | tar -x -C "$1"; }
elif [ "$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$REPO_DIR" && pwd -P)" ]; then
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
  printf 'commit %s\nbranch %s\ninstalled %s\nfrom %s\n' "$REV" "$BRANCH" "$(date -u +%FT%TZ)" \
    "${FROM_BUNDLE:+bundle }${FROM_BUNDLE:-$REPO_DIR}" > "$_stage/VERSION"
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
# The CA certs checked above, into this version's build context (the export never carries
# any: they are the host's, not the repo's). A bundle's images already hold theirs.
if [ -z "$FROM_BUNDLE" ]; then
  find "$DEST/image/certs" -maxdepth 1 -name '*.crt' -delete
  for _c in "${CA_FILES[@]}"; do install -m 0644 "$_c" "$DEST/image/certs/"; done
  if [ "${#CA_INFO[@]}" -gt 0 ]; then
    echo "    CA certs -> images (from $CA_FROM):"
    printf '      %s\n' "${CA_INFO[@]}"
  else
    echo "    no CA certs in $CA_FROM (AIRLOCK_CA_REQUIRED=1 makes that an error)"
  fi
fi
SRC_DIR="$DEST"

mkdir -p "$BIN_TARGET" "$CONFIG_DIR"

# Box telemetry is always off; the `airlock telemetry on` switch is retired. Clear every
# project's leftover marker now and name the projects, so none keeps telemetry on unseen.
# Their settings are corrected at each project's next launch; a running box keeps
# telemetry until it restarts. Removing a marker is safe even if this install fails later:
# every launcher treats a missing marker as off.
_tel=0
for _m in "$CONFIG_DIR"/state/*/telemetry-on; do
  [ -f "$_m" ] || continue
  rm -f -- "$_m"
  [ "$_tel" -eq 1 ] || echo "==> Telemetry is now always off in boxes. Turned it off for:" >&2
  _tel=1
  echo "    $(basename "$(dirname "$_m")")" >&2
done
[ "$_tel" -eq 0 ] || echo "    (running boxes keep it until they restart)" >&2

if [ -z "${AIRLOCK_CONFIG:-}" ] && [ ! -f "$CONFIG_DIR/config" ]; then
  cp "$SRC_DIR/config/config.example" "$CONFIG_DIR/config"
  echo "    wrote default config -> $CONFIG_DIR/config"
fi

# `airlock paste` needs ONE project (or a shared paste dir) to write clipboard images into:
# see docs/scratch-and-pastes.md. There is no safe default: it is typed from whatever
# terminal is free, so keying it off $PWD would silently write pastes into a directory the
# running box never mounts. An install never stops to ask: if neither the environment nor the
# config names one (an empty line in the config counts as a choice), a note at the end says
# how, and `airlock paste` says it again when it is run. The config check reads plain
# assignments only: a value set some other way gets a needless note, nothing worse.
_paste_note=""
if [ -z "${AIRLOCK_PASTE_PROJECT:-}${AIRLOCK_PASTE_DIR:-}" ] \
    && ! grep -qE '^[[:space:]]*(export[[:space:]]+)?AIRLOCK_PASTE_(PROJECT|DIR)=' "$CONFIG_FILE" 2>/dev/null; then
  _paste_note=1
fi
_print_paste_note() {
  [ -n "$_paste_note" ] || return 0
  echo "==> Note: 'airlock paste' (clipboard images into a box) is not set up. To use it, set"
  # The installing user's to edit: a writable file, or none yet where one can be made (the
  # nearest directory that exists is writable).
  _pd="$(dirname "$CONFIG_FILE")"
  while [ ! -e "$_pd" ] && [ "$_pd" != / ] && [ "$_pd" != . ]; do _pd="$(dirname "$_pd")"; done
  if { [ -f "$CONFIG_FILE" ] && [ -w "$CONFIG_FILE" ]; } \
      || { [ ! -e "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] && [ -d "$_pd" ] && [ -w "$_pd" ]; }; then
    echo "    AIRLOCK_PASTE_PROJECT=\"\$HOME/development/myproject\" (or AIRLOCK_PASTE_DIR) in $CONFIG_FILE."
  else
    echo "    AIRLOCK_PASTE_DIR (a shared drop box) or AIRLOCK_PASTE_PROJECT in $CONFIG_FILE: ask whoever manages it."
  fi
  echo
}

# The os image's layers must be exactly the base image's lowest layers: that is what makes
# dev's OS layers the ones the base (and doctor) has. A pull of the Debian tag by a
# concurrent install, or cache eviction, would quietly break it in a build, and a bundle
# must hold the same relationship.
_layers() { "$AIRLOCK_ENGINE" image inspect --format '{{range .RootFS.Layers}}{{.}} {{end}}' "$1"; }
_check_os_layers() {
  local os base
  os="$(_layers "claude-airlock:os-$REV")"
  base="$(_layers "claude-airlock:base-$REV")"
  if [ -z "$os" ] || [ "${base#"$os"}" = "$base" ]; then
    echo "claude-airlock: the os image for the dev image is not the base image's os stage" >&2
    echo "  (another build moved its inputs in between?). Nothing went live; run make install-airlock again." >&2
    exit 1
  fi
}
_id() { "$AIRLOCK_ENGINE" image inspect --format '{{.Id}}' "$1" 2>/dev/null || true; }

if [ -n "$FROM_BUNDLE" ]; then
  # A bundle: the images were built by whoever wrote it, from this same commit. Load them
  # under this commit's own tags and require exactly the image IDs its manifest names.
  _eng="$(awk '$1 == "engine" { print $2; exit }' "$FROM_BUNDLE/MANIFEST")"
  if [ "$_eng" != "$AIRLOCK_ENGINE" ]; then
    echo "claude-airlock: the bundle's images are ${_eng:-of an unnamed engine}'s and this account uses $AIRLOCK_ENGINE" >&2
    echo "  (their image IDs and names differ); ask for a bundle written with $AIRLOCK_ENGINE. Nothing went live." >&2
    exit 1
  fi
  # base (with its os stage) always; dev only for an account whose boxes run it.
  _types="base os dev" _archives="base dev"
  if [ "$ACCOUNT_IMAGE" = claude-airlock:base ]; then _types="base os" _archives="base"; fi
  for _a in $_archives; do
    _imgs="$FROM_BUNDLE/images-$_a-$REV.tar"
    [ -f "$_imgs" ] || { echo "claude-airlock: the bundle has no images-$_a-$REV.tar; nothing went live." >&2; exit 1; }
    echo "==> Loading the bundle's $_a image ($(du -h "$_imgs" | cut -f1))"
    "$AIRLOCK_ENGINE" load -q -i "$_imgs" >/dev/null
  done
  [ "$_archives" = base ] && echo "    (this account runs claude-airlock:base: the dev image is not loaded)"
  for _t in $_types; do
    _want="$(awk -v t="$_t" '$1 == "image" && $2 == t { print $3 }' "$FROM_BUNDLE/MANIFEST")"
    _have="$(_id "claude-airlock:$_t-$REV")"
    if [ -z "$_want" ] || [ "$_have" != "$_want" ]; then
      echo "claude-airlock: the bundle's $_t image is ${_have:-missing}, not the ${_want:-unnamed} its manifest names; nothing went live." >&2
      exit 1
    fi
  done
  _check_os_layers
else
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
  # engines and turns an offline `make install-airlock` (a launcher update, every layer cached)
  # into a hard failure; here it degrades to a warning, like the version lookup above.
  # APT_REFRESH is the cache key of the base apt layer (see image/Dockerfile): the current
  # ISO week, so the base is rebuilt at most weekly and `make install-airlock` is a cache hit the
  # rest of the week. Everything above the apt layer rebuilds with it, which is why the
  # default is a week and not a day.
  #
  # `make refresh` forces a rebuild now by passing "<week>.<timestamp>". The key that was
  # used is remembered in the config dir, and a later `make install-airlock` in the SAME week reuses
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
  _check_os_layers
  echo "==> Building dev image (claude-airlock:dev) — Python, Node 24, build tools"
  echo "    (a package refresh rebuilds it; a new Claude Code version only replaces its last layer)"
  "$AIRLOCK_ENGINE" build --build-arg "BASE_IMAGE=claude-airlock:base-$REV" \
    --build-arg "OS_IMAGE=claude-airlock:os-$REV" \
    -t "claude-airlock:dev-$REV" "$SRC_DIR/image/dev"
  echo "==> (optional) Playwright stack for browser E2E (~3GB) — build if you need it:"
  echo "      $AIRLOCK_ENGINE build -t claude-airlock:playwright \"$SRC_DIR/image/playwright\""
fi

# Which images this version is (a bundle carries the list): from a bundle, exactly the ones
# just loaded and checked (a dev-$REV tag left by a killed earlier install is not one of
# them); from a build, the ones built.
if [ -n "$FROM_BUNDLE" ]; then
  _have_types="$_types"
else
  _have_types="base os dev"
  [ -n "$(_id "claude-airlock:dev-$REV")" ] || _have_types="base os"
fi
for _t in $_have_types; do printf '%s %s\n' "$_t" "$(_id "claude-airlock:$_t-$REV")"; done > "$DEST/IMAGES"

# Both images built: make this version live. The image tags and `current` move together;
# `current` flips in one rename (a unique temp name, so concurrent installs cannot trip over
# each other), and the launcher link and every shell follow it. Touching DEST records
# activation time, which the prune orders by.
"$AIRLOCK_ENGINE" tag "claude-airlock:base-$REV" claude-airlock:base
"$AIRLOCK_ENGINE" tag "claude-airlock:os-$REV" claude-airlock:os
if [ "$_have_types" = "base os dev" ]; then
  "$AIRLOCK_ENGINE" tag "claude-airlock:dev-$REV" claude-airlock:dev
else
  # No dev for this account: let go of an older one, so the prune below can take its layers.
  "$AIRLOCK_ENGINE" rmi claude-airlock:dev >/dev/null 2>&1 || true
  if [ -n "$(_id claude-airlock:dev)" ]; then
    echo "claude-airlock: warning: an older claude-airlock:dev is still here (a running box holds it?);" >&2
    echo "  a launch on dev would run it. Remove it once no box uses it: $AIRLOCK_ENGINE rmi claude-airlock:dev" >&2
  fi
fi
# One at a time: an engine may stop at a name it does not have (no dev on a base-only account).
for _t in base os dev; do "$AIRLOCK_ENGINE" rmi "claude-airlock:$_t-$REV" >/dev/null 2>&1 || true; done
[ -n "$FROM_BUNDLE" ] || printf '%s\n' "$APT_REFRESH" > "$REFRESH_STAMP"
touch "$DEST"
_cur_tmp="$INSTALL_ROOT/.current.$$"
ln -sfn "versions/$REV" "$_cur_tmp"
mv -Tf "$_cur_tmp" "$INSTALL_ROOT/current"
_live=1
echo "==> Live: $INSTALL_ROOT/current -> versions/$REV"
# The command is `airlock`, on PATH for scripts and units too, not only for an interactive
# shell's alias; `claude-airlock` stays as a second name so nothing that calls it breaks.
echo "==> Installing launcher -> $BIN_TARGET/airlock (and $BIN_TARGET/claude-airlock)"
ln -sfn "$INSTALL_ROOT/current/bin/claude-airlock" "$BIN_TARGET/airlock"
ln -sfn "$INSTALL_ROOT/current/bin/claude-airlock" "$BIN_TARGET/claude-airlock"
# Host Claude's status line runs this copy (docs/install.md: Statusline), never the checkout's: a branch
# or an uncommitted edit there would otherwise run on the host at every refresh. A box can't
# write it (boxes get their own .claude). Replaced in one rename, so a refresh never reads half.
_sl="$HOME/.claude/airlock-statusline.sh"
mkdir -p "$HOME/.claude"
if cp "$INSTALL_ROOT/current/config/airlock-statusline.sh" "$_sl.tmp.$$" && chmod 0644 "$_sl.tmp.$$" \
   && mv -f "$_sl.tmp.$$" "$_sl"; then
  echo "==> Status line -> $_sl"
  if grep -q 'airlock-statusline\.sh' "$HOME/.claude/settings.json" 2>/dev/null \
     && ! grep -q '\.claude/airlock-statusline\.sh' "$HOME/.claude/settings.json"; then
    echo "    NOTE: ~/.claude/settings.json runs another copy of the status line; point it at $_sl (docs/install.md: Statusline)" >&2
  fi
else
  rm -f "$_sl.tmp.$$"
  echo "    WARNING: could not install the status line to $_sl" >&2
fi
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
    | grep -vF -e "$INSTALL_ROOT/current" -e 'claude-airlock/current/' -e '.local/bin/claude-airlock' -e '.local/bin/airlock' || true)"
  if [ -n "$_old" ]; then
    echo "" >&2
    echo "claude-airlock: WARNING: $_rc runs the launcher from somewhere other than the install:" >&2
    printf '%s\n' "$_old" | sed 's/^/    /' >&2
    echo "  Change it to use $INSTALL_ROOT/current (see the source line below), then open a new shell." >&2
  fi
done

_rollback_hint() {
  if [ -n "$FROM_BUNDLE" ]; then
    echo "  To roll back, ask for a bundle of the previous commit (${_prev#versions/}); its images are" >&2
    echo "  kept until an install passes these checks, so loading it again is quick." >&2
  else
    echo "  To roll back, reinstall the previous commit: git checkout ${_prev#versions/} && make install-airlock" >&2
  fi
}
echo "==> Verifying the host can actually contain a box (airlock doctor)"
if ! AIRLOCK_ENGINE="$AIRLOCK_ENGINE" AIRLOCK_IMAGE=claude-airlock:base "$SRC_DIR/scripts/airlock-doctor.sh"; then
  echo
  echo "claude-airlock: commit $REV is now live, but it FAILED the containment check." >&2
  echo "  The cause may be the host (see README, Setup, step 1: 'Rootless Podman" >&2
  echo "  prerequisites') or this version (its seccomp profile and image are what ran)." >&2
  if [ -n "$_prev" ] && [ "$_prev" != "versions/$REV" ] && [ -d "$INSTALL_ROOT/$_prev" ] \
      && [ "${_prev#versions/nogit-}" = "$_prev" ]; then
    _rollback_hint
  fi
  exit 1
fi

if [ "$_have_types" != "base os dev" ]; then
  echo "==> No dev image on this account: image smoke (the dev tools) skipped"
elif echo "==> Checking the dev image's tools work offline (image smoke)"
  ! AIRLOCK_ENGINE="$AIRLOCK_ENGINE" AIRLOCK_IMAGE=claude-airlock:dev "$SRC_DIR/scripts/image-smoke.sh"; then
  echo
  echo "claude-airlock: commit $REV is now live, but its dev image FAILED the smoke test above." >&2
  echo "  Boxes still start; a tool listed as FAIL will not work inside them." >&2
  if [ -n "$_prev" ] && [ "$_prev" != "versions/$REV" ] && [ -d "$INSTALL_ROOT/$_prev" ] \
      && [ "${_prev#versions/nogit-}" = "$_prev" ]; then
    _rollback_hint
  fi
  exit 1
fi

# Images no tag points to any more: what each install's re-tag leaves behind (about 4 GB a
# rebuild, and the weekly package refresh rebuilds everything), with the layer chain only they
# used. Removed only now, with this version live and through both checks (until then they
# are a way back; a failed install leaves them for the next one to collect). Only dangling
# images carrying claude-airlock's label (image/Dockerfile, os stage, inherited by every
# image) go: other projects' images stay, dangling or not, and the unlabelled parents (an
# older Debian base) only once nothing else uses them. The layers under the live tags are not
# dangling, so they stay and an unchanged rebuild still hits them. One a running box uses
# stays until the next install. A failure here warns; the install has already succeeded.
_img_count() { "$AIRLOCK_ENGINE" images -a -q 2>/dev/null | wc -l; }
_img_bytes() {  # podman only (docker's df gives no raw bytes)
  [ "$AIRLOCK_ENGINE" = podman ] || return 0
  podman system df --format json 2>/dev/null | tr -d ' \n' | sed -n 's/.*"Type":"Images"[^}]*"RawSize":\([0-9][0-9]*\).*/\1/p'
}
# The prune stops with an error at an image a container uses (a box on :os, the parent of the
# others), after removing what it could: what it freed is counted either way.
_n0="$(_img_count)" _b0="$(_img_bytes)" _prc=0
"$AIRLOCK_ENGINE" image prune -f --filter label=org.claude-airlock.apt-refresh >/dev/null 2>&1 || _prc=$?
_n1="$(_img_count)" _b1="$(_img_bytes)"
if [ "$_n0" -gt "$_n1" ]; then
  _sz=""
  if [ -n "$_b0" ] && [ -n "$_b1" ] && [ "$_b0" -gt "$_b1" ]; then
    _sz="$(numfmt --to=si --suffix=B "$((_b0 - _b1))" 2>/dev/null || echo "$((_b0 - _b1)) bytes"), "
  fi
  _note=""
  [ "$_prc" = 0 ] || _note="; some are in use by a box, the next install takes them"
  echo "==> Pruned superseded claude-airlock images: $_sz$((_n0 - _n1)) images and layers$_note"
elif [ "$_prc" != 0 ]; then
  echo "    WARNING: could not prune superseded claude-airlock images ($AIRLOCK_ENGINE image prune); the next install tries again" >&2
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

# From a bundle: an account that may have no shell of its own to integrate, and no host Claude
# to mint a token with (no network). It logs in from a box instead.
if [ -n "$FROM_BUNDLE" ]; then
  echo
  echo "==> Done (from a bundle). Shell integration and the Claude login are this account's own: with no"
  echo "    network of its own, set AIRLOCK_PERSIST_LOGIN=1 and /login inside a box"
  echo "    (docs/dedicated-user.md)."
  echo
  _print_paste_note
  exit 0
fi
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
_print_paste_note
cat <<EOF
Then: cd into any project and run 'airlock'.

Contributing? Install the git hook + test tools:  make hooks && make bootstrap
EOF
