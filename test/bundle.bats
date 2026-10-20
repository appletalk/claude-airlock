#!/usr/bin/env bats
# Bundles: one account installs claude-airlock (make install), writes the installed version
# to a directory (make bundle), and another account, or an offline host, installs that
# without building or fetching anything (install-bundle.sh). What must hold: the reader runs
# exactly the images the writer went live with (by image ID), a damaged or half-written
# bundle installs nothing, the bundle replaces an earlier one and goes when cleaned, and a
# reader keeps one version of the images, not every one it was ever handed.

load helper

# A fake engine with a store: "<tag> <id>" lines in $FE_STATE/tags (one store per account).
# build gives the tag a fresh id, tag copies one, rmi drops a tag (or every tag of an id),
# save writes the tags' lines to the archive and load reads them back (FE_LOAD_ID=<id>
# replaces every id it loads, as a damaged or foreign archive would).
fake_engine() {
  cat > "$STUBBIN/$ENGINE" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${ENGINE_ARGS_FILE:-/dev/null}"
st="${FE_STATE:?}/tags"; touch "$st"
norm() { local t="${1#localhost/}"; printf '%s' "$t"; }
get() { awk -v t="$(norm "$1")" '$1 == t { print $2 }' "$st"; }
put() { grep -v "^$(norm "$1") " "$st" > "$st.n" || true; printf '%s %s\n' "$(norm "$1")" "$2" >> "$st.n"; mv "$st.n" "$st"; }
case "$1" in
  image)
    [ "$2" = inspect ] || exit 0
    t="${*: -1}"; id="$(get "$t")"; [ -n "$id" ] || exit 1
    case "$4" in
      *RootFS*) case "$t" in *os*) echo "sha256:a sha256:b " ;; *) echo "sha256:a sha256:b sha256:c " ;; esac ;;
      *) echo "$id" ;;
    esac ;;
  build) shift; while [ $# -gt 0 ]; do [ "$1" = -t ] && { put "$2" "sha256:built-$RANDOM$RANDOM"; }; shift; done ;;
  tag) id="$(get "$2")"; [ -n "$id" ] || exit 1; put "$3" "$id" ;;
  rmi) shift; for a in "$@"; do
         case "$a" in -*) continue ;; esac
         if [ -n "$(get "$a")" ]; then grep -v "^$(norm "$a") " "$st" > "$st.n" || true
         else grep -v " $a$" "$st" > "$st.n" || true; fi
         mv "$st.n" "$st"
       done ;;
  save) out=""; tags=(); shift
        while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; -q|-m) ;; --format) shift ;; *) tags+=("$1") ;; esac; shift; done
        : > "$out"; for t in "${tags[@]}"; do printf '%s %s\n' "$(norm "$t")" "$(get "$t")" >> "$out"; done ;;
  load) shift; in=""; while [ $# -gt 0 ]; do [ "$1" = -i ] && in="$2"; shift; done
        while read -r t id; do put "$t" "${FE_LOAD_ID:-$id}"; done < "$in" ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/$ENGINE"
}

setup() {
  setup_airlock_env
  fake_engine
  W="$BATS_TEST_TMPDIR/writer" R="$BATS_TEST_TMPDIR/reader" B="$BATS_TEST_TMPDIR/bundle"
  mkdir -p "$W/fe" "$R/home" "$R/fe" "$B"
  REPO="$BATS_TEST_DIRNAME/.."
}

# The writer's live install of commit $1, with images of ids <prefix>-{base,os,dev}.
writer_install() {
  local rev=$1 p=${2:-w1} v="$W/root/versions/$1"
  mkdir -p "$v"
  tar -C "$REPO" --exclude=.git --exclude=.tooling -cf - . | tar -x -C "$v"
  printf 'commit %s\nbranch main\ninstalled now\nfrom test\n' "$rev" > "$v/VERSION"
  # The bundle's own host checks pass (they need a real engine): the install runs to the end.
  [ -n "${REAL_CHECKS:-}" ] || pass_checks "$v"
  : > "$v/IMAGES"
  for t in base os dev; do
    printf '%s sha256:%s-%s\n' "$t" "$p" "$t" >> "$v/IMAGES"
    FE_STATE="$W/fe" "$STUBBIN/$ENGINE" build -t "claude-airlock:$t" >/dev/null
    grep -v "^claude-airlock:$t " "$W/fe/tags" > "$W/fe/t" || true
    printf 'claude-airlock:%s sha256:%s-%s\n' "$t" "$p" "$t" >> "$W/fe/t"; mv "$W/fe/t" "$W/fe/tags"
  done
  ln -sfn "versions/$rev" "$W/root/current"
}
bundle() {  # bundle [--clean]: as the writer
  env -i PATH="$STUBBIN:/usr/bin:/bin" HOME="$W" FE_STATE="$W/fe" AIRLOCK_ENGINE="$ENGINE" \
    ENGINE_ARGS_FILE="$ENGINE_ARGS_FILE" AIRLOCK_INSTALL_ROOT="$W/root" bash "$REPO/bin/bundle.sh" "$@"
}
reader_install() {  # as the reader: the bundle's own install-bundle.sh
  env -i PATH="$STUBBIN:/usr/bin:/bin" HOME="$R/home" FE_STATE="$R/fe" AIRLOCK_ENGINE="$ENGINE" \
    ENGINE_ARGS_FILE="$ENGINE_ARGS_FILE" ${FE_LOAD_ID:+FE_LOAD_ID="$FE_LOAD_ID"} \
    ${FAIL_CHECK:+FAIL_CHECK="$FAIL_CHECK"} ${R_ENGINE:+AIRLOCK_ENGINE="$R_ENGINE"} \
    bash "$B/install-bundle.sh" </dev/null
}
RROOT() { printf '%s' "$R/home/.local/share/claude-airlock"; }
pass_checks() {  # pass_checks <tree>: its doctor and image smoke succeed (FAIL_CHECK=doctor|smoke fails one)
  printf '#!/bin/sh\n[ "${FAIL_CHECK:-}" = doctor ] && exit 1; exit 0\n' > "$1/scripts/airlock-doctor.sh"
  printf '#!/bin/sh\n[ "${FAIL_CHECK:-}" = smoke ] && exit 1; exit 0\n' > "$1/scripts/image-smoke.sh"
  chmod +x "$1/scripts/airlock-doctor.sh" "$1/scripts/image-smoke.sh"
}
REV1=aaaaaaaaaaaa REV2=bbbbbbbbbbbb

@test "bundle: the installed version's source and images, a manifest naming both, files 0640, no tags left behind" {
  writer_install "$REV1"
  run bundle "$B"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(ls "$B" | LC_ALL=C sort | tr '\n' ' ')" = "MANIFEST claude-airlock-$REV1.tar images-$REV1.tar install-bundle.sh " ]
  [ "$(stat -c %a "$B/MANIFEST" "$B/images-$REV1.tar" | sort -u)" = 640 ]
  grep -qx "commit $REV1" "$B/MANIFEST"
  grep -qx "image dev sha256:w1-dev" "$B/MANIFEST"
  grep -qx "sha256 $(sha256sum "$B/images-$REV1.tar" | cut -d' ' -f1) images-$REV1.tar" "$B/MANIFEST"
  grep -qx "claude-airlock:dev-$REV1 sha256:w1-dev" "$B/images-$REV1.tar"     # saved under the commit's tags
  ! grep -q -- "-$REV1 " "$W/fe/tags" || false                                 # ...which are gone again
}

@test "bundle: refused with nothing installed, with no image record, or when the tags moved since the install" {
  run bundle "$B"; [ "$status" -ne 0 ]; [[ "$output" == *"nothing installed"* ]]
  writer_install "$REV1"
  rm "$W/root/versions/$REV1/IMAGES"
  run bundle "$B"; [ "$status" -ne 0 ]; [[ "$output" == *"no image record"* ]]
  writer_install "$REV1"
  FE_STATE="$W/fe" "$STUBBIN/$ENGINE" build -t claude-airlock:os
  run bundle "$B"; [ "$status" -ne 0 ]; [[ "$output" == *"claude-airlock:os is "*"make install again"* ]]
  [ -z "$(ls -A "$B")" ]
}

@test "bundle: a new one replaces the earlier one; --clean removes it and nothing else" {
  writer_install "$REV1"; bundle "$B" >/dev/null
  touch "$B/notes.txt"
  writer_install "$REV2" w2; bundle "$B" >/dev/null
  [ ! -e "$B/images-$REV1.tar" ] && [ ! -e "$B/claude-airlock-$REV1.tar" ]
  grep -qx "commit $REV2" "$B/MANIFEST"
  run bundle --clean "$B"
  [ "$status" -eq 0 ]
  [ "$(ls -A "$B")" = notes.txt ]
}

@test "install-bundle: goes live with the bundle's images, loads them, builds and fetches nothing" {
  writer_install "$REV1"; bundle "$B" >/dev/null
  : > "$ENGINE_ARGS_FILE"
  run reader_install
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(readlink "$(RROOT)/current")" = "versions/$REV1" ]
  grep -qx "from bundle $B" "$(RROOT)/versions/$REV1/VERSION"
  [ "$(awk '$1 == "claude-airlock:dev" { print $2 }' "$R/fe/tags")" = sha256:w1-dev ]
  grep -qx "dev sha256:w1-dev" "$(RROOT)/versions/$REV1/IMAGES"
  engine_args | grep -qx load
  ! engine_args | grep -qxE 'build|pull' || false
  ! grep -q -- "-$REV1 " "$R/fe/tags" || false   # the per-commit tags are gone after the flip
}

@test "install-bundle: a file that does not match the manifest, or no manifest, installs nothing" {
  writer_install "$REV1"; bundle "$B" >/dev/null
  for f in "images-$REV1.tar" "claude-airlock-$REV1.tar" install-bundle.sh; do
    cp "$B/$f" "$BATS_TEST_TMPDIR/keep"; printf x >> "$B/$f"
    run env -i PATH="$STUBBIN:/usr/bin:/bin" HOME="$R/home" FE_STATE="$R/fe" AIRLOCK_ENGINE="$ENGINE" bash "$REPO/bin/install-bundle.sh" "$B"
    [ "$status" -ne 0 ] && [[ "$output" == *"$f does not match the manifest"* ]] || { echo "$f: $output"; return 1; }
    cp "$BATS_TEST_TMPDIR/keep" "$B/$f"
  done
  [ ! -e "$(RROOT)/current" ]
  rm "$B/MANIFEST"
  run reader_install
  [ "$status" -ne 0 ]; [[ "$output" == *"no MANIFEST"* ]]
}

@test "install-bundle: images that load as other ids than the manifest names: nothing goes live, no tags left" {
  writer_install "$REV1"; bundle "$B" >/dev/null
  FE_LOAD_ID=sha256:other run reader_install
  [ "$status" -ne 0 ]; [[ "$output" == *"not the sha256:w1-base its manifest names"* ]]
  [ ! -e "$(RROOT)/current" ]
  ! grep -q "claude-airlock:" "$R/fe/tags" || false
}

@test "install-bundle: a source tree that is not the manifest's commit is refused" {
  writer_install "$REV1"; bundle "$B" >/dev/null
  sed -i "s/^commit $REV1/commit $REV2/" "$B/MANIFEST"
  sed -i "s/claude-airlock-$REV1.tar/claude-airlock-$REV2.tar/; s/images-$REV1.tar/images-$REV2.tar/" "$B/MANIFEST"
  mv "$B/claude-airlock-$REV1.tar" "$B/claude-airlock-$REV2.tar"; mv "$B/images-$REV1.tar" "$B/images-$REV2.tar"
  run reader_install
  [ "$status" -ne 0 ]; [[ "$output" == *"not commit $REV2's"* ]]
  [ ! -e "$(RROOT)/current" ]
}

@test "install-bundle: the next bundle replaces the reader's images; the old ones go" {
  writer_install "$REV1"; bundle "$B" >/dev/null
  reader_install >/dev/null 2>&1 || true
  writer_install "$REV2" w2; bundle "$B" >/dev/null
  : > "$ENGINE_ARGS_FILE"
  run reader_install
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(readlink "$(RROOT)/current")" = "versions/$REV2" ]
  [ "$(cut -d' ' -f2 "$R/fe/tags" | sort -u | tr '\n' ' ')" = "sha256:w2-base sha256:w2-dev sha256:w2-os " ]
  engine_args | grep -qx sha256:w1-dev            # removed by id
  engine_args | grep -qx -- label=org.claude-airlock.apt-refresh   # and leftovers a box kept, collected
}

@test "install-bundle: the same bundle (or one whose images did not change) twice: the live images stay" {
  writer_install "$REV1"; bundle "$B" >/dev/null
  run reader_install; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  : > "$ENGINE_ARGS_FILE"
  run reader_install; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cut -d' ' -f2 "$R/fe/tags" | sort -u | tr '\n' ' ')" = "sha256:w1-base sha256:w1-dev sha256:w1-os " ]
  ! engine_args | grep -qx 'sha256:w1-dev' || false
}

@test "install-bundle: a failed containment check or smoke test keeps the images it replaced, and says how back" {
  for c in doctor smoke; do
    rm -rf "$R" "$W/root"; mkdir -p "$R/home" "$R/fe"; : > "$W/fe/tags"
    writer_install "$REV1"; bundle "$B" >/dev/null
    run reader_install; [ "$status" -eq 0 ]
    writer_install "$REV2" w2; bundle "$B" >/dev/null
    : > "$ENGINE_ARGS_FILE"
    FAIL_CHECK=$c run reader_install
    [ "$status" -ne 0 ] && [[ "$output" == *"ask for a bundle of the previous commit ($REV1)"* ]] || { echo "$c: $output"; return 1; }
    ! engine_args | grep -qxE 'sha256:w1-(base|os|dev)|label=org.claude-airlock.apt-refresh' || false
  done
}

@test "install-bundle: a bundle of the other engine is refused, clearly" {
  writer_install "$REV1"; bundle "$B" >/dev/null
  other=docker; [ "$ENGINE" = docker ] && other=podman
  cp "$STUBBIN/$ENGINE" "$STUBBIN/$other"
  R_ENGINE=$other run reader_install
  [ "$status" -ne 0 ]; [[ "$output" == *"the bundle's images are $ENGINE's and this account uses $other"* ]]
  [ ! -e "$(RROOT)/current" ]
}

@test "install-bundle: an os image that is not the base's own os stage is refused" {
  writer_install "$REV1"; bundle "$B" >/dev/null
  sed -i 's/\*os\*) echo "sha256:a sha256:b " ;;/*os*) echo "sha256:x " ;;/' "$STUBBIN/$ENGINE"
  run reader_install
  [ "$status" -ne 0 ]; [[ "$output" == *"is not the base image's os stage"* ]]
  [ ! -e "$(RROOT)/current" ]
}

@test "bundle waits for an install running in the writer's account (the install lock)" {
  writer_install "$REV1"
  ( exec 9>"$W/root/.lock"; flock 9; sleep 2 ) &
  sleep 0.3
  run bundle "$B"
  wait
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"An install is running; waiting"* ]]
  [ -f "$B/MANIFEST" ]
}

@test "a build install records its images and prunes only its own week-old untagged ones" {
  unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
  CLONE="$BATS_TEST_TMPDIR/clone"
  git clone -q "$REPO" "$CLONE"
  tar -C "$REPO" --exclude=.git --exclude=.tooling --exclude='image/certs/*.crt' -cf - . | tar -x -C "$CLONE"
  pass_checks "$CLONE"
  git -C "$CLONE" -c user.name=t -c user.email=t@example.com add -A
  git -C "$CLONE" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m t
  env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$W" FE_STATE="$W/fe" AIRLOCK_ENGINE="$ENGINE" \
    CLAUDE_CODE_VERSION=1.2.3 ENGINE_ARGS_FILE="$ENGINE_ARGS_FILE" bash "$CLONE/bin/install.sh" </dev/null >/dev/null 2>&1 || true
  r="$(git -C "$CLONE" rev-parse --short=12 HEAD)"
  v="$W/.local/share/claude-airlock/versions/$r"
  [ "$(cut -d' ' -f1 "$v/IMAGES" | tr '\n' ' ')" = "base os dev " ]
  [ "$(awk '$1 == "dev" { print $2 }' "$v/IMAGES")" = "$(awk '$1 == "claude-airlock:dev" { print $2 }' "$W/fe/tags")" ]
  engine_args | grep -qx -- label=org.claude-airlock.apt-refresh
  engine_args | grep -qx -- until=168h
  ! engine_args | grep -qx -- --all || false
}
