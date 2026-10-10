#!/usr/bin/env bash
#
# Run the bats suite once per engine, every (engine, file) pair as its own bats process,
# up to JOBS at a time. Output is buffered per pair and printed in order, so it reads as a
# serial run would; the exit status is non-zero if any pair failed.
#
# Not `bats --jobs`: that needs GNU parallel on the host, and the tests are already
# isolated per file (each bats run has its own tmpdir, HOME and engine stubs), so a file
# is the natural unit. The longest files start first, since they set the wall time.
#
#   ENGINES  engines to run the suite under (default: podman docker)
#   JOBS     concurrent bats processes (default: nproc)
#   TIMEOUT  seconds one (engine, file) pair may take before it counts as failed
#            (default: 600; 0 disables it). Output is buffered, so a hang would
#            otherwise show nothing.
#   BATS     the bats binary (default: bats on PATH, else .tooling/bin/bats)
#   args     test files (default: test/*.bats)
set -uo pipefail

cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." || exit 1
BATS="${BATS:-$(command -v bats 2>/dev/null || echo .tooling/bin/bats)}"
ENGINES="${ENGINES:-podman docker}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
TIMEOUT="${TIMEOUT:-600}"
command -v "$BATS" >/dev/null 2>&1 || { echo "bats not found — 'make bootstrap' or install it" >&2; exit 1; }
case "$JOBS$TIMEOUT" in *[!0-9]*) echo "run-tests: JOBS and TIMEOUT must be numbers" >&2; exit 1 ;; esac
[[ "$ENGINES" == *[![:space:]]* ]] || { echo "run-tests: ENGINES names no engine" >&2; exit 1; }

files=("$@")
[ ${#files[@]} -gt 0 ] || files=(test/*.bats)

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

# Longest first: test count is a good enough proxy for a file's run time.
mapfile -t ordered < <(for f in "${files[@]}"; do printf '%s %s\n' "$(grep -c '^@test' "$f")" "$f"; done \
  | sort -rn | cut -d' ' -f2-)

# shellcheck disable=SC2016  # expanded by the inner bash, per job
for e in $ENGINES; do
  for f in "${ordered[@]}"; do printf '%s\0%s\0' "$e" "$f"; done
done | xargs -0 -n2 -P "$JOBS" bash -c '
  log="$0/$3.$(basename "$4").tap"           # $0 out dir, $1 bats, $2 timeout, $3 engine, $4 file
  ENGINE="$3" timeout -k 10 "$2" "$1" "$4" >"$log" 2>&1
  echo $? >"$log.rc" 2>/dev/null           # gone already if the run was interrupted
' "$out" "$BATS" "$TIMEOUT"
xrc="${PIPESTATUS[1]}"
# xargs stops launching pairs when one is killed by a signal (an OOM kill, say), so the
# pairs it never ran have no .rc and must fail the run below, as must xargs failing.
rc=0
[ "$xrc" -eq 0 ] || rc=1
for e in $ENGINES; do
  echo "==> bats (ENGINE=$e)"
  tests=0; failed=0
  for f in "${files[@]}"; do
    log="$out/$e.$(basename "$f").tap"
    [ -f "$log.rc" ] || { echo "!! $f did not run"; rc=1; continue; }
    cat "$log"
    tests=$((tests + $(grep -cE '^(not )?ok ' "$log")))
    failed=$((failed + $(grep -cE '^not ok ' "$log")))
    case "$(cat "$log.rc")" in
      0)       ;;
      124)     rc=1; echo "!! $f timed out after ${TIMEOUT}s (output above is as far as it got)" ;;
      137)     rc=1; echo "!! $f was killed (rc=137: a timeout that ignored TERM, or e.g. an OOM kill)" ;;
      *)       rc=1; [ -s "$log" ] || echo "!! $f produced no output" ;;
    esac
  done
  echo "==> ENGINE=$e: $tests tests, $failed failed"
done
exit "$rc"
