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

# An empty value in the host config survives the launcher's default (the config is
# sourced after it). As a bare --network= podman picks its own default, which keeps
# pasta's 169.254.1.2 mapping to the host and gets no --dns, so the box gets Google
# Public DNS as well. Empty must mean the default, in the launcher and the doctor alike.
@test "an empty AIRLOCK_PODMAN_NETWORK in the host config still means pasta, mapping removed" {
  mkdir -p "$AIRLOCK_HOME/.config/claude-airlock"
  printf 'AIRLOCK_PODMAN_NETWORK=\n' > "$AIRLOCK_HOME/.config/claude-airlock/config"
  p="$(mkproj engnetempty)"
  AIRLOCK_ENGINE_OVERRIDE=podman _launch "$p" >/dev/null 2>&1 || true
  engine_args | grep -qx -- '--network=pasta:--map-guest-addr,none' \
    || { echo "got: $(engine_args | grep -- '^--network')"; false; }
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
  ! engine_args | grep -q -- '^--dns=' || false
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

# The doctor's throwaway box must get the launcher's network and resolvers. Without
# --dns, a loopback-only host resolver gets Google Public DNS appended to its
# resolv.conf, so the doctor would be testing (and warning about) a box that never runs.
_doctor_net_dns() { grep -E '^(--network=|--dns=|AIRLOCK_HOST_DNS=)' "$ENGINE_ARGS_FILE" | sort; }

# Run the doctor for engine $1 hermetically, passing only the environment `make doctor`
# and install.sh do (plus any VAR=value arguments).
_doctor() {
  local e="$1"; shift
  env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" USER=airlock-test \
    ENGINE_ARGS_FILE="$ENGINE_ARGS_FILE" AIRLOCK_ENGINE="$e" \
    AIRLOCK_HOST_RESOLV_FILES="$BATS_TEST_TMPDIR/resolv.loop" "$@" \
    bash "$BATS_TEST_DIRNAME/../scripts/airlock-doctor.sh" >/dev/null 2>&1 || true
}

# The same, keeping the doctor's output for `run`.
_doctor_out() {
  local e="$1"; shift
  env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" USER=airlock-test \
    ENGINE_ARGS_FILE="$ENGINE_ARGS_FILE" AIRLOCK_ENGINE="$e" \
    AIRLOCK_HOST_RESOLV_FILES="$BATS_TEST_TMPDIR/resolv.loop" "$@" \
    bash "$BATS_TEST_DIRNAME/../scripts/airlock-doctor.sh" 2>&1
}

@test "the doctor's box gets the same --network, --dns and AIRLOCK_HOST_DNS as a launched box" {
  printf 'nameserver ::1\nnameserver 127.0.0.1\n' > "$BATS_TEST_TMPDIR/resolv.loop"
  for c in "podman pasta -" "podman pasta:--mtu,1400 -" "podman slirp4netns -" \
           "docker pasta -" "podman pasta 192.0.2.53 2001:db8::53" "docker pasta 192.0.2.53"; do
    read -r e net dns <<< "$c"; [ "$dns" = - ] && dns=
    : > "$ENGINE_ARGS_FILE"
    p="$(mkproj "engdoctor-$e-${net%%:*}-${dns%% *}")"
    AIRLOCK_PODMAN_NETWORK="$net" AIRLOCK_DNS="$dns" \
      AIRLOCK_HOST_RESOLV_FILES="$BATS_TEST_TMPDIR/resolv.loop" \
      AIRLOCK_ENGINE_OVERRIDE="$e" _launch "$p" >/dev/null 2>&1 || true
    launched="$(_doctor_net_dns)"
    : > "$ENGINE_ARGS_FILE"
    _doctor "$e" AIRLOCK_PODMAN_NETWORK="$net" AIRLOCK_DNS="$dns"
    doctor="$(_doctor_net_dns)"
    [ -n "$launched" ] || { echo "$c: launcher recorded nothing"; false; }
    [ "$doctor" = "$launched" ] \
      || { printf '%s\nlauncher:\n%s\ndoctor:\n%s\n' "$c" "$launched" "$doctor"; false; }
  done
}

# `make doctor` and install.sh pass neither key, so the doctor must read them from the
# host config itself, and must not let the config's AIRLOCK_IMAGE replace the image the
# caller asked it to check.
@test "the doctor takes the network and resolvers from the host config, and only those" {
  printf 'nameserver ::1\nnameserver 127.0.0.1\n' > "$BATS_TEST_TMPDIR/resolv.loop"
  mkdir -p "$AIRLOCK_HOME/.config/claude-airlock"
  printf '%s\n' 'AIRLOCK_PODMAN_NETWORK=slirp4netns' 'AIRLOCK_DNS="192.0.2.53 2001:db8::53"' \
    'AIRLOCK_IMAGE=config-image:never' > "$AIRLOCK_HOME/.config/claude-airlock/config"
  p="$(mkproj engdoctorcfg)"
  AIRLOCK_HOST_RESOLV_FILES="$BATS_TEST_TMPDIR/resolv.loop" \
    AIRLOCK_ENGINE_OVERRIDE=podman _launch "$p" >/dev/null 2>&1 || true
  launched="$(_doctor_net_dns)"
  engine_args | grep -qx -- '--network=slirp4netns' || { echo "config not applied: $launched"; false; }
  : > "$ENGINE_ARGS_FILE"
  _doctor podman AIRLOCK_IMAGE=claude-airlock:base
  [ "$(_doctor_net_dns)" = "$launched" ] \
    || { printf 'launcher:\n%s\ndoctor:\n%s\n' "$launched" "$(_doctor_net_dns)"; false; }
  engine_args | grep -qx 'claude-airlock:base'
  ! engine_args | grep -q 'config-image' || false
}

# The launcher sets every AIRLOCK_* default before it sources the config, so a config may
# build on one. The doctor sets almost none, and must still get the same two values out.
@test "the doctor reads a config that builds on the launcher's defaults" {
  printf 'nameserver ::1\nnameserver 127.0.0.1\n' > "$BATS_TEST_TMPDIR/resolv.loop"
  mkdir -p "$AIRLOCK_HOME/.config/claude-airlock"
  printf '%s\n' 'AIRLOCK_ARTIFACT_DIRS="$AIRLOCK_ARTIFACT_DIRS target"' \
    'if [ "$AIRLOCK_ENGINE" = podman ]; then AIRLOCK_DNS="192.0.2.53"; fi' \
    > "$AIRLOCK_HOME/.config/claude-airlock/config"
  p="$(mkproj engdoctorbuild)"
  AIRLOCK_HOST_RESOLV_FILES="$BATS_TEST_TMPDIR/resolv.loop" \
    AIRLOCK_ENGINE_OVERRIDE=podman _launch "$p" >/dev/null 2>&1 || true
  launched="$(_doctor_net_dns)"
  engine_args | grep -qx -- '--dns=192.0.2.53' || { echo "config not applied: $launched"; false; }
  : > "$ENGINE_ARGS_FILE"
  env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" USER=airlock-test \
    ENGINE_ARGS_FILE="$ENGINE_ARGS_FILE" \
    AIRLOCK_HOST_RESOLV_FILES="$BATS_TEST_TMPDIR/resolv.loop" \
    bash "$BATS_TEST_DIRNAME/../scripts/airlock-doctor.sh" >/dev/null 2>&1 || true
  [ "$(_doctor_net_dns)" = "$launched" ] \
    || { printf 'launcher:\n%s\ndoctor:\n%s\n' "$launched" "$(_doctor_net_dns)"; false; }
}

# Through `airlock doctor`, the launcher has already sourced the config once; an
# environment value it hands on must be the one from BEFORE that, or a config that
# builds on it is applied twice. Leading space: the doctor must not trim what the
# launcher passes as is.
@test "airlock doctor applies the host config once, exactly as the launcher does" {
  printf 'nameserver ::1\nnameserver 127.0.0.1\n' > "$BATS_TEST_TMPDIR/resolv.loop"
  mkdir -p "$AIRLOCK_HOME/.config/claude-airlock"
  printf '%s\n' 'AIRLOCK_PODMAN_NETWORK="$AIRLOCK_PODMAN_NETWORK,--mtu,1400"' \
    'AIRLOCK_DNS="$AIRLOCK_DNS 192.0.2.53"' > "$AIRLOCK_HOME/.config/claude-airlock/config"
  for net in "pasta:--ipv4-only" " pasta"; do
    p="$(mkproj "engdoctoronce-${net// /_}")"
    : > "$ENGINE_ARGS_FILE"
    AIRLOCK_PODMAN_NETWORK="$net" AIRLOCK_DNS=198.51.100.1 \
      AIRLOCK_HOST_RESOLV_FILES="$BATS_TEST_TMPDIR/resolv.loop" \
      AIRLOCK_ENGINE_OVERRIDE=podman _launch "$p" >/dev/null 2>&1 || true
    launched="$(_doctor_net_dns)"
    : > "$ENGINE_ARGS_FILE"
    AIRLOCK_PODMAN_NETWORK="$net" AIRLOCK_DNS=198.51.100.1 \
      AIRLOCK_HOST_RESOLV_FILES="$BATS_TEST_TMPDIR/resolv.loop" \
      AIRLOCK_ENGINE_OVERRIDE=podman _launch "$p" doctor >/dev/null 2>&1 || true
    [ -n "$launched" ] || { echo "'$net': launcher recorded nothing"; false; }
    [ "$(_doctor_net_dns)" = "$launched" ] \
      || { printf "'%s'\nlauncher:\n%s\ndoctor:\n%s\n" "$net" "$launched" "$(_doctor_net_dns)"; false; }
  done
}

# A config that does not run to the end (an `exit`, say) must leave the defaults standing,
# not blank them: an empty read is pasta with no AIRLOCK_DNS by accident, not by choice.
@test "a config that stops early leaves the doctor's values as they were" {
  printf 'nameserver ::1\nnameserver 127.0.0.1\n' > "$BATS_TEST_TMPDIR/resolv.loop"
  mkdir -p "$AIRLOCK_HOME/.config/claude-airlock"
  printf '%s\n' 'AIRLOCK_PODMAN_NETWORK=bogus' 'exit 3' > "$AIRLOCK_HOME/.config/claude-airlock/config"
  : > "$ENGINE_ARGS_FILE"
  run env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" USER=airlock-test \
    ENGINE_ARGS_FILE="$ENGINE_ARGS_FILE" AIRLOCK_ENGINE=podman AIRLOCK_DNS=192.0.2.9 \
    AIRLOCK_HOST_RESOLV_FILES="$BATS_TEST_TMPDIR/resolv.loop" \
    bash "$BATS_TEST_DIRNAME/../scripts/airlock-doctor.sh"
  engine_args | grep -qx -- '--network=pasta:--map-guest-addr,none'
  engine_args | grep -qx -- '--dns=192.0.2.9'
  [[ "$output" == *"did not run to the end"* ]]
}

# A config's own EXIT trap fires when the doctor's subshell ends. It must not be able to
# print after the sentinel and so turn a config that ran fine into "did not run".
@test "a config with an EXIT trap that prints is still read by the doctor" {
  printf 'nameserver ::1\nnameserver 127.0.0.1\n' > "$BATS_TEST_TMPDIR/resolv.loop"
  mkdir -p "$AIRLOCK_HOME/.config/claude-airlock"
  printf '%s\n' 'trap "echo bye" EXIT' 'AIRLOCK_DNS=192.0.2.53' > "$AIRLOCK_HOME/.config/claude-airlock/config"
  : > "$ENGINE_ARGS_FILE"
  run _doctor_out podman
  engine_args | grep -qx -- '--dns=192.0.2.53'
  [[ "$output" != *"did not run to the end"* ]]
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
