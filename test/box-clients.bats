#!/usr/bin/env bats
# Box clients in the proxy posture: the proxy's client manifest (<listener>.clients next to its
# socket, written by airlock-envoy) names the hosts the box reaches by plain HTTP. The launcher
# points the box's git (url.insteadOf in the box's own gitconfig) and gh (a box-only config
# that talks over the socket, a placeholder token) at them. What matters most: the manifest
# ends up in git config, so a file that is not root's, or has any line out of form, is not
# used at all, and the launch goes on without it.
#
# Same socket fixtures as egress-proxy.bats: a `stat` stub reports owners from $FAKE_OWNERS.

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
  S="$SD/work.sock"
  M="$SD/work.clients"
  svcsock "$S"
  P="$(mkproj bc)"
  _launch "$P" egress proxy "$S" >/dev/null
  # The box config lives as long as its session, which the stub engine ends at once: the
  # stub snapshots each mounted box config (and where it was) before the launcher cleans up.
  SNAP="$BATS_TEST_TMPDIR/snap"
  for e in podman docker; do
    mv "$STUBBIN/$e" "$STUBBIN/$e.orig"
    cat > "$STUBBIN/$e" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = run ]; then
  rm -rf "$SNAP"; mkdir -p "$SNAP"
  for a in "\$@"; do
    case "\$a" in
      *:/home/dev/.gitconfig:rw) cp "\${a%%:*}" "$SNAP/gitconfig"; echo "\${a%%:*}" > "$SNAP/gitconfig.src" ;;
      *:/etc/airlock-box/gh:ro) cp -r "\${a%%:*}" "$SNAP/gh"; echo "\${a%%:*}" > "$SNAP/gh.src" ;;
    esac
  done
fi
exec "$STUBBIN/$e.orig" "\$@"
EOF
    chmod +x "$STUBBIN/$e"
  done
}

mksock() { python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"; }
owns() { printf '%s %s\n' "$1" "$2" >> "$FAKE_OWNERS"; }
rootdirs() { local d="$1"; while :; do owns 0 "$d"; [ "$d" = / ] && break; d="$(dirname "$d")"; done; }
svcsock() { mksock "$1"; owns "$SVC" "$1"; }
launched() { engine_args | grep -q '^ENGINE_INVOKED='; }
has_arg() { engine_args | grep -qx -- "$1"; }
arg_matches() { engine_args | grep -q -- "$1"; }
gitcfg() { cat "$SNAP/gitconfig" 2>/dev/null; }
# A manifest as airlock-envoy writes it: root's, 0644. Body as printf %b.
manifest() {
  printf '# airlock-envoy: the plain-HTTP hosts of listener work\n%b' "$1" > "$M"
  chmod 644 "$M"; owns 0 "$M"
}
host_config() { mkdir -p "$AIRLOCK_HOME/.config/claude-airlock"; printf '%s\n' "$1" > "$AIRLOCK_HOME/.config/claude-airlock/config"; }
# What the box's git makes of a remote URL, with only the box gitconfig in play.
box_url() {
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$SNAP/gitconfig" HOME=/nonexistent \
    git -C / ls-remote --get-url "$1"
}
no_clients() {
  launched                                       || { echo "engine not invoked"; return 1; }
  refute grep -q '^\[url' <<< "$(gitcfg)"
  refute grep -qi -e core -e sshcommand <<< "$(gitcfg)"
  refute arg_matches '^GH_TOKEN='
  refute arg_matches '^GH_CONFIG_DIR='
  refute arg_matches 'airlock-box/gh'
}

@test "no manifest: the box's git and gh are left alone" {
  _launch "$P" >/dev/null 2>&1 || true
  no_clients
}

@test "a manifest: git remotes of its git hosts become http:// in the box gitconfig, others untouched" {
  manifest 'git.example.org 443 git yes\nmetrics.example.org 443 victoria-metrics no\ngithub.com 443 git-read no\nany.example.org 8443 any yes\n'
  _launch "$P" >/dev/null 2>&1 || true
  launched
  arg_matches '/box-config\.[0-9]*\.[0-9]*/gitconfig:/home/dev/.gitconfig:rw$'
  [ "$(box_url git@git.example.org:o/r.git)" = http://git.example.org/o/r.git ]
  [ "$(box_url ssh://git.example.org/o/r.git)" = http://git.example.org/o/r.git ]
  [ "$(box_url git+ssh://git@git.example.org/o/r.git)" = http://git.example.org/o/r.git ]
  [ "$(box_url https://git.example.org:443/o/r.git)" = http://git.example.org/o/r.git ]
  [ "$(box_url ssh://git@git.example.org/o/r.git)" = http://git.example.org/o/r.git ]
  [ "$(box_url https://git.example.org/o/r.git)" = http://git.example.org/o/r.git ]
  [ "$(box_url git@github.com:cli/cli.git)" = http://github.com/cli/cli.git ]
  [ "$(box_url https://any.example.org/x)" = http://any.example.org/x ]
  # Not a git host (victoria-metrics), and a host not in the manifest: as they were.
  [ "$(box_url https://metrics.example.org/x)" = https://metrics.example.org/x ]
  [ "$(box_url git@gitlab.com:o/r.git)" = git@gitlab.com:o/r.git ]
  # An ssh port the host config doesn't name: not rewritten.
  [ "$(box_url ssh://git@git.example.org:2222/o/r.git)" = ssh://git@git.example.org:2222/o/r.git ]
  # gh is not configured without api.github.com.
  refute arg_matches '^GH_TOKEN='
}

@test "AIRLOCK_GIT_SSH_PORTS: remotes on those ssh ports are rewritten too; a bad entry is named and skipped" {
  host_config 'AIRLOCK_GIT_SSH_PORTS="2222 x 0 65536"'
  manifest 'git.example.org 443 git yes\n'
  run _launch "$P"
  [[ "$output" == *"ignoring AIRLOCK_GIT_SSH_PORTS entry 'x'"* ]]
  [[ "$output" == *"entry '0'"* && "$output" == *"entry '65536'"* ]]
  [ "$(box_url ssh://git@git.example.org:2222/o/r.git)" = http://git.example.org/o/r.git ]
  [ "$(box_url ssh://git@git.example.org:22/o/r.git)" = ssh://git@git.example.org:22/o/r.git ]
}

@test "the git identity stays alongside the rewrites" {
  host_config 'AIRLOCK_GIT_NAME="Box User"
AIRLOCK_GIT_EMAIL=box@example.org'
  manifest 'git.example.org 443 git yes\n'
  _launch "$P" >/dev/null 2>&1 || true
  [ "$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$SNAP/gitconfig" git config --global user.email)" = box@example.org ]
  [ "$(box_url git@git.example.org:o/r)" = http://git.example.org/o/r ]
}

@test "api.github.com in the manifest: a read-only box gh config over the socket, and a placeholder token" {
  manifest 'api.github.com 443 github-api yes\n'
  run _launch "$P"
  launched
  arg_matches '/box-config\.[0-9]*\.[0-9]*/gh:/etc/airlock-box/gh:ro$'
  has_arg GH_CONFIG_DIR=/etc/airlock-box/gh
  has_arg GH_TOKEN=airlock-proxy-adds-the-credential
  grep -qx "http_unix_socket: '$S'" "$SNAP/gh/config.yml"
  grep -qx 'git_protocol: https' "$SNAP/gh/config.yml"
  [[ "$output" != *"no credential for api.github.com"* ]]
  # gh itself reads it that way.
  if command -v gh >/dev/null; then
    [ "$(GH_CONFIG_DIR="$SNAP/gh" gh config get http_unix_socket)" = "$S" ]
  fi
}

@test "api.github.com without a credential: gh is not set up (GitHub would refuse the placeholder), and said" {
  manifest 'api.github.com 443 github-api no\ngithub.com 443 git-read no\n'
  run _launch "$P"
  launched
  [[ "$output" == *"no credential for api.github.com, so gh is not set up"* ]]
  refute arg_matches '^GH_TOKEN='
  refute arg_matches 'airlock-box/gh'
  [ "$(box_url git@github.com:cli/cli.git)" = http://github.com/cli/cli.git ]   # git still is
}

@test "other GitHub token secrets in the box are named too" {
  manifest 'api.github.com 443 github-api yes\n'
  _launch "$P" secret set GITHUB_TOKEN real-token-value >/dev/null
  run _launch "$P"
  has_arg GH_TOKEN=airlock-proxy-adds-the-credential
  [[ "$output" == *"secret(s) GITHUB_TOKEN put a token in the box too"* ]]
}

@test "each session has its own box config, gone when it ends; a dead session's is swept; the old shared file goes" {
  manifest 'git.example.org 443 git yes\napi.github.com 443 github-api yes\n'
  sd="$(state_dir "$P")"
  mkdir -p "$sd/box-config.999999.1" "$sd/box-config.1.1"; : > "$sd/gitconfig"
  _launch "$P" >/dev/null 2>&1 || true
  src="$(cat "$SNAP/gitconfig.src")"
  [[ "$src" == "$sd"/box-config.*/gitconfig ]]
  [ "$(dirname "$(cat "$SNAP/gh.src")")" = "$(dirname "$src")" ]
  [ ! -e "$(dirname "$src")" ]                       # removed at the session's end
  [ ! -e "$sd/box-config.999999.1" ] && [ ! -e "$sd/box-config.1.1" ] && [ ! -e "$sd/gitconfig" ]
  # The next launch writes a fresh one at another path: a running box keeps what it got.
  _launch "$P" >/dev/null 2>&1 || true
  [ "$(cat "$SNAP/gitconfig.src")" != "$src" ]
}

@test "a GH_TOKEN secret is not overridden by the placeholder, and the launch says it is needless" {
  manifest 'api.github.com 443 github-api yes\n'
  _launch "$P" secret set GH_TOKEN real-token-value >/dev/null
  run _launch "$P"
  launched
  refute arg_matches '^GH_TOKEN='
  [[ "$output" == *"secret GH_TOKEN puts one in the box too"* ]]
}

@test "a malformed manifest is not used at all, and the box still launches" {
  local bad
  for bad in \
    'git.example.org 443 git yes\n[core]\n\tsshCommand = touch /tmp/pwned\n' \
    'git.example.org 443 git yes\n[url "http://evil.example/"]\n' \
    'Git.example.org 443 git yes\n' \
    'git.example.org 443 git yes extra\n' \
    'git.example.org 443 git yes\r\n' \
    'git.example.org\t443 git yes\n' \
    ' git.example.org 443 git yes\n' \
    'git.example.org" 443 git yes\n' \
    'git.example.org/x 443 git yes\n' \
    '-x.example.org 443 git yes\n' \
    'x..example.org 443 git yes\n' \
    'localhost 443 git yes\n' \
    '10.0.0.1 443 git yes\n' \
    'git.example.org 0443 git yes\n' \
    'git.example.org 443 git maybe\n' \
    'git.example.org 443 Git yes\n' \
    'ok.example.org 443 git yes\ngit.example.org 443\n'; do
    manifest "$bad"
    : > "$ENGINE_ARGS_FILE"
    run _launch "$P"
    [[ "$output" == *"ignoring $M: line"*"box clients not set up for the proxy"* ]] || { echo "not refused: $bad"; echo "$output"; return 1; }
    no_clients || { echo "used: $bad"; return 1; }
    refute grep -q -e ok.example.org -e evil <<< "$(gitcfg)"
  done
}

@test "a manifest that is not root's, is group- or world-writable, is a symlink, or is too big: not used" {
  manifest 'git.example.org 443 git yes\n'
  sed -i "\\# $M\$#d" "$FAKE_OWNERS"; owns 1000 "$M"
  run _launch "$P"
  [[ "$output" == *"ignoring $M: it and its directory must be root's"* ]]; no_clients

  : > "$ENGINE_ARGS_FILE"
  manifest 'git.example.org 443 git yes\n'; chmod 664 "$M"
  run _launch "$P"
  [[ "$output" == *"ignoring $M: it and its directory must be root's"* ]]; no_clients

  : > "$ENGINE_ARGS_FILE"
  manifest 'git.example.org 443 git yes\n'; chmod 646 "$M"
  run _launch "$P"
  [[ "$output" == *"ignoring $M"* ]]; no_clients

  : > "$ENGINE_ARGS_FILE"
  rm -f "$M"; printf 'git.example.org 443 git yes\n' > "$SD/real"; ln -s "$SD/real" "$M"
  run _launch "$P"
  [[ "$output" == *"ignoring $M: not a regular file"* ]]; no_clients

  : > "$ENGINE_ARGS_FILE"
  rm -f "$M"; manifest "$(printf '# %.0s' $(seq 40000))\ngit.example.org 443 git yes\n"
  run _launch "$P"
  [[ "$output" == *"ignoring $M: over 64 KiB"* ]]; no_clients
}

@test "not in the proxy posture: a manifest next to some socket is never read" {
  manifest 'git.example.org 443 git yes\napi.github.com 443 github-api yes\n'
  _launch "$P" egress minimal >/dev/null
  _launch "$P" >/dev/null 2>&1 || true
  no_clients
}

@test "a launch with hosts, then one without: the rewrites and gh config do not linger" {
  manifest 'git.example.org 443 git yes\napi.github.com 443 github-api yes\n'
  _launch "$P" >/dev/null 2>&1 || true
  grep -q '^\[url' <<< "$(gitcfg)"
  manifest ''
  : > "$ENGINE_ARGS_FILE"
  _launch "$P" >/dev/null 2>&1 || true
  no_clients
  refute arg_matches ':/home/dev/.gitconfig:rw$'
}

@test "egress show lists the proxy's plain-HTTP hosts" {
  manifest 'git.example.org 443 git yes\nmetrics.example.org 443 victoria-metrics no\n'
  run _launch "$P" egress show
  [[ "$output" == *"plain HTTP through the proxy"* ]]
  [[ "$output" == *"git.example.org (rules git, credential yes)"* ]]
  [[ "$output" == *"metrics.example.org (rules victoria-metrics, credential no)"* ]]
  manifest 'Bad.example.org 443 git yes\n'
  run _launch "$P" egress show
  [[ "$output" == *"plain HTTP through the proxy: not set up (ignoring $M: line 2 is not"* ]]
}
