#!/usr/bin/env bats
# Container hardening: the assembled `docker run` drops docker's broad default
# capability set and re-adds only what the box needs — NET_ADMIN+NET_RAW (firewall)
# and SETUID+SETGID (gosu drops root -> dev) — plus no-new-privileges. The agent
# itself runs as non-root dev with no caps. (Runtime behaviour is validated against
# a real container separately; here we pin the flags so they can't silently regress.)

load helper
setup() { setup_airlock_env; }

@test "drops all caps, re-adds only firewall + gosu caps" {
  _launch "$(mkproj)"
  args="$(engine_args)"
  [[ "$args" == *"--cap-drop=ALL"* ]]
  [[ "$args" == *"--cap-add=NET_ADMIN"* ]]
  [[ "$args" == *"--cap-add=NET_RAW"* ]]
  [[ "$args" == *"--cap-add=SETUID"* ]]
  [[ "$args" == *"--cap-add=SETGID"* ]]
}

@test "sets no-new-privileges" {
  _launch "$(mkproj)"
  [[ "$(engine_args)" == *"--security-opt=no-new-privileges"* ]]
}
