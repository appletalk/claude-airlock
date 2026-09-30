#!/usr/bin/env bats
# Guards that keep host credentials out of a box through shares, mounts and secrets.
# A share approved once is re-checked on every launch: the box can write .airlock/config
# and any share_rw directory, so it can turn an approved path into a symlink later.

load helper

setup() {
  setup_airlock_env
  H="$AIRLOCK_HOME"
  CFG="$H/.config/claude-airlock/config"
  mkdir -p "$(dirname "$CFG")"
  # The env-file dies with the launch, so the stub copies it while it exists.
  cat > "$STUBBIN/$ENGINE" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${ENGINE_ARGS_FILE:-/dev/null}"
a=("$@")
for ((i=0; i<${#a[@]}; i++)); do
  [ "${a[$i]}" = "--env-file" ] && cp "${a[$((i+1))]}" "$ENGINE_ARGS_FILE.env"
done
exit 0
EOF
  chmod +x "$STUBBIN/$ENGINE"
}

approve() { local sd; sd="$(state_dir "$1")"; mkdir -p "$sd"; printf '%s\n' "$2" >> "$sd/approved-shares${3:-}"; }
shared() { engine_args | grep -q -- "$SHARE_BASE/$1:$SHARE_BASE/$1:"; }
# bats ignores a non-final `! cmd`, so negative checks must fail explicitly.
refute_shared() { if shared "$1"; then echo "unexpectedly shared: $1"; return 1; fi; }

@test "an approved share that later becomes a symlink out of the base is not mounted" {
  p="$(mkproj swap)"
  mkdir -p "$SHARE_BASE/repo" "$BATS_TEST_TMPDIR/elsewhere"
  write_config "$p" "share = repo"
  approve "$p" repo
  _launch "$p" >/dev/null 2>&1
  shared repo                                             # control: mounted while plain
  rm -rf "$SHARE_BASE/repo"; ln -s "$BATS_TEST_TMPDIR/elsewhere" "$SHARE_BASE/repo"
  : > "$ENGINE_ARGS_FILE"
  run _launch "$p"
  [[ "$output" == *"not a plain path"* ]]
  refute_shared repo
  [[ "$(engine_args)" != *"elsewhere"* ]]
}

@test "a symlink anywhere below the base refuses the share, rw included" {
  p="$(mkproj mid)"
  mkdir -p "$BATS_TEST_TMPDIR/real/inner"
  ln -s "$BATS_TEST_TMPDIR/real" "$SHARE_BASE/link"
  write_config "$p" "share_rw = link/inner"
  approve "$p" link/inner -rw
  run _launch "$p"
  [[ "$output" == *"not a plain path"* ]]
  [[ "$(engine_args)" != *"inner:"* ]]
}

@test "a symlinked share base is fine: the base is host-set" {
  mkdir -p "$BATS_TEST_TMPDIR/realbase/repo"
  rmdir "$SHARE_BASE"; ln -s "$BATS_TEST_TMPDIR/realbase" "$SHARE_BASE"
  p="$(mkproj base)"
  write_config "$p" "share = repo"
  approve "$p" repo
  _launch "$p" >/dev/null 2>&1
  shared repo
}

@test "a share holding the ssh agent socket is refused" {
  p="$(mkproj agent)"
  mkdir -p "$SHARE_BASE/repo/tmp"
  python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$SHARE_BASE/repo/tmp/agent.sock"
  export TEST_SSH_AUTH_SOCK="$SHARE_BASE/repo/tmp/agent.sock"
  write_config "$p" "share = repo"
  approve "$p" repo
  run _launch "$p"
  [[ "$output" == *"overlaps protected"* ]]
  refute_shared repo
}

@test "a share holding gpg's home (wherever gpgconf says it is) is refused" {
  p="$(mkproj gpg)"
  mkdir -p "$SHARE_BASE/repo/gnupg"
  cat > "$STUBBIN/gpgconf" <<EOF
#!/usr/bin/env bash
[ "\$2" = homedir ] && echo "$SHARE_BASE/repo/gnupg"
[ "\$2" = socketdir ] && echo "$BATS_TEST_TMPDIR/nowhere"
exit 0
EOF
  chmod +x "$STUBBIN/gpgconf"
  write_config "$p" "share = repo"
  approve "$p" repo
  run _launch "$p"
  [[ "$output" == *"overlaps protected"* ]]
  refute_shared repo
}

@test "AIRLOCK_PROTECTED_PATHS refuses a share that contains an entry, or is one" {
  p="$(mkproj prot)"
  mkdir -p "$SHARE_BASE/repo/run" "$SHARE_BASE/other"
  printf 'AIRLOCK_PROTECTED_PATHS="%s %s"\n' "$SHARE_BASE/repo/run" "$SHARE_BASE/other" > "$CFG"
  write_config "$p" "share = repo other"
  approve "$p" repo; approve "$p" other
  run _launch "$p"
  refute_shared repo
  refute_shared other
  [[ "$output" == *"overlaps protected"* ]]
}

@test "shares with no protected overlap still mount (control)" {
  p="$(mkproj ok)"
  mkdir -p "$SHARE_BASE/repo"
  printf 'AIRLOCK_PROTECTED_PATHS="%s"\n' "$BATS_TEST_TMPDIR/unrelated" > "$CFG"
  write_config "$p" "share = repo"
  approve "$p" repo
  _launch "$p" >/dev/null 2>&1
  shared repo
}

@test "airlock mount refuses a directory holding the ssh agent socket" {
  p="$(mkproj mnt)"
  mkdir -p "$H/stuff"; chmod 700 "$H/stuff"
  python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$H/stuff/agent.sock"
  export TEST_SSH_AUTH_SOCK="$H/stuff/agent.sock"
  run _launch "$p" mount add "$H/stuff"
  [ "$status" -ne 0 ]
  [[ "$output" == *"overlaps protected"* ]]
}

@test "secret set refuses a pass entry matching AIRLOCK_SECRET_DENY" {
  p="$(mkproj sdeny)"
  printf 'AIRLOCK_SECRET_DENY="github/* other/exact"\n' > "$CFG"
  for e in github/gh_token github/otto-app-private-key other/exact; do
    run _launch "$p" secret set KEY "pass:$e"
    [ "$status" -ne 0 ] || { echo "accepted $e"; false; }
    [[ "$output" == *"AIRLOCK_SECRET_DENY"* ]]
  done
  [ ! -s "$(state_dir "$p")/secrets" ]
}

@test "a denied entry already in the store stops the launch before the engine runs" {
  p="$(mkproj sstore)"
  sd="$(state_dir "$p")"; mkdir -p "$sd"; printf 'TOK=pass:github/gh_token\n' > "$sd/secrets"
  printf 'AIRLOCK_SECRET_DENY="github/*"\n' > "$CFG"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"AIRLOCK_SECRET_DENY"* ]]
  [ ! -s "$ENGINE_ARGS_FILE" ]
}

@test "with no deny list, pass and literal secrets inject as before" {
  p="$(mkproj snormal)"
  _launch "$p" secret set TOK pass:github/gh_token
  _launch "$p" secret set LIT hunter2
  _launch "$p" >/dev/null 2>&1
  grep -qx 'TOK=stub-secret-for-github/gh_token' "$ENGINE_ARGS_FILE.env"
  grep -qx 'LIT=hunter2' "$ENGINE_ARGS_FILE.env"
}

@test "a deny list leaves entries it does not match, and literals, alone" {
  p="$(mkproj spartial)"
  printf 'AIRLOCK_SECRET_DENY="github/*"\n' > "$CFG"
  _launch "$p" secret set MCP pass:mcp/foo
  _launch "$p" secret set LIT github/looks-like-a-path
  _launch "$p" >/dev/null 2>&1
  grep -qx 'MCP=stub-secret-for-mcp/foo' "$ENGINE_ARGS_FILE.env"
  grep -qx 'LIT=github/looks-like-a-path' "$ENGINE_ARGS_FILE.env"
}

@test "deny globs are not expanded against the filesystem" {
  p="$(mkproj sglob)"
  mkdir -p "$p/github"; : > "$p/github/decoy"
  printf 'AIRLOCK_SECRET_DENY="github/*"\n' > "$CFG"
  run _launch "$p" secret set KEY pass:github/gh_token
  [ "$status" -ne 0 ]
}

@test "a share inside an AIRLOCK_PROTECTED_PATHS entry is refused" {
  p="$(mkproj inside)"
  mkdir -p "$SHARE_BASE/vault/sub"
  printf 'AIRLOCK_PROTECTED_PATHS="%s"\n' "$SHARE_BASE/vault" > "$CFG"
  write_config "$p" "share = vault/sub"
  approve "$p" vault/sub
  run _launch "$p"
  [[ "$output" == *"overlaps protected"* ]]
  refute_shared vault/sub
}

@test "a share that is exactly a protected path is refused" {
  p="$(mkproj exact)"
  mkdir -p "$SHARE_BASE/vault"
  printf 'AIRLOCK_PROTECTED_PATHS="%s"\n' "$SHARE_BASE/vault" > "$CFG"
  write_config "$p" "share = vault"
  approve "$p" vault
  run _launch "$p"
  [[ "$output" == *"overlaps protected"* ]]
  refute_shared vault
}

@test "AIRLOCK_PROTECTED_PATHS expands ~/" {
  p="$(mkproj tilde)"
  mkdir -p "$SHARE_BASE/repo" "$H/prot"
  ln -s "$SHARE_BASE/repo" "$H/prot/link-to-repo" 2>/dev/null || true
  printf 'AIRLOCK_PROTECTED_PATHS="~/prot/link-to-repo"\n' > "$CFG"
  write_config "$p" "share = repo"; approve "$p" repo
  run _launch "$p"
  [[ "$output" == *"overlaps protected"* ]]
  refute_shared repo
}

@test "a / entry protects everything, a relative entry fails closed" {
  p="$(mkproj slash)"
  mkdir -p "$SHARE_BASE/repo"
  write_config "$p" "share = repo"; approve "$p" repo
  printf 'AIRLOCK_PROTECTED_PATHS="/"\n' > "$CFG"
  run _launch "$p"
  refute_shared repo
  : > "$ENGINE_ARGS_FILE"
  printf 'AIRLOCK_PROTECTED_PATHS="relative/path"\n' > "$CFG"
  run _launch "$p"
  [[ "$output" == *"not absolute"* ]]
  refute_shared repo
}

@test "a share inside one of the project's share_rw folders is refused" {
  p="$(mkproj nest)"
  mkdir -p "$SHARE_BASE/rw/sub"
  write_config "$p" "share_rw = rw
share = rw/sub"
  approve "$p" rw -rw; approve "$p" rw/sub
  run _launch "$p"
  [[ "$output" == *"inside share_rw"* ]]
  refute_shared rw/sub
  shared rw
}

@test "a share swapped for a symlink during pinentry is caught before the engine runs" {
  p="$(mkproj toctou)"
  mkdir -p "$SHARE_BASE/repo" "$H/.ssh"
  write_config "$p" "share = repo"; approve "$p" repo
  # pass runs after the share gate and before the engine: swap the share there.
  printf '#!/usr/bin/env bash\nrm -rf "%s"; ln -s "%s" "%s"\necho swapped\n' \
    "$SHARE_BASE/repo" "$H/.ssh" "$SHARE_BASE/repo" > "$STUBBIN/pass"
  chmod +x "$STUBBIN/pass"
  _launch "$p" secret set K pass:x >/dev/null
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"changed after it was checked"* ]]
  [ ! -s "$ENGINE_ARGS_FILE" ]
}

@test "the deny glob matches the entry pass would actually read" {
  p="$(mkproj norm)"
  printf 'AIRLOCK_SECRET_DENY="github/*"\n' > "$CFG"
  for e in /github/gh_token ./github/gh_token github//gh_token github/./gh_token ././github/gh_token; do
    run _launch "$p" secret set KEY "pass:$e"
    [ "$status" -ne 0 ] || { echo "accepted $e"; false; }
  done
}

@test "~/.keychain (where keychain keeps the ssh agent socket) cannot be mounted" {
  p="$(mkproj keych)"
  mkdir -p "$H/.keychain"; chmod 700 "$H/.keychain"
  run _launch "$p" mount add "$H/.keychain"
  [ "$status" -ne 0 ]
  [[ "$output" == *"protected"* ]]
}

@test "a real directory renamed into a share's place is caught before the engine runs" {
  p="$(mkproj rename)"
  mkdir -p "$SHARE_BASE/repo" "$SHARE_BASE/other"
  write_config "$p" "share = repo"; approve "$p" repo
  # No symlink: a different real directory now sits at the approved path.
  printf '#!/usr/bin/env bash\nmv "%s" "%s.old"; mv "%s" "%s"\necho swapped\n' \
    "$SHARE_BASE/repo" "$SHARE_BASE/repo" "$SHARE_BASE/other" "$SHARE_BASE/repo" > "$STUBBIN/pass"
  chmod +x "$STUBBIN/pass"
  _launch "$p" secret set K pass:x >/dev/null
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"changed after it was checked"* ]]
  [ ! -s "$ENGINE_ARGS_FILE" ]
}

@test "an AIRLOCK_ROOTS entry holding a protected location is not mounted" {
  p="$(mkproj roots)"
  mkdir -p "$BATS_TEST_TMPDIR/rootdir/vault"
  printf 'AIRLOCK_PROTECTED_PATHS="%s"\n' "$BATS_TEST_TMPDIR/rootdir/vault" > "$CFG"
  printf 'AIRLOCK_ROOTS="%s"\n' "$BATS_TEST_TMPDIR/rootdir" >> "$CFG"
  run _launch "$p"
  [[ "$output" == *"AIRLOCK_ROOTS entry"* ]]
  if engine_args | grep -q "/roots/rootdir"; then echo "root mounted"; false; fi
}
