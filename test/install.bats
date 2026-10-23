#!/usr/bin/env bats
# bin/install.sh: the image build must not silently reuse stale layers. The Claude Code
# version already keyed its own layer; the Debian packages had no key at all, so a rebuild
# reused the first build's apt layer forever (an apt layer from July inside an image built
# in September, 17 security updates behind). These pin what fixes that: the base tag is
# re-pulled (as a step that can fail soft), the apt layer is keyed on the ISO week, and a
# forced refresh is remembered so the next install in the same week keeps it.

load helper

# Every install compares the vendored installer with upstream. Serve it the vendored copy
# by default, so no test reaches the network and an offline host stays silent (no "drift
# unknown" WARNING); the drift tests below replace this stub with their own upstream.
setup() { setup_airlock_env; _stub_upstream_installer "$BATS_TEST_DIRNAME/../image/claude-install.sh"; }

# Run install.sh hermetically: isolated HOME, stubbed engine (records argv) and curl, a pinned
# Claude Code version so it never curls upstream, and stdin not a TTY (the install reads none).
# The trailing doctor fails against the stub, so the exit status is not
# asserted - only what the build was asked to do.
_install() {
  env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" \
    AIRLOCK_ENGINE="$ENGINE" CLAUDE_CODE_VERSION=1.2.3 ENGINE_ARGS_FILE="$ENGINE_ARGS_FILE" \
    ${AIRLOCK_APT_REFRESH:+AIRLOCK_APT_REFRESH="$AIRLOCK_APT_REFRESH"} \
    bash "$BATS_TEST_DIRNAME/../bin/install.sh" </dev/null 2>"$BATS_TEST_TMPDIR/install.err" >/dev/null || true
}
week() { date +%G-W%V; }
stamp_file() { printf '%s' "$AIRLOCK_HOME/.config/claude-airlock/apt-refresh"; }

@test "the base tag is pulled as its own step and the apt layer is keyed on the ISO week" {
  _install
  args="$(engine_args)"
  [[ "$args" == *"pull"* ]]
  engine_args | grep -qx -- "debian:trixie-slim"
  [[ "$args" != *"--pull"* ]]                         # not build --pull: that cannot fail soft
  engine_args | grep -qx -- "APT_REFRESH=$(week)"
  engine_args | grep -qx -- "CLAUDE_CODE_VERSION=1.2.3"
  [ "$(cat "$(stamp_file)")" = "$(week)" ]
}

@test "a failed pull warns and the build still runs from the cached tag" {
  cat > "$STUBBIN/$ENGINE" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${ENGINE_ARGS_FILE:-/dev/null}"
[ "${1:-}" = pull ] && exit 1
exit 0
EOF
  chmod +x "$STUBBIN/$ENGINE"
  _install
  grep -q 'could not pull' "$BATS_TEST_TMPDIR/install.err"
  engine_args | grep -qx -- "APT_REFRESH=$(week)"     # the build was still issued
}

@test "AIRLOCK_APT_REFRESH overrides the weekly key (what make refresh sets) and is remembered" {
  AIRLOCK_APT_REFRESH="$(week).2026-09-22-0700" _install
  engine_args | grep -qx -- "APT_REFRESH=$(week).2026-09-22-0700"
  [ "$(cat "$(stamp_file)")" = "$(week).2026-09-22-0700" ]
}

# The regression the first version of this change had: refresh mid-week, then a plain
# install re-tagged :base onto the cached, OLDER week layer and undid the refresh.
@test "a plain install in the same week reuses the forced refresh key" {
  AIRLOCK_APT_REFRESH="$(week).2026-09-22-0700" _install
  : > "$ENGINE_ARGS_FILE"
  _install
  engine_args | grep -qx -- "APT_REFRESH=$(week).2026-09-22-0700"
  ! engine_args | grep -qx -- "APT_REFRESH=$(week)" || false
}

@test "a remembered key from an earlier week is superseded by this week's" {
  mkdir -p "$(dirname "$(stamp_file)")"
  printf '2020-W01.2020-01-01-0000\n' > "$(stamp_file)"
  _install
  engine_args | grep -qx -- "APT_REFRESH=$(week)"
  [ "$(cat "$(stamp_file)")" = "$(week)" ]
}

@test "the Dockerfile consumes the key before the apt layer and records it as a label" {
  df="$BATS_TEST_DIRNAME/../image/Dockerfile"
  arg_line="$(grep -n '^ARG APT_REFRESH' "$df" | cut -d: -f1)"
  apt_line="$(grep -n 'apt-get update && apt-get upgrade' "$df" | cut -d: -f1)"
  [ -n "$arg_line" ]
  [ -n "$apt_line" ]
  [ "$arg_line" -lt "$apt_line" ]
  grep -q 'LABEL org.claude-airlock.apt-refresh="\$APT_REFRESH"' "$df"
  # The refresh must actually upgrade what the base tag already carries, not just
  # install newer versions of the packages we add.
  grep -q 'apt-get upgrade -y' "$df"
}

# The base holds what runs Claude Code and the airlock machinery; developer tools are dev's.
@test "the base installs python3 and no developer tools; dev installs them before using git" {
  base="$BATS_TEST_DIRNAME/../image/Dockerfile"
  dev="$BATS_TEST_DIRNAME/../image/dev/Dockerfile"
  apt_pkgs() { awk '/apt-get install/{f=1} f{print} /apt-get clean/{f=0}' "$1"; }
  base_pkgs="$(apt_pkgs "$base")"
  dev_pkgs="$(apt_pkgs "$dev")"
  for p in ca-certificates curl jq python3 iptables ipset iproute2 dnsutils aggregate gosu socat; do
    grep -qE "^[[:space:]]+$p \\\\\$" <<<"$base_pkgs" || { echo "base lacks $p"; false; }
  done
  for p in git gh make less vim zsh ripgrep; do
    refute grep -qE "^[[:space:]]+$p \\\\\$" <<<"$base_pkgs"
    grep -qE "^[[:space:]]+$p \\\\\$" <<<"$dev_pkgs" || { echo "dev lacks $p"; false; }
  done
  # The bare interpreter only: pip and venv stay dev's.
  refute grep -q -e python3-pip -e python3-venv <<<"$base_pkgs"
  # dev's first use of git (the bats clone) comes after its apt layer installs it.
  apt_line="$(grep -n 'apt-get install' "$dev" | head -1 | cut -d: -f1)"
  git_line="$(grep -nE '(^|[[:space:];])git -' "$dev" | grep -v '^[0-9]*:#' | head -1 | cut -d: -f1)"
  [ -n "$apt_line" ] && [ -n "$git_line" ] && [ "$apt_line" -lt "$git_line" ]
}

@test "make refresh forces a fresh key, prefixed with the week so install can recognise it" {
  grep -qE '^refresh:' "$BATS_TEST_DIRNAME/../Makefile"
  grep -A1 '^refresh:' "$BATS_TEST_DIRNAME/../Makefile" | grep -q 'AIRLOCK_APT_REFRESH="\$\$(date +%G-W%V)\.'
}

# --- supply chain of the non-Debian layers (review F12) ------------------------------
# Everything the images download is pinned so a re-tag, a bad mirror or a changed
# dependency tree fails the build instead of shipping. These pin the pins.

@test "Claude Code is installed from the vendored installer, never piped from the network" {
  df="$BATS_TEST_DIRNAME/../image/Dockerfile"
  ! grep -qE 'curl[^|]*install\.sh[^|]*\|[[:space:]]*bash' "$df" || false
  grep -q 'COPY .*claude-install.sh' "$df"
  grep -q 'bash /tmp/claude-install.sh' "$df"
  [ -s "$BATS_TEST_DIRNAME/../image/claude-install.sh" ]
  # The vendored script verifies the binary it downloads against the release manifest.
  grep -q 'checksum' "$BATS_TEST_DIRNAME/../image/claude-install.sh"
}

@test "Node is pinned by version and per-arch sha256, not resolved at build time" {
  df="$BATS_TEST_DIRNAME/../image/dev/Dockerfile"
  grep -qE '^ARG NODE_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$df"
  refute grep -q 'nodejs.org/dist/index.json' "$df"
  awk '/ARG NODE_VERSION/{f=1} f&&/sha256sum -c/{ok=1} f&&/node --version/{exit} END{exit !ok}' "$df"
}

@test "the ansible venv installs only hash-pinned packages" {
  df="$BATS_TEST_DIRNAME/../image/dev/Dockerfile"
  req="$BATS_TEST_DIRNAME/../image/dev/ansible-requirements.txt"
  grep -q -- '--require-hashes -r /tmp/ansible-requirements.txt' "$df"
  grep -qE '^ansible-lint==[0-9]+\.[0-9]+\.[0-9]+ ' "$req"
  # every pinned package carries at least one hash
  [ "$(grep -cE '^[A-Za-z0-9_.-]+==' "$req")" -gt 20 ]
  [ "$(grep -c -- '--hash=sha256:' "$req")" -ge "$(grep -cE '^[A-Za-z0-9_.-]+==' "$req")" ]
}

# The vendored installer goes stale by design; every build must say so, loudly, without
# failing, and stay quiet when it matches. curl is stubbed to play upstream.

@test "install reports installer drift loudly and still builds" {
  printf '#!/bin/sh\necho changed upstream\n' > "$BATS_TEST_TMPDIR/upstream.sh"
  _stub_upstream_installer "$BATS_TEST_TMPDIR/upstream.sh"
  _install
  grep -q 'INSTALLER DRIFT' "$BATS_TEST_TMPDIR/install.err"
  grep -q 'make claude-installer-update' "$BATS_TEST_TMPDIR/install.err"
  engine_args | grep -qx -- "APT_REFRESH=$(week)"      # the build still ran
}

@test "install is quiet about the installer when the vendored copy matches upstream" {
  _stub_upstream_installer "$BATS_TEST_DIRNAME/../image/claude-install.sh"
  _install
  refute grep -q 'INSTALLER DRIFT' "$BATS_TEST_TMPDIR/install.err"
}

@test "install warns, without failing, when upstream cannot be fetched to compare" {
  printf '#!/bin/sh\nexit 22\n' > "$STUBBIN/curl"; chmod +x "$STUBBIN/curl"
  _install
  grep -q 'drift unknown' "$BATS_TEST_TMPDIR/install.err"
  engine_args | grep -qx -- "APT_REFRESH=$(week)"
}

@test "make has diff and update targets for the vendored installer" {
  grep -qE '^claude-installer-diff:' "$BATS_TEST_DIRNAME/../Makefile"
  grep -qE '^claude-installer-update:' "$BATS_TEST_DIRNAME/../Makefile"
}

# --- the installed copy -------------------------------------------------------------
# The launcher runs from an export of one commit under ~/.local/share, never the working
# tree. These run install.sh from a throwaway clone so the tests control its commits.

IROOT() { printf '%s' "$AIRLOCK_HOME/.local/share/claude-airlock"; }
# Push every installed version's mtime 10s into the past, keeping their order. The prune
# orders by activation mtime; this stands in for "time passed" between installs, so the
# next install's own touch is what makes its version the newest, without a sleep.
_age_versions() {
  local d
  for d in "$(IROOT)"/versions/*/; do touch -r "$d" -d '-10 seconds' "$d"; done
}

mkclone() {
  # A git hook (the repo's pre-commit runs this suite) exports GIT_DIR, GIT_INDEX_FILE and
  # friends; left set, every git call below would act on the real repo, not the clone.
  unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
  CLONE="$BATS_TEST_TMPDIR/clone"
  git clone -q "$BATS_TEST_DIRNAME/.." "$CLONE"
  # Overlay the working tree, so uncommitted changes under test are what gets installed.
  # Local CA certs stay out: the tests that need one make their own.
  tar -C "$BATS_TEST_DIRNAME/.." --exclude=.git --exclude=.tooling --exclude='image/certs/*.crt' -cf - . \
    | tar -x -C "$CLONE"
  gitc add -A && gitc commit -q --allow-empty -m "working tree under test"
}
gitc() { git -C "$CLONE" -c user.name=t -c user.email=t@example.com "$@"; }
rev() { git -C "$CLONE" rev-parse --short=12 HEAD; }

_install_clone() {
  env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" \
    AIRLOCK_ENGINE="$ENGINE" CLAUDE_CODE_VERSION=1.2.3 ENGINE_ARGS_FILE="$ENGINE_ARGS_FILE" \
    ${STUB_MODE:+STUB_MODE="$STUB_MODE"} \
    bash "$CLONE/bin/install.sh" </dev/null 2>"$BATS_TEST_TMPDIR/install.err" >/dev/null || true
}

@test "install exports the commit under ~/.local/share and links the launcher through current" {
  mkclone
  _install_clone
  r="$(rev)"
  [ "$(readlink "$(IROOT)/current")" = "versions/$r" ]
  [ -x "$(IROOT)/versions/$r/bin/claude-airlock" ]
  [ "$(readlink "$AIRLOCK_HOME/.local/bin/claude-airlock")" = "$(IROOT)/current/bin/claude-airlock" ]
  [ "$(readlink "$AIRLOCK_HOME/.local/bin/airlock")" = "$(IROOT)/current/bin/claude-airlock" ]   # the command's name
  grep -qx "commit $r" "$(IROOT)/versions/$r/VERSION"
  [ ! -e "$(IROOT)/versions/$r/.git" ]
  ! readlink -f "$AIRLOCK_HOME/.local/bin/claude-airlock" | grep -q "^$CLONE" || false
}

@test "install puts the host status line in ~/.claude, a copy of the installed version's" {
  mkclone
  mkdir -p "$AIRLOCK_HOME/.claude"
  printf '{"statusLine":{"command":"bash %s/config/airlock-statusline.sh --host"}}' "$CLONE" > "$AIRLOCK_HOME/.claude/settings.json"
  _install_clone
  sl="$AIRLOCK_HOME/.claude/airlock-statusline.sh"
  [ -f "$sl" ] && [ ! -L "$sl" ]
  cmp -s "$sl" "$(IROOT)/current/config/airlock-statusline.sh"
  grep -q "runs another copy of the status line" "$BATS_TEST_TMPDIR/install.err"
  printf '{"statusLine":{"command":"bash ~/.claude/airlock-statusline.sh --host"}}' > "$AIRLOCK_HOME/.claude/settings.json"
  _install_clone
  ! grep -q "runs another copy of the status line" "$BATS_TEST_TMPDIR/install.err" || false
}

@test "images are built from the new version's own directory, not the checkout" {
  mkclone
  _install_clone
  engine_args | grep -qx -- "$(IROOT)/versions/$(rev)/image"
  engine_args | grep -qx -- "$(IROOT)/versions/$(rev)/image/dev"
  ! engine_args | grep -q -- "$CLONE/image" || false
}

@test "uncommitted edits in the checkout are not installed, and install says so" {
  mkclone
  printf '# local edit\n' >> "$CLONE/README.md"
  _install_clone
  refute grep -q '# local edit' "$(IROOT)/versions/$(rev)/README.md"
  grep -q 'uncommitted changes' "$BATS_TEST_TMPDIR/install.err"
}

@test "a new commit installs beside the old one and current moves to it" {
  mkclone
  _install_clone; first="$(rev)"
  gitc commit -q --allow-empty -m next
  _install_clone; second="$(rev)"
  [ "$first" != "$second" ]
  [ -d "$(IROOT)/versions/$first" ]
  [ "$(readlink "$(IROOT)/current")" = "versions/$second" ]
}

@test "reinstalling the same commit is idempotent" {
  mkclone
  _install_clone
  printf 'marker\n' > "$(IROOT)/versions/$(rev)/.marker"
  _install_clone
  [ -f "$(IROOT)/versions/$(rev)/.marker" ]
  [ "$(find "$(IROOT)/versions" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]
}

@test "the prune keeps the live version and the two most recently activated others" {
  mkclone
  revs=()
  for i in 1 2 3 4 5; do
    gitc commit -q --allow-empty -m "c$i"; _install_clone; revs+=("$(rev)"); _age_versions
  done
  [ "$(find "$(IROOT)/versions" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 3 ]
  for r in "${revs[2]}" "${revs[3]}" "${revs[4]}"; do [ -d "$(IROOT)/versions/$r" ]; done
  refute test -d "$(IROOT)/versions/${revs[0]}"
  refute test -d "$(IROOT)/versions/${revs[1]}"
}

@test "a rollback counts as an activation: the prune does not drop the version just made live" {
  mkclone
  gitc commit -q --allow-empty -m A; _install_clone; a="$(rev)"; _age_versions
  gitc commit -q --allow-empty -m B; _install_clone; b="$(rev)"; _age_versions
  gitc commit -q --allow-empty -m C; _install_clone; c="$(rev)"; _age_versions
  gitc checkout -q "$a"; _install_clone; _age_versions        # roll back to A
  [ "$(readlink "$(IROOT)/current")" = "versions/$a" ]
  gitc checkout -q -; gitc commit -q --allow-empty -m D; _install_clone; d="$(rev)"
  [ -d "$(IROOT)/versions/$d" ]; [ -d "$(IROOT)/versions/$a" ]; [ -d "$(IROOT)/versions/$c" ]
  refute test -d "$(IROOT)/versions/$b"
}

# _mkca DIR NAME [leaf]: a CA certificate (or, with leaf, a non-CA one) at DIR/NAME.crt
_mkca() {
  local ext="basicConstraints=critical,CA:TRUE"; [ "${3:-}" = leaf ] && ext="basicConstraints=CA:FALSE"
  mkdir -p "$1"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$BATS_TEST_TMPDIR/$2.key" \
    -out "$1/$2.crt" -days 2 -subj "/CN=$2" -addext "$ext" 2>/dev/null
}
# _ca_root DIR: stat answers "root's, 0755" for DIR, what is in it and every directory above it
# (a test can't chown to root). STUBBIN/.ca-mode overrides DIR's answer, .ca-file.<name> one
# file's ("uid:mode"). Every other path gets the real stat.
_ca_root() {
  printf '%s\n' "$1" > "$STUBBIN/.ca-root"
  cat > "$STUBBIN/stat" <<'S'
#!/bin/bash
d="$(dirname "$0")"; r="$(cat "$d/.ca-root")"; p="${*: -1}"
if [ "$1 $2" = "-c %u:%a" ]; then
  if [ "$p" = "$r" ]; then echo "0:$(cat "$d/.ca-mode" 2>/dev/null || echo 755)"; exit 0; fi
  if [ "${p%/*}" = "$r" ]; then f="$d/.ca-file.${p##*/}"; [ -f "$f" ] && cat "$f" || echo 0:644; exit 0; fi
  [ -e "$d/.ca-no-parents" ] || case "$r/" in "$p"/*|"$p"*) [ "$p" = / ] || [ "${r#"$p"/}" != "$r" ] && { echo 0:755; exit 0; } ;; esac
fi
exec /usr/bin/stat "$@"
S
  chmod +x "$STUBBIN/stat"
}
_ca_config() { mkdir -p "$AIRLOCK_HOME/.config/claude-airlock"; printf '%s\n' "$@" > "$AIRLOCK_HOME/.config/claude-airlock/config"; }

@test "CA certs from the clone's image/certs/ (no host dir): checked, copied, listed; refreshed per install" {
  command -v openssl >/dev/null || skip "no openssl"
  mkclone
  _ca_config "AIRLOCK_CA_DIR=clone"
  _mkca "$CLONE/image/certs" corp-root
  _install_clone
  [ -f "$(IROOT)/versions/$(rev)/image/certs/corp-root.crt" ]
  rm "$CLONE/image/certs/corp-root.crt"
  _install_clone
  refute test -f "$(IROOT)/versions/$(rev)/image/certs/corp-root.crt"
}

@test "CA certs: a leaf certificate, a key, or anything else in a .crt is refused before anything is installed" {
  command -v openssl >/dev/null || skip "no openssl"
  mkclone
  _ca_config "AIRLOCK_CA_DIR=clone"
  _mkca "$CLONE/image/certs" leafy leaf
  _install_clone
  grep -q 'is not a CA' "$BATS_TEST_TMPDIR/install.err" || { cat "$BATS_TEST_TMPDIR/install.err"; return 1; }
  refute test -d "$(IROOT)/versions/$(rev)"
  rm "$CLONE/image/certs/leafy.crt"
  _mkca "$CLONE/image/certs" withkey; cat "$BATS_TEST_TMPDIR/withkey.key" >> "$CLONE/image/certs/withkey.crt"
  _install_clone
  grep -q 'not PEM certificates only' "$BATS_TEST_TMPDIR/install.err"
  refute test -d "$(IROOT)/versions/$(rev)"
}

@test "CA certs from the host's root-owned dir win over the clone's; a writable dir, a link or a non-root owner is refused" {
  command -v openssl >/dev/null || skip "no openssl"
  mkclone
  H="$BATS_TEST_TMPDIR/hostca"; _mkca "$H" host-root; _ca_root "$H"
  _mkca "$CLONE/image/certs" clone-root
  _ca_config "AIRLOCK_CA_DIR=$H"
  _install_clone
  [ -f "$(IROOT)/versions/$(rev)/image/certs/host-root.crt" ] || { cat "$BATS_TEST_TMPDIR/install.err"; return 1; }
  refute test -f "$(IROOT)/versions/$(rev)/image/certs/clone-root.crt"
  gitc commit -q --allow-empty -m next
  echo 775 > "$STUBBIN/.ca-mode"; _install_clone
  grep -q 'writable by group or others' "$BATS_TEST_TMPDIR/install.err"; refute test -d "$(IROOT)/versions/$(rev)"
  rm "$STUBBIN/.ca-mode"; rm "$STUBBIN/stat"; _install_clone      # really the test user's: not root's
  grep -q "is not root's" "$BATS_TEST_TMPDIR/install.err"; refute test -d "$(IROOT)/versions/$(rev)"
  _ca_root "$H"; ln -s "$H/host-root.crt" "$H/linked.crt"; _install_clone
  grep -q 'is a link' "$BATS_TEST_TMPDIR/install.err"; refute test -d "$(IROOT)/versions/$(rev)"
}

@test "CA certs in the clone without AIRLOCK_CA_DIR=clone stop the install (a box could have put them there)" {
  command -v openssl >/dev/null || skip "no openssl"
  mkclone
  _ca_config "AIRLOCK_CA_DIR=$BATS_TEST_TMPDIR/no-such-dir"
  _mkca "$CLONE/image/certs" planted
  _install_clone
  grep -q 'used only with AIRLOCK_CA_DIR=clone' "$BATS_TEST_TMPDIR/install.err" || { cat "$BATS_TEST_TMPDIR/install.err"; return 1; }
  refute test -d "$(IROOT)/versions/$(rev)"
  # ...nor does REQUIRED accept the clone, even when opted in
  _ca_config AIRLOCK_CA_DIR=clone AIRLOCK_CA_REQUIRED=1
  _install_clone
  grep -q 'only from a root-owned host directory' "$BATS_TEST_TMPDIR/install.err"
  refute test -d "$(IROOT)/versions/$(rev)"
}

@test "CA certs: a file not root's or writable in a good dir, a link in the dir's path, a link or an oversized file in the clone are refused" {
  command -v openssl >/dev/null || skip "no openssl"
  mkclone
  H="$BATS_TEST_TMPDIR/hostca"; _mkca "$H" host-root; _ca_root "$H"; _ca_config "AIRLOCK_CA_DIR=$H"
  echo 0:664 > "$STUBBIN/.ca-file.host-root.crt"; _install_clone
  grep -q 'host-root.crt is writable by group or others' "$BATS_TEST_TMPDIR/install.err" || { cat "$BATS_TEST_TMPDIR/install.err"; return 1; }
  echo 1000:644 > "$STUBBIN/.ca-file.host-root.crt"; _install_clone
  grep -q "host-root.crt is not root's" "$BATS_TEST_TMPDIR/install.err"
  rm "$STUBBIN/.ca-file.host-root.crt"
  ln -s "$H" "$BATS_TEST_TMPDIR/via-link"; _ca_config "AIRLOCK_CA_DIR=$BATS_TEST_TMPDIR/via-link/"
  _install_clone
  grep -q 'is a link\|is not its real path' "$BATS_TEST_TMPDIR/install.err" || { cat "$BATS_TEST_TMPDIR/install.err"; return 1; }
  refute test -d "$(IROOT)/versions/$(rev)"
  _ca_config AIRLOCK_CA_DIR=clone
  _mkca "$BATS_TEST_TMPDIR/elsewhere" real; ln -s "$BATS_TEST_TMPDIR/elsewhere/real.crt" "$CLONE/image/certs/linked.crt"
  _install_clone; grep -q 'linked.crt is a link' "$BATS_TEST_TMPDIR/install.err"
  rm "$CLONE/image/certs/linked.crt"; head -c 70000 /dev/zero > "$CLONE/image/certs/big.crt"
  _install_clone; grep -q 'over 64 KiB' "$BATS_TEST_TMPDIR/install.err"
  refute test -d "$(IROOT)/versions/$(rev)"
}

@test "CA certs: a parent of the host dir that isn't root's is refused (the whole path is checked)" {
  command -v openssl >/dev/null || skip "no openssl"
  mkclone
  H="$BATS_TEST_TMPDIR/hostca"; _mkca "$H" host-root; _ca_root "$H"; _ca_config "AIRLOCK_CA_DIR=$H"
  touch "$STUBBIN/.ca-no-parents"                 # the stub fakes only the dir and its files now
  _install_clone
  grep -q "$BATS_TEST_TMPDIR is not root's" "$BATS_TEST_TMPDIR/install.err" || { cat "$BATS_TEST_TMPDIR/install.err"; return 1; }
  refute test -d "$(IROOT)/versions/$(rev)"
  run find "$(IROOT)" -maxdepth 1 -name '.ca.*'; [ -z "$output" ]       # and no copy left behind
}

@test "CA certs: the build context holds only the checked set (a committed cert, even in a subdir, is gone)" {
  command -v openssl >/dev/null || skip "no openssl"
  mkclone
  mkdir -p "$CLONE/image/certs/sub"; _mkca "$CLONE/image/certs/sub" committed
  gitc add -f image/certs/sub/committed.crt && gitc commit -q -m "a committed cert"
  _ca_config "AIRLOCK_CA_DIR=$BATS_TEST_TMPDIR/no-such-dir"
  _install_clone
  [ -d "$(IROOT)/versions/$(rev)" ] || { cat "$BATS_TEST_TMPDIR/install.err"; return 1; }
  [ "$(find "$(IROOT)/versions/$(rev)/image/certs" -mindepth 1)" = "$(IROOT)/versions/$(rev)/image/certs/.gitkeep" ]
}

@test "CA certs: what is built is the copy that was checked, not the path read again later" {
  command -v openssl >/dev/null || skip "no openssl"
  mkclone
  H="$BATS_TEST_TMPDIR/hostca"; _mkca "$H" host-root; _ca_root "$H"; _ca_config "AIRLOCK_CA_DIR=$H"
  cp "$H/host-root.crt" "$BATS_TEST_TMPDIR/checked.crt"
  # git archive (the export, after the checks) swaps the file for something unchecked
  printf '#!/bin/bash\nfor a in "$@"; do [ "$a" = archive ] && echo "NOT A CERT" > %s; done\nexec /usr/bin/git "$@"\n' "$H/host-root.crt" > "$STUBBIN/git"
  chmod +x "$STUBBIN/git"
  _install_clone
  rm "$STUBBIN/git"
  grep -q 'NOT A CERT' "$H/host-root.crt"                     # the swap happened
  cmp "$(IROOT)/versions/$(rev)/image/certs/host-root.crt" "$BATS_TEST_TMPDIR/checked.crt" || { cat "$BATS_TEST_TMPDIR/install.err"; return 1; }
}

@test "AIRLOCK_CA_REQUIRED=1: no install without a CA cert" {
  mkclone
  _ca_config "AIRLOCK_CA_DIR=$BATS_TEST_TMPDIR/no-such-dir" AIRLOCK_CA_REQUIRED=1
  _install_clone
  grep -q 'AIRLOCK_CA_REQUIRED=1, but there are no CA certs' "$BATS_TEST_TMPDIR/install.err" || { cat "$BATS_TEST_TMPDIR/install.err"; return 1; }
  refute test -d "$(IROOT)/versions/$(rev)"
}

@test "a failed image build leaves the previous version live" {
  mkclone
  _install_clone; first="$(rev)"
  gitc commit -q --allow-empty -m next
  cat > "$STUBBIN/$ENGINE" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${ENGINE_ARGS_FILE:-/dev/null}"
[ "${1:-}" = build ] && exit 1
exit 0
STUB
  chmod +x "$STUBBIN/$ENGINE"
  _install_clone
  [ "$(readlink "$(IROOT)/current")" = "versions/$first" ]
}

@test "install warns about rc lines that run the launcher from anywhere but the install" {
  mkclone
  for line in "source \"$CLONE/shell/claude-airlock.zsh\"" 'source "$HOME/dev/claude-airlock/shell/claude-airlock.zsh"' \
              'agent() { ~/dev/claude-airlock/bin/claude-airlock "$@"; }'; do
    printf '%s\n' "$line" > "$AIRLOCK_HOME/.zshrc.local"
    _install_clone
    grep -q "WARNING: $AIRLOCK_HOME/.zshrc.local runs the launcher from somewhere other than the install" \
      "$BATS_TEST_TMPDIR/install.err" || { echo "no warning for: $line"; false; }
  done
  printf 'source "$HOME/.local/share/claude-airlock/current/shell/claude-airlock.zsh"\n' > "$AIRLOCK_HOME/.zshrc.local"
  _install_clone
  refute grep -q 'WARNING' "$BATS_TEST_TMPDIR/install.err"
}

@test "a failed dev build moves no image tag and leaves the previous version live" {
  mkclone
  _install_clone; first="$(rev)"
  gitc commit -q --allow-empty -m next; second="$(rev)"
  cat > "$STUBBIN/$ENGINE" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${ENGINE_ARGS_FILE:-/dev/null}"
[ "${1:-}" = build ] && [[ "${*: -1}" == */image/dev ]] && exit 1
exit 0
STUB
  chmod +x "$STUBBIN/$ENGINE"
  : > "$ENGINE_ARGS_FILE"
  _install_clone
  [ "$(readlink "$(IROOT)/current")" = "versions/$first" ]
  engine_args | grep -qx -- "claude-airlock:base-$second"     # base did build, under its own tag
  ! engine_args | grep -qx -- tag || false
  refute test -d "$(IROOT)/versions/$second"                 # never went live, so not kept
}

stub_modes() {
  cat > "$STUBBIN/$ENGINE" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${ENGINE_ARGS_FILE:-/dev/null}"
if [ "${1:-}" = image ] && [ "${2:-}" = inspect ]; then
  case "${*: -1}" in
    claude-airlock:os-*)   echo "sha256:os " ;;
    claude-airlock:base-*) echo "sha256:os sha256:claude " ;;
  esac
fi
# faildev-slow: the base build also takes 2s, the window a concurrent install races in.
if [[ "${STUB_MODE:-}" == faildev* ]] && [ "${1:-}" = build ]; then
  [ "$STUB_MODE" = faildev-slow ] && [[ "${*: -1}" == */image ]] && sleep 2
  [[ "${*: -1}" == */image/dev ]] && exit 1
fi
exit 0
STUB
  chmod +x "$STUBBIN/$ENGINE"
}

@test "a failing install never deletes the version a concurrent install of that commit made live" {
  mkclone
  stub_modes
  STUB_MODE=faildev-slow _install_clone &
  sleep 0.5
  _install_clone
  wait
  live="$(readlink -f "$(IROOT)/current")"
  [ -x "$live/bin/claude-airlock" ]
  [ -x "$(readlink -f "$AIRLOCK_HOME/.local/bin/claude-airlock")" ]
}

@test "a failed build untags its per-commit images" {
  mkclone
  stub_modes
  : > "$ENGINE_ARGS_FILE"
  STUB_MODE=faildev _install_clone
  engine_args | grep -qx -- rmi
  engine_args | grep -qx -- "claude-airlock:base-$(rev)"
  engine_args | awk '$0=="rmi"{f=1} f && $0 ~ /^claude-airlock:base-/{ok=1} END{exit !ok}'
}

@test "the rc warning ignores comments and XDG-style spellings of the install" {
  mkclone
  printf '%s\n' '# source ~/dev/claude-airlock/shell/claude-airlock.zsh' \
    'source "${XDG_DATA_HOME:-$HOME/.local/share}/claude-airlock/current/shell/claude-airlock.zsh"' \
    > "$AIRLOCK_HOME/.zshrc.local"
  _install_clone
  refute grep -q 'WARNING' "$BATS_TEST_TMPDIR/install.err"
}

@test "a checkout git cannot read is refused, not copied with its uncommitted edits" {
  mkclone
  printf '#!/bin/sh\necho "fatal: detected dubious ownership" >&2\nexit 128\n' > "$STUBBIN/git"
  chmod +x "$STUBBIN/git"
  printf '# LOCAL EDIT\n' >> "$CLONE/bin/claude-airlock"
  run env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" AIRLOCK_ENGINE="$ENGINE" \
    CLAUDE_CODE_VERSION=1.2.3 ENGINE_ARGS_FILE="$ENGINE_ARGS_FILE" bash "$CLONE/bin/install.sh" </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"git cannot read it"* ]]
  refute test -e "$(IROOT)/current"
}

@test "stage dirs left by a hard kill are swept after an hour" {
  mkclone
  mkdir -p "$(IROOT)/versions/.stage.dead" "$(IROOT)/versions/.stage.recent"
  touch -d '2 hours ago' "$(IROOT)/versions/.stage.dead"
  _install_clone
  refute test -d "$(IROOT)/versions/.stage.dead"
  [ -d "$(IROOT)/versions/.stage.recent" ]
}

@test "a checkout inside some other repo is copied whole, never exported as an empty tree" {
  mkclone
  outer="$BATS_TEST_TMPDIR/outer"; mkdir -p "$outer/sub"
  git -C "$outer" init -q
  tar -C "$CLONE" --exclude=.git -cf - . | tar -x -C "$outer/sub"
  CLONE="$outer/sub" _install_clone
  live="$(readlink -f "$(IROOT)/current")"
  [ -x "$live/bin/claude-airlock" ]
  grep -q 'not a git checkout; installing the whole tree' "$BATS_TEST_TMPDIR/install.err"
}

@test "a relative AIRLOCK_INSTALL_ROOT is refused" {
  mkclone
  run env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" AIRLOCK_ENGINE="$ENGINE" \
    CLAUDE_CODE_VERSION=1.2.3 AIRLOCK_INSTALL_ROOT=rel/root bash "$CLONE/bin/install.sh" </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be an absolute path"* ]]
}

@test "two installs of the same commit at once leave one clean version" {
  mkclone
  _install_clone & _install_clone & wait
  [ "$(find "$(IROOT)/versions/$(rev)" -maxdepth 1 -name '.stage.*' | wc -l)" -eq 0 ]
  [ "$(find "$(IROOT)/versions" -maxdepth 1 -name '.stage.*' | wc -l)" -eq 0 ]
}

@test "a shell that sourced the installed zsh file follows current to the next install" {
  command -v zsh >/dev/null || skip "zsh not installed"
  mkclone
  _install_clone
  out="$(HOME="$AIRLOCK_HOME" zsh -fc "source '$(IROOT)/current/shell/claude-airlock.zsh'; print -r -- \$_AIRLOCK_LAUNCHER")"
  [ "$out" = "$(IROOT)/current/bin/claude-airlock" ]
}

@test "the containment check and the printed source line use the installed copy" {
  # Both run after the build, past the point the stubbed engine lets install.sh reach.
  grep -q '"$SRC_DIR/scripts/airlock-doctor.sh"' "$BATS_TEST_DIRNAME/../bin/install.sh"
  grep -q 'source "$INSTALL_ROOT/current/shell/claude-airlock.zsh"' "$BATS_TEST_DIRNAME/../bin/install.sh"
  grep -q 'ln -sfn "$INSTALL_ROOT/current/bin/claude-airlock" "$BIN_TARGET/claude-airlock"' "$BATS_TEST_DIRNAME/../bin/install.sh"
  grep -q 'ln -sfn "$INSTALL_ROOT/current/bin/claude-airlock" "$BIN_TARGET/airlock"' "$BATS_TEST_DIRNAME/../bin/install.sh"
}

# --- dev image layering: Claude Code last (a release must not rebuild the toolchain) ----

@test "the dev image builds on the base's os stage and gets Claude Code from the base" {
  mkclone
  _install_clone
  r="$(rev)"
  engine_args | grep -qx -- "--target"
  engine_args | grep -qx -- "claude-airlock:os-$r"
  engine_args | grep -qx -- "OS_IMAGE=claude-airlock:os-$r"
  engine_args | grep -qx -- "BASE_IMAGE=claude-airlock:base-$r"
  engine_args | grep -qx -- "debian:trixie-slim"        # the pull strips `AS os`
  engine_args | grep -qx -- "claude-airlock:os"         # :os moves with :base and :dev
  df="$BATS_TEST_DIRNAME/../image/dev/Dockerfile"
  grep -qE '^FROM \$\{BASE_IMAGE\} AS claude$' "$df"
  grep -qE '^FROM \$\{OS_IMAGE\}$' "$df"
  grep -qE '^FROM debian:trixie-slim AS os$' "$BATS_TEST_DIRNAME/../image/Dockerfile"
  # Nothing but the version check may follow the Claude Code copy: any RUN/COPY/ADD
  # after it would be rebuilt by every Claude Code release.
  copy="$(grep -n '^COPY --from=claude ' "$df" | cut -d: -f1)"
  [ -n "$copy" ]
  [ "$(awk -v c="$copy" 'NR > c && /^(RUN|COPY|ADD) /' "$df")" = "RUN gosu dev claude --version" ]
}

@test "a failed os build stops the install and untags all three per-commit images" {
  mkclone
  cat > "$STUBBIN/$ENGINE" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${ENGINE_ARGS_FILE:-/dev/null}"
[ "${1:-}" = build ] && [ "${2:-}" = --target ] && exit 1
exit 0
STUB
  chmod +x "$STUBBIN/$ENGINE"
  : > "$ENGINE_ARGS_FILE"
  _install_clone
  refute test -e "$(IROOT)/current"
  refute grep -qx -- "$(IROOT)/versions/$(rev)/image/dev" "$ENGINE_ARGS_FILE"   # dev never built
  engine_args | awk '$0=="rmi"{f=1} f && $0 ~ /^claude-airlock:os-/{ok=1} END{exit !ok}'
}

@test "an os image that is not the base's own os stage is refused before going live" {
  mkclone
  cat > "$STUBBIN/$ENGINE" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${ENGINE_ARGS_FILE:-/dev/null}"
if [ "${1:-}" = image ] && [ "${2:-}" = inspect ]; then
  case "${*: -1}" in
    claude-airlock:os-*)   echo "sha256:a sha256:x " ;;
    claude-airlock:base-*) echo "sha256:a sha256:b sha256:c " ;;
  esac
fi
exit 0
STUB
  chmod +x "$STUBBIN/$ENGINE"
  _install_clone
  grep -q "is not the base image's os stage" "$BATS_TEST_TMPDIR/install.err"
  refute test -e "$(IROOT)/current"
}

@test "an os image with no layers listed is refused (the check must not skip itself)" {
  mkclone
  cat > "$STUBBIN/$ENGINE" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${ENGINE_ARGS_FILE:-/dev/null}"
exit 0
STUB
  chmod +x "$STUBBIN/$ENGINE"
  _install_clone
  grep -q "is not the base image's os stage" "$BATS_TEST_TMPDIR/install.err"
  refute test -e "$(IROOT)/current"
}

@test "an os image whose layers start the base's passes the check" {
  mkclone
  cat > "$STUBBIN/$ENGINE" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${ENGINE_ARGS_FILE:-/dev/null}"
if [ "${1:-}" = image ] && [ "${2:-}" = inspect ]; then
  case "${*: -1}" in
    claude-airlock:os-*)   echo "sha256:a sha256:b " ;;
    claude-airlock:base-*) echo "sha256:a sha256:b sha256:c " ;;
  esac
fi
exit 0
STUB
  chmod +x "$STUBBIN/$ENGINE"
  _install_clone
  refute grep -q "is not the base image's os stage" "$BATS_TEST_TMPDIR/install.err"
  [ -e "$(IROOT)/current" ]
}

@test "a failed build untags the per-commit os image too" {
  mkclone
  stub_modes
  : > "$ENGINE_ARGS_FILE"
  STUB_MODE=faildev _install_clone
  engine_args | awk '$0=="rmi"{f=1} f && $0 ~ /^claude-airlock:os-/{ok=1} END{exit !ok}'
}

# --- shellcheck/bats: one pinned version for the image, CI and `make bootstrap` --------

@test "the image and bootstrap pin the same shellcheck and bats" {
  df="$BATS_TEST_DIRNAME/../image/dev/Dockerfile"
  bs="$BATS_TEST_DIRNAME/../scripts/bootstrap-tools.sh"
  arg() { sed -n "s/^ARG $1=//p" "$df"; }
  var() { sed -n "s/^$1=\"\\(.*\\)\"$/\\1/p" "$bs"; }
  [ -n "$(arg SHELLCHECK_VERSION)" ] && [ "$(arg SHELLCHECK_VERSION)" = "$(var SC_VER)" ]
  [ -n "$(arg BATS_VERSION)" ]       && [ "$(arg BATS_VERSION)" = "$(var BATS_VER)" ]
  [ -n "$(arg BATS_COMMIT)" ]        && [ "$(arg BATS_COMMIT)" = "$(var BATS_COMMIT)" ]
  grep -q "amd64) scarch=x86_64;  sha=$(var SC_SHA_X86_64) " "$df"
  grep -q "arm64) scarch=aarch64; sha=$(var SC_SHA_AARCH64) " "$df"
  # Neither comes from apt any more (that is how the versions drifted), in any layout.
  apt_pkgs="$(awk '/apt-get install/{f=1} f{print} /apt-get clean/{f=0}' "$df")"
  refute grep -qw shellcheck <<<"$apt_pkgs"
  refute grep -qw bats <<<"$apt_pkgs"
}

@test "the pins are actually checked, in the image and in bootstrap" {
  df="$BATS_TEST_DIRNAME/../image/dev/Dockerfile"
  bs="$BATS_TEST_DIRNAME/../scripts/bootstrap-tools.sh"
  # image: the tarball against its sha256, the clone against the pinned commit
  awk '/ARG SHELLCHECK_VERSION/{f=1} f&&/sha256sum -c -/{ok=1} f&&/shellcheck --version/{exit} END{exit !ok}' "$df"
  grep -qF 'test "$(git -C /tmp/bats rev-parse HEAD)" = "$BATS_COMMIT"' "$df"
  # ...and nothing on those lines can swallow a failure (the RUN is `set -e`). A guard
  # against accidental edits, not a proof: the build itself is the behavioural test.
  awk '/ARG SHELLCHECK_VERSION/{f=1} f&&/set -eux/{ok=1} f&&/shellcheck --version/{exit} END{exit !ok}' "$df"
  [ "$(grep -E 'sha256sum -c -|= "\$BATS_COMMIT"' "$df" | grep -c '||')" -eq 0 ]
  # bootstrap: tarball, extracted binary and any existing copy by sha256; bats by commit
  grep -qF 'echo "$sc_sha  $tmp/sc.tar.xz" | sha256sum -c -' "$bs"
  grep -qF 'echo "$sc_bin_sha  $tmp/shellcheck-v${SC_VER}/shellcheck" | sha256sum -c -' "$bs"
  grep -qF 'echo "$sc_bin_sha  $BIN/shellcheck" | sha256sum -c -' "$bs"
  grep -qF '[ "$(git -C "$TOOLDIR/bats-core" rev-parse HEAD)" != "$BATS_COMMIT" ]' "$bs"
}

@test "make and the hook prefer a system shellcheck/bats over the box-writable .tooling/" {
  mk="$BATS_TEST_DIRNAME/../Makefile"
  grep -qF 'SHELLCHECK ?= $(shell command -v shellcheck 2>/dev/null || echo .tooling/bin/shellcheck)' "$mk"
  grep -qF 'BATS       ?= $(shell command -v bats 2>/dev/null || echo .tooling/bin/bats)' "$mk"
  grep -qF 'shellcheck_bin="$(command -v shellcheck 2>/dev/null || echo .tooling/bin/shellcheck)"' \
    "$BATS_TEST_DIRNAME/../hooks/pre-commit"
}

@test "CI lints and tests with the bootstrapped tools, not the runner's" {
  ci="$BATS_TEST_DIRNAME/../.github/workflows/ci.yml"
  [ "$(grep -c 'bash scripts/bootstrap-tools.sh' "$ci")" -ge 2 ]
  grep -q 'make lint SHELLCHECK=\.tooling/bin/shellcheck' "$ci"
  refute grep -q 'apt-get install -y shellcheck' "$ci"
  refute grep -q 'apt-get install -y bats' "$ci"
  grep -q 'BATS=\.tooling/bin/bats .*scripts/run-tests\.sh' "$ci"
}

# --- closing instructions: only the steps that are not done yet -------------------------

# The doctor and smoke test need a real engine; replaced in the clone so the install runs
# to its closing message.
_install_to_end() {
  printf '#!/bin/sh\nexit 0\n' > "$CLONE/scripts/airlock-doctor.sh"
  printf '#!/bin/sh\nexit 0\n' > "$CLONE/scripts/image-smoke.sh"
  gitc diff --quiet || gitc commit -qam "stub doctor + smoke"
  env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" \
    AIRLOCK_ENGINE="$ENGINE" CLAUDE_CODE_VERSION=1.2.3 ENGINE_ARGS_FILE="$ENGINE_ARGS_FILE" \
    ${TOKEN_ENV:+CLAUDE_CODE_OAUTH_TOKEN="$TOKEN_ENV"} \
    ${INSTALL_ROOT_ENV:+AIRLOCK_INSTALL_ROOT="$INSTALL_ROOT_ENV"} \
    ${PASTE_PROJECT_ENV:+AIRLOCK_PASTE_PROJECT="$PASTE_PROJECT_ENV"} ${PASTE_DIR_ENV:+AIRLOCK_PASTE_DIR="$PASTE_DIR_ENV"} \
    ${CONFIG_ENV:+AIRLOCK_CONFIG="$CONFIG_ENV"} \
    bash "$CLONE/bin/install.sh" </dev/null >"$BATS_TEST_TMPDIR/install.out" 2>"$BATS_TEST_TMPDIR/install.err"
}

@test "a fresh install prints both setup steps" {
  mkclone
  _install_to_end
  grep -q 'Add this line to your ~/.zshrc' "$BATS_TEST_TMPDIR/install.out"
  grep -q 'One-time auth' "$BATS_TEST_TMPDIR/install.out"
}

@test "steps already done are not printed again" {
  mkclone
  printf 'source "$HOME/.local/share/claude-airlock/current/shell/claude-airlock.zsh"\n' > "$AIRLOCK_HOME/.zshrc"
  mkdir -p "$AIRLOCK_HOME/.config/claude-airlock"
  printf 'x' > "$AIRLOCK_HOME/.config/claude-airlock/token"
  _install_to_end
  refute grep -q 'Add this line' "$BATS_TEST_TMPDIR/install.out"
  refute grep -q 'One-time auth' "$BATS_TEST_TMPDIR/install.out"
  grep -q 'already set up' "$BATS_TEST_TMPDIR/install.out"
}

@test "a commented-out source line, an empty token file, or a checkout path still prompt" {
  mkclone
  printf '# source "$HOME/.local/share/claude-airlock/current/shell/claude-airlock.zsh"\nsource "%s/shell/claude-airlock.zsh"\n' "$CLONE" > "$AIRLOCK_HOME/.zshrc"
  mkdir -p "$AIRLOCK_HOME/.config/claude-airlock"
  : > "$AIRLOCK_HOME/.config/claude-airlock/token"
  _install_to_end
  grep -q 'Add this line' "$BATS_TEST_TMPDIR/install.out"
  grep -q 'One-time auth' "$BATS_TEST_TMPDIR/install.out"
}

@test "a token in CLAUDE_CODE_OAUTH_TOKEN counts as auth done" {
  mkclone
  TOKEN_ENV=x _install_to_end
  refute grep -q 'One-time auth' "$BATS_TEST_TMPDIR/install.out"
  grep -q 'Add this line' "$BATS_TEST_TMPDIR/install.out"
}

@test "a source line through a custom install root counts as done" {
  mkclone
  root="$AIRLOCK_HOME/opt/airlock"
  printf 'source "%s/current/shell/claude-airlock.zsh"\n' "$root" > "$AIRLOCK_HOME/.zshrc"
  INSTALL_ROOT_ENV="$root" _install_to_end
  refute grep -q 'Add this line' "$BATS_TEST_TMPDIR/install.out"
}

@test "a whitespace-only token file or a directory at the token path still prompts" {
  mkclone
  mkdir -p "$AIRLOCK_HOME/.config/claude-airlock"
  printf ' \n\t\n' > "$AIRLOCK_HOME/.config/claude-airlock/token"
  _install_to_end
  grep -q 'One-time auth' "$BATS_TEST_TMPDIR/install.out"
  rm "$AIRLOCK_HOME/.config/claude-airlock/token"
  mkdir -p "$AIRLOCK_HOME/.config/claude-airlock/token/x"
  _install_to_end
  grep -q 'One-time auth' "$BATS_TEST_TMPDIR/install.out"
}

# Telemetry is always off; install clears every project's leftover `telemetry-on` marker
# from the retired switch and names the projects, so none keeps it on unseen.
@test "install clears leftover telemetry-on markers and lists the projects" {
  st="$AIRLOCK_HOME/.config/claude-airlock/state"
  mkdir -p "$st/proj-a" "$st/proj-b" "$st/proj-c"
  touch "$st/proj-a/telemetry-on" "$st/proj-c/telemetry-on"
  _install
  [ ! -e "$st/proj-a/telemetry-on" ]
  [ ! -e "$st/proj-c/telemetry-on" ]
  grep -q 'always off' "$BATS_TEST_TMPDIR/install.err"
  grep -q 'proj-a' "$BATS_TEST_TMPDIR/install.err"
  grep -q 'proj-c' "$BATS_TEST_TMPDIR/install.err"
  ! grep -q 'proj-b' "$BATS_TEST_TMPDIR/install.err"
}

@test "install says nothing about telemetry when no project had it on" {
  _install
  ! grep -q 'always off' "$BATS_TEST_TMPDIR/install.err"
}

# --- airlock paste: never a prompt, a note while it isn't set up ----------------------------

@test "an install on a terminal never asks for a paste project; it ends with a note while none is set" {
  script --version 2>&1 | grep -q util-linux && command -v timeout >/dev/null || skip "needs util-linux script and timeout"
  mkclone
  _install_to_end   # writes the stubs, and the install itself must not need them on a tty
  w="$BATS_TEST_TMPDIR/tty-install.sh"
  cat > "$w" <<W
#!/bin/sh
[ -t 0 ] || { echo "stdin is not a terminal" >&2; exit 9; }
exec env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" \
  AIRLOCK_ENGINE="$ENGINE" CLAUDE_CODE_VERSION=1.2.3 ENGINE_ARGS_FILE="$ENGINE_ARGS_FILE" \
  bash "$CLONE/bin/install.sh"
W
  chmod +x "$w"
  run timeout 300 script -qec "$w" /dev/null </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" != *"Which project"* && "$output" != *"project path:"* ]]
  [[ "$output" == *"'airlock paste' (clipboard images into a box) is not set up"* ]]
  [[ "$output" == *"AIRLOCK_PASTE_PROJECT="* ]]
  refute grep -qE '^[[:space:]]*AIRLOCK_PASTE_PROJECT=' "$AIRLOCK_HOME/.config/claude-airlock/config"
}

@test "no paste note once the config names a paste project or dir, or says empty on purpose" {
  mkclone
  cfg="$AIRLOCK_HOME/.config/claude-airlock/config"
  _install_to_end
  grep -q "'airlock paste' (clipboard images into a box) is not set up" "$BATS_TEST_TMPDIR/install.out"
  for line in 'AIRLOCK_PASTE_PROJECT="$HOME/x"' 'export AIRLOCK_PASTE_DIR=/srv/inbox/pastes' 'AIRLOCK_PASTE_PROJECT='; do
    cp "$BATS_TEST_DIRNAME/../config/config.example" "$cfg"
    printf '%s\n' "$line" >> "$cfg"
    _install_to_end
    if grep -q 'is not set up' "$BATS_TEST_TMPDIR/install.out"; then echo "note with: $line"; return 1; fi
  done
  # a commented-out example is not a choice
  cp "$BATS_TEST_DIRNAME/../config/config.example" "$cfg"
  _install_to_end
  grep -q 'is not set up' "$BATS_TEST_TMPDIR/install.out"
}

@test "no paste note when the environment sets either; the note names AIRLOCK_CONFIG's file; a near-miss name is no choice" {
  mkclone
  out="$BATS_TEST_TMPDIR/install.out"
  PASTE_PROJECT_ENV=/x _install_to_end; refute grep -q 'is not set up' "$out"
  PASTE_DIR_ENV=/d _install_to_end;     refute grep -q 'is not set up' "$out"
  c="$BATS_TEST_TMPDIR/elsewhere.conf"
  printf 'AIRLOCK_PASTE_DIR=/srv/inbox/pastes\n' > "$c"
  CONFIG_ENV="$c" _install_to_end;     refute grep -q 'is not set up' "$out"
  printf 'AIRLOCK_PASTE_PROJECTS=/x\n' > "$c"
  CONFIG_ENV="$c" _install_to_end
  grep -qF "(or AIRLOCK_PASTE_DIR) in $c." "$out"
  # a config not made yet, where it can be: the user's to set
  CONFIG_ENV="$BATS_TEST_TMPDIR/new/agent.conf" _install_to_end
  grep -qF "(or AIRLOCK_PASTE_DIR) in $BATS_TEST_TMPDIR/new/agent.conf." "$out"
  CONFIG_ENV="$BATS_TEST_TMPDIR/none.conf" _install_to_end              # a writable dir, no file yet
  grep -qF "(or AIRLOCK_PASTE_DIR) in $BATS_TEST_TMPDIR/none.conf." "$out"
  # not the user's to make: a directory, or below a read-only dir (however deep)
  mkdir -p "$BATS_TEST_TMPDIR/adir" "$BATS_TEST_TMPDIR/ro"
  CONFIG_ENV="$BATS_TEST_TMPDIR/adir" _install_to_end
  grep -qF "in $BATS_TEST_TMPDIR/adir: ask whoever manages it." "$out"
  if [ "$(id -u)" != 0 ]; then
    chmod 0555 "$BATS_TEST_TMPDIR/ro"
    CONFIG_ENV="$BATS_TEST_TMPDIR/ro/sub/x.conf" _install_to_end
    chmod 0755 "$BATS_TEST_TMPDIR/ro"
    grep -qF "in $BATS_TEST_TMPDIR/ro/sub/x.conf: ask whoever manages it." "$out"
  fi
}
