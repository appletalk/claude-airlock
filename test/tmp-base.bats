#!/usr/bin/env bats
# The default scratch base is per user, /tmp/airlock-<user>, and refused when it is not
# that user's alone: in a shared /tmp anyone can make the name first, and whoever owns it
# (or can write to it) can read or swap what every box of that user mounts.

load helper

setup() {
  setup_airlock_env
  ME="$(id -un)"
}

# The launcher's own definitions, evaluated on their own: the default and the check.
tmp_fns() {
  sed -n -e '/^_AIRLOCK_TMP_DEFAULT=/p' -e '/^_airlock_tmp_base_ready() {/,/^}/p' "$AIRLOCK"
}

@test "the default base is /tmp/airlock-<user>" {
  run bash -c "$(tmp_fns)"'; printf %s "$_AIRLOCK_TMP_DEFAULT"'
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/airlock-$ME" ]
}

@test "a missing default base is made 0700; one of ours (0700) is accepted" {
  b="$BATS_TEST_TMPDIR/tbase"   # not "base": the helper's share base
  run bash -c "$(tmp_fns)"'; _AIRLOCK_TMP_DEFAULT="$1"; _airlock_tmp_base_ready "$1" && _airlock_tmp_base_ready "$1"' _ "$b"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$b")" = 700 ]
}

@test "a default base open to others, a symlink, or someone else's is refused" {
  b="$BATS_TEST_TMPDIR/tbase"   # not "base": the helper's share base
  check() { bash -c "$(tmp_fns)"'; _AIRLOCK_TMP_DEFAULT="$1"; _airlock_tmp_base_ready "$1"' _ "$b" 2>&1; }
  mkdir -m 0755 "$b"
  run check; [ "$status" -ne 0 ]; [[ "$output" == *"is not yours alone"* ]]
  chmod 0700 "$b"; mv "$b" "$b.real"; ln -s "$b.real" "$b"
  run check; [ "$status" -ne 0 ]; [[ "$output" == *"is not yours alone"* ]]
  rm "$b"; mv "$b.real" "$b"
  # Another owner: a stat stub answers for the base alone.
  printf '#!/usr/bin/env bash\n[ "$1 $2 $3" = "-c %%u %s" ] && { echo 4242; exit 0; }\nexec /usr/bin/stat "$@"\n' "$b" > "$STUBBIN/stat"
  chmod +x "$STUBBIN/stat"
  run env PATH="$STUBBIN:/usr/bin:/bin" bash -c "$(tmp_fns)"'; _AIRLOCK_TMP_DEFAULT="$1"; _airlock_tmp_base_ready "$1"' _ "$b"
  [ "$status" -ne 0 ]; [[ "$output" == *"is not yours alone"* ]]
}

@test "special bits alone (setgid, sticky) on our own 0700 base are fine" {
  b="$BATS_TEST_TMPDIR/tbase"; mkdir -m 2700 "$b"
  run bash -c "$(tmp_fns)"'; _AIRLOCK_TMP_DEFAULT="$1"; _airlock_tmp_base_ready "$1"' _ "$b"
  [ "$status" -eq 0 ]
}

@test "a launch with the default base refuses one someone else owns, and starts nothing" {
  b="/tmp/airlock-$ME"
  [ ! -e "$b" ] || [ "$(stat -c %u:%a "$b")" = "$(id -u):700" ] || skip "$b exists and is not ours alone"
  printf '#!/usr/bin/env bash\n[ "$1 $2 $3" = "-c %%u %s" ] && { echo 4242; exit 0; }\nexec /usr/bin/stat "$@"\n' "$b" > "$STUBBIN/stat"
  chmod +x "$STUBBIN/stat"
  p="$(mkproj sq)"
  unset AIRLOCK_TMP_BASE          # _launch passes it only when set: the launcher's default
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not yours alone"* ]]
  ! engine_args | grep -q '^ENGINE_INVOKED=' || false
}

@test "the host wrapper refuses a default base open to others, as the launcher does" {
  command -v zsh >/dev/null || skip "zsh not installed"
  b="/tmp/airlock-$ME"
  [ ! -e "$b" ] || [ "$(stat -c %u:%a "$b")" = "$(id -u):700" ] || skip "$b exists and is not ours alone"
  printf '#!/usr/bin/env bash\n[ "$1 $2 $3" = "-c %%a %s" ] && { echo 755; exit 0; }\nexec /usr/bin/stat "$@"\n' "$b" > "$STUBBIN/stat"
  chmod +x "$STUBBIN/stat"
  printf '#!/usr/bin/env bash\necho CLAUDE-RAN\n' > "$STUBBIN/claude"; chmod +x "$STUBBIN/claude"
  p="$(mkproj tbw)"
  run env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" TERM=xterm \
    zsh -c "source '$BATS_TEST_DIRNAME/../shell/claude-airlock.zsh' >/dev/null 2>&1; cd '$p' || exit 1; claude" </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not yours alone"* ]]
  [[ "$output" != *CLAUDE-RAN* ]]
}

@test "a base set in the environment is the user's choice: not checked" {
  b="$BATS_TEST_TMPDIR/custom"; mkdir -m 0777 "$b"
  run bash -c "$(tmp_fns)"'; _airlock_tmp_base_ready "$1"' _ "$b"
  [ "$status" -eq 0 ]
}

@test "airlock tmp, with no base set, names /tmp/airlock-<user>/<slug>" {
  # The real default (it is per user, so this touches only ours): made if missing, left empty.
  b="/tmp/airlock-$ME"
  [ ! -e "$b" ] || [ "$(stat -c %u:%a "$b")" = "$(id -u):700" ] || skip "$b exists and is not ours alone"
  p="$(mkproj tb)"
  run env -i PATH="/usr/bin:/bin" HOME="$AIRLOCK_HOME" bash -c 'cd "$1" && bash "$2" tmp' _ "$p" "$AIRLOCK"
  [ "$status" -eq 0 ]
  [ "$output" = "$b/$(_slug "$p")" ]
  rmdir "$output"
}

@test "the host wrapper exports the same default scratch dir as the launcher" {
  command -v zsh >/dev/null || skip "zsh not installed"
  b="/tmp/airlock-$ME"
  [ ! -e "$b" ] || [ "$(stat -c %u:%a "$b")" = "$(id -u):700" ] || skip "$b exists and is not ours alone"
  p="$(mkproj tbz)"
  printf '#!/usr/bin/env bash\nprintf %%s "$AIRLOCK_TMP" > "%s/wrapper-tmp"\n' "$BATS_TEST_TMPDIR" > "$STUBBIN/claude"
  chmod +x "$STUBBIN/claude"
  env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" TERM=xterm \
    zsh -c "source '$BATS_TEST_DIRNAME/../shell/claude-airlock.zsh' >/dev/null 2>&1; cd '$p' || exit 1; claude" </dev/null || true
  [ "$(cat "$BATS_TEST_TMPDIR/wrapper-tmp")" = "$b/$(_slug "$p")" ]
  rmdir "$b/$(_slug "$p")" 2>/dev/null || true
}
