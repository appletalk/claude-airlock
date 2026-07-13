#!/usr/bin/env bats
#
# Session/memory sharing across the host<->box boundary (AIRLOCK_SHARE_HISTORY,
# AIRLOCK_SHARE_MEMORY).
#
# This is the one place the sandbox boundary is deliberately porous, so the mount modes
# are load-bearing and worth pinning:
#
#   * Transcripts MUST be rw. The box records its own session there; a read-only
#     transcript mount means the box cannot hold a session at all.
#   * memory/ is rw BY DEFAULT and that is a known, accepted exposure — the host agent
#     auto-loads these files into context every session, so a compromised box can
#     influence the UNSANDBOXED host without ever touching the network. We take that
#     trade because the box is the primary workspace and read-only memory would make the
#     feature useless. The `ro`/`off` escape hatches must therefore actually work.

load helper

setup() { setup_airlock_env; }

@test "memory defaults to rw (accepted risk: box is the primary workspace)" {
  p="$(mkproj memdefault)"
  _launch "$p" >/dev/null 2>&1 || true
  # No ro memory mount is layered on: memory inherits rw from the parent project mount.
  [[ "$(engine_args)" != *"/memory:ro"* ]]
}

@test "AIRLOCK_SHARE_MEMORY=ro layers a read-only memory mount over the rw project" {
  p="$(mkproj memro)"
  AIRLOCK_SHARE_MEMORY=ro _launch "$p" >/dev/null 2>&1 || true
  # Line-anchored: each -v is its own argv token, and a glob with * would happily match
  # across newlines, silently passing on a mount that isn't the one we mean.
  grep -qE "^${AIRLOCK_HOME}/\.claude/projects/[^:]+/memory:[^:]+/memory:ro$" "$ENGINE_ARGS_FILE"
  # ...and the transcript dir is still rw, or the box could not record a session.
  grep -qE "^${AIRLOCK_HOME}/\.claude/projects/[^:]+:[^:]+:rw$" "$ENGINE_ARGS_FILE"
}

@test "AIRLOCK_SHARE_MEMORY=off shadows memory with container-local storage" {
  p="$(mkproj memoff)"
  AIRLOCK_SHARE_MEMORY=off _launch "$p" >/dev/null 2>&1 || true
  # Memory is served from the per-project state dir...
  grep -qE "^.*/box-memory:[^:]+/memory:rw$" "$ENGINE_ARGS_FILE"
  # ...and the host's real memories are never mounted at all.
  ! grep -qE "^${AIRLOCK_HOME}/\.claude/projects/[^:]+/memory:" "$ENGINE_ARGS_FILE"
}

@test "an invalid AIRLOCK_SHARE_MEMORY is rejected rather than silently ignored" {
  p="$(mkproj membad)"
  AIRLOCK_SHARE_MEMORY=readonly _launch "$p" >/dev/null 2>&1 || true
  # A typo must not fall through to the permissive default.
  [ -z "$(invoked_engine)" ]
}

@test "the transcript dir is always mounted rw when history sharing is on" {
  p="$(mkproj hist)"
  _launch "$p" >/dev/null 2>&1 || true
  [[ "$(engine_args)" == *".claude/projects/"*":rw"* ]]
}

@test "memory modes behave identically under BOTH engines" {
  for e in podman docker; do
    : > "$ENGINE_ARGS_FILE"
    p="$(mkproj "memeng-$e")"
    AIRLOCK_SHARE_MEMORY=ro AIRLOCK_ENGINE_OVERRIDE="$e" _launch "$p" >/dev/null 2>&1 || true
    grep -qE "/memory:[^:]+/memory:ro$" "$ENGINE_ARGS_FILE" || { echo "$e: memory not mounted ro"; false; }
  done
}
