#!/usr/bin/env bats
@test "a passing test passes" {
  run bash -c 'printf ok'
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}
