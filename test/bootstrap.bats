#!/usr/bin/env bats
# scripts/bootstrap-tools.sh fetches tools the host then RUNS, from a directory a box can
# write to. These drive the real script with stubbed curl/git and prove it fails closed:
# a wrong tarball, a wrong binary or a moved tag leaves no tool behind; an existing copy
# is re-verified, never trusted; and nothing is written through a planted symlink.

load helper

setup() {
  setup_airlock_env
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R/scripts"
  cp "$BATS_TEST_DIRNAME/../scripts/bootstrap-tools.sh" "$R/scripts/"
  STUB_LOG="$BATS_TEST_TMPDIR/stub.log"; : > "$STUB_LOG"
  BATS_COMMIT="$(sed -n 's/^BATS_COMMIT="\(.*\)"$/\1/p' "$R/scripts/bootstrap-tools.sh")"

  # A stand-in shellcheck release: a tarball laid out like the real one.
  mkdir -p "$BATS_TEST_TMPDIR/rel/shellcheck-v0.11.0"
  printf '#!/bin/sh\necho "version: 0.11.0"\n' > "$BATS_TEST_TMPDIR/rel/shellcheck-v0.11.0/shellcheck"
  chmod +x "$BATS_TEST_TMPDIR/rel/shellcheck-v0.11.0/shellcheck"
  tar -cJf "$BATS_TEST_TMPDIR/sc.tar.xz" -C "$BATS_TEST_TMPDIR/rel" shellcheck-v0.11.0
  TAR_SHA="$(sha256sum "$BATS_TEST_TMPDIR/sc.tar.xz" | cut -d' ' -f1)"
  BIN_SHA="$(sha256sum "$BATS_TEST_TMPDIR/rel/shellcheck-v0.11.0/shellcheck" | cut -d' ' -f1)"

  cat > "$STUBBIN/uname" <<'EOF'
#!/bin/sh
echo x86_64
EOF
  cat > "$STUBBIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
while [ $# -gt 0 ]; do [ "$1" = -o ] && { cp "$STUB_TARBALL" "$2"; exit 0; }; shift; done
exit 1
EOF
  cat > "$STUBBIN/git" <<'EOF'
#!/usr/bin/env bash
echo "git $*" >> "$STUB_LOG"
if [ "$1" = -C ]; then echo "$STUB_HEAD"; exit 0; fi
dir="${*: -1}"
mkdir -p "$dir/bin"
printf '#!/bin/sh\necho "Bats stub"\n' > "$dir/bin/bats"
chmod +x "$dir/bin/bats"
EOF
  chmod +x "$STUBBIN/uname" "$STUBBIN/curl" "$STUBBIN/git"
  export STUB_LOG STUB_TARBALL="$BATS_TEST_TMPDIR/sc.tar.xz" STUB_HEAD="$BATS_COMMIT"
}

# Point the copied script's x86_64 pins at the stand-in release.
pin_to_stub() {
  sed -i "s/^SC_SHA_X86_64=.*/SC_SHA_X86_64=\"${1:-$TAR_SHA}\"/; s/^SC_BIN_SHA_X86_64=.*/SC_BIN_SHA_X86_64=\"${2:-$BIN_SHA}\"/" \
    "$R/scripts/bootstrap-tools.sh"
}
boot() { PATH="$STUBBIN:$PATH" run bash "$R/scripts/bootstrap-tools.sh"; }
T() { printf '%s' "$R/.tooling"; }

@test "the pinned release installs both tools, without running either" {
  pin_to_stub
  boot
  [ "$status" -eq 0 ]
  [ "$("$(T)/bin/shellcheck" --version)" = "version: 0.11.0" ]
  [[ "$output" != *"Bats stub"* ]]          # the stub clone's bats was never executed
  [[ "$output" != *"version: 0.11.0"* ]]    # nor the installed shellcheck
  [ "$(readlink "$(T)/bin/bats")" = "../bats-core/bin/bats" ]
}

@test "a tarball that does not match its sha256 is refused and nothing is installed" {
  boot                                    # real pins, stand-in tarball
  [ "$status" -ne 0 ]
  [[ "$output" == *"tarball does not match its pinned sha256"* ]]
  refute test -e "$(T)/bin/shellcheck"
}

@test "a binary that does not match its sha256 is refused even from a matching tarball" {
  pin_to_stub "$TAR_SHA" 0000000000000000000000000000000000000000000000000000000000000000
  boot
  [ "$status" -ne 0 ]
  [[ "$output" == *"binary does not match its pinned sha256"* ]]
  refute test -e "$(T)/bin/shellcheck"
}

@test "an existing shellcheck is re-hashed: a swapped one is replaced, a verified one kept" {
  pin_to_stub
  mkdir -p "$(T)/bin"
  printf '#!/bin/sh\necho "version: 0.11.0"  # swapped\n' > "$(T)/bin/shellcheck"
  chmod +x "$(T)/bin/shellcheck"
  boot
  [ "$status" -eq 0 ]
  cmp "$(T)/bin/shellcheck" "$BATS_TEST_TMPDIR/rel/shellcheck-v0.11.0/shellcheck"
  : > "$STUB_LOG"
  boot
  refute grep -q '^curl' "$STUB_LOG"      # verified copy: no re-download
}

@test "a bats tag that moved is refused and no bats is left" {
  pin_to_stub
  STUB_HEAD=0000000000000000000000000000000000000000 boot
  [ "$status" -ne 0 ]
  [[ "$output" == *"no longer points at"* ]]
  refute test -e "$(T)/bin/bats"
  refute test -e "$(T)/bats-core"
}

@test "an existing bats checkout is never inspected, only replaced" {
  pin_to_stub
  mkdir -p "$(T)/bin" "$(T)/bats-core"
  : > "$(T)/bats-core/PLANTED"
  printf '#!/bin/sh\necho EVIL\n' > "$(T)/bin/bats"; chmod +x "$(T)/bin/bats"
  boot
  [ "$status" -eq 0 ]
  refute test -e "$(T)/bats-core/PLANTED"
  [ "$(readlink "$(T)/bin/bats")" = "../bats-core/bin/bats" ]
  # git ran only to clone and to read the fresh clone's HEAD - never before the clone.
  [ "$(grep '^git' "$STUB_LOG" | head -1 | grep -c ' clone ')" -eq 1 ]
}

@test "a symlinked .tooling or .tooling/bin is refused, nothing written through it" {
  pin_to_stub
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  : > "$BATS_TEST_TMPDIR/elsewhere/shellcheck"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$R/.tooling"
  boot
  [ "$status" -ne 0 ]
  [[ "$output" == *"is a symlink"* ]]
  [ ! -s "$BATS_TEST_TMPDIR/elsewhere/shellcheck" ]
  rm "$R/.tooling"; mkdir -p "$R/.tooling"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$R/.tooling/bin"
  boot
  [ "$status" -ne 0 ]
  [ -e "$BATS_TEST_TMPDIR/elsewhere/shellcheck" ]   # not deleted through the link
  [ ! -s "$BATS_TEST_TMPDIR/elsewhere/shellcheck" ]
}

@test "a swapped shellcheck is removed even when the re-fetch then fails" {
  mkdir -p "$(T)/bin"
  printf '#!/bin/sh\necho EVIL\n' > "$(T)/bin/shellcheck"; chmod +x "$(T)/bin/shellcheck"
  boot                                    # real pins: the stand-in tarball fails its sha256
  [ "$status" -ne 0 ]
  refute test -e "$(T)/bin/shellcheck"
}

@test "a planted bin/bats is removed even when the clone is then refused" {
  pin_to_stub
  mkdir -p "$(T)/bin"
  printf '#!/bin/sh\necho EVIL\n' > "$(T)/bin/bats"; chmod +x "$(T)/bin/bats"
  STUB_HEAD=0000000000000000000000000000000000000000 boot
  [ "$status" -ne 0 ]
  refute test -e "$(T)/bin/bats"
}

@test "the download dir is cleaned up on success and on failure" {
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  boot                                    # fails on the tarball sha
  [ "$status" -ne 0 ]
  [ -z "$(ls -A "$TMPDIR")" ]
  pin_to_stub
  boot
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$TMPDIR")" ]
}
