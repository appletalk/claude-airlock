#!/usr/bin/env bats
# airlock exec -- COMMAND: one command in the box instead of Claude, for scripts and service
# units. What must hold: the command reaches the engine exactly (after the image, nothing in
# between, never through a shell), the box is the one `airlock shell` gets, its exit status is
# the launcher's, and a run without a terminal asks the engine for none.

load helper

setup() { setup_airlock_env; }
teardown() { [ -z "${PEER:-}" ] || kill "$PEER" 2>/dev/null || true; }

# The engine argv after the image: what the box runs.
box_cmd() { engine_args | sed -n '/^claude-airlock:dev$/,/^ENGINE_INVOKED=/p' | sed '1d;$d'; }

@test "exec runs the command and its arguments exactly, never claude, never through a shell" {
  p="$(mkproj ex)"
  _launch "$p" exec -- python3 -I '/srv/x y/check.py' '$HOME' '*' >/dev/null 2>&1
  [ "$(box_cmd)" = "$(printf '%s\n' python3 -I '/srv/x y/check.py' '$HOME' '*')" ]
  if engine_args | grep -qx claude; then echo "claude was run"; return 1; fi
}

@test "exec needs -- and a command; nothing runs otherwise" {
  p="$(mkproj exu)"
  for a in "exec" "exec --" "exec python3"; do
    : > "$ENGINE_ARGS_FILE"
    # shellcheck disable=SC2086
    run _launch "$p" $a
    [ "$status" -eq 2 ] && [[ "$output" == *"usage: airlock exec -- COMMAND"* ]] || { echo "$a: $status $output"; return 1; }
    if engine_args | grep -q '^ENGINE_INVOKED='; then echo "$a: launched"; return 1; fi
  done
}

@test "exec: the command's exit status is the launcher's" {
  p="$(mkproj exs)"
  STUB_RUN_EXIT=3 run _launch "$p" exec -- false
  [ "$status" -eq 3 ]
  STUB_RUN_EXIT=0 run _launch "$p" exec -- true
  [ "$status" -eq 0 ]
}

@test "exec is a shell session: a live Claude session in the project doesn't stop it at the history prompt" {
  p="$(mkproj exk)"
  sleep 300 3>&- & peer=$!
  PEER=$peer
  _launch "$p" session register "$peer" airlock >/dev/null 2>&1
  : > "$ENGINE_ARGS_FILE"; run _launch "$p" --continue          # control: claude stops (no answer)
  if engine_args | grep -q '^ENGINE_INVOKED='; then kill "$peer"; echo "claude launched past the prompt"; return 1; fi
  : > "$ENGINE_ARGS_FILE"; run _launch "$p" exec -- true
  kill "$peer"
  [ "$status" -eq 0 ]; engine_args | grep -q '^ENGINE_INVOKED='
  grep -q "^SESSION=" "$ENGINE_ARGS_FILE.sessions"
}

@test "no terminal: -i without -t, for exec and for claude -p alike" {
  p="$(mkproj ext)"
  _launch "$p" exec -- true >/dev/null 2>&1
  engine_args | grep -qx -- -i
  if engine_args | grep -qx -- '-t\|-it'; then echo "asked for a terminal"; return 1; fi
  : > "$ENGINE_ARGS_FILE"
  _launch "$p" -p hello >/dev/null 2>&1
  engine_args | grep -qx -- -i
  if engine_args | grep -qx -- '-t\|-it'; then echo "asked for a terminal"; return 1; fi
}

@test "a terminal: -t too" {
  p="$(mkproj extty)"
  _launch_env
  cd "$p"
  script -qec "env -i $(printf '%q ' "${LAUNCH_ENV[@]}") bash $(printf '%q' "$AIRLOCK")" /dev/null >/dev/null 2>&1 </dev/null || true
  engine_args | grep -qx -- -t
}

@test "the firewall's log goes to stderr in the image (the box's stdout is the command's)" {
  grep -qx '  /usr/local/bin/init-firewall.sh >&2' "$BATS_TEST_DIRNAME/../image/entrypoint.sh"
}

@test "a terminal on stdin but output to a file: no -t (it would put CR and escapes in the output)" {
  p="$(mkproj exout)"
  _launch_env
  cd "$p"
  script -qec "env -i $(printf '%q ' "${LAUNCH_ENV[@]}") bash $(printf '%q' "$AIRLOCK") -p hi > $(printf '%q' "$BATS_TEST_TMPDIR/out")" /dev/null >/dev/null 2>&1 </dev/null || true
  engine_args | grep -qx -- -i
  if engine_args | grep -qx -- -t; then echo "asked for a terminal"; return 1; fi
}

@test "piped input never answers a prompt: a box-requested egress or rw share stays unapproved, the command gets all the input" {
  p="$(mkproj expipe)"
  mkdir -p "$SHARE_BASE/shr"
  write_config "$p" "egress = evil.example.com
share_rw = shr"
  _launch_env
  for cmd in "exec -- cat" "-p"; do
    : > "$ENGINE_ARGS_FILE"
    # shellcheck disable=SC2086
    out="$(cd "$p" && printf 'y\ny\nyes\n' | env -i "${LAUNCH_ENV[@]}" bash "$AIRLOCK" $cmd 2>&1)" || true
    [[ "$out" == *"(no terminal: no)"* ]] || { echo "$cmd: $out"; return 1; }
    if grep -qx evil.example.com "$(state_dir "$p")/approved-egress" 2>/dev/null; then echo "$cmd: egress approved"; return 1; fi
    if grep -q shr "$(state_dir "$p")/approved-shares-rw" 2>/dev/null; then echo "$cmd: share approved"; return 1; fi
  done
}

@test "an exec'd command gets an init as PID 1 (signals reach it, the box stops with its unit); claude doesn't" {
  p="$(mkproj exinit)"
  _launch "$p" exec -- true >/dev/null 2>&1
  engine_args | grep -qx -- --init
  : > "$ENGINE_ARGS_FILE"; _launch "$p" -p hi >/dev/null 2>&1
  if engine_args | grep -qx -- --init; then echo "claude got --init"; return 1; fi
}

@test "a live peer session: a headless claude -p --continue is refused without reading its input" {
  p="$(mkproj expeer)"
  sleep 300 3>&- & PEER=$!
  _launch "$p" session register "$PEER" airlock >/dev/null 2>&1
  _launch_env
  : > "$ENGINE_ARGS_FILE"
  run bash -c 'cd "$1" && shift && printf "yes\n" | env -i "$@"' _ "$p" "${LAUNCH_ENV[@]}" bash "$AIRLOCK" -p --continue
  [ "$status" -eq 1 ] && [[ "$output" == *"Aborted."* ]]
  if engine_args | grep -q '^ENGINE_INVOKED='; then echo "launched"; return 1; fi
  # a new conversation next to it is not asked about: it launches
  : > "$ENGINE_ARGS_FILE"
  run bash -c 'cd "$1" && shift && printf "yes\n" | env -i "$@"' _ "$p" "${LAUNCH_ENV[@]}" bash "$AIRLOCK" -p
  kill "$PEER" 2>/dev/null || true
  [ "$status" -eq 0 ]; engine_args | grep -q '^ENGINE_INVOKED='
}
