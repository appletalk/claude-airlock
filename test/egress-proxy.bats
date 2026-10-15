#!/usr/bin/env bats
# The 'proxy' egress posture: no network, everything through one host proxy socket. What
# matters most is that it fails CLOSED (no socket, no launch; never a quiet fall back to a
# network) and that nothing the box can write moves a project in or out of it.
#
# The socket rule needs a service-owned socket in root-owned directories; the same `stat`
# stub as socket.bats reports owners from $FAKE_OWNERS.

load helper
setup() {
  setup_airlock_env
  SVC=777
  export FAKE_OWNERS="$BATS_TEST_TMPDIR/owners"
  export FAKE_FSTYPE=tmpfs
  : > "$FAKE_OWNERS"
  cat > "$STUBBIN/stat" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = -f ] && [ -n "${FAKE_FSTYPE:-}" ]; then echo "$FAKE_FSTYPE"; exit 0; fi
if [ "$1" = -c ] && [ "$2" = %u ] && [ -s "${FAKE_OWNERS:-}" ]; then
  u="$(awk -v p="$3" '{ q = $0; sub(/^[^ ]+ /, "", q) } q == p { u = $1 } END { print u }' "$FAKE_OWNERS")"
  [ -n "$u" ] && { echo "$u"; exit 0; }
fi
exec /usr/bin/stat "$@"
STUB
  chmod +x "$STUBBIN/stat"
  SD="$BATS_TEST_TMPDIR/svc"
  mkdir -p "$SD"; chmod 755 "$SD"
  rootdirs "$SD"
  S="$SD/anthropic.sock"
  svcsock "$S"
}

mksock() { python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"; }
owns() { printf '%s %s\n' "$1" "$2" >> "$FAKE_OWNERS"; }
rootdirs() { local d="$1"; while :; do owns 0 "$d"; [ "$d" = / ] && break; d="$(dirname "$d")"; done; }
svcsock() { mksock "$1"; owns "$SVC" "$1"; }
launched() { engine_args | grep -q '^ENGINE_INVOKED='; }
has_arg() { engine_args | grep -qx -- "$1"; }
arg_matches() { engine_args | grep -q -- "$1"; }
mode_file() { cat "$(state_dir "$1")/egress-mode" 2>/dev/null; }

# Every property of a proxy-mode box's argv, for whichever engine ran.
assert_proxy_box() {
  launched                                      || { echo "engine not invoked"; return 1; }
  has_arg --network=none                        || { echo "no --network=none: $(engine_args | grep -- '^--network')"; return 1; }
  has_arg "$S:$S:ro"                            || { echo "proxy socket not mounted read-only"; return 1; }
  has_arg "AIRLOCK_EGRESS_PROXY=$S"             || { echo "AIRLOCK_EGRESS_PROXY not passed"; return 1; }
  has_arg "AIRLOCK_EGRESS_GROUPS="              || { echo "groups not empty"; return 1; }
  refute has_arg --cap-add=NET_ADMIN
  refute has_arg --cap-add=NET_RAW
  refute arg_matches '^--dns='
  refute arg_matches '^AIRLOCK_HOST_DNS='
  refute arg_matches '^AIRLOCK_EXTRA_EGRESS='
  [ "$(engine_args | grep -c -- '^--network')" = 1 ] || { echo "more than one --network"; return 1; }
}

@test "egress proxy SOCKET stores the posture host-side, and show reports it" {
  p="$(mkproj px)"
  run _launch "$p" egress proxy "$S"
  [ "$status" -eq 0 ]
  [[ "$output" == *"proxy via $S"* ]]
  [ "$(mode_file "$p")" = "proxy $S" ]
  run _launch "$p" egress show
  [[ "$output" == *"posture: proxy"* ]]
  [[ "$output" == *"proxy socket: $S"* ]]
  [[ "$output" != *"REFUSED"* ]]
  [[ "$output" == *"network: none"* ]]
}

@test "a launch in proxy mode: no network, no firewall capabilities, no resolver, socket bridged" {
  p="$(mkproj pl)"
  _launch "$p" egress proxy "$S"
  _launch "$p" >/dev/null 2>&1 || true
  assert_proxy_box
  [ ! -e "$ENGINE_ARGS_FILE.probed" ]           # pasta is never asked about
}

@test "both engines get --network=none in proxy mode" {
  for e in podman docker; do
    p="$(mkproj "pe-$e")"
    : > "$ENGINE_ARGS_FILE"
    AIRLOCK_ENGINE_OVERRIDE="$e" _launch "$p" egress proxy "$S"
    AIRLOCK_ENGINE_OVERRIDE="$e" _launch "$p" >/dev/null 2>&1 || true
    [ "$(invoked_engine)" = "$e" ] || { echo "$e: ran $(invoked_engine)"; false; }
    assert_proxy_box || { echo "($e)"; false; }
  done
}

@test "the other postures keep their network and firewall capabilities" {
  p="$(mkproj pm)"
  _launch "$p" >/dev/null 2>&1 || true
  has_arg --cap-add=NET_ADMIN
  has_arg --cap-add=NET_RAW
  refute has_arg --network=none
  refute arg_matches '^AIRLOCK_EGRESS_PROXY='
}

@test "fails closed: the socket gone at launch means no launch, never a network" {
  p="$(mkproj pg)"
  _launch "$p" egress proxy "$S"
  rm -f "$S"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not launching"* || "$output" == *"Not launching"* ]]
  refute launched
}

@test "fails closed: a socket that no longer passes the rule (now owned by you) means no launch" {
  p="$(mkproj po)"
  _launch "$p" egress proxy "$S"
  owns "$(id -u)" "$S"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"owned by you"* ]]
  refute launched
}

@test "fails closed: an image without the proxy entrypoint is refused" {
  p="$(mkproj pi)"
  _launch "$p" egress proxy "$S"
  : > "$ENGINE_ARGS_FILE"
  STUB_IMAGE_EGRESS_PROXY="" run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"predates the proxy posture"* ]]
  refute launched
}

@test "egress proxy refuses a socket that fails the rule, and writes nothing" {
  p="$(mkproj pr)"
  mksock "$SD/mine.sock"; owns "$(id -u)" "$SD/mine.sock"
  run _launch "$p" egress proxy "$SD/mine.sock"
  [ "$status" -ne 0 ]
  [[ "$output" == *"owned by you"* ]]
  [ -z "$(mode_file "$p")" ]
  run _launch "$p" egress proxy "$SD/absent.sock"
  [ "$status" -ne 0 ]
  [ -z "$(mode_file "$p")" ]
}

@test "egress proxy with no socket and no AIRLOCK_EGRESS_PROXY is a usage error" {
  p="$(mkproj pn)"
  run _launch "$p" egress proxy
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: airlock egress proxy SOCKET"* ]]
  [ -z "$(mode_file "$p")" ]
}

@test "egress proxy with no socket takes AIRLOCK_EGRESS_PROXY, and stores it explicitly" {
  p="$(mkproj pd)"
  TEST_EGRESS_PROXY="$S" run _launch "$p" egress proxy
  [ "$status" -eq 0 ]
  [ "$(mode_file "$p")" = "proxy $S" ]
}

@test "AIRLOCK_EGRESS_MODE=proxy makes it the default for a project with no posture of its own" {
  p="$(mkproj pdef)"
  TEST_EGRESS_MODE=proxy TEST_EGRESS_PROXY="$S" _launch "$p" >/dev/null 2>&1 || true
  assert_proxy_box
}

@test "AIRLOCK_EGRESS_MODE=proxy without a socket refuses to launch" {
  p="$(mkproj pnone)"
  TEST_EGRESS_MODE=proxy run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"names no socket"* ]]
  refute launched
}

@test "a project that overrides a proxy default is called out at launch and in show" {
  p="$(mkproj pov)"
  _launch "$p" egress dev
  TEST_EGRESS_MODE=proxy TEST_EGRESS_PROXY="$S" run _launch "$p"
  [[ "$output" == *"not the proxy (host default)"* ]]
  has_arg --cap-add=NET_ADMIN
  TEST_EGRESS_MODE=proxy TEST_EGRESS_PROXY="$S" run _launch "$p" egress show
  [[ "$output" == *"this project overrides it"* ]]
}

@test "box-written egress = lines are ignored in proxy mode: no prompt, no grant, a warning" {
  p="$(mkproj pq)"
  write_config "$p" "egress = evil.example.com"
  _launch "$p" egress proxy "$S"
  run _launch "$p"
  [[ "$output" == *"ignoring .airlock/config 'egress ='"* ]]
  [[ "$output" != *"Allow the sandbox to reach"* ]]
  [ ! -s "$(state_dir "$p")/approved-egress" ]
  assert_proxy_box
}

@test "host AIRLOCK_EXTRA_EGRESS is ignored in proxy mode, with a warning" {
  p="$(mkproj px2)"
  _launch "$p" egress proxy "$S"
  TEST_EXTRA_EGRESS=registry.example.com run _launch "$p"
  [[ "$output" == *"ignoring AIRLOCK_EXTRA_EGRESS"* ]]
  assert_proxy_box
}

@test "add and rm are refused in proxy mode and leave the posture alone" {
  p="$(mkproj pa)"
  _launch "$p" egress proxy "$S"
  for op in add rm; do
    run _launch "$p" egress "$op" github
    [ "$status" -ne 0 ]
    [[ "$output" == *"groups do not apply"* ]]
    [ "$(mode_file "$p")" = "proxy $S" ]
  done
}

@test "setting another posture leaves proxy mode, says so, and the box gets its network back" {
  for to in minimal dev github; do
    p="$(mkproj "pl-$to")"
    _launch "$p" egress proxy "$S"
    run _launch "$p" egress "$to"
    [ "$status" -eq 0 ]
    [[ "$output" == *"leaves proxy mode"* ]] || { echo "$to: $output"; false; }
    : > "$ENGINE_ARGS_FILE"
    _launch "$p" >/dev/null 2>&1 || true
    refute has_arg --network=none
    has_arg --cap-add=NET_ADMIN
  done
}

@test "a proxy socket also granted with 'airlock socket add' is mounted once" {
  p="$(mkproj pdup)"
  _launch "$p" socket add "$S"
  _launch "$p" egress proxy "$S"
  _launch "$p" >/dev/null 2>&1 || true
  [ "$(engine_args | grep -cx -- "$S:$S:ro")" = 1 ]
  assert_proxy_box
}

@test "a socket path with whitespace is refused" {
  p="$(mkproj pw)"
  run _launch "$p" egress proxy "$SD/a b.sock"
  [ "$status" -ne 0 ]
  [ -z "$(mode_file "$p")" ]
}

@test "the workspace cannot reach the posture: state is outside it and cannot be mounted" {
  p="$(mkproj pws)"
  _launch "$p" egress proxy "$S"
  case "$(state_dir "$p")" in "$p"/*) false ;; esac
  run _launch "$p" mount add "$AIRLOCK_HOME/.config/claude-airlock"
  [ "$status" -ne 0 ]
}

@test "a posture the launcher does not know is refused, not read as minimal" {
  for m in Proxy proxi "proxy:$S" "github bogus"; do
    p="$(mkproj "pu-${m//[^a-z]/}")"
    : > "$ENGINE_ARGS_FILE"
    TEST_EGRESS_MODE="$m" run _launch "$p"
    [ "$status" -ne 0 ] || { echo "$m launched"; false; }
    [[ "$output" == *"is not minimal, dev, proxy or a group list"* ]]
    refute launched
    TEST_EGRESS_MODE="$m" run _launch "$p" egress show
    [[ "$output" == *"launches are REFUSED"* ]] || { echo "$m: $output"; false; }
  done
}

@test "a hand-edited stored posture that is unknown is refused too" {
  p="$(mkproj ph)"
  _launch "$p" egress minimal
  printf 'proxi %s\n' "$S" > "$(state_dir "$p")/egress-mode"
  run _launch "$p"
  [ "$status" -ne 0 ]
  refute launched
}

@test "granted sockets that bypass the proxy are named at launch and in show" {
  p="$(mkproj pgs)"
  svcsock "$SD/other.sock"
  _launch "$p" socket add "$SD/other.sock"
  _launch "$p" egress proxy "$S"
  run _launch "$p"
  [[ "$output" == *"also reachable, outside the proxy"*"$SD/other.sock"* ]]
  run _launch "$p" egress show
  [[ "$output" == *"also reachable, outside the proxy"* ]]
  [[ "$output" == *"    $SD/other.sock"* ]]
}

@test "the proxy socket itself in the socket list is not named as a bypass" {
  p="$(mkproj pgs2)"
  _launch "$p" socket add "$S"
  _launch "$p" egress proxy "$S"
  run _launch "$p"
  [[ "$output" != *"also reachable"* ]]
}

@test "a default socket path with whitespace is refused at launch" {
  p="$(mkproj pws2)"
  TEST_EGRESS_MODE=proxy TEST_EGRESS_PROXY="$SD/a b.sock" run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"contains whitespace"* ]]
  refute launched
}

@test "secrets cannot set AIRLOCK_* or *_PROXY variables, and stored ones are skipped" {
  p="$(mkproj psec)"
  for k in AIRLOCK_EGRESS_PROXY HTTPS_PROXY https_proxy NO_PROXY AIRLOCK_EXTRA_EGRESS; do
    run _launch "$p" secret set "$k" x
    [ "$status" -ne 0 ] || { echo "$k accepted"; false; }
    [[ "$output" == *"is reserved"* ]]
  done
  _launch "$p" secret set OK_KEY fine
  printf 'AIRLOCK_EGRESS_PROXY=/x.sock\nHTTPS_PROXY=http://evil:1\n' >> "$(state_dir "$p")/secrets"
  run _launch "$p"
  [[ "$output" == *"ignoring secret AIRLOCK_EGRESS_PROXY"* ]]
  [[ "$output" == *"ignoring secret HTTPS_PROXY"* ]]
}
