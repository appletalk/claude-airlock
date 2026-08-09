#!/usr/bin/env bats
# Deliberately failing. If `bats` ever reports this suite as passing, the runner
# has degraded to a no-op and every other suite's green result is worthless.
@test "a failing test must be reported as failing" {
  run bash -c 'exit 3'
  [ "$status" -eq 0 ]
}
