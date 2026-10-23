#!/usr/bin/env bats
# scripts/private-names-check against the review's bypasses, in throwaway repos with a stand-in
# pattern list (test/private-names-check-test.sh says what each case is).

@test "private-names-check: binary and UTF-16 files, .gitattributes, merges, root commits, messages, bad lists" {
    run bash "$BATS_TEST_DIRNAME/private-names-check-test.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
