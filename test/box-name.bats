#!/usr/bin/env bats
# The box's name: airlock-<session name> (Claude's --name, as agent sessions pass it), else
# airlock-<project>, so journal lines, `podman ps` and htop say which box is which. A name
# still taken gets a suffix; nothing existing is replaced. And an interactive box's screen
# never goes to the engine's log (journald): --log-driver none with a terminal.

load helper
setup() {
  setup_airlock_env
  P="$(mkproj box-name)"
}
# the engine's --name (the first: Claude's own --name comes later, after the image)
box_name() { engine_args | grep -x -m1 -A1 -- --name | tail -1; }
launched() { engine_args | grep -q '^ENGINE_INVOKED='; }

@test "box name: the project's, without a session name" {
  _launch "$P" >/dev/null 2>&1
  launched
  [ "$(box_name)" = airlock-proj-box-name ]
}

@test "box name: the session's --name, in both spellings, wins over the project" {
  _launch "$P" --name demo.main >/dev/null 2>&1
  [ "$(box_name)" = airlock-demo.main ]
  : > "$ENGINE_ARGS_FILE"
  _launch "$P" --name=demo.review >/dev/null 2>&1
  [ "$(box_name)" = airlock-demo.review ]
  # and Claude still gets its own --name
  engine_args | grep -qx -- --name=demo.review
  [ "$(engine_args | grep -cx -- --name)" = 1 ]
}

@test "box name: characters an engine name can't hold become -, and it stays short" {
  _launch "$P" --name 'a b/c:d$(x)' >/dev/null 2>&1
  [ "$(box_name)" = 'airlock-a-b-c-d--x-' ]
  : > "$ENGINE_ARGS_FILE"
  _launch "$P" --name "$(printf 'n%.0s' $(seq 80))" >/dev/null 2>&1
  n="$(box_name)"
  [[ "$n" == airlock-nnn* ]] && [ "${#n}" -eq 56 ]
}

@test "box name: one still taken gets a suffix; nothing is replaced" {
  STUB_TAKEN_NAMES=airlock-demo.main,airlock-demo.main-2 _launch "$P" --name demo.main >/dev/null 2>&1
  [ "$(box_name)" = airlock-demo.main-3 ]
  ! engine_args | grep -qx -- --replace
}

@test "box name: a shell or exec box takes the project's name, not an argument's" {
  _launch "$P" shell >/dev/null 2>&1
  [ "$(box_name)" = airlock-proj-box-name ]
}

@test "box log: without a terminal (scripts, units) the engine's default stays; no -t either" {
  _launch "$P" >/dev/null 2>&1
  ! engine_args | grep -qx -- --log-driver
  ! engine_args | grep -qx -- -t
}

@test "box log: with a terminal, -t and --log-driver none (the screen stays out of the journal)" {
  command -v script >/dev/null || skip "no script(1) to give the launcher a terminal"
  cd "$P"
  _launch_env
  local cmd; cmd="$(printf '%q ' env -i "${LAUNCH_ENV[@]}" bash "$AIRLOCK")"
  script -qec "$cmd" /dev/null >/dev/null 2>&1 </dev/null || true
  engine_args | grep -qx -- -t
  [ "$(engine_args | grep -x -A1 -- --log-driver | tail -1)" = none ]
}
