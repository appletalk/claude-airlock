#!/usr/bin/env bash
#
# Write the installed version of claude-airlock (launcher and images) to DIR as a bundle,
# for another account on this host, or an offline host, to install without building or
# fetching anything:
#   bin/bundle.sh DIR           (make bundle DIR=...)   write it, replacing an earlier one
#   bin/bundle.sh --clean DIR   (make bundle-clean DIR=...)  remove it once every reader
#                               has installed it: a bundle is a handoff, not an archive
# The reader runs DIR/install-bundle.sh. DIR is whatever both accounts can reach: written
# by you, readable by the reader (its directory setgid with the reader's group, say).
# Files are written 0640, and the manifest last, so a reader never takes a half-written one.
set -euo pipefail
umask 027

clean=0
[ "${1:-}" = --clean ] && { clean=1; shift; }
DIR="${1:?usage: bundle.sh [--clean] DIR}"
[ -d "$DIR" ] || { echo "claude-airlock: $DIR is not a directory" >&2; exit 1; }
DIR="$(cd "$DIR" && pwd)"

# Only names this script writes; anything else in DIR is left alone.
_drop() {
  rm -f -- "$DIR/MANIFEST"                       # first: from here on no reader starts on it
  rm -f -- "$DIR"/claude-airlock-*.tar "$DIR"/images-*.tar "$DIR/install-bundle.sh" "$DIR"/*.part
}
if [ "$clean" = 1 ]; then _drop; echo "==> Removed the bundle in $DIR"; exit 0; fi
[ -w "$DIR" ] || { echo "claude-airlock: $DIR is not writable by you" >&2; exit 1; }

# The engine as the launcher sees it: the environment, then the config sourced over it.
CONFIG_FILE="${AIRLOCK_CONFIG:-$HOME/.config/claude-airlock/config}"
# shellcheck disable=SC1090
AIRLOCK_ENGINE="$( (set +eu; [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" </dev/null >/dev/null 2>&1; printf '%s' "${AIRLOCK_ENGINE:-}") || true)"
AIRLOCK_ENGINE="${AIRLOCK_ENGINE:-podman}"
case "$AIRLOCK_ENGINE" in podman|docker) ;; *) echo "claude-airlock: AIRLOCK_ENGINE must be podman or docker" >&2; exit 1 ;; esac

# The live install, and the images it went live with: the tags must still be those. Under the
# install lock, held to the end: an install (make refresh, say) builds under the same
# per-commit tags this borrows for the save, and must not move the live tags in between.
INSTALL_ROOT="${AIRLOCK_INSTALL_ROOT:-$HOME/.local/share/claude-airlock}"
[ -d "$INSTALL_ROOT" ] || { echo "claude-airlock: nothing installed (make install-airlock first)" >&2; exit 1; }
exec 9>"$INSTALL_ROOT/.lock"
if ! flock -n 9; then
  echo "==> An install is running; waiting up to 10 minutes for it to finish"
  flock -w 600 9 || { echo "claude-airlock: $INSTALL_ROOT/.lock is still held; see fuser -v $INSTALL_ROOT/.lock" >&2; exit 1; }
fi
cur="$(readlink "$INSTALL_ROOT/current" 2>/dev/null)" || { echo "claude-airlock: nothing installed (make install-airlock first)" >&2; exit 1; }
VER="$INSTALL_ROOT/$cur"
REV="$(sed -n 's/^commit \([0-9a-f]\{12\}\)$/\1/p' "$VER/VERSION" 2>/dev/null | head -1)"
[ -n "$REV" ] || { echo "claude-airlock: the live install ($cur) is not a git commit's; bundles carry commits only" >&2; exit 1; }
[ -f "$VER/IMAGES" ] || { echo "claude-airlock: $cur has no image record (installed before bundles existed): make install-airlock again" >&2; exit 1; }
_id() { "$AIRLOCK_ENGINE" image inspect --format '{{.Id}}' "$1" 2>/dev/null || true; }
for t in base os dev; do
  want="$(awk -v t="$t" '$1 == t { print $2 }' "$VER/IMAGES")"
  have="$(_id "claude-airlock:$t")"
  if [ -z "$want" ] || [ "$have" != "$want" ]; then
    echo "claude-airlock: claude-airlock:$t is ${have:-missing}, not the ${want:-unrecorded} image $REV went live with: make install-airlock again" >&2
    exit 1
  fi
done

_drop
trap 'rm -f -- "$DIR"/*.part; for t in base os dev; do "$AIRLOCK_ENGINE" rmi "claude-airlock:$t-$REV" >/dev/null 2>&1 || true; done' EXIT
echo "==> Bundling commit $REV into $DIR"
tar -C "$VER" -cf "$DIR/claude-airlock-$REV.tar.part" .
# Saved under this commit's own tags (added just for the save), so loading one moves no
# reader's live tags before its install has checked them. Two archives: base with its os
# stage, which every reader loads, and dev, which a reader loads only if its account runs dev
# (an account on :base never writes the dev image's layers).
for t in base os dev; do "$AIRLOCK_ENGINE" tag "claude-airlock:$t" "claude-airlock:$t-$REV"; done
_save() {  # _save <archive> <tag...>
  local out="$1"; shift
  if [ "$AIRLOCK_ENGINE" = podman ]; then podman save -q -m --format docker-archive -o "$out" "$@"
  else docker save -o "$out" "$@"; fi
}
_save "$DIR/images-base-$REV.tar.part" "claude-airlock:base-$REV" "claude-airlock:os-$REV"
_save "$DIR/images-dev-$REV.tar.part" "claude-airlock:dev-$REV"
cp "$VER/bin/install-bundle.sh" "$DIR/install-bundle.sh.part"
chmod 0640 "$DIR"/*.part
FILES=("claude-airlock-$REV.tar" "images-base-$REV.tar" "images-dev-$REV.tar" install-bundle.sh)
for f in "${FILES[@]}"; do mv -f "$DIR/$f.part" "$DIR/$f"; done
{
  echo "format 2"
  echo "commit $REV"
  echo "engine $AIRLOCK_ENGINE"
  for t in base os dev; do echo "image $t $(awk -v t="$t" '$1 == t { print $2 }' "$VER/IMAGES")"; done
  for f in "${FILES[@]}"; do
    echo "sha256 $(sha256sum "$DIR/$f" | cut -d' ' -f1) $f"
  done
} > "$DIR/MANIFEST.part"
mv -f "$DIR/MANIFEST.part" "$DIR/MANIFEST"
echo "==> Bundle ready: $(du -ch "$DIR/claude-airlock-$REV.tar" "$DIR"/images-*-"$REV".tar | tail -1 | cut -f1) in $DIR"
echo "    The other account: bash $DIR/install-bundle.sh"
echo "    Then remove it:    make bundle-clean DIR=$DIR   (or bin/bundle.sh --clean $DIR)"
