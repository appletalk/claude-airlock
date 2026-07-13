#!/usr/bin/env bats
# Host-side secret + share subcommands (the tamper-proof grants). Smoke-level:
# roundtrips and the key validations.

load helper
setup() { setup_airlock_env; }

@test "secret set/list/rm roundtrip; pass refs shown, literals masked" {
  p="$(mkproj)"
  _launch "$p" secret set TOKEN pass:mcp/foo
  run _launch "$p" secret list
  [[ "$output" == *"TOKEN = pass:mcp/foo"* ]]     # pass ref = a pointer, shown

  _launch "$p" secret set LIT hunter2
  run _launch "$p" secret list
  [[ "$output" == *"LIT = ***"* ]]                # literal value masked

  _launch "$p" secret rm TOKEN
  run _launch "$p" secret list
  [[ "$output" != *"TOKEN"* ]]
}

@test "secret rejects an invalid key" {
  run _launch "$(mkproj)" secret set "bad key" val
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid key"* ]]
}

@test "share list reflects approvals and rm revokes" {
  p="$(mkproj)"
  sd="$(state_dir "$p")"; mkdir -p "$sd"
  printf 'some/repo\n' > "$sd/approved-shares"        # as the launch TOFU would write

  run _launch "$p" share list
  [[ "$output" == *"some/repo"* ]]

  _launch "$p" share rm some/repo
  run _launch "$p" share list
  [[ "$output" != *"some/repo"* ]]
}

@test "share rm of an unknown path is a no-op with a message" {
  run _launch "$(mkproj)" share rm nope/nope
  [ "$status" -eq 0 ]
  [[ "$output" == *"no such approved share"* ]]
}

@test "share list tags ro and rw approvals; rm revokes from either store" {
  p="$(mkproj)"; sd="$(state_dir "$p")"; mkdir -p "$sd"
  printf 'readonly/repo\n' > "$sd/approved-shares"
  printf 'writable/repo\n' > "$sd/approved-shares-rw"

  run _launch "$p" share list
  [[ "$output" == *"readonly/repo"* ]]; [[ "$output" == *"(ro)"* ]]
  [[ "$output" == *"writable/repo"* ]]; [[ "$output" == *"(rw)"* ]]

  _launch "$p" share rm writable/repo
  run _launch "$p" share list
  [[ "$output" != *"writable/repo"* ]]
  [[ "$output" == *"readonly/repo"* ]]   # unaffected
}
