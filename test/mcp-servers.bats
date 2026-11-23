#!/usr/bin/env bats
# MCP servers and settings come from the host: `airlock mcp-servers` (per project) becomes the
# box's managed MCP config (exclusive in Claude Code), the host's settings.json reaches Claude
# through --settings, and the workspace's own .claude/settings*.json are named at each launch.

load helper

setup() {
  setup_airlock_env
  # The per-session files live only while the box runs; the stub engine ends at once, so it
  # snapshots each mounted one before the launcher cleans up.
  SNAP="$BATS_TEST_TMPDIR/snap"
  for e in podman docker; do
    mv "$STUBBIN/$e" "$STUBBIN/$e.orig"
    cat > "$STUBBIN/$e" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = run ]; then
  rm -rf "$SNAP"; mkdir -p "$SNAP"
  for a in "\$@"; do
    case "\$a" in
      *:/etc/claude-code/managed-mcp.json:ro) cp "\${a%%:*}" "$SNAP/mcp.json"; echo "\${a%%:*}" > "$SNAP/mcp.src" ;;
      *:/etc/airlock-box/settings.json:ro) cp "\${a%%:*}" "$SNAP/settings.json" ;;
    esac
  done
fi
exec "$STUBBIN/$e.orig" "\$@"
EOF
    chmod +x "$STUBBIN/$e"
  done
}

box_mcp() { cat "$SNAP/mcp.json"; }
_box_settings() { cat "$(state_dir "$1")/dot-claude/settings.json" 2>/dev/null; }
has_arg() { engine_args | grep -qx -- "$1"; }
# The claude arguments: every engine argument after the image's `claude`.
claude_argv() { engine_args | sed -n '/^claude$/,$p' | sed '1d'; }

@test "no MCP servers set: the box gets an empty managed MCP config, read-only" {
  p="$(mkproj)"
  _launch "$p" >/dev/null 2>&1
  engine_args | grep -q -- ':/etc/claude-code/managed-mcp.json:ro$'
  [ "$(jq -c . <<<"$(box_mcp)")" = '{"mcpServers":{}}' ]
  # host-side and per session, never in the box-writable dot-claude
  [[ "$(cat "$SNAP/mcp.src")" == "$(state_dir "$p")"/box-config.*/managed-mcp.json ]]
}

@test "mcp-servers set/show/rm: stored host-side, the box gets exactly those servers" {
  p="$(mkproj)"
  f="$BATS_TEST_TMPDIR/m.json"
  printf '%s\n' '{"mcpServers":{"hub":{"type":"http","url":"https://hub.example.org/mcp?k=secret","headers":{"Authorization":"Bearer ${HUB_TOKEN}"}},"local":{"command":"hub-mcp","args":["--x"],"env":{"T":"literal-secret"}}}}' > "$f"
  run _launch "$p" mcp-servers set "$f"
  [ "$status" -eq 0 ] && [[ "$output" == *"hub: http (https://hub.example.org/mcp)"* ]] && [[ "$output" == *"local: stdio (hub-mcp)"* ]] || { echo "$output"; false; }
  [[ "$output" != *secret* ]] && [[ "$output" != *"in the project"* ]]
  st="$(state_dir "$p")/mcp.json"
  [ "$(stat -c %a "$st")" = 600 ]
  run _launch "$p" mcp-servers show
  [[ "$output" == *"hub: http (https://hub.example.org/mcp)"* ]] && [[ "$output" == *"local: stdio (hub-mcp)"* ]] || { echo "$output"; false; }
  [[ "$output" != *secret* ]] && [[ "$output" != *Bearer* ]]
  _launch "$p" >/dev/null 2>&1
  [ "$(jq -c '.mcpServers | keys' <<<"$(box_mcp)")" = '["hub","local"]' ]
  [ "$(jq -r '.mcpServers.hub.headers.Authorization' <<<"$(box_mcp)")" = 'Bearer ${HUB_TOKEN}' ]
  run _launch "$p" mcp-servers rm
  [[ "$output" == *"removed"* ]] && [ ! -e "$st" ]
  _launch "$p" >/dev/null 2>&1
  [ "$(jq -c . <<<"$(box_mcp)")" = '{"mcpServers":{}}' ]
}

@test "mcp-servers set refuses what isn't a small {mcpServers: {...}} file" {
  p="$(mkproj)"; d="$BATS_TEST_TMPDIR"
  printf '[]\n' > "$d/a.json"; printf '{"mcpServers":[]}\n' > "$d/b.json"; printf 'nope\n' > "$d/c.json"
  printf '{"mcpServers":{}}\n' > "$d/ok.json"; ln -s "$d/ok.json" "$d/link.json"
  jq -n '{mcpServers: {x: {command: ("a" * 70000)}}}' > "$d/big.json"
  for f in a b c link big; do
    run _launch "$p" mcp-servers set "$d/$f.json"
    [ "$status" -ne 0 ] || { echo "$f accepted"; false; }
  done
  [ ! -e "$(state_dir "$p")/mcp.json" ]
}

@test "a stored file that went bad gives the box no MCP server, with a warning" {
  p="$(mkproj)"; sd="$(state_dir "$p")"; mkdir -p "$sd"
  printf 'garbage\n' > "$sd/mcp.json"
  run _launch "$p"
  [[ "$output" == *"MCP servers"*"are not valid"* ]] || { echo "$output"; false; }
  [ "$(jq -c . <<<"$(box_mcp)")" = '{"mcpServers":{}}' ]
}

@test "the Playwright image adds its MCP to the managed config, and an old ~/.claude.json entry goes" {
  p="$(mkproj)"; write_config "$p" "image = claude-airlock:playwright"
  sd="$(state_dir "$p")"; mkdir -p "$sd"
  printf '%s\n' '{"mcpServers":{"playwright":{"command":"x"},"boxadded":{"command":"y"}}}' > "$sd/claude.json"
  f="$BATS_TEST_TMPDIR/m.json"; printf '%s\n' '{"mcpServers":{"hub":{"type":"http","url":"https://h.example.org"}}}' > "$f"
  _launch "$p" mcp-servers set "$f"
  _launch "$p" >/dev/null 2>&1
  [ "$(jq -c '.mcpServers | keys' <<<"$(box_mcp)")" = '["hub","playwright"]' ]
  [ "$(jq -r '.mcpServers.playwright.command' <<<"$(box_mcp)")" = playwright-mcp ]
  [ "$(jq -c '.mcpServers | keys' "$sd/claude.json")" = '["boxadded"]' ]   # left, but never started
}

@test "a session started with a prompt word gets the host's settings too" {
  p="$(mkproj)"; mkdir -p "$AIRLOCK_HOME/.config/claude-airlock"
  echo '{"theme":"dark"}' > "$AIRLOCK_HOME/.config/claude-airlock/settings.json"
  _launch "$p" "fix the bug" >/dev/null 2>&1
  [ "$(claude_argv | grep -A1 -x -- --settings | tail -1)" = /etc/airlock-box/settings.json ]
  : > "$ENGINE_ARGS_FILE"
  _launch "$p" agents >/dev/null 2>&1
  claude_argv | grep -qx -- --settings
}

@test "mcp-servers set: a link is refused, the copy is compact, a file in the project is flagged" {
  p="$(mkproj)"
  jq -n '{mcpServers: {x: {command: "c", args: [range(0; 6000) | "aaaaaaaaaaaaaaa"]}}}' > "$BATS_TEST_TMPDIR/big.json"
  run _launch "$p" mcp-servers set "$BATS_TEST_TMPDIR/big.json"
  [ "$status" -ne 0 ]     # over 64 KiB once stored either way
  jq -n '{mcpServers: {x: {command: "c", args: [range(0; 1850) | "aaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]}}}' | jq . > "$BATS_TEST_TMPDIR/pretty.json"
  [ "$(stat -c %s "$BATS_TEST_TMPDIR/pretty.json")" -gt 65536 ]
  run _launch "$p" mcp-servers set "$BATS_TEST_TMPDIR/pretty.json"
  [ "$status" -eq 0 ] || { echo "$output"; false; }        # judged as stored: compact
  [ "$(stat -c %s "$(state_dir "$p")/mcp.json")" -le 65536 ]
  echo '{"mcpServers":{"w":{"command":"x"}}}' > "$p/.mcp.json"
  run _launch "$p" mcp-servers set "$p/.mcp.json"
  [[ "$output" == *"in the project, which the box can write"* ]] || { echo "$output"; false; }
  ln -sf "$p/.mcp.json" "$BATS_TEST_TMPDIR/l.json"
  run _launch "$p" mcp-servers set "$BATS_TEST_TMPDIR/l.json"
  [ "$status" -ne 0 ]
}

@test "mcp-servers show: no URL credentials, no forged lines or escapes" {
  p="$(mkproj)"
  printf '%s' '{"mcpServers":{"a\nfake: stdio (evil)":{"command":"x\u001b[2J"},"h":{"type":"http","url":"https://u:pw@h.example.org/mcp?k=s#frag"}}}' > "$BATS_TEST_TMPDIR/m.json"
  _launch "$p" mcp-servers set "$BATS_TEST_TMPDIR/m.json"
  run _launch "$p" mcp-servers show
  [ "${#lines[@]}" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" != *pw* ]] && [[ "$output" != *frag* ]] && [[ "$output" != *$'\e'* ]]
  [[ "$output" == *"h: http (https://h.example.org/mcp)"* ]]
}

@test "a claude subcommand doesn't get --settings" {
  p="$(mkproj)"; mkdir -p "$AIRLOCK_HOME/.config/claude-airlock"
  echo '{"theme":"dark"}' > "$AIRLOCK_HOME/.config/claude-airlock/settings.json"
  : > "$ENGINE_ARGS_FILE"
  _launch "$p" remote-control >/dev/null 2>&1
  [[ "$(claude_argv)" == *remote-control* ]]
  ! claude_argv | grep -qx -- --settings
}

@test "the host's settings.json reaches the session read-only through --settings; a bad one is skipped" {
  p="$(mkproj)"; mkdir -p "$AIRLOCK_HOME/.config/claude-airlock"
  hs="$AIRLOCK_HOME/.config/claude-airlock/settings.json"
  echo '{"theme":"dark","permissions":{"allow":["Bash(make:*)"]}}' > "$hs"
  _launch "$p" >/dev/null 2>&1
  engine_args | grep -q -- '/box-config\.[0-9]*\.[0-9]*/settings.json:/etc/airlock-box/settings.json:ro$'
  [ "$(claude_argv | grep -A1 -x -- --settings | tail -1)" = /etc/airlock-box/settings.json ]
  [ "$(jq -r .theme "$SNAP/settings.json")" = dark ]
  for bad in '[]' 'nope'; do
    printf '%s\n' "$bad" > "$hs"
    : > "$ENGINE_ARGS_FILE"
    run _launch "$p"
    [[ "$output" == *"settings.json is not a JSON object"* ]] || { echo "$output"; false; }
    ! claude_argv | grep -qx -- --settings
  done
  rm -f "$hs"; ln -s /etc/hostname "$hs"
  : > "$ENGINE_ARGS_FILE"
  run _launch "$p"
  [[ "$output" == *"settings.json is not a JSON object"* ]]
  ! claude_argv | grep -qx -- --settings
}

@test "the managed settings refuse inline shell in skills" {
  [ "$(jq -r '.disableSkillShellExecution' "$BATS_TEST_DIRNAME/../image/managed-settings.json")" = true ]
}

@test "mcp-servers set refuses two documents, and a server that isn't an object" {
  p="$(mkproj)"
  printf '"junk"\n{"mcpServers":{"a":{"command":"x"}}}\n' > "$BATS_TEST_TMPDIR/two.json"
  printf '{"mcpServers":{"a":"str"}}\n' > "$BATS_TEST_TMPDIR/str.json"
  for f in two str; do
    run _launch "$p" mcp-servers set "$BATS_TEST_TMPDIR/$f.json"
    [ "$status" -ne 0 ] || { echo "$f accepted: $output"; false; }
  done
  [ ! -e "$(state_dir "$p")/mcp.json" ]
}

@test "mcp-servers show turns bidi and zero-width characters into ?" {
  p="$(mkproj)"
  printf '{"mcpServers":{"a\\u202eb\\u200bc":{"command":"x"}}}\n' > "$BATS_TEST_TMPDIR/b.json"
  _launch "$p" mcp-servers set "$BATS_TEST_TMPDIR/b.json"
  run _launch "$p" mcp-servers show
  [[ "$output" == *"a?b?c: stdio (x)"* ]] || { echo "$output" | od -c | head; false; }
}

@test "the workspace's settings files are named at launch as read in the box; a .mcp.json as ignored" {
  p="$(mkproj)"; mkdir -p "$p/.claude"
  echo '{}' > "$p/.claude/settings.json"; echo '{}' > "$p/.claude/settings.local.json"; echo '{}' > "$p/.mcp.json"
  run _launch "$p"
  [[ "$output" == *"read in the box: .claude/settings.json .claude/settings.local.json"* ]] || { echo "$output"; false; }
  [[ "$output" == *"ignored in the box: .mcp.json"* ]] || { echo "$output"; false; }
  rm -rf "$p/.claude" "$p/.mcp.json"
  run _launch "$p"
  [[ "$output" != *"in the box:"* ]]
}
