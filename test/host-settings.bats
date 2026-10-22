#!/usr/bin/env bats
# config/host-managed-settings.json, the managed settings docs/setup.md has the operator install
# for the host's own Claude: valid JSON that keeps it off Remote Control, refuses other sessions'
# messages and denies artifacts and cloud triggers.

@test "host managed settings: no Remote Control, no inbound messages, artifacts and triggers denied" {
    f="$BATS_TEST_DIRNAME/../config/host-managed-settings.json"
    python3 -I - "$f" <<'P'
import json, sys
s = json.load(open(sys.argv[1]))
assert s["disableRemoteControl"] is True, s
assert s["crossSessionInbound"] == "refuse", s
assert sorted(s["permissions"]["deny"]) == ["Artifact", "ArtifactCheck", "ArtifactComments", "ArtifactData", "RemoteTrigger"], s
P
}

@test "docs/setup.md installs exactly that file" {
    grep -qF 'sudo install -D -m 0644 config/host-managed-settings.json /etc/claude-code/managed-settings.json' \
        "$BATS_TEST_DIRNAME/../docs/setup.md"
}
