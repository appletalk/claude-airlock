#!/usr/bin/env bats
#
# Mount destinations and git bind sources the box can redirect.
#
# A mount whose destination lies inside another mount (history inside ~/.claude, artifact
# dirs and git binds inside the workspace) is resolved by the runtime through the parent
# mount's source on the host, and the runtime follows a symlink it finds there inside the
# box's root. Those sources are box-writable, so a box could plant a link and have the
# NEXT launch mount a directory of its choosing over, say, /usr/local/bin: box code as
# root before the firewall starts. The launcher walks every such path and refuses a link.
#
# Git binds are checked once while the launch is assembled; a box on the same root could
# swap one for a link while a secret prompt waits. They are re-checked right before the run.

load helper

setup() { setup_airlock_env; }
# A test may chmod 000 a directory; give bats its tmpdir back.
teardown() { chmod -R u+rwx "$BATS_TEST_TMPDIR" 2>/dev/null || true; }

mkrepo() { git init -q "$1"; }
histslug() { printf '%s' "$1" | sed 's#[^a-zA-Z0-9]#-#g'; }

@test "a clean launch mounts the history directory and starts" {
  p="$(mkproj clean)"
  run _launch "$p"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  engine_args | grep -q -- ":/home/dev/.claude/projects/$(histslug "$p"):rw$"
  engine_args | grep -q '^ENGINE_INVOKED='
}

@test "a link planted at dot-claude/projects/<slug> refuses the launch (entrypoint swap)" {
  p="$(mkproj h1)"
  dc="$(state_dir "$p")/dot-claude"
  mkdir -p "$dc/projects"
  ln -s /usr/local/bin "$dc/projects/$(histslug "$p")"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to start: $dc/projects/$(histslug "$p") is a symlink"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"inside /home/dev/.claude"* ]]
  ! engine_args | grep -q '^ENGINE_INVOKED=' || false
}

@test "dot-claude/projects itself a link refuses the launch" {
  p="$(mkproj h1b)"
  dc="$(state_dir "$p")/dot-claude"
  mkdir -p "$dc" "$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$dc/projects"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to start: $dc/projects is a symlink"* ]] || { echo "$output"; return 1; }
  ! engine_args | grep -q '^ENGINE_INVOKED=' || false
}

@test "dot-claude/projects as a file (not a directory) refuses the launch" {
  p="$(mkproj h1c)"
  dc="$(state_dir "$p")/dot-claude"
  mkdir -p "$dc"; : > "$dc/projects"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$dc/projects is a symlink, not a directory, or can't be searched"* ]] || { echo "$output"; return 1; }
  ! engine_args | grep -q '^ENGINE_INVOKED=' || false
}

@test "with history off, a planted link there is not mounted through and the launch starts" {
  p="$(mkproj hoff)"
  dc="$(state_dir "$p")/dot-claude"
  mkdir -p "$dc/projects"
  ln -s /usr/local/bin "$dc/projects/$(histslug "$p")"
  AIRLOCK_SHARE_HISTORY=0 run _launch "$p"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! engine_args | grep -q -- ':/home/dev/.claude/projects/' || false
}

@test "an artifact dir that is a link is skipped with a warning: not mounted through" {
  p="$(mkproj art)"
  mkdir -p "$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" "$p/.venv"
  write_config "$p" "artifact_dirs = .venv"
  run _launch "$p"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"not shadowing artifact dir '.venv': $p/.venv is a symlink"* ]] || { echo "$output"; return 1; }
  ! engine_args | grep -q -- ":$p/.venv:" || false
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/target")" ]
}

@test "an artifact dir below a linked parent is skipped before mkdir follows the link" {
  p="$(mkproj art2)"
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  ln -s "$BATS_TEST_TMPDIR/outside" "$p/a"
  write_config "$p" "artifact_dirs = a/bin"
  run _launch "$p"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"not shadowing artifact dir 'a/bin': $p/a is a symlink"* ]] || { echo "$output"; return 1; }
  [ ! -e "$BATS_TEST_TMPDIR/outside/bin" ]
  ! engine_args | grep -q -- ":$p/a/bin:" || false
}

@test "an artifact dir below a directory the host can't search is skipped" {
  p="$(mkproj art4)"
  mkdir -p "$p/a"; chmod 000 "$p/a"
  write_config "$p" "artifact_dirs = a/bin"
  run _launch "$p"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"not shadowing artifact dir 'a/bin': $p/a is a symlink, not a directory, or can't be searched"* ]] || { echo "$output"; return 1; }
  ! engine_args | grep -q -- ":$p/a/bin:" || false
}

@test "a link hidden under a projects dir the host can't search refuses the launch" {
  p="$(mkproj h1d)"
  dc="$(state_dir "$p")/dot-claude"
  mkdir -p "$dc/projects"
  ln -s /usr/local/bin "$dc/projects/$(histslug "$p")"
  chmod 000 "$dc/projects"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to start: $dc/projects is a symlink, not a directory, or can't be searched"* ]] || { echo "$output"; return 1; }
  ! engine_args | grep -q '^ENGINE_INVOKED=' || false
}

@test "dot-claude itself unsearchable refuses the launch" {
  p="$(mkproj h1e)"
  dc="$(state_dir "$p")/dot-claude"
  mkdir -p "$dc/projects"
  ln -s /usr/local/bin "$dc/projects/$(histslug "$p")"
  chmod 000 "$dc"
  run _launch "$p"
  chmod 700 "$dc"
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  ! engine_args | grep -q '^ENGINE_INVOKED=' || false
}

@test "a clean artifact dir, nested or not, still launches" {
  p="$(mkproj art3)"
  write_config "$p" "artifact_dirs = .venv tools/bin"
  run _launch "$p"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  engine_args | grep -q -- ":$p/.venv:rw$"
  engine_args | grep -q -- ":$p/tools/bin:rw$"
}

@test "a git dir swapped for a link while a secret prompt waited: the launch stops" {
  p="$(mkproj gswap)"; mkrepo "$p"
  mkdir -p "$BATS_TEST_TMPDIR/decoy"
  _launch "$p" secret set TOKEN pass:x/y >/dev/null
  printf '#!/usr/bin/env bash\nmv "%s" "%s.away" && ln -s "%s" "%s"\necho secret\n' \
    "$p/.git/hooks" "$p/.git/hooks" "$BATS_TEST_TMPDIR/decoy" "$p/.git/hooks" > "$STUBBIN/pass"
  chmod +x "$STUBBIN/pass"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"git path $p/.git/hooks changed after it was checked"* ]] || { echo "$output"; return 1; }
  ! engine_args | grep -q '^ENGINE_INVOKED=' || false
}

@test "a git dir replaced by another directory while a secret prompt waited: the launch stops" {
  p="$(mkproj gswap2)"; mkrepo "$p"
  _launch "$p" secret set TOKEN pass:x/y >/dev/null
  printf '#!/usr/bin/env bash\nmv "%s" "%s.away" && mkdir "%s"\necho secret\n' \
    "$p/.git/hooks" "$p/.git/hooks" "$p/.git/hooks" > "$STUBBIN/pass"
  chmod +x "$STUBBIN/pass"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"git path $p/.git/hooks changed after it was checked"* ]] || { echo "$output"; return 1; }
  ! engine_args | grep -q '^ENGINE_INVOKED=' || false
}

@test "a git file that gains a second hard link while a secret prompt waited: the launch stops" {
  p="$(mkproj glink)"; mkrepo "$p"
  _launch "$p" secret set TOKEN pass:x/y >/dev/null
  printf '#!/usr/bin/env bash\nln "%s" "%s"\necho secret\n' \
    "$p/.git/config" "$p/config-alias" > "$STUBBIN/pass"
  chmod +x "$STUBBIN/pass"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"git path $p/.git/config changed after it was checked"* ]] || { echo "$output"; return 1; }
  ! engine_args | grep -q '^ENGINE_INVOKED=' || false
}

@test "host git adding a directory under .git while a secret prompt waited still launches" {
  p="$(mkproj gsub)"; mkrepo "$p"
  _launch "$p" secret set TOKEN pass:x/y >/dev/null
  printf '#!/usr/bin/env bash\nmkdir -p "%s"\necho secret\n' "$p/.git/rebase-merge" > "$STUBBIN/pass"
  chmod +x "$STUBBIN/pass"
  run _launch "$p"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  engine_args | grep -q '^ENGINE_INVOKED='
}

@test "a git repo with a secret prompt and nothing swapped still launches" {
  p="$(mkproj gok)"; mkrepo "$p"
  _launch "$p" secret set TOKEN pass:x/y >/dev/null
  run _launch "$p"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  engine_args | grep -q -- "^$p/.git/hooks:$p/.git/hooks:ro$"
}
