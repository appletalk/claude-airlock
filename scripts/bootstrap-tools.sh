#!/usr/bin/env bash
#
# Vendor shellcheck + bats into .tooling/ so the lint/test suite runs without a
# system install or sudo. Idempotent; safe to re-run. Prefer your package manager
# (pacman -S shellcheck bats / apt install shellcheck bats) when you can — this is
# the portable fallback for machines where that's not an option.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLDIR="$REPO/.tooling"
BIN="$TOOLDIR/bin"
mkdir -p "$BIN"

SC_VER="0.11.0"
BATS_VER="v1.13.0"
arch="$(uname -m)"

if [ ! -x "$BIN/shellcheck" ]; then
  case "$arch" in
    x86_64|amd64)  sc_arch="linux.x86_64" ;;
    aarch64|arm64) sc_arch="linux.aarch64" ;;
    *)             sc_arch="" ;;
  esac
  if [ -z "$sc_arch" ]; then
    echo "bootstrap: no prebuilt shellcheck for arch '$arch' — install it via your package manager" >&2
  else
    url="https://github.com/koalaman/shellcheck/releases/download/v${SC_VER}/shellcheck-v${SC_VER}.${sc_arch}.tar.xz"
    echo "==> fetching shellcheck $SC_VER ($sc_arch)"
    tmp="$(mktemp -d)"
    curl -fsSL "$url" | tar -xJ -C "$tmp"
    install -m 0755 "$tmp/shellcheck-v${SC_VER}/shellcheck" "$BIN/shellcheck"
    rm -rf "$tmp"
  fi
fi

if [ ! -x "$BIN/bats" ]; then
  echo "==> cloning bats-core $BATS_VER"
  rm -rf "$TOOLDIR/bats-core"
  git clone --depth 1 --branch "$BATS_VER" \
    https://github.com/bats-core/bats-core.git "$TOOLDIR/bats-core"
  ln -sf ../bats-core/bin/bats "$BIN/bats"
fi

echo "==> tools ready under $BIN"
[ -x "$BIN/shellcheck" ] && "$BIN/shellcheck" --version | sed -n '2p'
[ -x "$BIN/bats" ] && "$BIN/bats" --version
echo "Make finds these automatically; or add $BIN to PATH."
