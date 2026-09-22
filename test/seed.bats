#!/usr/bin/env bats
# What the box's ~/.claude.json is seeded with from the host's. It used to be "everything
# except projects and mcpServers", which carried the account profile, the host install's
# stable identifiers and githubRepoPaths - a map of every other repo on the machine - into
# a box whose premise is that it sees only its own project. Now an allowlist at seed time,
# plus a launch-time strip for projects provisioned before that.

load helper
setup() {
  setup_airlock_env
  cat > "$AIRLOCK_HOME/.claude.json" <<'EOF'
{
  "theme": "light",
  "editorMode": "vim",
  "preferredNotifChannel": "terminal_bell",
  "numStartups": 42,
  "tipsHistory": {"a": 1},
  "userID": "host-user-id-0000000000000000000000000000000000000000000000000000",
  "machineID": "host-machine-id-00000000000000000000000000000000000000000000000",
  "oauthAccount": {"emailAddress": "someone@example.com", "organizationUuid": "org-1"},
  "githubRepoPaths": {"org/other-repo": ["/home/someone/development/other-repo"]},
  "mcpServers": {"x": {}},
  "projects": {"/home/someone/development/other": {"hasTrustDialogAccepted": true}},
  "cachedGrowthBookFeatures": {"f": true}
}
EOF
}
box_json() { cat "$(state_dir "$1")/claude.json"; }

@test "a new project's claude.json is seeded from an allowlist: prefs in, identity and repo map out" {
  p="$(mkproj seed)"; _launch "$p"
  j="$(box_json "$p")"
  [ "$(jq -r .theme <<<"$j")" = light ]
  [ "$(jq -r .editorMode <<<"$j")" = vim ]
  [ "$(jq -r .preferredNotifChannel <<<"$j")" = terminal_bell ]
  for k in userID machineID oauthAccount githubRepoPaths mcpServers numStartups tipsHistory cachedGrowthBookFeatures; do
    [ "$(jq --arg k "$k" 'has($k)' <<<"$j")" = false ] || { echo "$k leaked into the box"; false; }
  done
  # the friction-skips the launcher enforces are still there, and only THIS project
  [ "$(jq -r .hasCompletedOnboarding <<<"$j")" = true ]
  [ "$(jq -r --arg ws "$p" '.projects[$ws].hasTrustDialogAccepted' <<<"$j")" = true ]
  [ "$(jq '.projects | length' <<<"$j")" = 1 ]
}

@test "a project provisioned by the old seed is stripped at launch: host install identity and repo map go" {
  p="$(mkproj old)"; sd="$(state_dir "$p")"; mkdir -p "$sd"
  jq 'del(.projects, .mcpServers)' "$AIRLOCK_HOME/.claude.json" > "$sd/claude.json"   # exactly the old seed
  _launch "$p"
  j="$(box_json "$p")"
  for k in userID machineID githubRepoPaths; do
    [ "$(jq --arg k "$k" 'has($k)' <<<"$j")" = false ] || { echo "$k survived the launch strip"; false; }
  done
  [ "$(jq -r .theme <<<"$j")" = light ]                    # everything else untouched
  [ "$(jq -r .numStartups <<<"$j")" = 42 ]
}

@test "identity a box generated for itself is kept: only the host's own values are stripped" {
  p="$(mkproj own)"; sd="$(state_dir "$p")"; mkdir -p "$sd"
  printf '{"userID":"box-generated","machineID":"box-machine","githubRepoPaths":{"a":["/x"]}}\n' > "$sd/claude.json"
  _launch "$p"
  j="$(box_json "$p")"
  [ "$(jq -r .userID <<<"$j")" = box-generated ]
  [ "$(jq -r .machineID <<<"$j")" = box-machine ]
  [ "$(jq 'has("githubRepoPaths")' <<<"$j")" = false ]      # the repo map goes regardless
}

# A login done inside the box (persist mode, or /login in any box) writes the box's own
# oauthAccount, and for the same account it can be identical to the host's. Equality
# cannot tell them apart, so the launch strip never touches it - in either login mode.
@test "oauthAccount is never stripped at launch, whether it matches the host's or not, in either login mode" {
  for mode in token persist; do
    p="$(mkproj "acct-$mode")"; sd="$(state_dir "$p")"; mkdir -p "$sd"
    [ "$mode" = persist ] && _launch "$p" login persist >/dev/null
    jq 'del(.projects, .mcpServers)' "$AIRLOCK_HOME/.claude.json" > "$sd/claude.json"   # host-identical profile
    _launch "$p"
    j="$(box_json "$p")"
    [ "$(jq -r .oauthAccount.emailAddress <<<"$j")" = someone@example.com ] || { echo "$mode: profile stripped"; false; }
    [ "$(jq 'has("userID")' <<<"$j")" = false ]            # install identifiers still go
  done
}

@test "no host claude.json at all still yields a valid, minimal box config" {
  rm -f "$AIRLOCK_HOME/.claude.json"
  p="$(mkproj none)"; _launch "$p"
  jq -e . "$(state_dir "$p")/claude.json" >/dev/null
  [ "$(jq -r .hasCompletedOnboarding "$(state_dir "$p")/claude.json")" = true ]
}
