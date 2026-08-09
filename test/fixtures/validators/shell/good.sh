#!/usr/bin/env bash
# A clean script: quoted expansions, no unused vars.
set -euo pipefail
target="${1:-/tmp}"
printf 'listing %s\n' "$target"
ls -1 -- "$target"
