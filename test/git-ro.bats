#!/usr/bin/env bats
# Read-write repos: what host git reads as instructions is bound read-only, so a box can't
# plant a hook, an fsmonitor or a hooksPath that host git later runs. The refusals matter
# most: each is a shape a box could have left behind in an earlier session.

load helper
setup() {
  setup_airlock_env
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
}

approve() { local sd; sd="$(state_dir "$1")"; mkdir -p "$sd"; printf '%s\n' "$2" >> "$sd/approved-shares${3:-}"; }
bound() { engine_args | grep -qx -- "$1:$1:$2"; }
refute_bound() { if engine_args | grep -q -- "^$1:$1:"; then echo "unexpectedly bound: $1"; return 1; fi; }
mkrepo() { git init -q "$1"; }
bound_at() { engine_args | grep -qx -- "$1:$2:$3"; }   # source, box path, mode
no_dup_dest() {   # podman refuses a launch with two mounts at one destination
  local d; d="$(engine_args | grep -E ':(ro|rw)$' | awk -F: '{ print $2 }' | while IFS= read -r x; do realpath -ms -- "$x"; done | sort | uniq -d)"
  [ -z "$d" ] || { echo "duplicate mount destination: $d"; return 1; }
}
commit_init() { git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init; }

@test "a workspace repo: .git bound onto itself rw, config and hooks read-only" {
  p="$(mkproj ws)"; mkrepo "$p"
  _launch "$p" >/dev/null 2>&1
  bound "$p/.git" rw
  bound "$p/.git/config" ro
  bound "$p/.git/hooks" ro
}

@test "a share_rw repo gets the same binds" {
  p="$(mkproj sh)"; mkrepo "$SHARE_BASE/repo"
  write_config "$p" "share_rw = repo"; approve "$p" repo -rw
  _launch "$p" >/dev/null 2>&1
  bound "$SHARE_BASE/repo/.git" rw
  bound "$SHARE_BASE/repo/.git/config" ro
  bound "$SHARE_BASE/repo/.git/hooks" ro
}

@test "a read-only share is left alone (it is read-only already)" {
  p="$(mkproj ro)"; mkrepo "$SHARE_BASE/rorepo"
  write_config "$p" "share = rorepo"; approve "$p" rorepo
  _launch "$p" >/dev/null 2>&1
  refute_bound "$SHARE_BASE/rorepo/.git/config"
}

@test "a missing hooks dir is created on the host, then bound read-only" {
  p="$(mkproj nohooks)"; mkrepo "$p"; rm -rf "$p/.git/hooks"
  _launch "$p" >/dev/null 2>&1
  [ -d "$p/.git/hooks" ]
  bound "$p/.git/hooks" ro
}

@test "a relative core.hooksPath inside the repo is bound read-only (created if missing)" {
  p="$(mkproj hp)"; mkrepo "$p"; git -C "$p" config core.hooksPath .githooks
  _launch "$p" >/dev/null 2>&1
  [ -d "$p/.githooks" ]
  bound "$p/.githooks" ro
}

@test "a core.hooksPath outside every read-write root is not bound" {
  p="$(mkproj hpout)"; mkrepo "$p"; mkdir -p "$BATS_TEST_TMPDIR/hooks-elsewhere"
  git -C "$p" config core.hooksPath "$BATS_TEST_TMPDIR/hooks-elsewhere"
  _launch "$p" >/dev/null 2>&1
  refute_bound "$BATS_TEST_TMPDIR/hooks-elsewhere"
  bound "$p/.git/config" ro
}

@test "an include.path / includeIf path inside a read-write root is bound read-only" {
  p="$(mkproj inc)"; mkrepo "$p"
  git -C "$p" config include.path ../extra.gitconfig
  git -C "$p" config 'includeIf.gitdir:/.path' "$p/cond.gitconfig"
  _launch "$p" >/dev/null 2>&1
  bound "$p/extra.gitconfig" ro
  bound "$p/cond.gitconfig" ro
}

@test "a hooksPath reached through a symlink inside the root refuses the launch" {
  p="$(mkproj hpsym)"; mkrepo "$p"; mkdir -p "$p/real"; ln -s real "$p/link"
  git -C "$p" config core.hooksPath link
  : > "$ENGINE_ARGS_FILE"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"goes through, a symlink"*"not launching"* ]]
  [ ! -s "$ENGINE_ARGS_FILE" ]
}

@test "a symlinked .git/config refuses the launch" {
  p="$(mkproj cfgsym)"; mkrepo "$p"; mv "$p/.git/config" "$p/planted"; ln -s ../planted "$p/.git/config"
  : > "$ENGINE_ARGS_FILE"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *".git/config is, or goes through, a symlink"* ]]
  [ ! -s "$ENGINE_ARGS_FILE" ]
}

@test "a symlinked .git/hooks or .git refuses the launch" {
  p="$(mkproj hooksym)"; mkrepo "$p"; rm -rf "$p/.git/hooks"; mkdir "$p/h"; ln -s ../h "$p/.git/hooks"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *".git/hooks is, or goes through, a symlink"* ]]
  q="$(mkproj gitsym)"; mkrepo "$BATS_TEST_TMPDIR/realrepo"; ln -s "$BATS_TEST_TMPDIR/realrepo/.git" "$q/.git"
  run _launch "$q"
  [ "$status" -ne 0 ]
  [[ "$output" == *"/.git is a symlink"* ]]
}

@test "a hard-linked .git/config refuses the launch (its other name stays writable)" {
  p="$(mkproj hard)"; mkrepo "$p"; ln "$p/.git/config" "$p/notes.txt"
  : > "$ENGINE_ARGS_FILE"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"more than one hard link"* ]]
  [ ! -s "$ENGINE_ARGS_FILE" ]
}

@test "a linked worktree's .git pointer file is bound read-only" {
  mkrepo "$BATS_TEST_TMPDIR/main"
  git -C "$BATS_TEST_TMPDIR/main" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  p="$BATS_TEST_TMPDIR/proj-wt"
  git -C "$BATS_TEST_TMPDIR/main" worktree add -q "$p"
  mkdir -p "$p/.airlock"
  _launch "$p" >/dev/null 2>&1
  bound "$p/.git" ro
}

@test "existing linked worktrees: their gitdir bound onto itself, commondir read-only" {
  p="$(mkproj wtmain)"; mkrepo "$p"
  git -C "$p" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$p" worktree add -q "$BATS_TEST_TMPDIR/sibling"
  _launch "$p" >/dev/null 2>&1
  bound "$p/.git/worktrees/sibling" rw
  bound "$p/.git/worktrees/sibling/commondir" ro
}

@test "extensions.worktreeConfig: config.worktree is bound read-only (created if missing)" {
  p="$(mkproj wtcfg)"; mkrepo "$p"; git -C "$p" config extensions.worktreeConfig true
  _launch "$p" >/dev/null 2>&1
  [ -f "$p/.git/config.worktree" ]
  bound "$p/.git/config.worktree" ro
}

@test "submodule gitdirs: bound onto themselves, config and hooks read-only" {
  p="$(mkproj sub)"; mkrepo "$p"
  mkdir -p "$p/.git/modules/lib"; git init -q --bare "$p/.git/modules/lib"
  _launch "$p" >/dev/null 2>&1
  bound "$p/.git/modules/lib" rw
  bound "$p/.git/modules/lib/config" ro
  bound "$p/.git/modules/lib/hooks" ro
}

@test "a workspace that is not a repo launches with no git binds" {
  p="$(mkproj plain)"
  _launch "$p" >/dev/null 2>&1
  refute_bound "$p/.git"
  grep -q '^ENGINE_INVOKED=' "$ENGINE_ARGS_FILE"
}

@test "AIRLOCK_GIT_RO=0 turns the guard off" {
  p="$(mkproj off)"; mkrepo "$p"; ln "$p/.git/config" "$p/notes.txt"
  AIRLOCK_GIT_RO=0 _launch "$p" >/dev/null 2>&1
  refute_bound "$p/.git/config"
  grep -q '^ENGINE_INVOKED=' "$ENGINE_ARGS_FILE"
}

@test "reading the config never runs it (fsmonitor is not triggered)" {
  p="$(mkproj noexec)"; mkrepo "$p"
  git -C "$p" config core.fsmonitor "touch $BATS_TEST_TMPDIR/PWNED"
  _launch "$p" >/dev/null 2>&1
  [ ! -e "$BATS_TEST_TMPDIR/PWNED" ]
  bound "$p/.git/config" ro
}

@test "a hooksPath set in an included file is guarded too, through nested includes" {
  p="$(mkproj incnest)"; mkrepo "$p"
  printf '[include]\n\tpath = inner.cfg\n' > "$p/outer.cfg"
  printf '[core]\n\thooksPath = %s\n' "$p/viainclude" > "$p/inner.cfg"
  git -C "$p" config include.path ../outer.cfg
  _launch "$p" >/dev/null 2>&1
  bound "$p/outer.cfg" ro
  bound "$p/inner.cfg" ro
  bound "$p/viainclude" ro
}

@test "an include outside every read-write root is read for hooksPath but not bound" {
  p="$(mkproj incout)"; mkrepo "$p"
  printf '[core]\n\thooksPath = %s\n' "$p/fromhost" > "$BATS_TEST_TMPDIR/host.cfg"
  git -C "$p" config include.path "$BATS_TEST_TMPDIR/host.cfg"
  _launch "$p" >/dev/null 2>&1
  refute_bound "$BATS_TEST_TMPDIR/host.cfg"
  bound "$p/fromhost" ro
}

@test "a symlinked or hard-linked config.worktree refuses the launch" {
  p="$(mkproj wtsym)"; mkrepo "$p"; git -C "$p" config extensions.worktreeConfig true
  : > "$p/planted"; ln -s ../planted "$p/.git/config.worktree"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"config.worktree is, or goes through, a symlink"* ]]
  q="$(mkproj wthard)"; mkrepo "$q"; git -C "$q" config extensions.worktreeConfig true
  : > "$q/.git/config.worktree"; ln "$q/.git/config.worktree" "$q/twin"
  run _launch "$q"
  [ "$status" -ne 0 ]
  [[ "$output" == *"more than one hard link"* ]]
}

@test "includes nested more than 10 deep refuse the launch" {
  p="$(mkproj deep)"; mkrepo "$p"
  for n in $(seq 0 11); do printf '[include]\n\tpath = i%s.cfg\n' "$((n + 1))" > "$p/i$n.cfg"; done
  : > "$p/i12.cfg"
  git -C "$p" config include.path ../i0.cfg
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nested more than 10 deep"* ]]
}

@test "a config git cannot parse refuses the launch (never read as empty)" {
  p="$(mkproj bad)"; mkrepo "$p"
  printf '[core]\n\thooksPath = .githooks\n[broken\n' >> "$p/.git/config"
  : > "$ENGINE_ARGS_FILE"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot read git config"*"not launching"* ]]
  [ ! -s "$ENGINE_ARGS_FILE" ]
}

@test "the launcher's working directory (the repo itself) does not change what is read" {
  p="$(mkproj cwd)"; mkrepo "$p"
  printf '[include]\n\tpath = loop.cfg\n' > "$p/loop.cfg"
  git -C "$p" config core.hooksPath .githooks
  git -C "$p" config include.path ../loop.cfg
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nested more than 10 deep"* ]]
}

# ---- from the 2026-10-19 cold review ----

@test "commondir: created as '.' and bound read-only, so the box can't add one pointing elsewhere" {
  p="$(mkproj cd1)"; mkrepo "$p"; commit_init "$p"
  _launch "$p" >/dev/null 2>&1
  [ "$(cat "$p/.git/commondir")" = . ]
  bound "$p/.git/commondir" ro
  git -C "$p" -c user.name=t -c user.email=t@t commit -q --allow-empty -m still-works
  no_dup_dest
}

@test "a commondir pointing anywhere else refuses the launch" {
  p="$(mkproj cd2)"; mkrepo "$p"; mkdir "$p/.git/alt"; echo alt > "$p/.git/commondir"
  : > "$ENGINE_ARGS_FILE"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"commondir points git somewhere else"* ]]
  [ ! -s "$ENGINE_ARGS_FILE" ]
}

@test "a workspace reached through a symlinked parent: binds at the path the box sees" {
  mkdir -p "$BATS_TEST_TMPDIR/real"; ln -s "$BATS_TEST_TMPDIR/real" "$BATS_TEST_TMPDIR/link"
  mkrepo "$BATS_TEST_TMPDIR/real/proj"; mkdir -p "$BATS_TEST_TMPDIR/real/proj/.airlock"
  # env -i drops PWD, so bash would use the physical path; an interactive shell passes the logical one.
  TEST_LOGICAL_PWD="$BATS_TEST_TMPDIR/link/proj" _launch "$BATS_TEST_TMPDIR/link/proj" >/dev/null 2>&1
  engine_args | grep -qx -- "$BATS_TEST_TMPDIR/link/proj:$BATS_TEST_TMPDIR/link/proj:rw"   # the workspace really is logical here
  bound_at "$BATS_TEST_TMPDIR/real/proj/.git/config" "$BATS_TEST_TMPDIR/link/proj/.git/config" ro
  bound_at "$BATS_TEST_TMPDIR/real/proj/.git/hooks" "$BATS_TEST_TMPDIR/link/proj/.git/hooks" ro
  no_dup_dest
}

@test "a share_rw under a symlinked share base still gets its config bound" {
  mkdir -p "$BATS_TEST_TMPDIR/realbase"; mkrepo "$BATS_TEST_TMPDIR/realbase/repo"
  ln -s "$BATS_TEST_TMPDIR/realbase" "$BATS_TEST_TMPDIR/linkbase"
  SHARE_BASE="$BATS_TEST_TMPDIR/linkbase"
  p="$(mkproj sbl)"; write_config "$p" "share_rw = repo"; approve "$p" repo -rw
  _launch "$p" >/dev/null 2>&1
  engine_args | grep -q -- "realbase/repo/.git/config:.*/repo/.git/config:ro$"
  no_dup_dest
}

@test "an unreadable .git/worktrees or submodule gitdir refuses the launch (no silent skip)" {
  p="$(mkproj perm)"; mkrepo "$p"; commit_init "$p"
  git -C "$p" worktree add -q "$BATS_TEST_TMPDIR/sib"
  chmod 000 "$p/.git/worktrees"
  run _launch "$p"
  chmod 755 "$p/.git/worktrees"
  [ "$status" -ne 0 ]
  [[ "$output" == *"can't be read"* ]]
  q="$(mkproj perm2)"; mkrepo "$q"; git init -q --bare "$q/.git/modules/lib"; chmod 000 "$q/.git/modules/lib"
  run _launch "$q"
  chmod 755 "$q/.git/modules/lib"
  [ "$status" -ne 0 ]
  [[ "$output" == *"can't be read"* ]]
}

@test "an in-root linked worktree: pointer read-only, its relative hooksPath and config.worktree guarded" {
  p="$(mkproj inwt)"; mkrepo "$p"; commit_init "$p"
  git -C "$p" config core.hooksPath .githooks
  git -C "$p" config extensions.worktreeConfig true
  git -C "$p" worktree add -q "$p/.wt/feat"
  _launch "$p" >/dev/null 2>&1
  bound "$p/.wt/feat/.git" ro
  bound "$p/.wt/feat/.githooks" ro
  bound "$p/.githooks" ro
  [ -f "$p/.git/worktrees/feat/config.worktree" ]
  bound "$p/.git/worktrees/feat/config.worktree" ro
  no_dup_dest
}

@test "a workspace that is a linked worktree: its relative hooksPath is guarded too" {
  mkrepo "$BATS_TEST_TMPDIR/main2"; commit_init "$BATS_TEST_TMPDIR/main2"
  git -C "$BATS_TEST_TMPDIR/main2" config core.hooksPath .husky/_
  p="$BATS_TEST_TMPDIR/proj-lwt"
  git -C "$BATS_TEST_TMPDIR/main2" worktree add -q "$p"; mkdir -p "$p/.airlock"
  _launch "$p" >/dev/null 2>&1
  bound "$p/.git" ro
  bound "$p/.husky/_" ro
}

@test "an existing worktree's config.worktree that is a symlink or hard link refuses" {
  p="$(mkproj wtc)"; mkrepo "$p"; commit_init "$p"; git -C "$p" config extensions.worktreeConfig true
  git -C "$p" worktree add -q "$BATS_TEST_TMPDIR/sib2"
  : > "$p/twin"; ln "$p/twin" "$p/.git/worktrees/sib2/config.worktree"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"more than one hard link"* ]]
}

@test "a worktree gitdir or its commondir that is a symlink refuses" {
  p="$(mkproj wts)"; mkrepo "$p"; commit_init "$p"
  git -C "$p" worktree add -q "$BATS_TEST_TMPDIR/sib3"
  mv "$p/.git/worktrees/sib3/commondir" "$p/cd"; ln -s ../../../cd "$p/.git/worktrees/sib3/commondir"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"commondir is, or goes through, a symlink"* ]]
  q="$(mkproj wts2)"; mkrepo "$q"; commit_init "$q"
  git -C "$q" worktree add -q "$BATS_TEST_TMPDIR/sib4"
  mv "$q/.git/worktrees/sib4" "$q/wtdir"; ln -s ../../wtdir "$q/.git/worktrees/sib4"
  run _launch "$q"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sib4 is, or goes through, a symlink"* ]]
}

@test "includes written ./x or ../x launch (bound once, canonical)" {
  p="$(mkproj incdot)"; mkrepo "$p"
  git -C "$p" config include.path ./inc.cfg
  git -C "$p" config --add include.path ../.gitconfig-extra
  : > "$p/.git/inc.cfg"; : > "$p/.gitconfig-extra"
  _launch "$p" >/dev/null 2>&1
  bound "$p/.git/inc.cfg" ro
  bound "$p/.gitconfig-extra" ro
  no_dup_dest
}

@test "a hook that is a symlink into the repo: its target is bound read-only" {
  p="$(mkproj hooklink)"; mkrepo "$p"; mkdir -p "$p/scripts"; printf '#!/bin/sh\n' > "$p/scripts/pre-commit"
  ln -s ../../scripts/pre-commit "$p/.git/hooks/pre-commit"
  _launch "$p" >/dev/null 2>&1
  bound "$p/scripts/pre-commit" ro
}

@test "nested submodule gitdirs deep under modules/ are guarded, and their checkout pointers" {
  p="$(mkproj deepmod)"; mkrepo "$p"
  m="$p/.git/modules/a/modules/b/modules/c"
  mkdir -p "$m"; git init -q --bare "$m"; git init -q --bare "$p/.git/modules/a"
  mkdir -p "$p/a"; printf 'gitdir: ../.git/modules/a\n' > "$p/a/.git"
  git -C / config --file "$p/.git/modules/a/config" core.worktree ../../../a
  _launch "$p" >/dev/null 2>&1
  bound "$m/config" ro
  bound "$m/hooks" ro
  bound "$p/a/.git" ro
  no_dup_dest
}

@test "a hooksPath through a symlink outside every root that lands inside one refuses" {
  p="$(mkproj outlink)"; mkrepo "$p"; mkdir -p "$p/.githooks"
  ln -s "$p" "$BATS_TEST_TMPDIR/sneaky"
  git -C "$p" config core.hooksPath "$BATS_TEST_TMPDIR/sneaky/.githooks"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"goes through, a symlink"* ]]
}
