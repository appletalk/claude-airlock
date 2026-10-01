#!/usr/bin/env bash
#
# Vendor shellcheck + bats into .tooling/ so the lint/test suite runs without a
# system install or sudo. Idempotent; safe to re-run. This is what CI runs, and the
# CI passes them to make explicitly, because lint results depend on the linter's
# version and distro packages differ (Debian, Ubuntu and Arch all ship different
# ones). The versions here match the ones pinned in image/dev/Dockerfile
# (test/install.bats enforces it), so the host, CI and a box all run the same tools.
#
# Both are verified, not trusted on TLS alone: shellcheck against a pinned sha256 of the
# release tarball, bats against the commit id its release tag pointed at when pinned (a
# moved tag fails the check). Every run re-verifies: an existing shellcheck is re-hashed
# (sha256sum only reads it) and replaced on mismatch, and bats is ALWAYS re-cloned - an
# existing checkout is never inspected, because running git in a directory a box could
# have written means running that directory's config (core.fsmonitor and friends) on the
# host, and git can be told to hide changes (skip-worktree). A failed fetch leaves no
# tool in place, and the tools are never executed here.
#
# This protects against what a box LEFT in .tooling/, not against a box running at the
# same time: one watching the mount could still swap a file between a check and its use.
# Run it with no box open on this checkout (see SECURITY.md on host tooling in a repo a
# box has touched).
#
# The Makefile still prefers a system install over these: .tooling/ is inside the
# project dir a box mounts read-write. Re-running this script re-verifies them.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLDIR="$REPO/.tooling"
BIN="$TOOLDIR/bin"
# Everything below deletes and writes under these paths; a symlink planted in their place
# would aim that at somewhere outside the repo.
for _d in "$TOOLDIR" "$BIN"; do
  if [ -L "$_d" ]; then
    echo "bootstrap: $_d is a symlink — refusing to write through it; remove it and re-run" >&2
    exit 1
  fi
done
mkdir -p "$BIN"

SC_VER="0.11.0"
SC_SHA_X86_64="8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198"
SC_SHA_AARCH64="12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588"
# sha256 of the shellcheck binary inside each tarball, to re-verify an existing copy.
SC_BIN_SHA_X86_64="4da528ddb3a4d1b7b24a59d4e16eb2f5fd960f4bd9a3708a15baddbdf1d5a55b"
SC_BIN_SHA_AARCH64="127f13925eadd52c341bca0ebaf9ab0dbd78c6468f30a8f262a528bf8de47546"
BATS_VER="1.14.0"
BATS_COMMIT="eb7f42f8d608ac693d7a4b67474f6714ea68cfc5"
arch="$(uname -m)"
tmp=""
trap '[ -n "$tmp" ] && rm -rf -- "$tmp"' EXIT

case "$arch" in
  x86_64|amd64)  sc_arch="linux.x86_64";  sc_sha="$SC_SHA_X86_64";  sc_bin_sha="$SC_BIN_SHA_X86_64" ;;
  aarch64|arm64) sc_arch="linux.aarch64"; sc_sha="$SC_SHA_AARCH64"; sc_bin_sha="$SC_BIN_SHA_AARCH64" ;;
  *)             sc_arch="" ;;
esac

if [ -z "$sc_arch" ]; then
  echo "bootstrap: no prebuilt shellcheck for arch '$arch' — install it via your package manager" >&2
elif ! { [ -f "$BIN/shellcheck" ] && echo "$sc_bin_sha  $BIN/shellcheck" | sha256sum -c - >/dev/null 2>&1; }; then
  rm -f "$BIN/shellcheck"
  url="https://github.com/koalaman/shellcheck/releases/download/v${SC_VER}/shellcheck-v${SC_VER}.${sc_arch}.tar.xz"
  echo "==> fetching shellcheck $SC_VER ($sc_arch)"
  tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmp/sc.tar.xz"
  if ! echo "$sc_sha  $tmp/sc.tar.xz" | sha256sum -c - >/dev/null 2>&1; then
    echo "bootstrap: shellcheck $SC_VER tarball does not match its pinned sha256" >&2
    exit 1
  fi
  tar -xJf "$tmp/sc.tar.xz" -C "$tmp"
  if ! echo "$sc_bin_sha  $tmp/shellcheck-v${SC_VER}/shellcheck" | sha256sum -c - >/dev/null 2>&1; then
    echo "bootstrap: shellcheck $SC_VER binary does not match its pinned sha256" >&2
    exit 1
  fi
  install -m 0755 "$tmp/shellcheck-v${SC_VER}/shellcheck" "$BIN/shellcheck"
  rm -rf "$tmp"
fi

echo "==> cloning bats-core v$BATS_VER"
rm -rf "$TOOLDIR/bats-core" "$BIN/bats"
# The tag is annotated; git notes that on a shallow clone ("... is not a commit!").
git -c advice.detachedHead=false clone -q --depth 1 --branch "v$BATS_VER" \
  https://github.com/bats-core/bats-core.git "$TOOLDIR/bats-core"
if [ "$(git -C "$TOOLDIR/bats-core" rev-parse HEAD)" != "$BATS_COMMIT" ]; then
  echo "bootstrap: bats-core tag v$BATS_VER no longer points at $BATS_COMMIT — refusing it" >&2
  rm -rf "$TOOLDIR/bats-core"
  exit 1
fi
ln -sf ../bats-core/bin/bats "$BIN/bats"

# The pinned versions, not `<tool> --version`: executing what is in .tooling/ is what this
# script exists to make safe, and it is never safer than right after the checks.
echo "==> tools ready under $BIN: shellcheck $SC_VER, bats $BATS_VER"
echo "Make uses these when no system shellcheck/bats is installed. Do not put $BIN on your PATH: boxes can write there."
