#!/usr/bin/env bats
# airlock exec -- COMMAND: one command in the box instead of Claude, for scripts and service
# units. What must hold: the command reaches the engine exactly (after the image, nothing in
# between, never through a shell), the box is the one `airlock shell` gets, its exit status is
# the launcher's, and a run without a terminal asks the engine for none.

load helper

setup() { setup_airlock_env; }

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
  sleep 300 & peer=$!
  _launch "$p" session register "$peer" airlock >/dev/null 2>&1
  : > "$ENGINE_ARGS_FILE"; run _launch "$p"                     # control: claude stops (no answer)
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
