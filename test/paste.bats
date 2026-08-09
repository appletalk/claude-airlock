#!/usr/bin/env bats
# `airlock paste` — the clipboard-to-file bridge.
#
# The box cannot read a clipboard, so an image crosses as a FILE at a path both sides
# agree on. What these tests pin down is mostly failure behaviour, because the dangerous
# outcome is not an error — it is a STALE file being read as fresh. Every failure path
# must therefore leave no output file at all.
#
# Both clipboard backends are stubbed, so the X11 branch is exercised on a Wayland CI
# runner and vice versa. The converter is stubbed too: whether the host happens to have
# ImageMagick must not decide what these tests assert.

load helper

setup() {
  setup_airlock_env
  # A 1x1 PNG and a BMP header, as the two shapes a real clipboard offers.
  PNG_B64='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='
  # Keep scratch inside the bats tmpdir: the suite must not write to the real
  # /tmp/airlock, and inside a container that path is root-owned anyway.
  TMP_BASE="$BATS_TEST_TMPDIR/airlock-tmp"
  export PNG_B64 TMP_BASE
}

# Stub both clipboard tools. $CLIPTEST selects what the "clipboard" holds.
stub_clipboard() {
  cat > "$STUBBIN/wl-paste" <<'EOF'
#!/usr/bin/env bash
case "$CLIPTEST" in
  png)  [ "$1" = --list-types ] && { echo "image/png"; exit 0; }; base64 -d <<<"$PNG_B64" ;;
  bmp)  [ "$1" = --list-types ] && { echo "image/bmp"; exit 0; }; printf 'BM\x76\x00\x00\x00body' ;;
  text) [ "$1" = --list-types ] && { echo "text/plain"; exit 0; }; echo hello ;;
  empty)[ "$1" = --list-types ] && { echo "image/png"; exit 0; }; : ;;
esac
EOF
  cat > "$STUBBIN/xclip" <<'EOF'
#!/usr/bin/env bash
# xclip -selection clipboard -t <TYPE> -o
for a in "$@"; do [ "$a" = TARGETS ] && t=targets; done
case "$CLIPTEST" in
  png)  [ "${t:-}" = targets ] && { echo "image/png"; exit 0; }; base64 -d <<<"$PNG_B64" ;;
  bmp)  [ "${t:-}" = targets ] && { echo "image/bmp"; exit 0; }; printf 'BM\x76\x00\x00\x00body' ;;
  text) [ "${t:-}" = targets ] && { echo "text/plain"; exit 0; }; echo hello ;;
esac
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/wl-copy"
  chmod +x "$STUBBIN/wl-paste" "$STUBBIN/xclip" "$STUBBIN/wl-copy"
}

# Run `airlock paste` hermetically. Display vars and the paste project are passed
# explicitly because the shared _launch scrubs the environment with `env -i`.
_paste() {
  local proj="$1"; shift
  cd "$proj" || return 1
  env -i \
    PATH="${PATH_OVERRIDE:-$STUBBIN:/usr/bin:/usr/sbin:/bin}" \
    HOME="$AIRLOCK_HOME" \
    TERM=xterm \
    AIRLOCK_ENGINE="$ENGINE" \
    AIRLOCK_IMAGE="claude-airlock:dev" \
    AIRLOCK_TMP_BASE="$TMP_BASE" \
    PNG_B64="$PNG_B64" \
    ${CLIPTEST:+CLIPTEST="$CLIPTEST"} \
    ${AIRLOCK_CONFIG:+AIRLOCK_CONFIG="$AIRLOCK_CONFIG"} \
    ${WAYLAND_DISPLAY:+WAYLAND_DISPLAY="$WAYLAND_DISPLAY"} \
    ${DISPLAY:+DISPLAY="$DISPLAY"} \
    ${AIRLOCK_PASTE_PROJECT:+AIRLOCK_PASTE_PROJECT="$AIRLOCK_PASTE_PROJECT"} \
    bash "$AIRLOCK" paste "$@" </dev/null
}

pastes_dir() { printf '%s' "$TMP_BASE/$(_slug "$1")/pastes"; }

# Replace the real /usr/bin with symlinks to exactly the binaries the paste path needs,
# minus the clipboard tools. A "tool is not installed" test must not pass merely because
# the CI runner happens to lack xclip: on a developer's desktop the same test takes a
# different branch, and against a live Wayland socket it would read their real clipboard.
minimal_path() {
  MINBIN="$BATS_TEST_TMPDIR/minbin"; mkdir -p "$MINBIN"
  local b src
  for b in bash sed date mkdir chmod mktemp head od tr grep cp mv rm ls cat python3; do
    src="$(command -v "$b" 2>/dev/null)" && ln -sf "$src" "$MINBIN/$b"
  done
  PATH_OVERRIDE="$STUBBIN:$MINBIN"
}

@test "paste refuses without AIRLOCK_PASTE_PROJECT and says how to set it" {
  p="$(mkproj)"
  export WAYLAND_DISPLAY=wayland-0 CLIPTEST=png
  stub_clipboard
  run _paste "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"AIRLOCK_PASTE_PROJECT is not set"* ]]
  [[ "$output" == *"--project"* ]]
}

@test "paste rejects a project directory that does not exist" {
  p="$(mkproj)"
  export WAYLAND_DISPLAY=wayland-0 CLIPTEST=png AIRLOCK_PASTE_PROJECT="$BATS_TEST_TMPDIR/nope"
  stub_clipboard
  run _paste "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"paste project not found"* ]]
}

@test "no graphical session is a clear refusal, not a crash" {
  p="$(mkproj)"; export AIRLOCK_PASTE_PROJECT="$p"
  # _paste forwards DISPLAY/WAYLAND_DISPLAY when the caller has them, which is the point
  # for the tests below - but it means this one only tested "no graphical session" on a
  # machine that happens to have none. Green in a container, red on any desktop. Clear
  # them explicitly rather than inheriting whatever the runner happens to be.
  unset DISPLAY WAYLAND_DISPLAY
  stub_clipboard
  run _paste "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no graphical session"* ]]
}

@test "a Wayland session without wl-paste names the package to install" {
  p="$(mkproj)"; unset DISPLAY
  export AIRLOCK_PASTE_PROJECT="$p" WAYLAND_DISPLAY=wayland-0
  minimal_path                                 # never rely on the HOST lacking wl-paste
  run _paste "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"wl-clipboard"* ]]
}

@test "an X11 session without xclip names the package to install" {
  # Must be X11 ONLY: a runner with a live Wayland session would take the other branch.
  p="$(mkproj)"; unset WAYLAND_DISPLAY
  export AIRLOCK_PASTE_PROJECT="$p" DISPLAY=:0
  minimal_path
  run _paste "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"xclip"* ]]
}

@test "wayland: a PNG on the clipboard lands as a PNG and the path is printed" {
  p="$(mkproj)"; export AIRLOCK_PASTE_PROJECT="$p" WAYLAND_DISPLAY=wayland-0 CLIPTEST=png
  stub_clipboard
  run _paste "$p"
  [ "$status" -eq 0 ]
  [ -s "$output" ]
  [[ "$output" == "$(pastes_dir "$p")/"*.png ]]
  [ "$(head -c 4 "$output" | od -An -tx1 | tr -d ' \n')" = "89504e47" ]
}

@test "x11: the xclip branch works the same way" {
  p="$(mkproj)"; export AIRLOCK_PASTE_PROJECT="$p" DISPLAY=:0 CLIPTEST=png
  stub_clipboard
  run _paste "$p"
  [ "$status" -eq 0 ]
  [ -s "$output" ]
  [ "$(head -c 4 "$output" | od -An -tx1 | tr -d ' \n')" = "89504e47" ]
}

@test "under XWayland the native reader wins over xclip" {
  p="$(mkproj)"; export AIRLOCK_PASTE_PROJECT="$p" WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 CLIPTEST=png
  stub_clipboard
  # Make xclip fatal: if the launcher picks it with WAYLAND_DISPLAY set, this test fails.
  printf '#!/usr/bin/env bash\necho XCLIP-WAS-USED >&2\nexit 3\n' > "$STUBBIN/xclip"
  chmod +x "$STUBBIN/xclip"
  run _paste "$p"
  [ "$status" -eq 0 ]
  [[ "$output" != *"XCLIP-WAS-USED"* ]]
}

@test "a clipboard with no image fails and writes nothing" {
  p="$(mkproj)"; export AIRLOCK_PASTE_PROJECT="$p" WAYLAND_DISPLAY=wayland-0 CLIPTEST=text
  stub_clipboard
  run _paste "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no image on the clipboard"* ]]
  run _paste "$p" list
  [ -z "$output" ]
}

@test "an image type that reads back empty fails and writes nothing" {
  p="$(mkproj)"; export AIRLOCK_PASTE_PROJECT="$p" WAYLAND_DISPLAY=wayland-0 CLIPTEST=empty
  stub_clipboard
  run _paste "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"produced no data"* ]]
  run _paste "$p" list
  [ -z "$output" ]
}

@test "BMP is converted, not stored raw" {
  p="$(mkproj)"; export AIRLOCK_PASTE_PROJECT="$p" WAYLAND_DISPLAY=wayland-0 CLIPTEST=bmp
  stub_clipboard
  # Stub the converter so the assertion does not depend on the host having ImageMagick.
  cat > "$STUBBIN/magick" <<'EOF'
#!/usr/bin/env bash
out="${2#png:}"; base64 -d <<<"$PNG_B64" > "$out"
EOF
  chmod +x "$STUBBIN/magick"
  run _paste "$p"
  [ "$status" -eq 0 ]
  [ "$(head -c 4 "$output" | od -An -tx1 | tr -d ' \n')" = "89504e47" ]
}

@test "a FAILING converter leaves no file behind - stale must be impossible" {
  p="$(mkproj)"; export AIRLOCK_PASTE_PROJECT="$p" WAYLAND_DISPLAY=wayland-0 CLIPTEST=png
  stub_clipboard
  run _paste "$p"                                  # one good paste first
  [ "$status" -eq 0 ]
  good="$output"

  export CLIPTEST=bmp
  # The stub must write a PARTIAL file before failing. A converter that dies having
  # written nothing leaves no trace either way, so it cannot prove the cleanup runs —
  # the hazard is a half-written file surviving and later being read as a real paste.
  cat > "$STUBBIN/magick" <<'EOF'
#!/usr/bin/env bash
out="${2#png:}"; printf 'truncated-garbage' > "$out"; exit 1
EOF
  chmod +x "$STUBBIN/magick"
  run _paste "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not convert"* ]]

  # Exactly the earlier paste survives: the failed grab added nothing.
  run _paste "$p" list
  [ "$output" = "$good" ]
}

@test "list returns newest first and honours N" {
  p="$(mkproj)"; export AIRLOCK_PASTE_PROJECT="$p" WAYLAND_DISPLAY=wayland-0 CLIPTEST=png
  stub_clipboard
  d="$(pastes_dir "$p")"; mkdir -p "$d"
  for n in 20260101-000000001 20260101-000000002 20260101-000000003; do
    base64 -d <<<"$PNG_B64" > "$d/$n.png"
  done
  run _paste "$p" list 2
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == *"20260101-000000003.png" ]]
  [[ "${lines[1]}" == *"20260101-000000002.png" ]]
}

@test "only the newest 20 pastes are retained" {
  p="$(mkproj)"; export AIRLOCK_PASTE_PROJECT="$p" WAYLAND_DISPLAY=wayland-0 CLIPTEST=png
  stub_clipboard
  d="$(pastes_dir "$p")"; mkdir -p "$d"
  for i in $(seq 1 25); do base64 -d <<<"$PNG_B64" > "$d/$(printf '20260101-%09d' "$i").png"; done
  run _paste "$p"                                  # the 26th
  [ "$status" -eq 0 ]
  run _paste "$p" list 999
  [ "${#lines[@]}" -eq 20 ]
  [ ! -e "$d/20260101-000000001.png" ]             # oldest pruned
  [ -e "$d/20260101-000000025.png" ]               # newest kept
}

@test "--project overrides the configured default" {
  p="$(mkproj)"; other="$(mkproj other)"
  export AIRLOCK_PASTE_PROJECT="$p" WAYLAND_DISPLAY=wayland-0 CLIPTEST=png
  stub_clipboard
  run _paste "$p" --project "$other"
  [ "$status" -eq 0 ]
  [[ "$output" == "$(pastes_dir "$other")/"* ]]
}

# --- regressions found by review (2026-08-09) ------------------------------------

@test "a clipboard tool that FAILS is reported, not a silent exit" {
  p="$(mkproj)"; export AIRLOCK_PASTE_PROJECT="$p" WAYLAND_DISPLAY=wayland-0 CLIPTEST=png
  stub_clipboard
  # The real failure mode: `wl-paste --list-types` exits nonzero. Under `set -e` an
  # assignment from a command substitution took that status and killed the script with
  # no output at all, so the "no image on the clipboard" branch was unreachable.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBBIN/wl-paste"; chmod +x "$STUBBIN/wl-paste"
  run _paste "$p"
  [ "$status" -ne 0 ]
  [ -n "$output" ]                                   # the whole point: it must SAY something
  [[ "$output" == *"no image on the clipboard"* ]]
}

@test "a clipboard read that fails after type detection is reported" {
  p="$(mkproj)"; export AIRLOCK_PASTE_PROJECT="$p" WAYLAND_DISPLAY=wayland-0 CLIPTEST=png
  stub_clipboard
  cat > "$STUBBIN/wl-paste" <<'EOF'
#!/usr/bin/env bash
[ "$1" = --list-types ] && { echo "image/png"; exit 0; }
exit 4
EOF
  chmod +x "$STUBBIN/wl-paste"
  run _paste "$p"
  [ "$status" -ne 0 ]
  [ -n "$output" ]
  [[ "$output" == *"reading the clipboard failed"* ]] || [[ "$output" == *"produced no data"* ]]
}

@test "the prune never deletes the paste it just wrote" {
  p="$(mkproj)"; export AIRLOCK_PASTE_PROJECT="$p" WAYLAND_DISPLAY=wayland-0 CLIPTEST=png
  stub_clipboard
  d="$(pastes_dir "$p")"; mkdir -p "$d"
  # Hand-copied files, which the tool's own error message tells people to drop here.
  # 's' sorts after every digit, so a lexical prune would take the NEW file instead.
  for i in $(seq 1 25); do base64 -d <<<"$PNG_B64" > "$d/screenshot-$i.png"; done
  run _paste "$p"
  [ "$status" -eq 0 ]
  [ -e "$output" ]                                   # the printed path must still exist
  new="$output"
  run _paste "$p" list 1
  [ "$output" = "$new" ]                             # and be the newest
  # And the foreign files are left strictly alone - never listed out of order, never
  # pruned. Deleting a file this tool did not write would be the worst surprise of all.
  [ -e "$d/screenshot-1.png" ]
  [ -e "$d/screenshot-25.png" ]
  run _paste "$p" list 999
  [ "${#lines[@]}" -eq 1 ]
}

@test "the prune spares the new paste even when 20+ others sort after it" {
  p="$(mkproj)"; export AIRLOCK_PASTE_PROJECT="$p" WAYLAND_DISPLAY=wayland-0 CLIPTEST=png
  stub_clipboard
  d="$(pastes_dir "$p")"; mkdir -p "$d"
  # Future-dated pastes: a clock that moved backwards (timezone change, NTP correcting a
  # fast clock) puts the NEW file first in lexical order, so a prune that does not
  # exclude it deletes the very paste it just printed and still exits 0.
  for i in $(seq 1 25); do base64 -d <<<"$PNG_B64" > "$d/$(printf '20990101-%09d' "$i").png"; done
  run _paste "$p"
  [ "$status" -eq 0 ]
  [ -e "$output" ]                                   # printed path must exist afterwards
}

@test "a converter that writes garbage and exits 0 is rejected" {
  p="$(mkproj)"; export AIRLOCK_PASTE_PROJECT="$p" WAYLAND_DISPLAY=wayland-0 CLIPTEST=bmp
  stub_clipboard
  cat > "$STUBBIN/magick" <<'EOF'
#!/usr/bin/env bash
out="${2#png:}"; printf 'NOT-A-PNG-AT-ALL' > "$out"; exit 0
EOF
  chmod +x "$STUBBIN/magick"
  run _paste "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a PNG"* ]]
  run _paste "$p" list
  [ -z "$output" ]                                   # nothing published
}

@test "filenames have ONE shape, so list order is creation order reversed" {
  p="$(mkproj)"; export AIRLOCK_PASTE_PROJECT="$p" WAYLAND_DISPLAY=wayland-0 CLIPTEST=png
  stub_clipboard
  run _paste "$p"; first="$output"
  run _paste "$p"; second="$output"
  run _paste "$p"; third="$output"
  [ "$first" != "$second" ] && [ "$second" != "$third" ]
  for f in "$first" "$second" "$third"; do
    [[ "$(basename "$f")" =~ ^[0-9]{8}-[0-9]{9}\.png$ ]]   # YYYYMMDD-HHMMSSmmm.png
  done
  run _paste "$p" list 3
  [ "${lines[0]}" = "$third" ]
  [ "${lines[1]}" = "$second" ]
  [ "${lines[2]}" = "$first" ]
}

@test "a RELATIVE paste project is refused, not resolved against \$PWD" {
  p="$(mkproj)"; export AIRLOCK_PASTE_PROJECT="somewhere/relative" WAYLAND_DISPLAY=wayland-0 CLIPTEST=png
  stub_clipboard
  run _paste "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ABSOLUTE path"* ]]
}

@test "AIRLOCK_TMP_BASE set in the CONFIG is refused (host and box would diverge)" {
  p="$(mkproj)"; export AIRLOCK_PASTE_PROJECT="$p" WAYLAND_DISPLAY=wayland-0 CLIPTEST=png
  stub_clipboard
  export AIRLOCK_CONFIG="$BATS_TEST_TMPDIR/cfg"
  printf 'AIRLOCK_TMP_BASE=%s\n' "$BATS_TEST_TMPDIR/from-config" > "$AIRLOCK_CONFIG"
  run _paste "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must come from the"* ]]
  [ ! -d "$BATS_TEST_TMPDIR/from-config" ]
}

@test "--copy does not hang a command substitution" {
  p="$(mkproj)"; export AIRLOCK_PASTE_PROJECT="$p" WAYLAND_DISPLAY=wayland-0 CLIPTEST=png
  stub_clipboard
  # Real wl-copy/xclip -i fork a selection owner that keeps running and INHERITS stdout,
  # so `out=$(airlock paste --copy)` blocks until the clipboard next changes.
  cat > "$STUBBIN/wl-copy" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
sleep 30 &          # the selection owner, holding whatever fds it inherited
exit 0
EOF
  chmod +x "$STUBBIN/wl-copy"

  # bats' own `run` captures through a temp file, not a pipe, so it CANNOT reproduce
  # this. The capture has to be a real command substitution, in its own script.
  cat > "$BATS_TEST_TMPDIR/capture.sh" <<EOF
#!/usr/bin/env bash
out="\$(env -i \
  PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" TERM=xterm \
  AIRLOCK_ENGINE="$ENGINE" AIRLOCK_IMAGE="claude-airlock:dev" \
  AIRLOCK_TMP_BASE="$TMP_BASE" PNG_B64="$PNG_B64" CLIPTEST=png \
  WAYLAND_DISPLAY=wayland-0 AIRLOCK_PASTE_PROJECT="$p" \
  bash "$AIRLOCK" paste --copy)"
printf '%s' "\$out"
EOF
  run timeout 15 bash "$BATS_TEST_TMPDIR/capture.sh"
  [ "$status" -ne 124 ]                              # 124 = timed out = the hang
  [ "$status" -eq 0 ]
  [ -e "$output" ]
}
