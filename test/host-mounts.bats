#!/usr/bin/env bats
# Host-configured extra mounts (AIRLOCK_EXTRA_MOUNTS) and a host managed-settings drop-in
# (AIRLOCK_MANAGED_SETTINGS): set by the operator's config or the launching process, never by
# the box-writable .airlock/config.

load helper

setup() {
  setup_airlock_env
  T="$(readlink -f "$BATS_TEST_TMPDIR")"
  # stat stub: owners and modes from files ("value path" lines), the real stat otherwise; every
  # directory above the tmpdir is reported root's and closed, as /srv would be.
  FO="$T/owners" FM="$T/modes"; : > "$FO"; : > "$FM"
  cat > "$STUBBIN/stat" <<STUB
#!/usr/bin/env bash
look() { awk -v p="\$2" '{ q = \$0; sub(/^[^ ]+ /, "", q) } q == p { v = \$1 } END { print v }' "\$1"; }
if [ "\$1" = -c ] && [ "\$2" = %u ]; then v="\$(look "$FO" "\$3")"; [ -n "\$v" ] && { echo "\$v"; exit 0; }; fi
if [ "\$1" = -c ] && [ "\$2" = %a ]; then v="\$(look "$FM" "\$3")"; [ -n "\$v" ] && { echo "\$v"; exit 0; }; fi
exec /usr/bin/stat "\$@"
STUB
  chmod +x "$STUBBIN/stat"
  local d; d="$(dirname "$T")"
  while :; do printf '0 %s\n' "$d" >> "$FO"; printf '755 %s\n' "$d" >> "$FM"; [ "$d" = / ] && break; d="$(dirname "$d")"; done
  # a queue: <tmp>/srv/q root's 0755; requests/ root's, group-writable and sticky (3770);
  # answers/ root's 2750
  Q="$T/srv/q"; mkdir -p "$Q/requests" "$Q/answers"; chmod 755 "$T" "$T/srv" "$Q"
  printf '0 %s\n' "$T" "$T/srv" "$Q" "$Q/requests" "$Q/answers" >> "$FO"
  printf '3770 %s\n' "$Q/requests" >> "$FM"; printf '2750 %s\n' "$Q/answers" >> "$FM"
  mkdir -p "$AIRLOCK_HOME/.config/claude-airlock"; CFG="$AIRLOCK_HOME/.config/claude-airlock/config"
}

@test "extra mounts from the config: each at its own path, ro or rw as named; a group-writable dir is fine" {
  p="$(mkproj em)"
  printf 'AIRLOCK_EXTRA_MOUNTS="%s:rw %s:ro"\n' "$Q/requests" "$Q/answers" > "$CFG"
  _launch "$p" >/dev/null 2>&1 || true
  engine_args | grep -qx -- "$Q/requests:$Q/requests:rw"
  engine_args | grep -qx -- "$Q/answers:$Q/answers:ro"
}

@test "extra mounts from the launching process add to the config's" {
  p="$(mkproj emenv)"
  printf 'AIRLOCK_EXTRA_MOUNTS="%s:ro"\n' "$Q/answers" > "$CFG"
  AIRLOCK_EXTRA_MOUNTS="$Q/requests:rw" _launch "$p" >/dev/null 2>&1 || true
  engine_args | grep -qx -- "$Q/requests:$Q/requests:rw"
  engine_args | grep -qx -- "$Q/answers:$Q/answers:ro"
}

@test "the box-writable .airlock/config can't add an extra mount or managed settings" {
  p="$(mkproj emproj)"
  mkdir -p "$p/.airlock"
  printf 'AIRLOCK_EXTRA_MOUNTS=%s:rw\nextra_mounts = %s:rw\nAIRLOCK_MANAGED_SETTINGS=/x\n' "$Q/requests" "$Q/requests" > "$p/.airlock/config"
  run _launch "$p"
  if engine_args | grep -q -- "$Q/requests:"; then echo "mounted from .airlock/config"; return 1; fi
  [[ "$output" != *"AIRLOCK_MANAGED_SETTINGS '/x'"* ]]
}

@test "extra mounts refused: no mode, world-writable, not root's or ours, a parent not root's, a system dir, a symlink, the workspace" {
  p="$(mkproj emref)"
  refused() {  # refused <entry> <message part>
    printf 'AIRLOCK_EXTRA_MOUNTS="%s"\n' "$1" > "$CFG"
    : > "$ENGINE_ARGS_FILE"; run _launch "$p"
    [[ "$output" == *"$2"* ]] || { echo "no '$2' for $1: $output"; return 1; }
    if engine_args | grep -q -- "^${1%:*}:"; then echo "mounted anyway: $1"; return 1; fi
  }
  refused "$Q/requests" "needs :ro or :rw"
  refused "$Q/requests:rx" "needs :ro or :rw"
  printf '3777 %s\n' "$Q/requests" >> "$FM"; refused "$Q/requests:rw" "world-writable"; sed -i '$d' "$FM"
  printf '4242 %s\n' "$Q/answers" >> "$FO"; refused "$Q/answers:ro" "must be root's or yours"; sed -i '$d' "$FO"
  printf '4242 %s\n' "$Q" >> "$FO"; refused "$Q/answers:ro" "must be root's, so the directory's owner cannot swap it"; sed -i '$d' "$FO"
  printf '775 %s\n' "$Q" >> "$FM"; refused "$Q/answers:ro" "group/world-writable"; sed -i '$d' "$FM"
  refused "/etc:ro" "system directory"
  ln -s "$Q/answers" "$T/link"; refused "$T/link:ro" "is not its real path"
  mkdir -p "$p/sub"; refused "$p/sub:rw" "inside the workspace"
  refused "$T/nope:ro" "does not exist"
}

@test "an extra mount swapped for a link while a secret prompt waited: the launch stops" {
  p="$(mkproj emswap)"
  mkdir -p "$AIRLOCK_HOME/.ssh"
  printf 'AIRLOCK_EXTRA_MOUNTS="%s:ro"\n' "$Q/answers" > "$CFG"
  _launch "$p" secret set TOKEN pass:x/y >/dev/null
  printf '#!/usr/bin/env bash\nmv "%s" "%s.away" && ln -s "%s" "%s"\necho secret\n' "$Q/answers" "$Q/answers" "$AIRLOCK_HOME/.ssh" "$Q/answers" > "$STUBBIN/pass"
  chmod +x "$STUBBIN/pass"
  run _launch "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"extra mount $Q/answers changed after it was checked"* ]] || { echo "$output"; return 1; }
  ! engine_args | grep -q '^ENGINE_INVOKED=' || false
}

@test "managed settings: a root-owned JSON object is copied in as the box's managed-settings drop-in" {
  p="$(mkproj ms)"
  f="$T/ms.json"; printf '{"permissions":{"deny":["SendMessage","ListAgents"]}}\n' > "$f"
  printf '0 %s\n' "$f" >> "$FO"; printf '644 %s\n' "$f" >> "$FM"
  printf 'AIRLOCK_MANAGED_SETTINGS=%s\n' "$f" > "$CFG"
  _launch "$p" >/dev/null 2>&1 || true
  sd="$AIRLOCK_HOME/.config/claude-airlock/state/$(_slug "$p")/managed-settings.d"
  cmp -s "$f" "$sd/50-host.json"
  engine_args | grep -qx -- "$sd:/etc/claude-code/managed-settings.d:ro"
}

@test "managed settings refused (the launch stops): missing, not root's, writable by others, not a JSON object" {
  p="$(mkproj msref)"
  f="$T/ms.json"; printf '{"a":1}\n' > "$f"
  stops() {  # stops <message part>
    printf 'AIRLOCK_MANAGED_SETTINGS=%s\n' "${MS:-$f}" > "$CFG"
    : > "$ENGINE_ARGS_FILE"; run _launch "$p"
    [[ "$output" == *"$1"* ]] || { echo "no '$1': $output"; return 1; }
    if engine_args | grep -q '^ENGINE_INVOKED='; then echo "launched anyway"; return 1; fi
  }
  MS="$T/none.json" stops "does not exist"
  printf '644 %s\n' "$f" >> "$FM"; stops "must be a file root owns"                  # ours, not root's
  printf '0 %s\n' "$f" >> "$FO"; printf '664 %s\n' "$f" >> "$FM"; stops "must be a file root owns"
  printf '644 %s\n' "$f" >> "$FM"; printf '[1,2]\n' > "$f"; stops "not a JSON object"
  printf 'not json\n' > "$f"; stops "not a JSON object"
}

@test "a workspace holding the account's airlock state (\$HOME or above) is refused: it would hand the box its managed settings" {
  f="$T/ms.json"; printf '{"a":1}\n' > "$f"; printf '0 %s\n' "$f" >> "$FO"; printf '644 %s\n' "$f" >> "$FM"
  printf 'AIRLOCK_MANAGED_SETTINGS=%s\n' "$f" > "$CFG"
  run _launch "$AIRLOCK_HOME"
  [ "$status" -ne 0 ]; [[ "$output" == *"this account's airlock state"* ]] || { echo "$output"; return 1; }
  if engine_args | grep -q '^ENGINE_INVOKED='; then echo "launched"; return 1; fi
}

@test "the state refusal holds through symlinks, from /, and from inside the state or install dirs" {
  refused() {  # refused <dir> [logical pwd]
    : > "$ENGINE_ARGS_FILE"; TEST_LOGICAL_PWD="${2:-}" run _launch "$1"
    [ "$status" -ne 0 ] && [[ "$output" == *"this account's airlock state"* ]] || { echo "$1: $output"; return 1; }
    if engine_args | grep -q '^ENGINE_INVOKED='; then echo "$1: launched"; return 1; fi
  }
  mkdir -p "$AIRLOCK_HOME/.config/claude-airlock/state" "$AIRLOCK_HOME/.local/share/claude-airlock/versions"
  ln -s "$AIRLOCK_HOME" "$T/homelink"
  refused "$T/homelink" "$T/homelink"                                   # a symlink to $HOME
  refused /
  refused "$AIRLOCK_HOME/.config/claude-airlock/state"
  refused "$AIRLOCK_HOME/.local/share/claude-airlock/versions"
  # the config dir symlinked out of $HOME: $HOME itself is still refused
  mv "$AIRLOCK_HOME/.config/claude-airlock" "$T/cfg-elsewhere"; ln -s "$T/cfg-elsewhere" "$AIRLOCK_HOME/.config/claude-airlock"
  refused "$AIRLOCK_HOME"
  refused "$T/cfg-elsewhere/state"
  refused / //                                                         # "//" resolves to /
  mkdir -p "$AIRLOCK_HOME/.local/bin"; refused "$AIRLOCK_HOME/.local/bin"
  # an installed launcher's own root (<root>/versions/<rev>), wherever the root is
  mkdir -p "$T/iroot/versions/r1" "$T/iroot/work"
  tar -C "$BATS_TEST_DIRNAME/.." --exclude=.git --exclude=.tooling -cf - . | tar -x -C "$T/iroot/versions/r1"
  ( AIRLOCK="$T/iroot/versions/r1/bin/claude-airlock"; refused "$T/iroot/work" )
  # an AIRLOCK_CONFIG the account owns: refused only when the workspace holds the file
  mkdir -p "$T/cfgs/proj"; printf '' > "$T/cfgs/airlock.conf"
  TEST_AIRLOCK_CONFIG="$T/cfgs/airlock.conf" refused "$T/cfgs"
  : > "$ENGINE_ARGS_FILE"; TEST_AIRLOCK_CONFIG="$T/cfgs/airlock.conf" _launch "$T/cfgs/proj" >/dev/null 2>&1 || true
  engine_args | grep -q '^ENGINE_INVOKED='
  # a project folder still launches
  p="$(mkproj fine)"; : > "$ENGINE_ARGS_FILE"; _launch "$p" >/dev/null 2>&1 || true
  engine_args | grep -q '^ENGINE_INVOKED='
}

@test "extra mounts: entries on later lines of a multi-line value are kept" {
  p="$(mkproj emlines)"
  printf 'AIRLOCK_EXTRA_MOUNTS="%s:ro\n%s:ro"\n' "$Q/requests" "$Q/answers" > "$CFG"
  : > "$ENGINE_ARGS_FILE"; _launch "$p" >/dev/null 2>&1 || true
  engine_args | grep -qx -- "$Q/requests:$Q/requests:ro"
  engine_args | grep -qx -- "$Q/answers:$Q/answers:ro"
}

@test "extra mounts: read-write needs a root-owned dir (ours is read-only only); named twice, mounted once, ro wins; env-only mounted once; no globbing" {
  p="$(mkproj emmore)"
  mkdir -p "$Q/mine"; printf '%s %s\n' "$(id -u)" "$Q/mine" >> "$FO"; printf '755 %s\n' "$Q/mine" >> "$FM"
  printf 'AIRLOCK_EXTRA_MOUNTS="%s:rw"\n' "$Q/mine" > "$CFG"
  : > "$ENGINE_ARGS_FILE"; run _launch "$p"
  [[ "$output" == *"read-write needs a directory root owns"* ]]; if engine_args | grep -q -- "^$Q/mine:"; then return 1; fi
  printf 'AIRLOCK_EXTRA_MOUNTS="%s:ro"\n' "$Q/mine" > "$CFG"
  : > "$ENGINE_ARGS_FILE"; _launch "$p" >/dev/null 2>&1 || true
  engine_args | grep -qx -- "$Q/mine:$Q/mine:ro"
  # twice (config rw + env ro): one mount, read-only
  printf 'AIRLOCK_EXTRA_MOUNTS="%s:rw"\n' "$Q/requests" > "$CFG"
  : > "$ENGINE_ARGS_FILE"; AIRLOCK_EXTRA_MOUNTS="$Q/requests:ro" _launch "$p" >/dev/null 2>&1 || true
  [ "$(engine_args | grep -c -- "^$Q/requests:")" = 1 ]; engine_args | grep -qx -- "$Q/requests:$Q/requests:ro"
  # environment only (nothing in the config): once
  : > "$CFG"; : > "$ENGINE_ARGS_FILE"; AIRLOCK_EXTRA_MOUNTS="$Q/answers:ro" _launch "$p" >/dev/null 2>&1 || true
  [ "$(engine_args | grep -c -- "^$Q/answers:")" = 1 ]
  # a glob is a literal path, never expanded into what's there
  mkdir -p "$Q/x"; printf '0 %s\n' "$Q/x" >> "$FO"; printf '755 %s\n' "$Q/x" >> "$FM"
  printf 'AIRLOCK_EXTRA_MOUNTS="%s/*:ro"\n' "$Q" > "$CFG"
  : > "$ENGINE_ARGS_FILE"; _launch "$p" >/dev/null 2>&1 || true
  if engine_args | grep -q -- "^$Q/x:"; then echo "glob expanded"; return 1; fi
}

@test "an extra mount swapped for another real directory (not a link) while a prompt waited: the inode pin stops the launch" {
  p="$(mkproj emswap2)"
  printf 'AIRLOCK_EXTRA_MOUNTS="%s:ro"\n' "$Q/answers" > "$CFG"
  _launch "$p" secret set TOKEN pass:x/y >/dev/null
  printf '#!/usr/bin/env bash\nmv "%s" "%s.away" && mkdir "%s"\necho secret\n' "$Q/answers" "$Q/answers" "$Q/answers" > "$STUBBIN/pass"
  chmod +x "$STUBBIN/pass"
  run _launch "$p"
  [ "$status" -ne 0 ]; [[ "$output" == *"extra mount $Q/answers changed after it was checked"* ]] || { echo "$output"; return 1; }
}

# Web research in the box CLAUDE.md: the queue's rule first, how to ask last, only with the queue
# mounted as the agents apply sets it up and both files root's.
webq() {  # a queue lib/ holding both rendered files, root's
  mkdir -p "$Q/lib"; printf '0 %s\n' "$Q/lib" >> "$FO"; printf '755 %s\n' "$Q/lib" >> "$FM"
  printf '# RULE-TOP\n' > "$Q/lib/web-research-rule.md"; printf '\n## HOW-TO-ASK\n' > "$Q/lib/web-research.md"
  printf '0 %s\n' "$Q/lib/web-research-rule.md" "$Q/lib/web-research.md" >> "$FO"
}
webmounts() { printf 'AIRLOCK_EXTRA_MOUNTS="%s:rw %s:ro %s:ro"\n' "$Q/requests" "$Q/answers" "$Q/lib" > "$CFG"; }
box_md() { cat "$(state_dir "$1")/dot-claude/CLAUDE.md"; }
seed_md() { cat "$BATS_TEST_DIRNAME/../config/box-CLAUDE.md"; }

@test "box CLAUDE.md with web research: the rule above the seeded conventions, how to ask after them" {
  p="$(mkproj webmd)"; webq; webmounts
  _launch "$p" >/dev/null 2>&1 || true
  [ "$(box_md "$p")" = "$(printf '# RULE-TOP\n\n'; seed_md; printf '\n## HOW-TO-ASK')" ]
}

@test "box CLAUDE.md without the whole queue, or files not root's, missing, a link or too big: the seeded file" {
  p="$(mkproj webno)"; webq
  plain() { _launch "$p" >/dev/null 2>&1 || true; [ "$(box_md "$p")" = "$(seed_md)" ] || { echo "not plain: $1"; return 1; }; }
  : > "$CFG"; plain "no mounts"
  printf 'AIRLOCK_EXTRA_MOUNTS="%s:ro %s:ro"\n' "$Q/answers" "$Q/lib" > "$CFG"; plain "no requests"
  printf 'AIRLOCK_EXTRA_MOUNTS="%s:rw %s:ro"\n' "$Q/requests" "$Q/lib" > "$CFG"; plain "no answers"
  printf 'AIRLOCK_EXTRA_MOUNTS="%s:rw %s:ro"\n' "$Q/requests" "$Q/answers" > "$CFG"; plain "no lib"
  printf 'AIRLOCK_EXTRA_MOUNTS="%s:rw %s:ro %s:rw"\n' "$Q/requests" "$Q/answers" "$Q/lib" > "$CFG"; plain "lib rw"
  # the worker steps' shapes: requests read-only, answers read-write
  printf 'AIRLOCK_EXTRA_MOUNTS="%s:ro %s:ro %s:ro"\n' "$Q/requests" "$Q/answers" "$Q/lib" > "$CFG"; plain "requests ro"
  printf 'AIRLOCK_EXTRA_MOUNTS="%s:rw %s:rw %s:ro"\n' "$Q/requests" "$Q/answers" "$Q/lib" > "$CFG"; plain "answers rw"
  # ro wins: the config's rw requests, read-only from the launching process
  webmounts; AIRLOCK_EXTRA_MOUNTS="$Q/requests:ro" _launch "$p" >/dev/null 2>&1 || true
  [ "$(box_md "$p")" = "$(seed_md)" ] || { echo "not plain: requests ro from the environment"; return 1; }
  webmounts
  printf '%s %s\n' "$(id -u)" "$Q/lib/web-research.md" >> "$FO"; plain "how-to not root's"; sed -i '$d' "$FO"
  printf '%s %s\n' "$(id -u)" "$Q/lib/web-research-rule.md" >> "$FO"; plain "rule not root's"; sed -i '$d' "$FO"
  printf '664 %s\n' "$Q/lib/web-research-rule.md" >> "$FM"; plain "rule group-writable"; sed -i '$d' "$FM"
  printf '646 %s\n' "$Q/lib/web-research.md" >> "$FM"; plain "how-to world-writable"; sed -i '$d' "$FM"
  chmod 000 "$Q/lib/web-research.md"; plain "how-to unreadable"; chmod 644 "$Q/lib/web-research.md"
  mv "$Q/lib/web-research.md" "$Q/lib/w.away"; mkdir "$Q/lib/web-research.md"; printf '0 %s\n' "$Q/lib/web-research.md" >> "$FO"
  plain "how-to a directory"; rmdir "$Q/lib/web-research.md"; sed -i '$d' "$FO"; mv "$Q/lib/w.away" "$Q/lib/web-research.md"
  mv "$Q/lib/web-research.md" "$Q/lib/w.away"; plain "how-to missing"
  ln -s w.away "$Q/lib/web-research.md"; plain "how-to a link"; rm "$Q/lib/web-research.md"; mv "$Q/lib/w.away" "$Q/lib/web-research.md"
  head -c 16385 /dev/zero > "$Q/lib/web-research-rule.md"; plain "rule too big"
}

@test "box CLAUDE.md: web research one launch, not the next: the parts do not linger" {
  p="$(mkproj weblinger)"; webq; webmounts
  _launch "$p" >/dev/null 2>&1 || true
  grep -q 'RULE-TOP' <<< "$(box_md "$p")"
  : > "$CFG"; _launch "$p" >/dev/null 2>&1 || true
  [ "$(box_md "$p")" = "$(seed_md)" ]
}

# The box CLAUDE.md's base (AIRLOCK_BOX_CLAUDE_MD) and the account's additions
# (AIRLOCK_BOX_CLAUDE_EXTRA, else ~/.config/claude-airlock/box-CLAUDE.md).
mdfile() {  # mdfile <path> <text> [owner] [mode]
  mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"
  printf '%s %s\n' "${3:-0}" "$1" >> "$FO"; printf '%s %s\n' "${4:-644}" "$1" >> "$FM"
}

@test "box CLAUDE.md layers: base none, a base file, the default additions, named additions, in order" {
  p="$(mkproj layers)"
  printf 'AIRLOCK_BOX_CLAUDE_MD=none\n' > "$CFG"
  _launch "$p" >/dev/null 2>&1 || true
  [ "$(box_md "$p")" = "" ]
  mdfile "$Q/base.md" "BASE-TEXT"
  printf 'AIRLOCK_BOX_CLAUDE_MD=%s\n' "$Q/base.md" > "$CFG"
  _launch "$p" >/dev/null 2>&1 || true
  [ "$(box_md "$p")" = "BASE-TEXT" ]
  # the account's own file, found by default, after the toolkit's base
  : > "$CFG"; mdfile "$AIRLOCK_HOME/.config/claude-airlock/box-CLAUDE.md" "MINE" "$(id -u)"
  _launch "$p" >/dev/null 2>&1 || true
  [ "$(box_md "$p")" = "$(seed_md; printf '\nMINE')" ]
  # a named one wins over the default; with web research it sits before the how-to
  mdfile "$Q/extra.md" "NAMED" "$(id -u)"; webq
  printf 'AIRLOCK_EXTRA_MOUNTS="%s:rw %s:ro %s:ro"\nAIRLOCK_BOX_CLAUDE_EXTRA=%s\n' "$Q/requests" "$Q/answers" "$Q/lib" "$Q/extra.md" > "$CFG"
  _launch "$p" >/dev/null 2>&1 || true
  [ "$(box_md "$p")" = "$(printf '# RULE-TOP\n\n'; seed_md; printf '\nNAMED\n\n## HOW-TO-ASK')" ]
}

@test "box CLAUDE.md layers refused (the launch stops): missing, another owner, writable by others, too big, in the workspace or the box state" {
  p="$(mkproj layref)"
  stops() {  # stops <var> <path> <message part>
    printf '%s=%s\n' "$1" "$2" > "$CFG"
    : > "$ENGINE_ARGS_FILE"; run _launch "$p"
    [ "$status" -ne 0 ] && ! launched_any || { echo "launched with $1=$2: $output"; return 1; }
    [[ "$output" == *"$3"* ]] || { echo "no '$3' for $1=$2: $output"; return 1; }
  }
  launched_any() { engine_args | grep -q '^ENGINE_INVOKED='; }
  stops AIRLOCK_BOX_CLAUDE_MD "$Q/nope.md" "does not exist"
  stops AIRLOCK_BOX_CLAUDE_EXTRA "$Q/nope.md" "does not exist"
  mdfile "$Q/other.md" x 4242; stops AIRLOCK_BOX_CLAUDE_EXTRA "$Q/other.md" "root's or yours"
  mdfile "$Q/gw.md" x 0 664; stops AIRLOCK_BOX_CLAUDE_MD "$Q/gw.md" "no one else may write"
  mdfile "$Q/big.md" x; head -c 65537 /dev/zero > "$Q/big.md"; stops AIRLOCK_BOX_CLAUDE_EXTRA "$Q/big.md" "at most 64 KiB"
  mkdir -p "$Q/d"; printf '0 %s\n' "$Q/d" >> "$FO"; stops AIRLOCK_BOX_CLAUDE_MD "$Q/d" "readable file"
  mdfile "$p/notes.md" x "$(id -u)"; stops AIRLOCK_BOX_CLAUDE_EXTRA "$p/notes.md" "inside the workspace"
  sd="$(state_dir "$p")"; mdfile "$sd/dot-claude/mine.md" x "$(id -u)"; stops AIRLOCK_BOX_CLAUDE_EXTRA "$sd/dot-claude/mine.md" "box state"
  ln -s "$sd/dot-claude/mine.md" "$Q/link.md"; stops AIRLOCK_BOX_CLAUDE_EXTRA "$Q/link.md" "box state"
}

@test "box CLAUDE.md: a box's own edits to it are replaced at the next launch" {
  p="$(mkproj layedit)"
  _launch "$p" >/dev/null 2>&1 || true
  printf 'PLANTED\n' >> "$(state_dir "$p")/dot-claude/CLAUDE.md"
  _launch "$p" >/dev/null 2>&1 || true
  [ "$(box_md "$p")" = "$(seed_md)" ]
}
