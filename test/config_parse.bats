#!/usr/bin/env bats
# Safe-parse of the BOX-WRITABLE .airlock/config. These are the security-critical
# rejections: a compromised session must not be able to escape the share base,
# shadow-mount host paths, or point the sandbox at an arbitrary image. Each test
# does a full (stubbed) launch and asserts on the assembled `docker run` argv.

load helper
setup() { setup_airlock_env; }

@test "share with .. is rejected (never mounted)" {
  p="$(mkproj)"; write_config "$p" "share = ../escape"
  run _launch "$p"
  [ "$status" -eq 0 ]
  [[ "$(engine_args)" != *"escape"* ]]
}

@test "absolute share path is rejected" {
  p="$(mkproj)"; write_config "$p" "share = /etc"
  _launch "$p"
  [[ "$(engine_args)" != *":/etc:ro"* ]]
}

@test "approved relative share mounts read-only at its real path" {
  p="$(mkproj)"; mkdir -p "$SHARE_BASE/sib"
  write_config "$p" "share = sib"
  sd="$(state_dir "$p")"; mkdir -p "$sd"; printf 'sib\n' > "$sd/approved-shares"
  _launch "$p"
  [[ "$(engine_args)" == *"$SHARE_BASE/sib:$SHARE_BASE/sib:ro"* ]]
}

@test "artifact_dirs rejects absolute and .. entries, keeps the safe one" {
  p="$(mkproj)"; write_config "$p" "artifact_dirs = /abs ../up safe"
  _launch "$p"
  args="$(engine_args)"
  [[ "$args" == *"/safe:rw"* ]]     # safe relative dir shadow-mounted
  [[ "$args" != *"/abs:"* ]]        # absolute rejected
  [[ "$args" != *"up:rw"* ]]        # parent-escape rejected
}

@test "image must be a claude-airlock:* tag (arbitrary image rejected)" {
  p="$(mkproj)"; write_config "$p" "image = evil/backdoor:latest"
  _launch "$p"
  args="$(engine_args)"
  [[ "$args" != *"evil/backdoor"* ]]
  [[ "$args" == *"claude-airlock:"* ]]   # fell back to the default tag
}

@test "a claude-airlock:* image override is honored" {
  p="$(mkproj)"; write_config "$p" "image = claude-airlock:playwright"
  _launch "$p"
  [[ "$(engine_args)" == *"claude-airlock:playwright"* ]]
}

# Auth mode is HOST-gated. A box that could set persist_login in its own (box-writable)
# config could suppress the injected token and stand up an interactive login prompt of
# its own — phishing the operator for an account credential from inside the sandbox.
# The parser ignores unknown keys, so this is really a regression guard: it fails the day
# someone adds persist_login to the key switch without thinking about who writes the file.
@test "persist_login cannot be enabled from the box-writable .airlock/config" {
  p="$(mkproj)"; write_config "$p" "persist_login = 1"
  cat > "$STUBBIN/$ENGINE" <<'EOF'
#!/usr/bin/env bash
a=("$@")
for ((i=0; i<${#a[@]}; i++)); do
  if [ "${a[$i]}" = "--env-file" ]; then
    grep -q 'CLAUDE_CODE_OAUTH_TOKEN' "${a[$((i+1))]}" && echo yes > "$ENGINE_ARGS_FILE.hasvar"
  fi
done
EOF
  chmod +x "$STUBBIN/$ENGINE"
  _launch "$p"
  [ "$(cat "$ENGINE_ARGS_FILE.hasvar" 2>/dev/null)" = "yes" ]   # token still injected
}

@test "share_rw with .. is rejected" {
  p="$(mkproj)"; write_config "$p" "share_rw = ../escape"
  run _launch "$p"
  [ "$status" -eq 0 ]
  [[ "$(engine_args)" != *"escape"* ]]
}

@test "approved share_rw mounts read-write at its real path" {
  p="$(mkproj)"; mkdir -p "$SHARE_BASE/wsib"
  write_config "$p" "share_rw = wsib"
  sd="$(state_dir "$p")"; mkdir -p "$sd"; printf 'wsib\n' > "$sd/approved-shares-rw"
  _launch "$p"
  [[ "$(engine_args)" == *"$SHARE_BASE/wsib:$SHARE_BASE/wsib:rw"* ]]
}

@test "a read approval does NOT grant write (share_rw needs its own store)" {
  p="$(mkproj)"; mkdir -p "$SHARE_BASE/wsib2"
  write_config "$p" "share_rw = wsib2"
  sd="$(state_dir "$p")"; mkdir -p "$sd"
  printf 'wsib2\n' > "$sd/approved-shares"          # approved read-only only
  _launch "$p"                                       # rw unapproved; stdin=/dev/null -> prompt EOF -> skipped
  [[ "$(engine_args)" != *"wsib2:$SHARE_BASE/wsib2:rw"* ]]
  [[ "$(engine_args)" != *"/wsib2:ro"* ]]            # and not silently mounted ro either
}

@test "launch heals a path stuck in both ro and rw stores (rw config wins)" {
  p="$(mkproj)"; mkdir -p "$SHARE_BASE/dup"
  write_config "$p" "share_rw = dup"
  sd="$(state_dir "$p")"; mkdir -p "$sd"
  printf 'dup\n' > "$sd/approved-shares"             # stale ro entry
  printf 'dup\n' > "$sd/approved-shares-rw"          # already approved rw
  _launch "$p"
  run cat "$sd/approved-shares"
  [[ "$output" != *"dup"* ]]                          # ro copy dropped
  [[ "$(engine_args)" == *"$SHARE_BASE/dup:$SHARE_BASE/dup:rw"* ]]   # mounted rw
  [[ "$(engine_args)" != *"$SHARE_BASE/dup:$SHARE_BASE/dup:ro"* ]]   # not also ro
}

@test "rw->ro downgrade is silent (privilege reduction) and migrates the store" {
  p="$(mkproj)"; mkdir -p "$SHARE_BASE/dg"
  write_config "$p" "share = dg"                     # config now asks for read-only
  sd="$(state_dir "$p")"; mkdir -p "$sd"
  printf 'dg\n' > "$sd/approved-shares-rw"           # was approved read-write
  run _launch "$p"                                    # stdin=/dev/null: must NOT need a prompt
  [ "$status" -eq 0 ]
  [[ "$output" == *"downgraded to read-only"* ]]
  [[ "$(engine_args)" == *"$SHARE_BASE/dg:$SHARE_BASE/dg:ro"* ]]     # mounted ro
  [[ "$(engine_args)" != *"$SHARE_BASE/dg:$SHARE_BASE/dg:rw"* ]]
  grep -qxF dg "$sd/approved-shares"                 # migrated into ro store
  [ ! -s "$sd/approved-shares-rw" ] || ! grep -qxF dg "$sd/approved-shares-rw"  # cleared from rw
}

@test "ro->rw upgrade still needs approval (more access)" {
  p="$(mkproj)"; mkdir -p "$SHARE_BASE/ug"
  write_config "$p" "share_rw = ug"                  # config now asks for read-write
  sd="$(state_dir "$p")"; mkdir -p "$sd"
  printf 'ug\n' > "$sd/approved-shares"              # only approved read-only
  _launch "$p"                                        # stdin=/dev/null: write prompt gets EOF -> skipped
  [[ "$(engine_args)" != *"$SHARE_BASE/ug:$SHARE_BASE/ug:rw"* ]]     # not silently upgraded
}

# --- egress entry parsing -----------------------------------------------------
# A grant that is silently dropped is the worst outcome here: the box comes up
# looking configured while having no access to the endpoint. Each of these was a
# real bug -- the comma list, the IP:port shape, and the silent skip.

@test "egress accepts a comma-separated list (both entries reach the box)" {
  p="$(mkproj)"; write_config "$p" "egress = a.example.com, b.example.com"
  sd="$(state_dir "$p")"; mkdir -p "$sd"
  printf 'a.example.com\nb.example.com\n' > "$sd/approved-egress"
  _launch "$p"
  args="$(engine_args)"
  [[ "$args" == *"a.example.com"* ]]
  [[ "$args" == *"b.example.com"* ]]
}

@test "egress accepts an IP:port datasource grant" {
  p="$(mkproj)"; write_config "$p" "egress = 10.1.15.115:8428"
  sd="$(state_dir "$p")"; mkdir -p "$sd"
  printf '10.1.15.115:8428\n' > "$sd/approved-egress"
  _launch "$p"
  [[ "$(engine_args)" == *"10.1.15.115:8428"* ]]
}

@test "a malformed egress entry aborts the launch rather than being skipped" {
  p="$(mkproj)"; write_config "$p" "egress = 10.1.15.115::8428"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a valid"* ]]
}
