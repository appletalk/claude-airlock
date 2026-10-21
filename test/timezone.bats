#!/usr/bin/env bats
# The box's timezone: AIRLOCK_TZ, else TZ, else the host's zone (timedatectl, then where
# /etc/localtime points), else UTC; only a plain zone name reaches the box.

load helper

setup() { setup_airlock_env; }

# A timedatectl stub: the zone the host reports (empty: it fails, as without systemd).
host_zone() {
  if [ -n "$1" ]; then printf '#!/bin/sh\necho "%s"\n' "$1"; else printf '#!/bin/sh\nexit 1\n'; fi > "$STUBBIN/timedatectl"
  chmod +x "$STUBBIN/timedatectl"
}
box_tz() { : > "$ENGINE_ARGS_FILE"; _launch "$(mkproj "${1:-tz}")" >/dev/null 2>"$BATS_TEST_TMPDIR/err" || true; engine_args | sed -n 's/^TZ=//p'; }

@test "the host's zone reaches the box when nothing sets one" {
  host_zone America/Vancouver
  [ "$(box_tz)" = America/Vancouver ]
}

@test "without timedatectl, where this host's /etc/localtime points (else UTC)" {
  host_zone ""
  want="$(readlink /etc/localtime 2>/dev/null)" || want=""
  case "$want" in */zoneinfo/*) want="${want#*/zoneinfo/}" ;; *) want=UTC ;; esac
  [ "$(box_tz)" = "$want" ]
}

@test "TZ beats the host's zone, and AIRLOCK_TZ beats both" {
  host_zone America/Vancouver
  TEST_TZ=Asia/Tokyo; [ "$(box_tz a)" = Asia/Tokyo ]
  AIRLOCK_TZ=Europe/Berlin; [ "$(box_tz b)" = Europe/Berlin ]
}

@test "no timedatectl answer: no warning either way" {
  host_zone ""
  box_tz >/dev/null
  ! grep -q timezone "$BATS_TEST_TMPDIR/err"
}

@test "anything but a plain zone name: UTC, with a warning" {
  host_zone America/Vancouver
  for bad in '../../etc/passwd' '/etc/localtime' 'America/Vancouver;id' 'America//X' 'Europe/Berlin '; do
    AIRLOCK_TZ="$bad"
    [ "$(box_tz)" = UTC ] || { echo "passed: $bad"; return 1; }
    grep -q 'is not a plain zone name' "$BATS_TEST_TMPDIR/err"
  done
  AIRLOCK_TZ=:Etc/GMT+8; [ "$(box_tz)" = Etc/GMT+8 ]
}

@test "the box-writable .airlock/config can't set the timezone" {
  host_zone America/Vancouver
  p="$(mkproj cfg)"; write_config "$p" "tz = Asia/Tokyo
AIRLOCK_TZ = Asia/Tokyo
timezone = Asia/Tokyo"
  : > "$ENGINE_ARGS_FILE"; _launch "$p" >/dev/null 2>&1 || true
  [ "$(engine_args | sed -n 's/^TZ=//p')" = America/Vancouver ]
}
