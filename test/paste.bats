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
  # /tmp/airlock-<user>.
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
  for b in bash sed date mkdir chmod mktemp head od tr grep cp mv rm ls cat python3 id stat find; do
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
sleep 30 3>&- &    # the selection owner, holding whatever fds it inherited (bar bats' fd 3)
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

# --- AIRLOCK_PASTE_DIR: a drop box another account writes and this one's boxes read ---------

# A stat stub: owners and modes from files ("value path" lines), the real stat otherwise. Every
# directory above the test's tmpdir is reported root's and closed, as /srv would be: the
# runner's real /tmp is world-writable, which the check rightly refuses.
stub_stat() {
  FO="$BATS_TEST_TMPDIR/owners" FM="$BATS_TEST_TMPDIR/modes"
  : > "$FO"; : > "$FM"
  cat > "$STUBBIN/stat" <<STUB
#!/usr/bin/env bash
look() { awk -v p="\$2" '{ q = \$0; sub(/^[^ ]+ /, "", q) } q == p { v = \$1 } END { print v }' "\$1"; }
if [ "\$1" = -c ] && [ "\$2" = %u ]; then v="\$(look "$FO" "\$3")"; [ -n "\$v" ] && { echo "\$v"; exit 0; }; fi
if [ "\$1" = -c ] && [ "\$2" = %a ]; then v="\$(look "$FM" "\$3")"; [ -n "\$v" ] && { echo "\$v"; exit 0; }; fi
exec /usr/bin/stat "\$@"
STUB
  chmod +x "$STUBBIN/stat"
  local d; d="$(dirname "$(readlink -f "$BATS_TEST_TMPDIR")")"
  while :; do printf '0 %s\n' "$d" >> "$FO"; printf '755 %s\n' "$d" >> "$FM"; [ "$d" = / ] && break; d="$(dirname "$d")"; done
}
# The drop box: <tmpdir>/inbox/pastes, ours, 0755; the directories above it reported root's
# (as /srv/<inbox> would be), and the config naming it.
mkinbox() {
  T="$(readlink -f "$BATS_TEST_TMPDIR")" D="$(readlink -f "$BATS_TEST_TMPDIR")/inbox/pastes"
  mkdir -p "$D"; chmod 755 "$T" "$T/inbox" "$D"
  printf '0 %s\n' "$T" "$T/inbox" >> "$FO"
  export AIRLOCK_CONFIG="$BATS_TEST_TMPDIR/cfg"
  printf 'AIRLOCK_PASTE_DIR=%s\n' "$D" > "$AIRLOCK_CONFIG"
}

@test "paste dir: paste writes there, for any project and with no paste project set; list reads it" {
  p="$(mkproj)"; stub_stat; stub_clipboard; mkinbox
  export WAYLAND_DISPLAY=wayland-0 CLIPTEST=png
  run _paste "$p"
  [ "$status" -eq 0 ]
  [[ "$output" == "$D/"*.png ]]
  [ "$(head -c 4 "$output" | od -An -tx1 | tr -d ' \n')" = "89504e47" ]
  [ "$(stat -c %a "$output")" = 640 ]        # the reading account reads it through the group
  [ ! -d "$(pastes_dir "$p")" ]
  f="$output"
  run _paste "$p" list
  [ "$status" -eq 0 ]; [ "$output" = "$f" ]
}

@test "paste dir: --project does not apply, and says so" {
  p="$(mkproj)"; stub_stat; stub_clipboard; mkinbox
  export WAYLAND_DISPLAY=wayland-0 CLIPTEST=png
  run _paste "$p" --project "$p"
  [ "$status" -ne 0 ]; [[ "$output" == *"--project does not apply"* ]]
}

@test "paste dir: not writable by this account (its owner pastes): refused, nothing written; list still works" {
  p="$(mkproj)"; stub_stat; stub_clipboard; mkinbox
  chmod 555 "$D"
  export WAYLAND_DISPLAY=wayland-0 CLIPTEST=png
  run _paste "$p"
  [ "$status" -ne 0 ]; [[ "$output" == *"not writable by you"* ]]
  [ -z "$(ls -A "$D")" ]
  run _paste "$p" list
  [ "$status" -eq 0 ]
  chmod 755 "$D"
}

@test "paste dir: refused when relative, a symlink, open to others, under a dir that is not root's alone, home, protected, in the workspace, or holding a hard link" {
  p="$(mkproj)"; stub_stat; stub_clipboard; mkinbox
  export WAYLAND_DISPLAY=wayland-0 CLIPTEST=png
  refused() {  # refused <AIRLOCK_PASTE_DIR> <message part>
    printf 'AIRLOCK_PASTE_DIR=%s\n' "$1" > "$AIRLOCK_CONFIG"
    run _paste "$p"
    [ "$status" -ne 0 ] && [[ "$output" == *"$2"* ]] || { echo "not refused as '$2': $1: $output"; return 1; }
  }
  refused "inbox/pastes" "must be an absolute path"
  refused "$T/nope" "does not exist"
  refused "$T/a:b" "contains ':'"
  ln -s "$T/inbox/pastes" "$T/link"
  refused "$T/link" "is not its real path"
  refused "$T/inbox/pastes/" "is not its real path"
  chmod 775 "$T/inbox/pastes"; refused "$T/inbox/pastes" "is group/world-writable"; chmod 755 "$T/inbox/pastes"
  mkdir -p "$T/open/pastes"; chmod 777 "$T/open"; chmod 755 "$T/open/pastes"; printf '0 %s\n' "$T/open" >> "$FO"
  refused "$T/open/pastes" "'$T/open' (holding or being"
  # A parent of the writer's own (not root's): the writer could swap the paste dir for a link.
  mkdir -p "$T/mine/pastes"; chmod 755 "$T/mine" "$T/mine/pastes"
  refused "$T/mine/pastes" "'$T/mine' (above '$T/mine/pastes') must be root's"
  printf '4242 %s\n' "$T/inbox" >> "$FO"
  refused "$T/inbox/pastes" "must be root's"
  sed -i '$d' "$FO"
  mkdir -p "$p/pastes"; chmod 755 "$p/pastes"
  refused "$p/pastes" "inside the workspace"
  refused "$AIRLOCK_HOME" "itself"
  mkdir -p "$AIRLOCK_HOME/.ssh/pastes"; chmod 755 "$AIRLOCK_HOME" "$AIRLOCK_HOME/.ssh" "$AIRLOCK_HOME/.ssh/pastes"
  refused "$AIRLOCK_HOME/.ssh/pastes" "protected"
  printf x > "$T/elsewhere"; ln "$T/elsewhere" "$T/inbox/pastes/hl.png"
  refused "$T/inbox/pastes" "hard-linked"
}

@test "paste dir: every box mounts it READ-ONLY at its path and finds it as \$AIRLOCK_PASTES" {
  p="$(mkproj pd)"; stub_stat; mkinbox
  mkdir -p "$AIRLOCK_HOME/.config/claude-airlock"
  printf 'AIRLOCK_PASTE_DIR=%s\n' "$D" > "$AIRLOCK_HOME/.config/claude-airlock/config"
  _launch "$p" >/dev/null 2>&1 || true
  engine_args | grep -qx -- "$D:$D:ro"
  ! engine_args | grep -q -- "^$D:$D:rw" || false
  engine_args | grep -qx -- "AIRLOCK_PASTES=$D"
}

@test "no paste dir: no extra mount, \$AIRLOCK_PASTES is the project's scratch pastes" {
  p="$(mkproj np)"
  _launch "$p" >/dev/null 2>&1 || true
  engine_args | grep -qx -- "AIRLOCK_PASTES=$AIRLOCK_TMP_BASE/$(_slug "$p")/pastes"
}

@test "a paste dir that fails the check is not mounted: the launch warns and goes on" {
  p="$(mkproj bad)"; stub_stat; mkinbox
  chmod 777 "$D"
  mkdir -p "$AIRLOCK_HOME/.config/claude-airlock"
  printf 'AIRLOCK_PASTE_DIR=%s\n' "$D" > "$AIRLOCK_HOME/.config/claude-airlock/config"
  run _launch "$p"
  [[ "$output" == *"NOT mounting AIRLOCK_PASTE_DIR"*"group/world-writable"* ]]
  engine_args | grep -q '^ENGINE_INVOKED='
  ! engine_args | grep -q -- "$D:$D" || false
  ! engine_args | grep -q -- "^AIRLOCK_PASTES=" || false
  chmod 755 "$D"
}

@test "paste dir: a system directory (it would cover the box's own) is refused; so are ',' and a newline" {
  p="$(mkproj)"; stub_stat; stub_clipboard; mkinbox
  export WAYLAND_DISPLAY=wayland-0 CLIPTEST=png
  for d in /etc /usr/local/bin /var/lib /opt; do
    printf 'AIRLOCK_PASTE_DIR=%s\n' "$d" > "$AIRLOCK_CONFIG"
    run _paste "$p"
    [ "$status" -ne 0 ] && [[ "$output" == *"is a system directory"* ]] || { echo "$d: $output"; return 1; }
  done
  printf 'AIRLOCK_PASTE_DIR=%s\n' "$T/a,b" > "$AIRLOCK_CONFIG"
  run _paste "$p"; [ "$status" -ne 0 ]; [[ "$output" == *"contains ':', ','"* ]]
  printf 'AIRLOCK_PASTE_DIR="%s\nx"\n' "$T/a" > "$AIRLOCK_CONFIG"
  run _paste "$p"; [ "$status" -ne 0 ]; [[ "$output" == *"control character"* ]]
}

# The paste dir is checked while the launch is assembled; a prompt (pass, pinentry) may wait
# after that for as long as a person takes. A swap or a chmod in that time stops the launch.
swap_during_pass() {  # swap_during_pass <shell command run when pass is asked>
  printf '#!/usr/bin/env bash\n%s\necho secret\n' "$1" > "$STUBBIN/pass"; chmod +x "$STUBBIN/pass"
}
@test "paste dir swapped for a link while a secret prompt waited: the launch stops, nothing mounted" {
  p="$(mkproj sw)"; stub_stat; mkinbox
  mkdir -p "$AIRLOCK_HOME/.config/claude-airlock" "$AIRLOCK_HOME/.ssh"
  printf 'AIRLOCK_PASTE_DIR=%s\n' "$D" > "$AIRLOCK_HOME/.config/claude-airlock/config"
  _launch "$p" secret set TOKEN pass:x/y >/dev/null
  swap_during_pass "mv '$D' '$D.away' && ln -s '$AIRLOCK_HOME/.ssh' '$D'"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"paste dir $D changed after it was checked"* ]]
  ! engine_args | grep -q '^ENGINE_INVOKED=' || false
}
@test "paste dir made group-writable while a secret prompt waited: the launch stops" {
  p="$(mkproj sw2)"; stub_stat; mkinbox
  mkdir -p "$AIRLOCK_HOME/.config/claude-airlock"
  printf 'AIRLOCK_PASTE_DIR=%s\n' "$D" > "$AIRLOCK_HOME/.config/claude-airlock/config"
  _launch "$p" secret set TOKEN pass:x/y >/dev/null
  swap_during_pass "chmod 775 '$D'"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"changed after it was checked"* ]]
  ! engine_args | grep -q '^ENGINE_INVOKED=' || false
  chmod 755 "$D"
}
