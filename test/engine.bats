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

# pasta's host mapping (169.254.1.2 -> any host service on 0.0.0.0) is switched off in
# pasta itself, so the in-box firewall is not the only thing standing between the box and
# the host. The DNS forwarder must survive that: it is a separate pasta option.
@test "podman gets an explicit --network (default pasta) with the host mapping removed" {
  p="$(mkproj engnet)"
  AIRLOCK_ENGINE_OVERRIDE=podman _launch "$p" >/dev/null 2>&1 || true
  engine_args | grep -qx -- '--network=pasta:--map-guest-addr,none'
  engine_args | grep -qx -- '--dns=169.254.1.1'
}

@test "pasta with operator options keeps them and still removes the host mapping" {
  p="$(mkproj engnetopt)"
  AIRLOCK_PODMAN_NETWORK='pasta:--mtu,1400' AIRLOCK_ENGINE_OVERRIDE=podman _launch "$p" >/dev/null 2>&1 || true
  engine_args | grep -qx -- '--network=pasta:--mtu,1400,--map-guest-addr,none'
  engine_args | grep -qx -- '--dns=169.254.1.1'
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

# DNS. With a loopback-only host resolver, both engines append Google Public DNS to the
# box's resolv.conf; these pin the two layers that stop the box using it (lib/host-dns.sh).

@test "podman+pasta points the box at pasta's forwarder to the host resolver" {
  p="$(mkproj engdnspasta)"
  AIRLOCK_ENGINE_OVERRIDE=podman _launch "$p" >/dev/null 2>&1 || true
  [ "$(engine_args | grep -c '^--dns=')" -eq 1 ]
  engine_args | grep -qx -- '--dns=169.254.1.1'
}

@test "podman+slirp4netns points the box at slirp's forwarder" {
  p="$(mkproj engdnsslirp)"
  AIRLOCK_PODMAN_NETWORK=slirp4netns AIRLOCK_ENGINE_OVERRIDE=podman _launch "$p" >/dev/null 2>&1 || true
  engine_args | grep -qx -- '--dns=10.0.2.3'
}

@test "docker gets no --dns by default (keeps its own list; the firewall filters it)" {
  p="$(mkproj engdnsdocker)"
  AIRLOCK_ENGINE_OVERRIDE=docker _launch "$p" >/dev/null 2>&1 || true
  ! engine_args | grep -q -- '^--dns='
}

@test "AIRLOCK_DNS overrides the resolver under BOTH engines" {
  for e in podman docker; do
    : > "$ENGINE_ARGS_FILE"
    p="$(mkproj "engdnsov-$e")"
    AIRLOCK_DNS="192.0.2.53 2001:db8::53" AIRLOCK_ENGINE_OVERRIDE="$e" _launch "$p" >/dev/null 2>&1 || true
    engine_args | grep -qx -- '--dns=192.0.2.53'   || { echo "$e: v4 override missing"; false; }
    engine_args | grep -qx -- '--dns=2001:db8::53' || { echo "$e: v6 override missing"; false; }
    ! engine_args | grep -qx -- '--dns=169.254.1.1' || { echo "$e: forwarder not replaced"; false; }
  done
}

@test "the host's own resolvers reach the firewall as AIRLOCK_HOST_DNS under BOTH engines" {
  # Includes the systemd-resolved upstream file, which is what docker copies when
  # /etc/resolv.conf is the 127.0.0.53 stub; a missing file must not break the launch.
  printf 'nameserver 127.0.0.53\noptions edns0\n' > "$BATS_TEST_TMPDIR/resolv.stub"
  printf 'nameserver 1.1.1.1\nnameserver 2606:4700:4700::1111\n' > "$BATS_TEST_TMPDIR/resolv.upstream"
  for e in podman docker; do
    : > "$ENGINE_ARGS_FILE"
    p="$(mkproj "engdnshost-$e")"
    AIRLOCK_HOST_RESOLV_FILES="$BATS_TEST_TMPDIR/resolv.stub $BATS_TEST_TMPDIR/resolv.upstream $BATS_TEST_TMPDIR/absent" \
      AIRLOCK_ENGINE_OVERRIDE="$e" _launch "$p" >/dev/null 2>&1 || true
    engine_args | grep -qx 'AIRLOCK_HOST_DNS=1.1.1.1 127.0.0.53 2606:4700:4700::1111' \
      || { echo "$e: got: $(engine_args | grep AIRLOCK_HOST_DNS)"; false; }
  done
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
