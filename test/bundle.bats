#!/usr/bin/env bats
# Bundles: one account installs claude-airlock (make install), writes the installed version
# to a directory (make bundle), and another account, or an offline host, installs that
# without building or fetching anything (install-bundle.sh). What must hold: the reader runs
# exactly the images the writer went live with (by image ID), a damaged or half-written
# bundle installs nothing, the bundle replaces an earlier one and goes when cleaned, and a
# reader keeps one version of the images, not every one it was ever handed.

load helper

# A fake engine with a store, one per account ($FE_STATE): "<tag> <id>" lines in tags, and
# "<id> <label>" lines in images (every image, tagged or not; label L is claude-airlock's,
# - none). build gives the tag a fresh labelled image, tag points one at another's, rmi drops
# a tag (the image too once nothing tags it) or an id, save writes the tags' lines to the
# archive and load reads them back (FE_LOAD_ID=<id> replaces every id, as a foreign archive
# would). image prune with the label removes untagged labelled images, except FE_INUSE (an
# id a running box holds); FE_PRUNE_FAIL=1 makes it fail, FE_BUILD_FAIL=<tag> fails that build.
fake_engine() {
  cat > "$STUBBIN/$ENGINE" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${ENGINE_ARGS_FILE:-/dev/null}"
st="${FE_STATE:?}/tags" im="${FE_STATE:?}/images"; touch "$st" "$im"
norm() { local t="${1#localhost/}"; printf '%s' "$t"; }
get() { awk -v t="$(norm "$1")" '$1 == t { print $2 }' "$st"; }
tagged() { awk -v i="$1" '$2 == i { f = 1 } END { exit !f }' "$st"; }
put() {
  grep -v "^$(norm "$1") " "$st" > "$st.n" || true; printf '%s %s\n' "$(norm "$1")" "$2" >> "$st.n"; mv "$st.n" "$st"
  grep -q "^$2 " "$im" || printf '%s %s\n' "$2" "${3:-L}" >> "$im"
}
drop_image() { grep -v "^$1 " "$im" > "$im.n" || true; mv "$im.n" "$im"; }
case "$1" in
  image)
    case "$2" in
      inspect)
        t="${*: -1}"; id="$(get "$t")"; [ -n "$id" ] || exit 1
        case "$4" in
          *RootFS*) case "$t" in *os*) echo "sha256:a sha256:b " ;; *) echo "sha256:a sha256:b sha256:c " ;; esac ;;
          *) echo "$id" ;;
        esac ;;
      prune)
        [ -z "${FE_PRUNE_FAIL:-}" ] || exit 1
        [[ "$*" == *"label=org.claude-airlock.apt-refresh"* ]] || exit 0
        while read -r id lab; do
          [ "$lab" = L ] && ! tagged "$id" && [ "$id" != "${FE_INUSE:-}" ] && drop_image "$id"
        done < <(cat "$im") ;;
    esac ;;
  images) cut -d' ' -f1 "$im" ;;
  build) shift; t=""; while [ $# -gt 0 ]; do [ "$1" = -t ] && t="$2"; shift; done
         [ -z "${FE_BUILD_FAIL:-}" ] || [[ "$t" != *"$FE_BUILD_FAIL"* ]] || exit 1
         [ -z "$t" ] || put "$t" "sha256:built-$RANDOM$RANDOM" ;;
  tag) id="$(get "$2")"; [ -n "$id" ] || exit 1; put "$3" "$id" ;;
  rmi) shift; for a in "$@"; do
         case "$a" in -*) continue ;; esac
         id="$(get "$a")"
         if [ -n "$id" ]; then grep -v "^$(norm "$a") " "$st" > "$st.n" || true; mv "$st.n" "$st"; tagged "$id" || drop_image "$id"
         else grep -v " $a$" "$st" > "$st.n" || true; mv "$st.n" "$st"; drop_image "$a"; fi
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
    FE_STATE="$W/fe" "$STUBBIN/$ENGINE" tag "claude-airlock:$t" "claude-airlock:$t" >/dev/null   # (no-op: built above)
    grep -v "^claude-airlock:$t " "$W/fe/tags" > "$W/fe/t" || true
    printf 'claude-airlock:%s sha256:%s-%s\n' "$t" "$p" "$t" >> "$W/fe/t"; mv "$W/fe/t" "$W/fe/tags"
    grep -q "^sha256:$p-$t " "$W/fe/images" || printf 'sha256:%s-%s L\n' "$p" "$t" >> "$W/fe/images"
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
  [ "$(cut -d' ' -f1 "$R/fe/images" | sort | tr '\n' ' ')" = "sha256:w2-base sha256:w2-dev sha256:w2-os " ]
  [[ "$output" == *"Pruned 3 superseded claude-airlock image(s)"* ]]
}

@test "install-bundle: the same bundle (or one whose images did not change) twice: the live images stay" {
  writer_install "$REV1"; bundle "$B" >/dev/null
  run reader_install; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  : > "$ENGINE_ARGS_FILE"
  run reader_install; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cut -d' ' -f2 "$R/fe/tags" | sort -u | tr '\n' ' ')" = "sha256:w1-base sha256:w1-dev sha256:w1-os " ]
  [ "$(cut -d' ' -f1 "$R/fe/images" | sort | tr '\n' ' ')" = "sha256:w1-base sha256:w1-dev sha256:w1-os " ]
  [[ "$output" != *"Pruned"* ]]                   # nothing to prune: no line
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
    ! engine_args | grep -qx 'label=org.claude-airlock.apt-refresh' || false
    grep -q '^sha256:w1-dev ' "$R/fe/images"     # the replaced images stay, a way back
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

build_clone() {  # a clone of this tree (with passing host checks) and a commit on it
  unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
  CLONE="$BATS_TEST_TMPDIR/clone"
  git clone -q "$REPO" "$CLONE"
  tar -C "$REPO" --exclude=.git --exclude=.tooling --exclude='image/certs/*.crt' -cf - . | tar -x -C "$CLONE"
  pass_checks "$CLONE"
  gitb add -A; gitb commit -q --allow-empty -m t
}
gitb() { git -C "$CLONE" -c user.name=t -c user.email=t@example.com "$@"; }
build_install() {
  env -i PATH="$STUBBIN:/usr/bin:/usr/sbin:/bin" HOME="$W" FE_STATE="$W/fe" AIRLOCK_ENGINE="$ENGINE" \
    CLAUDE_CODE_VERSION=1.2.3 ENGINE_ARGS_FILE="$ENGINE_ARGS_FILE" ${FE_INUSE:+FE_INUSE="$FE_INUSE"} \
    ${FE_PRUNE_FAIL:+FE_PRUNE_FAIL=1} ${FE_BUILD_FAIL:+FE_BUILD_FAIL="$FE_BUILD_FAIL"} \
    bash "$CLONE/bin/install.sh" </dev/null
}
live_ids() { awk '$1 ~ /^claude-airlock:(base|os|dev)$/ { print $2 }' "$W/fe/tags" | sort | tr '\n' ' '; }
all_ids() { cut -d' ' -f1 "$W/fe/images" | sort | tr '\n' ' '; }

@test "a build install records its images; the next prunes the ones it superseded and nothing else" {
  build_clone
  printf 'sha256:someone-elses -\n' >> "$W/fe/images"     # another project's dangling image
  run build_install; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  r="$(git -C "$CLONE" rev-parse --short=12 HEAD)"
  v="$W/.local/share/claude-airlock/versions/$r"
  [ "$(cut -d' ' -f1 "$v/IMAGES" | tr '\n' ' ')" = "base os dev " ]
  [ "$(awk '$1 == "dev" { print $2 }' "$v/IMAGES")" = "$(awk '$1 == "claude-airlock:dev" { print $2 }' "$W/fe/tags")" ]
  [[ "$output" != *"Pruned"* ]]                              # a first install: nothing superseded
  gitb commit -q --allow-empty -m t2
  : > "$ENGINE_ARGS_FILE"
  run build_install; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"==> Pruned 3 superseded claude-airlock image(s)"* ]]
  [ "$(all_ids)" = "$(printf '%s\n' $(live_ids) sha256:someone-elses | sort | tr '\n' ' ')" ]
  engine_args | grep -qx -- label=org.claude-airlock.apt-refresh
  ! engine_args | grep -qxE -- '--all|until=.*' || false     # dangling only, no age window
}

@test "an image a running box holds stays, and the next install collects it" {
  build_clone
  build_install >/dev/null 2>&1
  held="$(awk '$1 == "claude-airlock:dev" { print $2 }' "$W/fe/tags")"
  gitb commit -q --allow-empty -m t2
  FE_INUSE="$held" run build_install; [ "$status" -eq 0 ]
  [[ "$output" == *"Pruned 2 superseded"* ]]
  grep -q "^$held " "$W/fe/images"
  gitb commit -q --allow-empty -m t3
  run build_install; [ "$status" -eq 0 ]
  ! grep -q "^$held " "$W/fe/images" || false
}

@test "a prune that fails warns and the install still succeeds" {
  build_clone
  build_install >/dev/null 2>&1
  gitb commit -q --allow-empty -m t2
  FE_PRUNE_FAIL=1 run build_install
  [ "$status" -eq 0 ]; [[ "$output" == *"WARNING: could not prune superseded claude-airlock images"* ]]
}

@test "a failed build or failed host check prunes nothing" {
  build_clone
  build_install >/dev/null 2>&1
  before="$(all_ids)"
  gitb commit -q --allow-empty -m t2
  : > "$ENGINE_ARGS_FILE"
  FE_BUILD_FAIL=claude-airlock:dev- run build_install
  [ "$status" -ne 0 ]
  ! engine_args | grep -qx -- label=org.claude-airlock.apt-refresh || false
  for id in $before; do grep -q "^$id " "$W/fe/images" || { echo "removed: $id"; return 1; }; done
  printf '#!/bin/sh\nexit 1\n' > "$CLONE/scripts/airlock-doctor.sh"; gitb add -A; gitb commit -q -m t3
  : > "$ENGINE_ARGS_FILE"
  run build_install
  [ "$status" -ne 0 ]
  ! engine_args | grep -qx -- label=org.claude-airlock.apt-refresh || false
}
