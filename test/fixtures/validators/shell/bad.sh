#!/usr/bin/env bash
# SC2086: unquoted expansion. Word-splits on a path containing spaces, which is
# how an "rm the temp dir" line becomes an "rm two unrelated paths" line.
set -euo pipefail
target=$1
rm -rf $target
