#!/usr/bin/env bats
# bin/install.sh: the image build must not silently reuse stale layers. The Claude Code
# version already keyed its own layer; the Debian packages had no key at all, so a rebuild
# reused the first build's apt layer forever (an apt layer from July inside an image built
# in September, 17 security updates behind). These pin what fixes that: the base tag is
# re-pulled (as a step that can fail soft), the apt layer is keyed on the ISO week, and a
# forced refresh is remembered so the next install in the same week keeps it.

load helper
setup() { setup_airlock_env; }

# Run install.sh hermetically: isolated HOME, stubbed engine (records argv), a pinned
# Claude Code version so it never curls upstream, and stdin not a TTY so the paste-project
# prompt is skipped. The trailing doctor fails against the stub, so the exit status is not
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
_stub_upstream_installer() {   # $1 = file to serve as https://claude.ai/install.sh
  printf '#!/usr/bin/env bash\nfor a in "$@"; do case "$a" in *claude.ai/install.sh) cat "%s"; exit 0 ;; esac; done\nexit 22\n' "$1" > "$STUBBIN/curl"
  chmod +x "$STUBBIN/curl"
}

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
    bash "$CLONE/bin/install.sh" </dev/null 2>"$BATS_TEST_TMPDIR/install.err" >/dev/null || true
}

@test "install exports the commit under ~/.local/share and links the launcher through current" {
  mkclone
  _install_clone
  r="$(rev)"
  [ "$(readlink "$(IROOT)/current")" = "versions/$r" ]
  [ -x "$(IROOT)/versions/$r/bin/claude-airlock" ]
  [ "$(readlink "$AIRLOCK_HOME/.local/bin/claude-airlock")" = "$(IROOT)/current/bin/claude-airlock" ]
  grep -qx "commit $r" "$(IROOT)/versions/$r/VERSION"
  [ ! -e "$(IROOT)/versions/$r/.git" ]
  ! readlink -f "$AIRLOCK_HOME/.local/bin/claude-airlock" | grep -q "^$CLONE" || false
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
    gitc commit -q --allow-empty -m "c$i"; _install_clone; revs+=("$(rev)"); sleep 1
  done
  [ "$(find "$(IROOT)/versions" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 3 ]
  for r in "${revs[2]}" "${revs[3]}" "${revs[4]}"; do [ -d "$(IROOT)/versions/$r" ]; done
  refute test -d "$(IROOT)/versions/${revs[0]}"
  refute test -d "$(IROOT)/versions/${revs[1]}"
}

@test "a rollback counts as an activation: the prune does not drop the version just made live" {
  mkclone
  gitc commit -q --allow-empty -m A; _install_clone; a="$(rev)"; sleep 1
  gitc commit -q --allow-empty -m B; _install_clone; b="$(rev)"; sleep 1
  gitc commit -q --allow-empty -m C; _install_clone; c="$(rev)"; sleep 1
  gitc checkout -q "$a"; _install_clone; sleep 1              # roll back to A
  [ "$(readlink "$(IROOT)/current")" = "versions/$a" ]
  gitc checkout -q -; gitc commit -q --allow-empty -m D; _install_clone; d="$(rev)"
  [ -d "$(IROOT)/versions/$d" ]; [ -d "$(IROOT)/versions/$a" ]; [ -d "$(IROOT)/versions/$c" ]
  refute test -d "$(IROOT)/versions/$b"
}

@test "local CA certs (untracked by design) are copied into the build context and listed" {
  mkclone
  printf 'CERT\n' > "$CLONE/image/certs/corp-root.crt"
  _install_clone
  [ -f "$(IROOT)/versions/$(rev)/image/certs/corp-root.crt" ]
  rm "$CLONE/image/certs/corp-root.crt"
  _install_clone
  refute test -f "$(IROOT)/versions/$(rev)/image/certs/corp-root.crt"
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
              'otto() { ~/dev/claude-airlock/bin/claude-airlock "$@"; }'; do
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
}
