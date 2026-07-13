#!/usr/bin/env bats
# Egress posture: the group resolver + `airlock egress` verbs. This is the
# logic that hid the GROUPS-special-var and pattern-substitution bugs, so it
# earns the most coverage.

load helper
setup() { setup_airlock_env; }

@test "defaults to minimal (no groups)" {
  run _launch "$(mkproj)" egress show
  [ "$status" -eq 0 ]
  [[ "$output" == *"posture: minimal"* ]]
  [[ "$output" == *"active groups: <none"* ]]
}

@test "dev opens all groups" {
  p="$(mkproj)"; _launch "$p" egress dev
  run active_groups "$p"
  [ "$output" = "github npm pypi" ]
}

@test "explicit subset excludes npm" {
  p="$(mkproj)"; _launch "$p" egress github pypi
  run active_groups "$p"
  [ "$output" = "github pypi" ]
}

@test "add unions with the current set" {
  p="$(mkproj)"; _launch "$p" egress github; _launch "$p" egress add pypi
  run active_groups "$p"
  [ "$output" = "github pypi" ]
}

@test "rm drops a group" {
  p="$(mkproj)"; _launch "$p" egress github pypi; _launch "$p" egress rm pypi
  run active_groups "$p"
  [ "$output" = "github" ]
}

@test "rm of the last group collapses to minimal" {
  p="$(mkproj)"; _launch "$p" egress github; _launch "$p" egress rm github
  run cat "$(state_dir "$p")/egress-mode"
  [ "$output" = "minimal" ]
}

@test "dev then rm npm keeps github pypi" {
  p="$(mkproj)"; _launch "$p" egress dev; _launch "$p" egress rm npm
  run active_groups "$p"
  [ "$output" = "github pypi" ]
}

@test "repeated groups are de-duplicated" {
  p="$(mkproj)"; _launch "$p" egress github github
  run active_groups "$p"
  [ "$output" = "github" ]
}

@test "unknown group argument is rejected (not written to state)" {
  p="$(mkproj)"
  run _launch "$p" egress add bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown egress group 'bogus'"* ]]
  [ ! -f "$(state_dir "$p")/egress-mode" ]   # rejected before any write
}

@test "a bare unknown verb prints usage and fails" {
  run _launch "$(mkproj)" egress bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage:"* ]]
}

@test "AIRLOCK_EGRESS_MODE shifts the default for a fresh project" {
  p="$(mkproj)"
  run env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" \
    AIRLOCK_EGRESS_MODE=dev CLAUDE_CODE_OAUTH_TOKEN=x \
    bash -c "cd '$p' && bash '$AIRLOCK' egress show"
  [[ "$output" == *"active groups: github npm pypi"* ]]
}
