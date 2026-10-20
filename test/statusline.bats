#!/usr/bin/env bats
# The status line names whose session it is, left of the (airlock) / (host) badge.

SL="$BATS_TEST_DIRNAME/../config/airlock-statusline.sh"
J='{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Opus"}}'

@test "in the box: the host user the launcher passed, then the (airlock) badge" {
  run bash -c 'printf "%s" "$1" | AIRLOCK_HOST_USER=agent bash "$2"' _ "$J" "$SL"
  [ "$status" -eq 0 ]
  [[ "$output" == "agent "$'\033'"[1;38;5;28m(airlock)"* ]]
}

@test "on the host: the current user, then the (host) badge" {
  run bash -c 'printf "%s" "$1" | env -u AIRLOCK_HOST_USER bash "$2" --host' _ "$J" "$SL"
  [ "$status" -eq 0 ]
  [[ "$output" == "$(id -un) "$'\033'"[1;31m(host)"* ]]
}

@test "a user value can't carry terminal escapes into the line" {
  run bash -c 'printf "%s" "$1" | AIRLOCK_HOST_USER="$3" bash "$2"' _ "$J" "$SL" $'ev\e]0;t\a/al'
  [ "$status" -eq 0 ]
  [[ "$output" == "ev0tal "$'\033'"[1;38;5;28m(airlock)"* ]]
}
