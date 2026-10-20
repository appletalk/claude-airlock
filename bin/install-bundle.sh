#!/usr/bin/env bash
#
# Install claude-airlock from a bundle (bin/bundle.sh wrote it): check every file against
# the manifest, unpack the bundle's own source tree, and run its installer, which loads the
# images and goes live without building or fetching anything.
#   bash DIR/install-bundle.sh      (or bin/install-bundle.sh DIR, or make install-bundle DIR=...)
# Runs as the account that will use the boxes; the bundle stays where it is (its writer
# removes it).
set -euo pipefail

DIR="${1:-$(dirname "${BASH_SOURCE[0]}")}"
DIR="$(cd "$DIR" && pwd)"
M="$DIR/MANIFEST"
[ -f "$M" ] || { echo "claude-airlock: no bundle in $DIR (no MANIFEST; still being written?)" >&2; exit 1; }
grep -qx 'format 1' "$M" || { echo "claude-airlock: $M is not a bundle this version reads" >&2; exit 1; }
REV="$(sed -n 's/^commit \([0-9a-f]\{12\}\)$/\1/p' "$M" | head -1)"
[ -n "$REV" ] || { echo "claude-airlock: $M names no commit" >&2; exit 1; }

# Exactly the three files, each matching. A name is only ever one of these: nothing in the
# manifest can point outside DIR.
for f in "claude-airlock-$REV.tar" "images-$REV.tar" install-bundle.sh; do
  want="$(awk -v f="$f" '$1 == "sha256" && $3 == f { print $2 }' "$M")"
  [ -n "$want" ] || { echo "claude-airlock: $M has no checksum for $f" >&2; exit 1; }
  have="$(sha256sum "$DIR/$f" 2>/dev/null | cut -d' ' -f1)"
  [ "$have" = "$want" ] || { echo "claude-airlock: $DIR/$f does not match the manifest (changed, or partly written); nothing was installed" >&2; exit 1; }
done

src="$(mktemp -d "${TMPDIR:-/tmp}/claude-airlock-bundle.XXXXXX")"
trap 'rm -rf -- "$src"' EXIT
tar -C "$src" --no-same-owner -xf "$DIR/claude-airlock-$REV.tar"
[ -x "$src/bin/install.sh" ] || { echo "claude-airlock: the bundle's source has no bin/install.sh" >&2; exit 1; }
echo "==> Installing commit $REV from the bundle in $DIR"
bash "$src/bin/install.sh" --from-bundle "$DIR"
