#!/usr/bin/env bats
#
# Container-engine selection (AIRLOCK_ENGINE) and the podman-specific run args.
#
# These assertions exist because the two engines are NOT interchangeable, and the
# differences are silent-but-fatal rather than loud:
#
#   * Rootless podman without --userns=keep-id maps the host user to container ROOT and
#     `dev` to a subuid — every bind-mounted file appears root-owned and the agent cannot
#     write its own workspace. The container still starts, so nothing fails loudly.
#   * Passing --userns=keep-id to Docker is an error, so the flag cannot simply be
#     unconditional.
#
# Whichever engine the author stops using is the one that rots. CI runs the whole suite
# under both (ENGINE=podman|docker); these tests pin the differences explicitly.

load helper

setup() { setup_airlock_env; }

@test "engine defaults to podman when AIRLOCK_ENGINE is unset" {
  p="$(mkproj engdefault)"
  _launch_default_engine "$p" >/dev/null 2>&1 || true
  [ "$(invoked_engine)" = "podman" ]
}

@test "AIRLOCK_ENGINE=docker invokes docker, not podman" {
  p="$(mkproj engdocker)"
  AIRLOCK_ENGINE_OVERRIDE=docker _launch "$p" >/dev/null 2>&1 || true
  [ "$(invoked_engine)" = "docker" ]
}

@test "podman gets --userns=keep-id pinned to uid/gid 1000 (the image's dev user)" {
  p="$(mkproj engkeepid)"
  AIRLOCK_ENGINE_OVERRIDE=podman _launch "$p" >/dev/null 2>&1 || true
  [[ "$(engine_args)" == *"--userns=keep-id:uid=1000,gid=1000"* ]]
}

@test "docker does NOT get --userns=keep-id (it would be an error)" {
  p="$(mkproj engnokeepid)"
  AIRLOCK_ENGINE_OVERRIDE=docker _launch "$p" >/dev/null 2>&1 || true
  [[ "$(engine_args)" != *"keep-id"* ]]
}

@test "podman gets an explicit --network (default pasta)" {
  p="$(mkproj engnet)"
  AIRLOCK_ENGINE_OVERRIDE=podman _launch "$p" >/dev/null 2>&1 || true
  [[ "$(engine_args)" == *"--network=pasta"* ]]
}

@test "AIRLOCK_PODMAN_NETWORK overrides the podman network stack" {
  p="$(mkproj engnetov)"
  AIRLOCK_PODMAN_NETWORK=slirp4netns AIRLOCK_ENGINE_OVERRIDE=podman _launch "$p" >/dev/null 2>&1 || true
  [[ "$(engine_args)" == *"--network=slirp4netns"* ]]
}

@test "docker gets no --network flag (it uses its own default bridge)" {
  p="$(mkproj engnonet)"
  AIRLOCK_ENGINE_OVERRIDE=docker _launch "$p" >/dev/null 2>&1 || true
  [[ "$(engine_args)" != *"--network="* ]]
}

@test "an unknown engine is rejected and nothing is launched" {
  p="$(mkproj engbad)"
  run env AIRLOCK_ENGINE_OVERRIDE=containerd bash -c '_launch() { :; }; true'
  AIRLOCK_ENGINE_OVERRIDE=containerd _launch "$p" >/dev/null 2>&1 || true
  # No engine should have been invoked at all.
  [ -z "$(invoked_engine)" ]
}

@test "the hardening flags are identical under BOTH engines" {
  # The capability posture is the core of the sandbox; it must not silently differ.
  for e in podman docker; do
    : > "$ENGINE_ARGS_FILE"
    p="$(mkproj "enghard-$e")"
    AIRLOCK_ENGINE_OVERRIDE="$e" _launch "$p" >/dev/null 2>&1 || true
    args="$(engine_args)"
    [[ "$args" == *"--cap-drop=ALL"* ]]                    || { echo "$e: missing cap-drop=ALL"; false; }
    [[ "$args" == *"--cap-add=NET_ADMIN"* ]]               || { echo "$e: missing NET_ADMIN"; false; }
    [[ "$args" == *"--cap-add=NET_RAW"* ]]                 || { echo "$e: missing NET_RAW"; false; }
    [[ "$args" == *"--security-opt=no-new-privileges"* ]]  || { echo "$e: missing no-new-privileges"; false; }
    # Capabilities the box must NEVER get, under either engine.
    [[ "$args" != *"SYS_ADMIN"* ]]                         || { echo "$e: SYS_ADMIN granted"; false; }
    [[ "$args" != *"--privileged"* ]]                      || { echo "$e: --privileged set"; false; }
  done
}

@test "the egress posture is passed to the box under BOTH engines" {
  # The firewall reads AIRLOCK_EGRESS_GROUPS; if it never arrives, the box silently
  # falls back to core-only — safe, but it would mask a broken host->box handoff.
  for e in podman docker; do
    : > "$ENGINE_ARGS_FILE"
    p="$(mkproj "engegr-$e")"
    AIRLOCK_ENGINE_OVERRIDE="$e" _launch "$p" >/dev/null 2>&1 || true
    [[ "$(engine_args)" == *"AIRLOCK_EGRESS_GROUPS="* ]] || { echo "$e: no egress groups passed"; false; }
  done
}
