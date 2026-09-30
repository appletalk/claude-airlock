#!/usr/bin/env bats
# Guards on how the suite asserts. `refute` negates one command, so `refute a | b` negates
# only `a`; a pipeline needs `! a | b || false`. Line-based: a refute continued onto a
# second line, or a bare mid-test `! a | b`, is not caught here.

@test "no test uses refute on a pipeline" {
  run grep -nE '^[[:space:]]*refute [^#]*\|' "$BATS_TEST_DIRNAME"/*.bats
  [ "$status" -ne 0 ] || { echo "$output"; false; }
}
