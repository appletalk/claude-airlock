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
    PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" \
    HOME="$AIRLOCK_HOME" \
    TERM=xterm \
    AIRLOCK_ENGINE="$ENGINE" \
    AIRLOCK_IMAGE="claude-airlock:dev" \
    AIRLOCK_TMP_BASE="$TMP_BASE" \
    PNG_B64="$PNG_B64" \
    ${CLIPTEST:+CLIPTEST="$CLIPTEST"} \
    ${WAYLAND_DISPLAY:+WAYLAND_DISPLAY="$WAYLAND_DISPLAY"} \
    ${DISPLAY:+DISPLAY="$DISPLAY"} \
    ${AIRLOCK_PASTE_PROJECT:+AIRLOCK_PASTE_PROJECT="$AIRLOCK_PASTE_PROJECT"} \
    bash "$AIRLOCK" paste "$@" </dev/null
}

pastes_dir() { printf '%s' "$TMP_BASE/$(_slug "$1")/pastes"; }

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
  stub_clipboard
  run _paste "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no graphical session"* ]]
}

@test "a Wayland session without wl-paste names the package to install" {
  p="$(mkproj)"; export AIRLOCK_PASTE_PROJECT="$p" WAYLAND_DISPLAY=wayland-0
  run _paste "$p"                              # no stubs installed
  [ "$status" -ne 0 ]
  [[ "$output" == *"wl-clipboard"* ]]
}

@test "an X11 session without xclip names the package to install" {
  p="$(mkproj)"; export AIRLOCK_PASTE_PROJECT="$p" DISPLAY=:0
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
  for n in 20260101-000001 20260101-000002 20260101-000003; do
    base64 -d <<<"$PNG_B64" > "$d/$n.png"
  done
  run _paste "$p" list 2
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == *"20260101-000003.png" ]]
  [[ "${lines[1]}" == *"20260101-000002.png" ]]
}

@test "only the newest 50 pastes are retained" {
  p="$(mkproj)"; export AIRLOCK_PASTE_PROJECT="$p" WAYLAND_DISPLAY=wayland-0 CLIPTEST=png
  stub_clipboard
  d="$(pastes_dir "$p")"; mkdir -p "$d"
  for i in $(seq 1 55); do base64 -d <<<"$PNG_B64" > "$d/$(printf '20260101-%06d' "$i").png"; done
  run _paste "$p"                                  # the 56th
  [ "$status" -eq 0 ]
  run _paste "$p" list 999
  [ "${#lines[@]}" -eq 50 ]
  [ ! -e "$d/20260101-000001.png" ]                # oldest pruned
  [ -e "$d/20260101-000055.png" ]                  # newest kept
}

@test "--project overrides the configured default" {
  p="$(mkproj)"; other="$(mkproj other)"
  export AIRLOCK_PASTE_PROJECT="$p" WAYLAND_DISPLAY=wayland-0 CLIPTEST=png
  stub_clipboard
  run _paste "$p" --project "$other"
  [ "$status" -eq 0 ]
  [[ "$output" == "$(pastes_dir "$other")/"* ]]
}
