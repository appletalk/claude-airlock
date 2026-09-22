#!/usr/bin/env bats
# No symlinks in the shared ~/.claude/projects/<slug> directory. Host Claude follows them
# when it auto-loads memory/ (measured: a MEMORY.md pointing outside the directory was
# loaded verbatim) and writes its transcript back into the same directory, so a box that
# plants one turns "influence channel" into "read any host file and get it back". Both
# entry points to a host session over that directory refuse while a link exists, and
# neither deletes it.

load helper

setup() {
  setup_airlock_env
  ZSH_LIB="$BATS_TEST_DIRNAME/../shell/claude-airlock.zsh"
}

# Claude's own key for the project dir: every non-alphanumeric to '-', leading dashes
# KEPT (unlike the launcher's state slug, which strips them).
histproj() { printf '%s' "$AIRLOCK_HOME/.claude/projects/$(printf '%s' "$1" | sed 's#[^a-zA-Z0-9]#-#g')"; }

plant() {  # plant a symlink at $1/memory/MEMORY.md pointing at a host file
  mkdir -p "$1/memory"
  printf 'not for the box\n' > "$AIRLOCK_HOME/secret"
  ln -sfn "$AIRLOCK_HOME/secret" "$1/memory/MEMORY.md"
}

@test "the launcher refuses to start a box while the shared dir holds a symlink, and names it" {
  p="$(mkproj link)"; d="$(histproj "$p")"; plant "$d"
  run _launch "$p"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to start"* ]]
  [[ "$output" == *"$d/memory/MEMORY.md"* ]]
  [ -z "$(invoked_engine)" ]                       # the engine never ran
  [ -L "$d/memory/MEMORY.md" ]                     # and the link was not removed for us
}

@test "a symlink anywhere under the shared dir is refused, not just in memory/" {
  p="$(mkproj deep)"; d="$(histproj "$p")"
  mkdir -p "$d/sessions/x"; ln -s /etc/hostname "$d/sessions/x/note.jsonl"
  run _launch "$p"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sessions/x/note.jsonl"* ]]
}

@test "regular files and directories in the shared dir do not trip the guard" {
  p="$(mkproj plain)"; d="$(histproj "$p")"
  mkdir -p "$d/memory"; printf '# index\n' > "$d/memory/MEMORY.md"; printf '{}\n' > "$d/s.jsonl"
  _launch "$p"
  [ "$(invoked_engine)" = "$ENGINE" ]
}

@test "with history sharing off the launcher does not look (nothing is mounted)" {
  p="$(mkproj off)"; d="$(histproj "$p")"; plant "$d"
  cd "$p"
  run env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" TERM=xterm \
    AIRLOCK_ENGINE="$ENGINE" AIRLOCK_IMAGE=claude-airlock:dev AIRLOCK_SHARE_BASE="$SHARE_BASE" \
    AIRLOCK_ROOTS="" CLAUDE_CODE_OAUTH_TOKEN=t ENGINE_ARGS_FILE="$ENGINE_ARGS_FILE" \
    AIRLOCK_TMP_BASE="$AIRLOCK_TMP_BASE" AIRLOCK_SHARE_HISTORY=0 bash "$AIRLOCK" </dev/null
  [ "$status" -eq 0 ]
  ! engine_args | grep -q -- "$d"
}

# --- the host wrapper ---------------------------------------------------------------

_host_claude() {
  local proj="$1"; shift
  printf '#!/usr/bin/env bash\necho HOST-CLAUDE-RAN >> "%s/ran"\n' "$BATS_TEST_TMPDIR" > "$STUBBIN/claude"
  chmod +x "$STUBBIN/claude"
  env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$AIRLOCK_HOME" TERM=xterm \
    AIRLOCK_TMP_BASE="$AIRLOCK_TMP_BASE" \
    zsh -c "source '$ZSH_LIB' >/dev/null 2>&1; cd '$proj' || exit 1; claude $*" </dev/null
}

@test "the host claude wrapper refuses to start over a shared dir holding a symlink" {
  command -v zsh >/dev/null || skip "zsh not installed"
  p="$(mkproj hostlink)"; d="$(histproj "$p")"; plant "$d"
  run _host_claude "$p"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to start"* ]]
  [[ "$output" == *"$d/memory/MEMORY.md"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]                                   # host claude never ran
  [ ! -e "$(state_dir "$p")/session.lock" ]                          # nothing left behind
  [ ! -d "$(state_dir "$p")/sessions" ] || [ -z "$(ls -A "$(state_dir "$p")/sessions")" ]
  [ -L "$d/memory/MEMORY.md" ]
}

@test "the host claude wrapper runs normally when the shared dir is clean or absent" {
  command -v zsh >/dev/null || skip "zsh not installed"
  p="$(mkproj hostclean)"
  _host_claude "$p"
  grep -q HOST-CLAUDE-RAN "$BATS_TEST_TMPDIR/ran"
  mkdir -p "$(histproj "$p")/memory"; printf '# index\n' > "$(histproj "$p")/memory/MEMORY.md"
  _host_claude "$p"
  [ "$(grep -c HOST-CLAUDE-RAN "$BATS_TEST_TMPDIR/ran")" -eq 2 ]
}
