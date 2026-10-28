#!/usr/bin/env bats
# The agents toolkit (agents/): airlock-agents-apply (render + provision) and the operator command,
# against a fake root with every system command stubbed (useradd, getent, passwd, systemctl,
# loginctl, mkfs.xfs, machinectl, nft...). Nothing here touches the real system. The site: an
# operator alice and agents agent, agent-web, agent-guard (uids 1100-1102).

# site_file <agent size> <web size> <guard size>: the test site (sizes as the site file has them)
site_file() {
    cat > "$E/agents.conf" <<EOF
operator alice
command  agent
agent    agent        uid 1100 subuid 1100000 home $1
web      agent-web    uid 1101 subuid 1200000 home $2
guard    agent-guard  uid 1102 subuid 1300000 home $3
internal-name example.com
EOF
}
# env_set <KEY> <value>: change one name in the operator command's agents.env
env_set() { sed -i "s#^$1=.*#$1=$2#" "$AIRLOCK_AGENTS_ENV"; }

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"; export REPO
    T="$BATS_TEST_TMPDIR"
    export AIRLOCK_AGENTS_ROOT="$T/root" LOG="$T/calls" AIRLOCK_AGENTS_SYSTEMD_VERSION=257
    R="$AIRLOCK_AGENTS_ROOT"
    # The site file and each user's claude-airlock config, where apply reads them (under the root).
    E="$R/etc/claude-airlock/agents"; mkdir -p "$E"
    site_file 1G 1G 1G
    for u in agent agent-web agent-guard; do "$REPO/agents/airlock-agents-apply" --user-conf "$u" > "$E/$u.conf"; done
    # The operator command's names, as apply renders them (its inbox and queue under the test dir).
    export AIRLOCK_AGENTS_ENV="$T/agents.env"
    "$REPO/agents/airlock-agents-apply" --env > "$AIRLOCK_AGENTS_ENV"
    # Every file apply renders for this site (the tests read them here).
    RENDER="$T/render"; "$REPO/agents/airlock-agents-apply" --render "$RENDER" >/dev/null
    # Each user's default claude-airlock config (what install writes on the first run).
    UC="$T/userconf"; mkdir -p "$UC"
    for u in agent agent-web agent-guard; do "$REPO/agents/airlock-agents-apply" --user-conf "$u" > "$UC/$u.conf"; done
    mkdir -p "$R/home/alice" "$R/home/agent" "$R/home/agent-web" "$R/home/agent-guard" "$R/etc" "$R/var/lib/systemd/linger" "$T/bin"
    chmod 755 "$R/home/alice"
    : > "$R/etc/subuid"; : > "$R/etc/subgid"; : > "$LOG"
    printf 'alice:100000:65536\n' > "$R/etc/subuid"; cp "$R/etc/subuid" "$R/etc/subgid"
    : > "$T/passwd"; : > "$T/group"
    export PASSWD="$T/passwd" GROUP="$T/group"
    # getent answers from the fake passwd/group files; alice (1000) always exists.
    cat > "$T/bin/getent" <<'S'
#!/bin/bash
db=$1 key=${2:-}; f=$PASSWD; [ "$db" = group ] && f=$GROUP
{ [ "$db" = group ] && echo "alice:x:1000:" || echo "alice:x:1000:1000::/home/alice:/bin/zsh"; cat "$f"; } \
    | awk -F: -v k="$key" 'k == "" || $1 == k || $3 == k { print; found = 1 } END { exit !found }'
S
    cat > "$T/bin/useradd" <<'S'
#!/bin/bash
echo "useradd $*" >> "$LOG"; n=$2; u="${*: -1}"; echo "$u:x:$n:$n::/home/$u:/bin/bash" >> "$PASSWD"
S
    cat > "$T/bin/groupadd" <<'S'
#!/bin/bash
echo "groupadd $*" >> "$LOG"; echo "$3:x:$2:" >> "$GROUP"
S
    # id -nG <user>: AGENT_GROUPS for agent, AGENT_WEB_GROUPS for agent-web, else the user's own.
    cat > "$T/bin/id" <<'S'
#!/bin/bash
case "$1" in
    -u) echo 0 ;;
    -nG) case "$2" in agent) echo "${AGENT_GROUPS:-agent}" ;; agent-web) echo "${AGENT_WEB_GROUPS:-agent-web}" ;; *) echo "$2" ;; esac ;;
    *) echo "uid=($1)" ;;
esac
S
    cat > "$T/bin/passwd" <<'S'
#!/bin/bash
echo "passwd $*" >> "$LOG"
[ "$1" = -S ] && echo "$2 ${PASSWD_STATE:-P}"
exit 0
S
    # getfacl -cpnE <path>: the named entries a test wrote for that path ($ACLS/<path, / as _>).
    export ACLS="$T/acls"; mkdir -p "$ACLS"
    cat > "$T/bin/getfacl" <<'S'
#!/bin/bash
f="$ACLS/$(printf '%s' "${*: -1}" | tr / _)"; [ -f "$f" ] && cat "$f"; exit 0
S
    # stat -c <fmt> <path>: for paths with a sidecar in $STATS (owner:group:mode as numbers),
    # that answer for %u:%g:%a (a test can't chown to root or agent); otherwise the real stat.
    export STATS="$T/stats"; mkdir -p "$STATS"
    cat > "$T/bin/stat" <<'S'
#!/bin/bash
f="$STATS/$(printf '%s' "${*: -1}" | tr / _)"
if [ "$1 $2" = "-c %u:%g:%a" ] && [ -f "$f" ]; then cat "$f"; else exec /usr/bin/stat "$@"; fi
S
    # systemd-tmpfiles --create /etc/tmpfiles.d/<f>: log it, and make the d/D dirs of the rendered
    # file under the fake root with their modes (owners and ACLs can't be set in a test).
    cat > "$T/bin/systemd-tmpfiles" <<'S'
#!/bin/bash
echo "systemd-tmpfiles $*" >> "$LOG"
awk '$1 == "d" || $1 == "D" { print $2, $3 }' "$AIRLOCK_AGENTS_ROOT$2" | while read -r p m; do
    mkdir -p "$AIRLOCK_AGENTS_ROOT$p"; chmod "$m" "$AIRLOCK_AGENTS_ROOT$p"
done
S
    cat > "$T/bin/mountpoint" <<'S'
#!/bin/bash
[ -n "${MOUNTED:-}" ]
S
    printf '#!/bin/sh\nexit 0\n' > "$T/bin/crun"                  # installed (the agents' box runtime)
    for c in systemctl loginctl mkfs.xfs chown nft; do
        printf '#!/bin/bash\necho "%s $*" >> "$LOG"\n' "$c" > "$T/bin/$c"
    done
    # Read-only queries are not actions: systemctl is-enabled/is-active and nft list answer
    # (NFT_LOADED: the agents' table is loaded and its unit enabled) without a log line.
    cat > "$T/bin/systemctl" <<'S'
#!/bin/bash
case "$1" in is-enabled|is-active) [ -n "${NFT_LOADED:-}" ]; exit ;; esac
echo "systemctl $*" >> "$LOG"
S
    cat > "$T/bin/nft" <<'S'
#!/bin/bash
# nft list: the live table, here the installed file (NFT_LOADED) or nothing loaded
[ "$1" = -n ] && shift
if [ "$1 ${2:-}" = "list ruleset" ]; then cat "${NFT_RULESET:-/dev/null}"; exit; fi
if [ "$1" = list ]; then [ -n "${NFT_LOADED:-}" ] && cat "${NFT_LIVE:-$AIRLOCK_AGENTS_ROOT/etc/airlock-agents.nft}"; exit; fi
echo "nft $*" >> "$LOG"
S
    # setpriv: record the identity, run the command (as the test user).
    cat > "$T/bin/setpriv" <<'S'
#!/bin/bash
ids=(); while [[ "$1" == --* ]]; do ids+=("$1"); shift; done
echo "setpriv ${ids[*]} $*" >> "$LOG"; exec "$@"
S
    # install: owners can't be set in a test (no agent user); drop -o/-g, keep the rest.
    cat > "$T/bin/install" <<'S'
#!/bin/bash
args=(); while [ $# -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac; done
echo "install ${args[*]}" >> "$LOG"; exec /usr/bin/install "${args[@]}"
S
    chmod +x "$T"/bin/*
    export PATH="$T/bin:$PATH"
    mkdir -p "$R/usr/local/lib/airlock-agents/bin"; ln -sf "$T/bin/install" "$R/usr/local/lib/airlock-agents/bin/install"
    printf '#!/bin/bash\necho "nodump-refresh $*" >> "$LOG"\n' > "$R/usr/local/lib/airlock-agents/nodump-refresh"; chmod +x "$R/usr/local/lib/airlock-agents/nodump-refresh"
    P="$REPO/agents/airlock-agents-apply"
}

@test "provision dry run: lists every step and changes nothing" {
    run "$P"
    [ "$status" -eq 0 ]
    [[ "$output" == *"would: chmod 0700 /home/alice (was 755)"* ]]
    [[ "$output" == *"would: create /var/lib/agent/home.img: sparse 1G, XFS"* ]]
    [[ "$output" == *"would: enable and start home-agent.mount"* ]]
    [[ "$output" == *"would: groupadd -g 1100 agent"* ]]
    [[ "$output" == *"would: useradd agent"* ]]
    [[ "$output" == *"would: /etc/subuid: agent:1100000:65536"* ]]
    [[ "$output" == *"would: loginctl enable-linger agent"* ]]
    [[ "$output" == *"would: /srv/agent-inbox root 0755, pastes/ and airlock/ alice:agent 2750"* ]]
    [[ "$output" == *"run with --confirm to apply"* ]]
    [ ! -s "$LOG" ]
    [ "$(stat -c %a "$R/home/alice")" = 755 ]
    [ ! -e "$R/var/lib/agent/home.img" ]
}

@test "an existing user config missing a setting the current default has: named, never changed" {
    sed -i '/^AIRLOCK_BOX_CLAUDE_MD=/d' "$E/agent-web.conf"
    before="$(cat "$E/agent-web.conf")"
    run "$P"
    [ "$status" -eq 0 ]
    [[ "$output" == *"note /etc/claude-airlock/agents/agent-web.conf has no AIRLOCK_BOX_CLAUDE_MD, which the current default sets (docs/agents.md): AIRLOCK_BOX_CLAUDE_MD=none"* ]]
    [ "$(cat "$E/agent-web.conf")" = "$before" ]
    # a mention mid-line is not a setting; every missing key is named, in each file
    printf '# see AIRLOCK_BOX_CLAUDE_MD=none in the docs\n' >> "$E/agent-web.conf"
    sed -i '/^AIRLOCK_EGRESS_PROXY=/d' "$E/agent.conf"
    run "$P"
    [[ "$output" == *"agent-web.conf has no AIRLOCK_BOX_CLAUDE_MD"* ]]
    [[ "$output" == *"/etc/claude-airlock/agents/agent.conf has no AIRLOCK_EGRESS_PROXY, which the current default sets (docs/agents.md): AIRLOCK_EGRESS_PROXY=/run/airlock-envoy/agent/agent-anthropic.sock"* ]]
    # a commented-out line or an export counts as the operator's decision: no note
    printf '# AIRLOCK_BOX_CLAUDE_MD=none\n' >> "$E/agent-web.conf"
    printf 'export AIRLOCK_EGRESS_PROXY=/x.sock\n' >> "$E/agent.conf"
    run "$P"
    [[ "$output" != *"has no AIRLOCK_BOX_CLAUDE_MD"* ]]
    [[ "$output" != *"has no"* ]]
}

@test "provision --confirm: creates a sparse image, the user, subids, locks the password" {
    run "$P" --confirm
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(stat -c %a "$R/home/alice")" = 700 ]
    [ "$(du -k --apparent-size "$R/var/lib/agent/home.img" | cut -f1)" -ge $((1024 * 1024)) ]
    [ "$(du -k "$R/var/lib/agent/home.img" | cut -f1)" -lt 1024 ]          # sparse: nothing allocated
    grep -q "mkfs.xfs -q -L agent " "$LOG"
    grep -q "useradd -u 1100 -g agent -d /home/agent -M -s /bin/bash -c Claude (airlock) -K SUB_UID_COUNT=0 -K SUB_GID_COUNT=0 agent" "$LOG"
    if grep -q -- " -G" "$LOG"; then echo "should not match (line 119)"; return 1; fi                                              # no extra groups
    grep -q "passwd -q -l agent" "$LOG"
    grep -qx "agent:1100000:65536" "$R/etc/subuid"
    grep -qx "agent:1100000:65536" "$R/etc/subgid"
    grep -q "loginctl enable-linger agent" "$LOG"
    [ -d "$R/srv/agent-inbox/pastes" ]
    [ -d "$R/srv/agent-inbox/airlock" ]
    [ "$(stat -c %a "$R/srv/agent-inbox/airlock")" = 2750 ]
}

@test "provision refuses: uid taken by someone else, overlapping subuids, extra groups" {
    echo "mallory:x:1100:1100::/home/m:/bin/sh" > "$PASSWD"
    run "$P" --confirm
    [ "$status" -eq 1 ]; [[ "$output" == *"uid 1100 belongs to mallory"* ]]

    : > "$PASSWD"
    echo "other:1100500:10" >> "$R/etc/subuid"
    run "$P" --confirm
    [ "$status" -eq 1 ]; [[ "$output" == *"/etc/subuid already uses part of 1100000"* ]]

    printf 'alice:100000:65536\n' > "$R/etc/subuid"
    AGENT_GROUPS="agent wheel" run "$P" --confirm
    [ "$status" -eq 1 ]; [[ "$output" == *"agent is in other groups (wheel)"* ]]
}

@test "provision is idempotent: a second run changes nothing" {
    run "$P" --confirm
    [ "$status" -eq 0 ]
    # The state the first run produced, as the live system would report it.
    touch "$R/var/lib/systemd/linger/agent"
    : > "$LOG"
    MOUNTED=1 PASSWD_STATE=L run "$P"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # chown/install don't run in tests, so the home and inbox ownership checks still differ;
    # everything else must report ok.
    [[ "$output" == *"ok   /home/alice is 0700"* ]]
    [[ "$output" == *"ok   /var/lib/agent/home.img exists"* ]]
    [[ "$output" == *"ok   user agent"* ]]
    [[ "$output" == *"ok   agent's password is locked"* ]]
    [[ "$output" == *"ok   /etc/subuid has agent"* ]]
    [[ "$output" == *"ok   linger on"* ]]
    [[ "$output" != *"would: create"* && "$output" != *"would: useradd"* && "$output" != *"would: lock"* ]]
}

@test "provision --check: the dry run as a drift check, exit 1 on any change, and nothing run" {
    run "$P" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"would: useradd agent"* && "$output" == *"drifted from the site file"* ]]
    [[ "$output" == *"airlock/"* ]]
    # agent's own starter dirs are agent's to keep: a note, never drift.
    [[ "$output" == *"note: /home/agent starter dirs missing"* && "$output" != *"would: starter dirs"* ]]
    [ ! -s "$LOG" ]
}

@test "the inbox's tmpfiles.d keeps pastes and bundles transient: emptied at boot, aged out after a day" {
    f="$RENDER/etc/tmpfiles.d/airlock-agents-inbox.conf"
    grep -qE '^d /srv/agent-inbox +0755 root +root ' "$f"
    grep -qE '^D /srv/agent-inbox/pastes +2750 alice 1100 1d$' "$f"
    grep -qE '^D /srv/agent-inbox/airlock +2750 alice 1100 1d$' "$f"
}

@test "provision rejects a bad size and unknown arguments" {
    site_file lots 1G 1G
    run "$P"
    [ "$status" -ne 0 ]; [[ "$output" == *"bad home size 'lots'"* ]]
    site_file 1G 1G 1G
    run "$P" --yes
    [ "$status" -ne 0 ]; [[ "$output" == *"unknown option --yes"* ]]
}

# ---- the agent command ------------------------------------------------------------------

op_stubs() {
    # machinectl: log the call; for octl's /bin/sh wrapper, answer like the remote side
    # would (REMOTE_OUT, a CR, then the status marker; REMOTE_RC sets it).
    # orun's calls run for real: the remote /bin/sh script, with systemd-run a stub that runs
    # the command after "--" (so the status and marker handling are what's under test).
    cat > "$T/bin/machinectl" <<'S'
#!/bin/bash
echo "machinectl $*" >> "$LOG"
# orun: the remote shell is agent's execute-only copy of sh ($ND/sh, here bash), and the script
# calls "$nd/systemd-run" (here the stub below): run it for real
if [[ "$4" == */sh && "$5" == -c && "$6" == *'/systemd-run" --user --wait --pipe'* ]]; then
    exec "$4" -c "$6" "${@:7}"
fi
# a unit's NeedDaemonReload: UNREAD names the managers (user@) that haven't read their changed units
case "$*" in *"show -p NeedDaemonReload"*)
    r=no; for a; do case "$a" in *@) case " ${UNREAD:-} " in *" ${a%@} "*) r=yes ;; esac ;; esac; done
    printf '%s\r\nagent-rc=0\r\n' "$r"; exit 0 ;; esac
case "$*" in *"agent-rc="*) printf '%s\r\nagent-rc=%s\r\n' "${REMOTE_OUT:-remote output}" "${REMOTE_RC:-0}" ;; esac
exit 0
S
    cat > "$T/bin/systemd-run" <<'S'
#!/bin/bash
while [ "$1" != -- ]; do shift; done; shift
exec "$@"
S
    chmod +x "$T/bin/systemd-run"
    chmod +x "$T/bin/machinectl"
    # agent's execute-only copies, as stubs: sh is bash, systemd-run the stub above
    export AGENTS_NODUMP_DIR="$T/nd"; mkdir -p "$T/nd"
    ln -sf /bin/bash "$T/nd/sh"; ln -sf "$T/bin/systemd-run" "$T/nd/systemd-run"; ln -sf /bin/true "$T/nd/systemctl"
    for b in sh systemd-run systemctl; do echo 0:0:711 > "$STATS/$(printf '%s' "$T/nd/$b" | tr / _)"; done   # root's, 0711
    O="$REPO/agents/operator"
}
octl_call() {  # the systemctl arguments octl sent, from the log
    grep -F "systemctl\" --user --no-pager" "$LOG" | sed 's/.*agent-rc=$?" sh [^ ]* //'
}

@test "agent ls, agent list and plain agent all list the sessions" {
    op_stubs
    for c in ls list ""; do
        : > "$LOG"
        run "$O" ${c:+"$c"}
        [ "$status" -eq 0 ]
        octl_call | grep -qxF "list-units --all --full --no-legend --plain agent-session@*.service"
    done
}

@test "agent new/stop/restart/attach target agent's user manager and the right unit" {
    op_stubs
    run "$O" new infra-planning
    [ "$status" -eq 0 ]
    M="machinectl shell -q agent@"
    octl_call | grep -qx "enable --now agent-session@infra-planning.main.service"
    grep -q -- "-E SYSTEMD_PAGER=cat -E SYSTEMD_COLORS=0 agent@ $T/nd/sh -c" "$LOG"
    run "$O" new k8s review
    octl_call | grep -qx "enable --now agent-session@k8s.review.service"
    run "$O" stop k8s.review
    octl_call | grep -qx "disable --now agent-session@k8s.review.service"
    REMOTE_OUT="agent-session@infra-planning.main.service loaded active running agent session" \
        run "$O" restart infra-planning
    octl_call | grep -qx "restart agent-session@infra-planning.main.service"
    # attach and shell run inside agent's user manager (its netns and /tmp), not the login session
    run "$O" attach k8s.review
    grep -qx "$M $T/nd/systemd-run --user --pty --wait --collect --quiet --same-dir -- /usr/bin/tmux -S /run/user/1100/agent-k8s.review.sock attach" "$LOG"
    run "$O" shell
    grep -qx "$M $T/nd/systemd-run --user --pty --wait --collect --quiet --same-dir -- /bin/bash -l" "$LOG"
    if grep -q -- "-M agent@" "$LOG"; then echo "should not match (line 247)"; return 1; fi                       # never systemctl -M (needs manage-units)
}

@test "agent reload: every agent's manager reloads, agent-web's and agent-guard's workers start; an agent not provisioned is skipped" {
    op_stubs
    echo "agent-web:x:1101:1101::/home/agent-web:/bin/bash" >> "$PASSWD"
    run "$O" reload
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    for u in agent agent-web; do
        grep -E "machinectl shell -q .* $u@ .*daemon-reload" "$LOG" >/dev/null || { echo "no reload for $u"; return 1; }
    done
    grep -E "machinectl shell -q .* agent-web@ .*start agent-web-worker.path agent-web-worker.timer" "$LOG" >/dev/null
    if grep -qE " agent@ .*start " "$LOG"; then echo "started units in agent's manager"; return 1; fi
    if grep -q "agent-guard@" "$LOG"; then echo "agent-guard isn't provisioned"; return 1; fi
}

# halt/resume: sudo runs the root script for real (as the test user), with systemctl, loginctl, ps
# and airlock-envoy's tools stubs that log (its --stop/--start make and remove the stopped file);
# MASKED makes systemctl is-enabled answer "masked" for agent's manager alone.
halt_stubs() {
    op_stubs
    echo "agent:x:1100:1100::/home/agent:/bin/bash" >> "$PASSWD"
    echo "agent-web:x:1101:1101::/home/agent-web:/bin/bash" >> "$PASSWD"
    cat > "$T/bin/sudo" <<'S'
#!/bin/bash
[ "$1" = -- ] && shift
echo "sudo $1 $2" >> "$LOG"; echo "SUDO-RAN"
exec "$@"
S
    cat > "$T/bin/systemctl" <<'S'
#!/bin/bash
case "$1" in is-enabled) [ -n "${MASKED:-}" ] && [ "$2" = user@1100.service ] && echo masked; exit 0 ;; esac
echo "systemctl $*" >> "$LOG"
[ "$1" != "${FAIL_SYSTEMCTL:-}" ]
S
    printf '#!/bin/bash\necho "ps $*" >> "$LOG"\nprintf "agent 4242 01:00 claude \\033]0;evil\\007--x\\n"\n' > "$T/bin/ps"
    mkdir -p "$T/ophome"
    export HOME="$T/ophome" AGENTS_ENVOY_SBIN="$T/envoy" AGENTS_HALT_MARK="$T/halted" AGENTS_ENVOY_STOPPED="$T/envoy-stopped" XDG_STATE_HOME="$T/state" \
        AGENTS_ENVOY_CRED_STATE="$T/credstate"
    printf 'unlocked until x\ndeadline %s\n' "$(( $(date +%s) + 7200 ))" > "$T/credstate"
    mkdir -p "$T/envoy"
    cat > "$T/envoy/airlock-envoy-apply" <<'S'
#!/bin/bash
echo "airlock-envoy-apply $*" >> "$LOG"
# as the real one: --stop writes an empty file; a --start that doesn't finish writes it again
case "$1" in
    --stop) /usr/bin/install -m 0644 /dev/null "$AGENTS_ENVOY_STOPPED" ;;
    --start) rm -f "$AGENTS_ENVOY_STOPPED"; [ -z "${START_UNDO:-}" ] || { /usr/bin/install -m 0644 /dev/null "$AGENTS_ENVOY_STOPPED"; exit 1; } ;;
esac
S
    printf '#!/bin/bash\necho "airlock-envoy-cred $*" >> "$LOG"\n' > "$T/envoy/airlock-envoy-cred"
    chmod +x "$T/bin/sudo" "$T/bin/systemctl" "$T/bin/ps" "$T/envoy/"*
}

@test "agent halt: kills each provisioned agent user's processes first, says why before sudo, then masks, kills, cuts Envoy and stops" {
    halt_stubs
    run "$O" halt
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # phase 1, no sudo: each user kills what it may signal (agent-guard isn't provisioned)
    grep -qx "machinectl shell -q agent@ $T/nd/sh -c kill -KILL -1" "$LOG"
    grep -qx "machinectl shell -q agent-web@ $T/nd/sh -c kill -KILL -1" "$LOG"
    [[ "$output" == *"agent: kill sent"*"agent-web: kill sent"* ]]
    if grep -q "agent-guard@" "$LOG"; then echo "agent-guard isn't provisioned"; return 1; fi
    [ "$(grep -n 'kill -KILL' "$LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n '^sudo' "$LOG" | cut -d: -f1)" ]
    # the reason comes before the prompt, and names what root will do
    before="${output%%SUDO-RAN*}"
    [[ "$before" == *"next, as root"*"mask, kill and"*"agent agent-web"*"airlock-envoy's egress"*"sudo asks for your password"* ]] || { echo "$before"; return 1; }
    # one sudo; root's steps in order: mask, kill (manager and sessions), Envoy, then the slow stop
    [ "$(grep -c '^sudo' "$LOG")" = 1 ]
    grep -vE '^(machinectl|ps|sudo) ' "$LOG" > "$T/root-steps"
    diff - "$T/root-steps" <<E
systemctl mask user@1100.service user@1101.service
systemctl kill -s KILL user@1100.service user@1101.service
loginctl terminate-user 1100
loginctl terminate-user 1101
airlock-envoy-apply --stop
airlock-envoy-cred lock
systemctl stop user@1100.service user@1101.service
E
    # the mint timer keeps running: it retries the revokes the lock started
    if grep -q 'airlock-envoy-mint' "$LOG"; then echo "touched the mint timer"; return 1; fi
    grep -q '^halted ' "$T/halted" && grep -q "^envoy-stopped-by-halt " "$T/halted"
    # the record: what ran, cleaned (an agent's command line can carry escapes), kept in a log
    [[ "$output" == *"agent 4242 01:00 claude"* && "$output" != *$'\033'* ]]
    grep -q 'agent 4242' "$T"/state/airlock-agents/halt-*.log
    grep -qx "ps -o user=,pid=,etime=,args= -u 1100,1101" "$LOG"
}

@test "agent halt without airlock-envoy: the agents only, and the message says so" {
    halt_stubs
    AGENTS_ENVOY_SBIN="$T/none" run "$O" halt
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qx "systemctl mask user@1100.service user@1101.service" "$LOG"
    if grep -q "airlock-envoy" "$LOG" || [[ "$output" == *"airlock-envoy's egress"* ]]; then echo "envoy steps without envoy"; return 1; fi
}

@test "agent halt: missing execute-only copies don't stop it (root still masks, kills and stops); a failed root step fails it, every step running" {
    halt_stubs
    rm -f "$STATS"/*
    run "$O" halt
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    if grep -q 'kill -KILL' "$LOG"; then echo "ran the readable originals"; return 1; fi
    [[ "$output" == *"left to root's kill"* ]]
    grep -qx "systemctl stop user@1100.service user@1101.service" "$LOG"
    rm -f "$T/halted"; : > "$LOG"
    FAIL_SYSTEMCTL=mask run "$O" halt
    [ "$status" -ne 0 ] && [[ "$output" == *"a root step failed"* ]]
    grep -qx "airlock-envoy-apply --stop" "$LOG" && grep -qx "systemctl stop user@1100.service user@1101.service" "$LOG"
    # Envoy's steps failing fail halt too
    for c in airlock-envoy-apply airlock-envoy-cred; do
        cp "$T/envoy/$c" "$T/$c.ok"; printf '#!/bin/bash\necho "%s $*" >> "$LOG"; exit 1\n' "$c" > "$T/envoy/$c"
        rm -f "$T/halted"; run "$O" halt
        [ "$status" -ne 0 ] || { echo "$c failing didn't fail halt"; return 1; }
        mv "$T/$c.ok" "$T/envoy/$c"
    done
    run "$O" halt now; [ "$status" -ne 0 ] && [[ "$output" == *"usage"* ]]
}

@test "agent resume: Envoy back first, then the managers unmasked and started, then the unlock" {
    halt_stubs
    run "$O" halt; : > "$LOG"
    run "$O" resume
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    before="${output%%SUDO-RAN*}"
    [[ "$before" == *"unmask and start"*"agent agent-web"*"lift airlock-envoy's kill switch"*"sudo asks for your password"* ]] || { echo "$before"; return 1; }
    [ "$(grep -n 'airlock-envoy-apply --start' "$LOG" | cut -d: -f1)" -lt "$(grep -n 'systemctl start user@' "$LOG" | cut -d: -f1)" ]
    grep -qx "systemctl unmask user@1100.service user@1101.service" "$LOG"
    grep -qx "systemctl start user@1100.service user@1101.service" "$LOG"
    [ "$(tail -1 "$LOG")" = "airlock-envoy-cred unlock" ]
    [ ! -e "$T/halted" ] && [ ! -e "$T/envoy-stopped" ]
}

@test "agent resume lifts only a kill switch a halt turned on: not one on before, not with no halt, not twice" {
    halt_stubs
    # on before halt (the operator's): halt doesn't claim it, resume leaves it on
    : > "$T/envoy-stopped"; run "$O" halt; : > "$LOG"
    if grep -q envoy-stopped-by-halt "$T/halted"; then echo "claimed the operator's switch"; return 1; fi
    run "$O" resume
    if grep -q 'airlock-envoy-apply --start' "$LOG"; then echo "lifted a kill switch halt didn't set"; return 1; fi
    [[ "${output%%SUDO-RAN*}" == *"no kill switch of a halt to lift"* ]]
    # halt twice: one record, lifted once
    rm -f "$T/envoy-stopped" "$T/halted"
    run "$O" halt; run "$O" halt; : > "$LOG"
    [ "$(grep -c "^envoy-stopped-by-halt " "$T/halted")" = 1 ]
    run "$O" resume
    grep -qx "airlock-envoy-apply --start" "$LOG"
    # no halt recorded (a kill switch set by hand): left alone
    : > "$T/envoy-stopped"; : > "$LOG"
    run "$O" resume
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    if grep -q 'airlock-envoy-apply --start' "$LOG"; then echo "lifted a hand-set kill switch"; return 1; fi
}

@test "agent resume: a failed root step keeps the halt record; a retry doesn't redo Envoy; a halt after a partial resume stops it again, and the next resume lifts it" {
    halt_stubs
    run "$O" halt
    FAIL_SYSTEMCTL=start run "$O" resume
    [ "$status" -ne 0 ] && [ -e "$T/halted" ] && ! grep -q envoy-stopped-by-halt "$T/halted" && [ ! -e "$T/envoy-stopped" ]
    : > "$T/envoy-stopped"; : > "$LOG"   # the operator turned it on by hand meanwhile
    run "$O" resume
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    if grep -q 'airlock-envoy-apply --start' "$LOG"; then echo "a retry lifted the switch again"; return 1; fi
    # partial resume, then halt again, then resume: Envoy back
    rm -f "$T/envoy-stopped" "$T/halted"
    run "$O" halt; FAIL_SYSTEMCTL=start run "$O" resume
    run "$O" halt; [ -e "$T/envoy-stopped" ] && grep -q "^envoy-stopped-by-halt " "$T/halted"
    : > "$LOG"; run "$O" resume
    [ "$status" -eq 0 ] && grep -qx "airlock-envoy-apply --start" "$LOG" && [ ! -e "$T/envoy-stopped" ] || { echo "$output"; return 1; }
    FAIL_SYSTEMCTL=unmask run "$O" resume; [ "$status" -ne 0 ]
}

@test "each airlock-envoy step needs only its own tool: the kill switch -apply, the lock and unlock -cred" {
    halt_stubs
    mv "$T/envoy/airlock-envoy-apply" "$T/apply.away"
    run "$O" halt
    grep -qx "airlock-envoy-cred lock" "$LOG" && ! grep -q "airlock-envoy-apply" "$LOG"
    [[ "${output%%SUDO-RAN*}" == *"lock airlock-envoy's credentials"* && "${output%%SUDO-RAN*}" != *"egress"* ]]
    : > "$LOG"; run "$O" resume; grep -qx "airlock-envoy-cred unlock" "$LOG"
    mv "$T/apply.away" "$T/envoy/airlock-envoy-apply"; rm -f "$T/halted" "$T/envoy-stopped"; : > "$LOG"
    rm "$T/envoy/airlock-envoy-cred"
    run "$O" halt
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qx "airlock-envoy-apply --stop" "$LOG" && ! grep -q "airlock-envoy-cred" "$LOG"
    [[ "${output%%SUDO-RAN*}" == *"cut airlock-envoy's egress"* && "${output%%SUDO-RAN*}" != *"lock airlock-envoy's credentials"* ]]
    : > "$LOG"; run "$O" resume
    grep -qx "airlock-envoy-apply --start" "$LOG" && ! grep -q "airlock-envoy-cred" "$LOG"
}

@test "resume: a kill switch rewritten by hand since the halt is the operator's; one --stop turned on but failed is the halt's; a tool gone keeps the record" {
    halt_stubs
    # by hand during the halt: --start, then --stop (a new file): left on
    run "$O" halt; sleep 0.05
    "$T/envoy/airlock-envoy-apply" --start; sleep 0.05; "$T/envoy/airlock-envoy-apply" --stop; : > "$LOG"
    run "$O" resume
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    if grep -q 'airlock-envoy-apply --start' "$LOG"; then echo "lifted the operator's switch"; return 1; fi
    [[ "$output" == *"rewritten since the halt"* ]]
    # --stop that writes the switch and then fails: halt fails, but the switch is recorded as its own
    rm -f "$T/envoy-stopped" "$T/halted"
    cp "$T/envoy/airlock-envoy-apply" "$T/apply.ok"
    printf '#!/bin/bash\necho "airlock-envoy-apply $*" >> "$LOG"\n[ "$1" = --stop ] && { : > "$AGENTS_ENVOY_STOPPED"; exit 1; }\nexit 0\n' > "$T/envoy/airlock-envoy-apply"
    run "$O" halt; [ "$status" -ne 0 ]
    grep -q "^envoy-stopped-by-halt " "$T/halted"
    mv "$T/apply.ok" "$T/envoy/airlock-envoy-apply"; : > "$LOG"
    run "$O" resume; grep -qx "airlock-envoy-apply --start" "$LOG" || { echo "$output"; return 1; }
    # the tool gone at resume: said, and the record kept (resume fails)
    run "$O" halt; mv "$T/envoy/airlock-envoy-apply" "$T/apply.away"
    run "$O" resume
    [ "$status" -ne 0 ] && grep -q "^envoy-stopped-by-halt " "$T/halted" && [[ "$output" == *"airlock-envoy-apply is gone"* ]] || { echo "$output"; return 1; }
    mv "$T/apply.away" "$T/envoy/airlock-envoy-apply"; : > "$LOG"
    run "$O" resume; [ "$status" -eq 0 ] && grep -qx "airlock-envoy-apply --start" "$LOG"
}

@test "resume unlocks only what a halt locked: unlocked before it, locked by it" {
    halt_stubs
    run "$O" resume
    if grep -q 'airlock-envoy-cred unlock' "$LOG"; then echo "unlocked with no halt"; return 1; fi
    run "$O" halt; : > "$LOG"; run "$O" resume
    grep -qx 'airlock-envoy-cred unlock' "$LOG"
    # locked before the halt (by the operator, or expired), in the real format (a deadline line
    # may linger): stays locked
    printf 'locked\ndeadline %s\n' "$(( $(date +%s) + 7200 ))" > "$T/credstate"; run "$O" halt; : > "$LOG"; run "$O" resume
    if grep -q 'airlock-envoy-cred unlock' "$LOG"; then echo "unlocked what the operator had locked"; return 1; fi
    # the cred tool gone at resume: said
    printf 'unlocked until x\ndeadline %s\n' "$(( $(date +%s) + 7200 ))" > "$T/credstate"; run "$O" halt; mv "$T/envoy/airlock-envoy-cred" "$T/cred.away"
    run "$O" resume; [[ "$output" == *"airlock-envoy-cred is gone: not unlocked"* ]]
}

@test "resume: a --start that undoes itself writes the switch again: claimed again, the retry lifts it; a halt's switch gone with its tool lets resume go on" {
    halt_stubs
    run "$O" halt
    : > "$LOG"; START_UNDO=1 run "$O" resume
    [ "$status" -ne 0 ] && [ -e "$T/envoy-stopped" ] && grep -q "^envoy-stopped-by-halt " "$T/halted"
    if grep -q 'systemctl unmask' "$LOG"; then echo "agents back while Envoy's step failed"; return 1; fi
    [[ "$output" == *"stay halted"* ]]
    : > "$LOG"; run "$O" resume
    [ "$status" -eq 0 ] && grep -qx "airlock-envoy-apply --start" "$LOG" && [ ! -e "$T/envoy-stopped" ] || { echo "$output"; return 1; }
    # the tool and the switch both gone (uninstalled): nothing left to lift, resume goes on
    run "$O" halt; rm -f "$T/envoy-stopped"; mv "$T/envoy/airlock-envoy-apply" "$T/apply.away"
    run "$O" resume
    [ "$status" -eq 0 ] && [ ! -e "$T/halted" ] || { echo "$output"; return 1; }
}

@test "the preview before sudo never reads Envoy's config directory (the operator can't); root decides and says so" {
    halt_stubs
    run "$O" halt
    chmod 000 "$T/envoy-stopped"
    run "$O" resume
    chmod 644 "$T/envoy-stopped" 2>/dev/null || true
    [[ "${output%%SUDO-RAN*}" == *"lift airlock-envoy's kill switch if it is still the one the halt turned on"* ]] || { echo "$output"; return 1; }
}

@test "halt with airlock-envoy installed but not set up (no config directory): its switch step is skipped, halt succeeds" {
    halt_stubs
    export AGENTS_ENVOY_STOPPED="$T/no-envoy-etc/stopped"
    run "$O" halt
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    if grep -q 'airlock-envoy-apply --stop' "$LOG"; then echo "ran --stop with no config"; return 1; fi
    [[ "$output" == *"no config directory"* ]]
}

@test "halt with the state directory unwritable (a full disk): no record, no mark, but the kill and root's steps all run" {
    halt_stubs
    mkdir -p "$T/ro"; chmod 555 "$T/ro"; export XDG_STATE_HOME="$T/ro/state" HOME="$T/ro/home"
    run "$O" halt
    chmod 755 "$T/ro"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -q 'kill -KILL -1' "$LOG" && grep -qx "systemctl mask user@1100.service user@1101.service" "$LOG" && grep -qx "airlock-envoy-apply --stop" "$LOG"
    [[ "$output" == *"no record"* ]]
}

@test "root's steps say what failed: a lock that fails is not reported as locked" {
    halt_stubs
    printf '#!/bin/bash\necho "airlock-envoy-cred $*" >> "$LOG"; [ "$1" != lock ]\n' > "$T/envoy/airlock-envoy-cred"
    run "$O" halt
    [ "$status" -ne 0 ] && [[ "$output" == *"FAILED: $T/envoy/airlock-envoy-cred lock"* && "$output" != *"credentials locked"* ]] || { echo "$output"; return 1; }
}

@test "a halt cut short between its --stop and the nonce: the switch is still the halt's (halt again claims it, resume lifts it)" {
    halt_stubs
    printf 'halted x\nenvoy-claim-pending\n' > "$T/halted"; /usr/bin/install -m 0644 /dev/null "$T/envoy-stopped"
    run "$O" resume
    [ "$status" -eq 0 ] && grep -qx "airlock-envoy-apply --start" "$LOG" || { echo "$output"; return 1; }
    printf 'halted x\nenvoy-claim-pending\n' > "$T/halted"; /usr/bin/install -m 0644 /dev/null "$T/envoy-stopped"
    run "$O" halt
    grep -q "^envoy-stopped-by-halt " "$T/halted" && ! grep -q envoy-claim-pending "$T/halted"
}

@test "a halt killed right after its --stop (root's script dies): the next halt claims the switch, resume lifts it; an interrupt goes on with the next step" {
    halt_stubs
    cp "$T/envoy/airlock-envoy-apply" "$T/apply.ok"
    printf '#!/bin/bash\necho "airlock-envoy-apply $*" >> "$LOG"\n[ "$1" = --stop ] && { /usr/bin/install -m 0644 /dev/null "$AGENTS_ENVOY_STOPPED"; kill -KILL $PPID; }\nexit 0\n' > "$T/envoy/airlock-envoy-apply"
    run "$O" halt; [ "$status" -ne 0 ]
    grep -qx envoy-claim-pending "$T/halted" && [ -e "$T/envoy-stopped" ]
    mv "$T/apply.ok" "$T/envoy/airlock-envoy-apply"
    run "$O" halt; [ "$status" -eq 0 ] && grep -q "^envoy-stopped-by-halt " "$T/halted" || { echo "$output"; return 1; }
    : > "$LOG"; run "$O" resume
    [ "$status" -eq 0 ] && grep -qx "airlock-envoy-apply --start" "$LOG" || { echo "$output"; return 1; }
    # an INT to root's script while a step runs: the later steps still run
    printf '#!/bin/bash\necho "airlock-envoy-apply $*" >> "$LOG"\n[ "$1" = --stop ] && { /usr/bin/install -m 0644 /dev/null "$AGENTS_ENVOY_STOPPED"; kill -INT $PPID; sleep 0.2; }\nexit 0\n' > "$T/envoy/airlock-envoy-apply"
    : > "$LOG"; run "$O" halt
    [ "$status" -ne 0 ] && [[ "$output" == *"interrupted: going on"* ]] && grep -qx "airlock-envoy-cred lock" "$LOG" && grep -qx "systemctl stop user@1100.service user@1101.service" "$LOG" || { echo "$output"; cat "$LOG"; return 1; }
}

@test "a HUP to root's halt script cuts no step; a nonce that can't be written keeps the claim for the next halt; HOME unset still halts" {
    halt_stubs
    cp "$T/envoy/airlock-envoy-apply" "$T/apply.ok"
    printf '#!/bin/bash\necho "airlock-envoy-apply $*" >> "$LOG"\n[ "$1" = --stop ] && { /usr/bin/install -m 0644 /dev/null "$AGENTS_ENVOY_STOPPED"; kill -HUP $PPID; sleep 0.2; }\nexit 0\n' > "$T/envoy/airlock-envoy-apply"
    run "$O" halt
    [ "$status" -eq 0 ] && grep -qx "airlock-envoy-cred lock" "$LOG" && grep -qx "systemctl stop user@1100.service user@1101.service" "$LOG" && grep -q "^envoy-stopped-by-halt " "$T/halted" || { echo "$output"; return 1; }
    # the nonce write fails (the switch file read-only to the stub's root): the claim stays
    rm -f "$T/halted" "$T/envoy-stopped"
    printf '#!/bin/bash\necho "airlock-envoy-apply $*" >> "$LOG"\n[ "$1" = --stop ] && /usr/bin/install -m 0444 /dev/null "$AGENTS_ENVOY_STOPPED"\nexit 0\n' > "$T/envoy/airlock-envoy-apply"
    run "$O" halt
    [ "$status" -ne 0 ] && grep -qx envoy-claim-pending "$T/halted" && ! grep -q "^envoy-stopped-by-halt " "$T/halted" || { echo "$output"; cat "$T/halted"; return 1; }
    mv "$T/apply.ok" "$T/envoy/airlock-envoy-apply"; chmod 644 "$T/envoy-stopped"
    run "$O" halt; grep -q "^envoy-stopped-by-halt " "$T/halted"
    : > "$LOG"; run "$O" resume; grep -qx "airlock-envoy-apply --start" "$LOG" || { echo "$output"; return 1; }
    # HOME unset: the kill and root's steps still run
    : > "$LOG"; env -u HOME "$O" halt >/dev/null 2>&1 || true
    grep -q 'kill -KILL -1' "$LOG" && grep -qx "systemctl mask user@1100.service user@1101.service" "$LOG"
}

@test "resume: an empty nonce for a halt cut short is a failure, and the agents stay halted" {
    halt_stubs
    printf 'halted x\nenvoy-claim-pending\n' > "$T/halted"; /usr/bin/install -m 0644 /dev/null "$T/envoy-stopped"
    mkdir -p "$T/notr"; printf '#!/bin/sh\ncat >/dev/null\n' > "$T/notr/tr"; printf '#!/bin/sh\nexit 1\n' > "$T/notr/od"; chmod +x "$T/notr/"*
    PATH="$T/notr:$PATH" run "$O" resume
    [ "$status" -ne 0 ] && [[ "$output" == *"could not record the switch"* ]] || { echo "$output"; return 1; }
    if grep -q 'systemctl unmask' "$LOG"; then echo "agents back with no record"; return 1; fi
    grep -qx envoy-claim-pending "$T/halted"
}

@test "resume: a failed --start whose re-claim can't write the switch keeps the claim, and the next resume lifts it" {
    halt_stubs
    run "$O" halt
    cp "$T/envoy/airlock-envoy-apply" "$T/apply.ok"
    printf '#!/bin/bash\necho "airlock-envoy-apply $*" >> "$LOG"\n[ "$1" = --start ] && { rm -f "$AGENTS_ENVOY_STOPPED"; /usr/bin/install -m 0444 /dev/null "$AGENTS_ENVOY_STOPPED"; exit 1; }\nexit 0\n' > "$T/envoy/airlock-envoy-apply"
    run "$O" resume
    [ "$status" -ne 0 ] && grep -qx envoy-claim-pending "$T/halted" || { echo "$output"; cat "$T/halted"; return 1; }
    mv "$T/apply.ok" "$T/envoy/airlock-envoy-apply"; chmod 644 "$T/envoy-stopped"; : > "$LOG"
    run "$O" resume
    [ "$status" -eq 0 ] && grep -qx "airlock-envoy-apply --start" "$LOG" && [ ! -e "$T/envoy-stopped" ] && [ ! -e "$T/halted" ] || { echo "$output"; return 1; }
}

@test "apply: a masked slice is not the halt's (it says to move it away)" {
    halt_stubs
    run "$P" --confirm
    ln -s /dev/null "$R/etc/systemd/system/user-1100.slice"
    run "$P" --confirm
    [ "$status" -ne 0 ] && [[ "$output" == *"replaces the system's unit"* && "$output" != *"masked by"* ]] || { echo "$output"; return 1; }
}

@test "halt: the mark is readable whatever the umask; uid 0 refused" {
    halt_stubs
    (umask 077; run "$O" halt; exit "$status")
    [ "$(stat -c %a "$T/halted")" = 644 ]
    : > "$LOG"; rm -f "$T/halted"
    echo "agent-guard:x:0:0::/home/agent-guard:/bin/bash" >> "$PASSWD"
    run "$O" halt
    [ "$status" -ne 0 ] && ! grep -q '^systemctl mask' "$LOG"
}

@test "halting: from the kill until root's mask (a refused sudo included) the operator's commands refuse; resume clears it" {
    halt_stubs
    printf '#!/bin/bash\n[ "$1" = -- ] && shift\necho "sudo $1 $2" >> "$LOG"; exit 1\n' > "$T/bin/sudo"
    run "$O" halt
    [ "$status" -ne 0 ] && [[ "$output" == *"sudo was refused"* ]]
    : > "$LOG"
    run "$O" ls; [ "$status" -ne 0 ] && [[ "$output" == *"halted"* ]]
    run "$O" _complete sessions; [ -z "$output" ]
    if grep -q '^machinectl' "$LOG"; then echo "reached an agent while halting"; return 1; fi
    printf '#!/bin/bash\n[ "$1" = -- ] && shift\necho "sudo $1 $2" >> "$LOG"; echo SUDO-RAN\nexec "$@"\n' > "$T/bin/sudo"
    run "$O" halt; run "$O" resume
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run "$O" ls; [ "$status" -eq 0 ]
}

@test "apply while halted: says to resume, rather than to move the mask away" {
    halt_stubs
    run "$P" --confirm
    ln -s /dev/null "$R/etc/systemd/system/user@1100.service"
    run "$P" --confirm
    [ "$status" -ne 0 ] && [[ "$output" == *"masked by agent halt: agent resume first"* ]] || { echo "$output"; return 1; }
}

@test "while halted (agent's manager masked), the other commands refuse and point at resume; completion is silent; halt, resume and help still run" {
    halt_stubs
    for c in ls "new p" "attach p" update reload "web ls"; do
        MASKED=1 run "$O" $c
        [ "$status" -ne 0 ] && [[ "$output" == *"halted"*"agent resume first"* ]] || { echo "$c: $output"; return 1; }
    done
    MASKED=1 run "$O" _complete sessions; [ "$status" -eq 0 ] && [ -z "$output" ]
    # the halting mark (before root's mask) is seen by completion's bare environment too
    bare() { env -i PATH="$PATH" HOME="$HOME" AIRLOCK_AGENTS_ENV="$AIRLOCK_AGENTS_ENV" AGENTS_NODUMP_DIR="$AGENTS_NODUMP_DIR" LOG="$LOG" STATS="$STATS" PASSWD="$PASSWD" GROUP="$GROUP" "$O" _complete sessions >/dev/null 2>&1 || true; }
    : > "$LOG"; bare; grep -q '^machinectl' "$LOG" || { echo "control: the bare environment never reached machinectl"; return 1; }
    run "$O" halt; : > "$LOG"; bare
    if grep -q '^machinectl' "$LOG"; then echo "completion reached an agent while halting"; return 1; fi
    MASKED=1 run "$O" help; [ "$status" -eq 0 ]
    if grep -q '^machinectl' "$LOG"; then echo "a refused command reached an agent"; return 1; fi
    MASKED=1 run "$O" resume; [ "$status" -eq 0 ]
}

@test "the root scripts refuse a uid that isn't a number" {
    halt_stubs
    echo "agent-guard:x:1x02:1102::/home/agent-guard:/bin/bash" >> "$PASSWD"
    run "$O" halt
    [ "$status" -ne 0 ]
    if grep -q '^systemctl mask' "$LOG"; then echo "masked with a bad uid"; return 1; fi
}

@test "agent new/restart and web new/restart/attach reload a manager that hasn't read a changed unit first; attach and a current one don't" {
    op_stubs
    reloads() { octl_call | grep -cx daemon-reload || true; }
    for c in "new k8s" "restart k8s.main"; do
        : > "$LOG"; UNREAD=agent REMOTE_OUT="agent-session@k8s.main.service loaded active running x" run "$O" $c
        [ "$status" -eq 0 ] || { echo "$c: $output"; return 1; }
        [ "$(reloads)" = 1 ] || { echo "$c: no reload"; cat "$LOG"; return 1; }
        # the reload comes before the start
        octl_call | grep -vx 'show -p NeedDaemonReload --value agent-session@k8s.main.service' | head -1 | grep -qx daemon-reload || { echo "$c: order"; octl_call; return 1; }
        [[ "$output" == *"agent-session@k8s.main.service changed on disk since agent's manager read it: reloading first"* ]]
        : > "$LOG"; REMOTE_OUT="agent-session@k8s.main.service loaded active running x" run "$O" $c
        [ "$status" -eq 0 ] && [ "$(reloads)" = 0 ] || { echo "$c: reloaded a current manager"; return 1; }
    done
    # agent-web's manager, never agent's
    : > "$LOG"; UNREAD=agent-web REMOTE_OUT="agent-web-session@main.service loaded active running x" run "$O" web restart
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qE "agent-web@ .*daemon-reload" "$LOG"
    ! grep -qE " agent@ .*daemon-reload" "$LOG" || { echo "reloaded agent's manager"; return 1; }
    # and before the start
    for c in "web new research2" "web"; do
        : > "$LOG"; UNREAD=agent-web REMOTE_OUT="" run "$O" $c
        first="$(grep -nE "agent-web@ .*(daemon-reload|start agent-web-session@)" "$LOG" | head -1)"
        [[ "$first" == *daemon-reload* ]] || { echo "$c: no reload before the start"; cat "$LOG"; return 1; }
    done
    # attach starts nothing: no check, no reload
    : > "$LOG"; UNREAD=agent run "$O" attach k8s.main
    ! grep -q NeedDaemonReload "$LOG" || { echo "attach checked the unit"; return 1; }
    # a failed reload stops it before the start
    : > "$LOG"; UNREAD=agent REMOTE_RC=1 run "$O" new k8s
    [ "$status" -ne 0 ] && [[ "$output" == *"the reload failed"* ]] && ! octl_call | grep -q '^enable' || { echo "$output"; return 1; }
}

@test "apply enables the queue workers' path and timer units globally, and says so once they are" {
    run "$P" --confirm
    grep -qx 'systemctl --global enable agent-web-worker.path agent-web-worker.timer agent-guard-worker.path agent-guard-worker.timer' "$LOG"
    for u in agent-web agent-guard; do
        for k in service path timer; do
            grep -qx "ConditionUser=$u" "$RENDER/etc/systemd/user/$u-worker.$k" || { echo "$u-worker.$k: no ConditionUser"; return 1; }
        done
        grep -qx "ExecStart=/usr/local/lib/airlock-agents/${u#agent-}-worker" "$RENDER/etc/systemd/user/$u-worker.service"
        [ -x "$REPO/agents/lib/${u#agent-}-worker" ]
    done
}

@test "a bare project means its one session; with several or none, agent refuses and names them, and touches nothing" {
    op_stubs
    two=$'agent-session@agent.main.service loaded active running x\nagent-session@agent.review.service loaded active running x'
    for c in restart stop attach; do
        : > "$LOG"
        REMOTE_OUT="$two" run "$O" $c agent
        [ "$status" -ne 0 ] || { echo "$c went ahead: $output"; return 1; }
        [[ "$output" == *"agent has several sessions (agent.main agent.review): say which, e.g. agent $c agent.main"* ]]
        ! octl_call | grep -qvE '^list-units ' || { echo "$c ran: $(octl_call)"; return 1; }
        if grep -q "tmux" "$LOG"; then echo "should not match (line 259)"; return 1; fi
        : > "$LOG"
        REMOTE_OUT="" run "$O" $c agent
        [ "$status" -ne 0 ]; [[ "$output" == *"no session for agent"* ]]
        if octl_call | grep -qvE '^list-units '; then echo "should not match (line 263)"; return 1; fi
    done
    # the list is matched on the project exactly: agent-web's sessions are not agent's
    : > "$LOG"
    REMOTE_OUT=$'agent-session@agent.main.service loaded active running x' run "$O" restart agent
    [ "$status" -eq 0 ]; octl_call | grep -qx "restart agent-session@agent.main.service"
    octl_call | grep -qxF 'list-units --all --full --no-legend --plain agent-session@agent.*.service'
    # a full name never asks the list
    : > "$LOG"
    REMOTE_OUT="$two" run "$O" restart agent.review
    [ "$status" -eq 0 ]; octl_call | grep -qx "restart agent-session@agent.review.service"
    if octl_call | grep -q '^list-units'; then echo "should not match (line 274)"; return 1; fi
    # a stopped session (gone from systemd's list) still counts, through its id file on agent's side
    hh="$T/agenthome"; mkdir -p "$hh/.local/state/agent-session"
    : > "$hh/.local/state/agent-session/agent.main.id"; : > "$hh/.local/state/agent-session/agent.review.id"
    : > "$hh/.local/state/agent-session/agent-web.x.id"                      # another project: not agent's
    : > "$LOG"
    HOME="$hh" REMOTE_OUT=$'agent-session@agent.review.service loaded active running x' run "$O" restart agent
    [ "$status" -ne 0 ]; [[ "$output" == *"agent has several sessions (agent.main agent.review)"* ]]
    if octl_call | grep -q '^restart'; then echo "should not match (line 282)"; return 1; fi
    : > "$LOG"
    rm "$hh/.local/state/agent-session/agent.main.id"
    HOME="$hh" REMOTE_OUT=$'agent-session@agent.review.service loaded active running x' run "$O" restart agent
    [ "$status" -eq 0 ]; octl_call | grep -qx "restart agent-session@agent.review.service"
    # a trailing dot or a wildcard is no name
    for bad in "agent." "agen*" "a?ent"; do
        : > "$LOG"; REMOTE_OUT="$two" run "$O" restart "$bad"
        [ "$status" -ne 0 ] && ! octl_call | grep -q '^restart' || { echo "accepted: $bad"; return 1; }
    done
    # a hostile unit name in the list is refused like a typed one
    : > "$LOG"
    REMOTE_OUT=$'agent-session@agent.x;rm.service loaded active running x' run "$O" stop agent
    [ "$status" -ne 0 ]; ! octl_call | grep -q '^disable'
}

@test "agent refuses session names that could reach another unit or path" {
    op_stubs
    for bad in "../x" "a/b" "x;y" ".hidden" "a b" "x.y.z"; do
        run "$O" new "$bad"
        [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }
    done
    [ ! -s "$LOG" ]
}

@test "B1: root touches only the home's top; the starter dirs are made as agent (a planted link is agent's own problem)" {
    mkdir -p "$T/victim"; chmod 755 "$T/victim"
    ln -s "$T/victim" "$R/home/agent/.config"
    run "$P" --confirm
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qx "chown -h 1100:1100 $R/home/agent" "$LOG"
    grep -q "setpriv --reuid=1100 --regid=1100 --clear-groups $R/usr/local/lib/airlock-agents/bin/install -d -m 0700 $R/home/agent/.config" "$LOG"
    # One install inside the home, and it came through setpriv (the stub logs both lines).
    [ "$(grep -c "^setpriv .*/install -d -m 0700 $R/home/agent/.config" "$LOG")" = 1 ]
    [ "$(grep -c "^install -d -m 0700 $R/home/agent/.config" "$LOG")" = 1 ]
    if grep -q "^chown .*$R/home/agent/" "$LOG"; then echo "should not match (line 317)"; return 1; fi           # root's chown is the top only
}

@test "S2: an agent with the wrong uid or gid is refused, not accepted" {
    echo "agent:x:1001:1001::/home/agent:/bin/bash" > "$PASSWD"
    run "$P" --confirm
    [ "$status" -eq 1 ]; [[ "$output" == *"user agent exists as uid:gid 1001:1001, not 1100:1100"* ]]
    : > "$PASSWD"; echo "agent:x:4242:" > "$GROUP"
    run "$P" --confirm
    [ "$status" -eq 1 ]; [[ "$output" == *"group agent exists as gid 4242, not 1100"* ]]
}

@test "S1: useradd adds no subids of its own; an existing agent range that isn't exactly ours is refused" {
    printf 'alice:100000:65536\nagent:165536:65536\n' > "$R/etc/subuid"
    run "$P" --confirm
    [ "$status" -eq 1 ]; [[ "$output" == *"/etc/subuid has 'agent:165536:65536 ', not exactly agent:1100000:65536"* ]]
}

@test "S4: a failed mkfs leaves no image for a later run to accept" {
    printf '#!/bin/bash\necho "mkfs.xfs $*" >> "$LOG"; exit 1\n' > "$T/bin/mkfs.xfs"; chmod +x "$T/bin/mkfs.xfs"
    run "$P" --confirm
    [ "$status" -ne 0 ]
    [ ! -e "$R/var/lib/agent/home.img" ]
}

@test "S5: a ceiling the disk can't back is refused" {
    site_file 900000T 1G 1G
    run "$P" --confirm
    [ "$status" -eq 1 ]; [[ "$output" == *"less than the ceilings 900000T (agent)"* ]]
    [ ! -e "$R/var/lib/agent/home.img" ]
}

@test "agent carries the remote exit status back, strips CRs, hides the marker" {
    op_stubs
    run "$O" new k8s
    [ "$status" -eq 0 ]; [[ "$output" == *"remote output"* && "$output" != *$'\r'* && "$output" != *"agent-rc="* ]]
    REMOTE_RC=5 run "$O" new k8s
    [ "$status" -ne 0 ]; [[ "$output" != *"started"* ]]
}

@test "a subuid line keyed by uid 1100 is not missed" {
    printf 'alice:100000:65536\n1100:2000000:65536\n' > "$R/etc/subuid"
    run "$P" --confirm
    [ "$status" -eq 1 ]; [[ "$output" == *"/etc/subuid has '1100:2000000:65536 ', not exactly"* ]]
}

@test "agent's own tree in the way: a warning, and the root steps still all ran" {
    : > "$R/home/agent/.local"                 # a file where a dir goes
    run "$P" --confirm
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"WARN: agent's starter dirs could not be created"* ]]
    grep -q "loginctl enable-linger agent" "$LOG"
    [ -d "$R/srv/agent-inbox/pastes" ]
}

@test "dry run with an oversized ceiling reports it and still shows the whole plan" {
    site_file 900000T 1G 1G
    run "$P"
    [ "$status" -eq 0 ]
    [[ "$output" == *"less than the ceilings 900000T (agent)"* && "$output" == *"would: loginctl enable-linger agent"* ]]
}

update_stubs() {  # alice's installed bundle.sh (logs), and the bundle's install-bundle.sh
    op_stubs
    env_set AGENTS_INBOX "$T/inbox"; mkdir -p "$T/inbox/airlock"
    H="$T/alicehome"; b="$H/.local/share/claude-airlock/current/bin"; mkdir -p "$b"
    printf '#!/bin/bash\necho "bundle.sh $*" >> "$LOG"\n' > "$b/bundle.sh"; chmod +x "$b/bundle.sh"
    # What agent's side runs: INSTALL says how it behaves.
    cat > "$T/inbox/airlock/install-bundle.sh" <<'S'
echo "installing"
case "${INSTALL:-ok}" in
    ok) echo "done" ;;
    fail) exit 3 ;;
    forge) printf 'agent-rc=0\npartial'; exit 1 ;;
    term) kill -TERM $$ ;;
    escape) printf 'evil \033]0;title\007 line\n'; printf '\033[1mbold\033[0m \033[32mok\033[0m ünïcode\n'
            printf 'c1 \302\2331;31mred\302\23552;c;ZXZpbA==\302\234 \302\235osc to the bel\007bs\010 dcs\302\220apc\302\237 Āě\n'
            printf 'rejoin \302\001\233X \302\033\233Y \302\302\200\233Z \033[>c\033[38:2:1:2:3mend\n' ;;
    nonl) printf 'done, no newline' ;;
esac
S
}
@test "agent update: bundles alice's installed claude-airlock, agent installs it, the bundle goes; on a failure it stays" {
    update_stubs
    HOME="$H" run "$O" update
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"installing"*"done"*"agent has it"* && "$output" != *"agent-rc"* ]]
    grep -qx "bundle.sh $T/inbox/airlock" "$LOG"
    grep -qF "/bin/bash $T/inbox/airlock/install-bundle.sh" "$LOG"
    grep -qx "bundle.sh --clean $T/inbox/airlock" "$LOG"
    : > "$LOG"
    INSTALL=fail HOME="$H" run "$O" update
    [ "$status" -ne 0 ]; [[ "$output" == *"the bundle stays"* ]]
    ! grep -q -- "--clean" "$LOG" || false
}

@test "agent update: a forged marker, a kill by signal, or a last line without a newline: the real status counts" {
    update_stubs
    for mode in forge term; do
        : > "$LOG"
        INSTALL=$mode HOME="$H" run "$O" update
        [ "$status" -ne 0 ] && ! grep -q -- "--clean" "$LOG" || { echo "$mode: $output"; return 1; }
    done
    INSTALL=nonl HOME="$H" run "$O" update
    [ "$status" -eq 0 ]; [[ "$output" == *"done, no newline"* ]]
}

@test "agent update: escape sequences (colours, titles) and control characters from agent's side don't reach alice's terminal" {
    update_stubs
    INSTALL=escape HOME="$H" run "$O" update
    [ "$status" -eq 0 ]
    [[ "$output" == *"evil  line"* && "$output" == *"bold ok ünïcode"* && "$output" == *"Āě"* ]]
    [[ "$output" != *$'\033'* && "$output" != *"[1m"* && "$output" != *"]0;title"* ]]
    # C1 controls (UTF-8 CSI, OSC, ST) and BEL/BS go; other UTF-8 (continuation bytes 80-9f) stays
    [[ "$output" != *$'\302\233'* && "$output" != *$'\302\235'* && "$output" != *$'\302\234'* ]]
    [[ "$output" != *$'\007'* && "$output" != *$'\010'* && "$output" == *"c1 red bs dcsapc Āě"* ]]
    # a deletion must not join the bytes of a C1 control around it; CSI with <=>: parameters goes whole
    [[ "$output" != *$'\302\233'* && "$output" == *"rejoin X Y Z end"* ]]
}

@test "agent ls/new/stop/restart: escape sequences and control characters from agent's systemctl don't reach alice's terminal" {
    op_stubs
    evil=$'unit \033]52;c;ZXZpbA==\007 \033]8;;http://x\033\\link\033]8;;\033\\ \033[2J\302\2331m c1 \001\177 ok Āě\302\001\233'
    for c in "stop k8s.main" "restart k8s.main" "new k8s"; do
        REMOTE_OUT="$evil" run "$O" $c
        [[ "$output" == *"unit  link  c1  ok Āě"* ]] || { echo "$c: $(printf %q "$output")"; return 1; }
        [[ "$output" != *$'\033'* && "$output" != *$'\302\233'* && "$output" != *$'\001'* && "$output" != *$'\177'* ]]
    done
    # a line that isn't valid UTF-8 is listed too (cleaned), not dropped by grep as binary
    REMOTE_OUT=$'agent-session@x.main.service loaded \033]0;t\007active running\nagent-session@y\377.main.service loaded active running' LC_ALL=C.UTF-8 run "$O" ls
    [[ "$output" != *$'\033'* && "$output" == *"x.main"* && "$output" == *$'\n'y* ]] || { printf '%q\n' "$output"; return 1; }
}

@test "agent update without an installed claude-airlock that has bundles: says what to do" {
    op_stubs
    env_set AGENTS_INBOX "$T/inbox"; mkdir -p "$T/inbox/airlock"
    HOME="$T/nohome" run "$O" update
    [ "$status" -ne 0 ]; [[ "$output" == *"make install-airlock in claude-airlock first"* ]]
}

@test "agent's manager has its own /tmp, /var/tmp, /dev/shm and /dev/mqueue, and reads the root-owned claude-airlock config" {
    d="$RENDER/etc/systemd/system/user@1100.service.d/10-airlock-agents.conf"
    grep -qx 'PrivateTmp=yes' "$d"
    grep -qx 'PrivateIPC=yes' "$d"
    grep -qx 'PrivateNetwork=yes' "$d"
    grep -qE '^TemporaryFileSystem=.*/dev/shm:mode=1777' "$d"
    grep -qE '^TemporaryFileSystem=.*/dev/mqueue:mode=1777' "$d"
    grep -qx 'Environment=AIRLOCK_CONFIG=/etc/claude-airlock/agents/agent.conf' "$d"
    grep -qx 'ProtectProc=invisible' "$d"
    grep -qx 'Environment=CONTAINERS_CONF_OVERRIDE=/usr/local/share/airlock-agents/containers.conf' "$d"
    # its own home and runtime dir only; no system bus; the other agents' cgroups hidden
    grep -qx 'ProtectHome=tmpfs' "$d"
    grep -qx 'BindPaths=/home/agent /run/user/1100' "$d"
    grep -qx 'TemporaryFileSystem=/run:mode=0755,nosuid,nodev' "$d"
    grep -qx 'InaccessiblePaths=-/sys/fs/cgroup/user.slice/user-1101.slice -/sys/fs/cgroup/user.slice/user-1102.slice' "$d"
    grep -qx 'After=user-1101.slice user-1102.slice' "$d"
    grep -qx 'ProtectSystem=strict' "$d"
    c="$UC/agent.conf"
    grep -qx 'AIRLOCK_EGRESS_PROXY=/run/airlock-envoy/agent/agent-anthropic.sock' "$c"
    grep -qx 'AIRLOCK_PASTE_DIR=/srv/agent-inbox/pastes' "$c"
    grep -qx 'AIRLOCK_SHARE_BASE=/home/agent/development' "$c"
    grep -qx '# AIRLOCK_GIT_NAME=' "$c"                          # the site's to fill in
    grep -qx '# AIRLOCK_GIT_EMAIL=' "$c"
}

@test "agent's login shells find airlock and get an orange prompt; nobody else's shell changes" {
    f="$RENDER/etc/profile.d/airlock-agents.sh"
    run bash -c 'id(){ echo 1100; }; PS1="\s-\v\$ "; . "$1"; printf "%s" "$PS1"' _ "$f"
    [ "$status" -eq 0 ]; [[ "$output" == *'38;5;208m\]\u\[\e[0m\]@\h '* ]]
    run bash -c 'id(){ echo 1100; }; HOME=/home/agent PATH=/usr/bin; . "$1"; . "$1"; printf "%s" "$PATH"' _ "$f"
    [ "$status" -eq 0 ]; [ "$output" = /home/agent/.local/bin:/usr/bin ]
    run bash -c 'id(){ echo 1000; }; PATH=/usr/bin; . "$1"; printf "%s" "$PATH"' _ "$f"
    [ "$status" -eq 0 ]; [ "$output" = /usr/bin ]
    run bash -c 'id(){ echo 1000; }; PS1="\s-\v\$ "; . "$1"; printf "%s" "$PS1"' _ "$f"
    [ "$status" -eq 0 ]; [ "$output" = '\s-\v$ ' ]
}

@test "agent's tmux reads only root's config: no status bar, Claude's copy on to foot, no requests or passthrough" {
    grep -q '^ExecStart=/usr/bin/tmux -f /usr/local/share/airlock-agents/tmux.conf ' "$RENDER/etc/systemd/user/agent-session@.service"
    c="$REPO/agents/share/tmux.conf"
    grep -qx 'set -g status off' "$c"
    grep -qx 'set -g set-clipboard off' "$c"                    # by default nothing from the pane reaches the clipboard
    grep -qx 'set -g set-clipboard on' "$REPO/agents/share/tmux-clipboard.conf"   # clipboard on: Claude's copy goes on to the terminal
    grep -qxF "set -as terminal-features 'foot*:clipboard'" "$c"
    grep -qx 'set -s get-clipboard off' "$c"                    # no answer to the pane's requests
    grep -qx 'set -g allow-passthrough off' "$c"
}

@test "agent's tmux: Shift+Enter reaches Claude as Alt+Enter (a new line)" {
    c="$REPO/agents/share/tmux.conf"
    grep -qx 'bind -n S-Enter send-keys M-Enter' "$c"
    if grep -q 'extended-keys' "$c"; then echo "should not match (line 503)"; return 1; fi     # not needed: tmux sees Shift+Enter from foot with the defaults
}

# ---- agent-web and agent-guard (agent-web.md, step 1) ----------------------------------------

# The fake state a provisioned host would show for the queue and the inbox: owner, group and
# mode (stat sidecars) and named ACL entries (getfacl sidecars), read from the repo's
# tmpfiles.d files, so provision only says ok if those files and its own table agree.
fake_queue_state() {
    python3 -I - "$RENDER/etc/tmpfiles.d/airlock-agents-queue.conf" "$RENDER/etc/tmpfiles.d/airlock-agents-inbox.conf" "$R" "$STATS" "$ACLS" <<'PY'
import os, sys
web, inbox, root, stats, acls = sys.argv[1:]
ids = {"root": "0", "alice": "1000", "": ""}
modes = {}
def side(d, p, text):
    with open(os.path.join(d, (root + p).replace("/", "_")), "w") as f: f.write(text)
for conf in (web, inbox):
    for line in open(conf):
        f = line.split()
        if not f or f[0].startswith("#"): continue
        if f[0] in ("d", "D"):
            os.makedirs(root + f[1], exist_ok=True)
            u, g = (ids.get(x, x) for x in (f[3], f[4]))
            side(stats, f[1], f"{u}:{g}:{int(f[2], 8):o}\n")
            modes[f[1]] = int(f[2], 8)
        elif f[0] == "a":
            out = []
            for e in f[6].split(","):
                d = e.startswith("d:"); e = e[2:] if d else e
                t, who, perm = e.split(":")
                out.append(("default:" if d else "") + {"u": "user", "g": "group", "m": "mask"}[t] + ":" + ids.get(who, who) + ":" + perm)
            # what tmpfiles adds to a default ACL (assumed; tests/agent-web-host.sh checks it on
            # the host): group and other from the dir's own bits unless given
            if any(o.startswith("default:") for o in out):
                m = modes[f[1]]
                rwx = lambda b: "".join(c if b & v else "-" for c, v in (("r", 4), ("w", 2), ("x", 1)))
                if not any(o.startswith("default:group::") for o in out): out.append("default:group::" + rwx(m >> 3 & 7))
                out.append("default:other::" + rwx(m & 7))
            side(acls, f[1], "\n".join(out) + "\n")
PY
    # The rendered files in place, as an apply leaves them.
    cp -a "$RENDER/." "$R/"
    # pastes/ is alice:agent 2750 and the provisioned users exist, as on the host.
    printf 'agent:x:1100:1100::/home/agent:/bin/bash\nagent-web:x:1101:1101::/home/agent-web:/bin/bash\nagent-guard:x:1102:1102::/home/agent-guard:/bin/bash\n' > "$PASSWD"
    printf 'agent:x:1100:\nagent-web:x:1101:\nagent-guard:x:1102:\n' > "$GROUP"
}

@test "provision dry run covers agent-web and agent-guard: their images, escaped mount units, users, subids, linger" {
    run "$P"
    [ "$status" -eq 0 ]
    [[ "$output" == *"would: create /var/lib/agent-web/home.img: sparse 1G, XFS"* ]]
    [[ "$output" == *"would: create /var/lib/agent-guard/home.img: sparse 1G, XFS"* ]]
    [[ "$output" == *'would: enable and start home-agent\x2dweb.mount'* ]]
    [[ "$output" == *'would: enable and start home-agent\x2dguard.mount'* ]]
    [[ "$output" == *"would: groupadd -g 1101 agent-web"* && "$output" == *"would: groupadd -g 1102 agent-guard"* ]]
    [[ "$output" == *"would: /etc/subuid: agent-web:1200000:65536"* && "$output" == *"would: /etc/subgid: agent-guard:1300000:65536"* ]]
    [[ "$output" == *"would: loginctl enable-linger agent-web"* && "$output" == *"would: loginctl enable-linger agent-guard"* ]]
    [[ "$output" == *"would: /srv/agent-web: every dir root's, groups, modes and ACLs as listed"* ]]
    [ ! -s "$LOG" ]
}

@test "provision --confirm: all three users, each with its own image, label, ids and subids; the queue from tmpfiles.d" {
    run "$P" --confirm
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    for u in agent agent-web agent-guard; do [ -f "$R/var/lib/$u/home.img" ] || { echo "no image for $u"; return 1; }; done
    grep -q "mkfs.xfs -q -L agent-web " "$LOG"
    grep -q "mkfs.xfs -q -L agent-guard " "$LOG"
    grep -qF 'systemctl enable --now home-agent\x2dweb.mount' "$LOG"
    grep -q "useradd -u 1101 -g agent-web -d /home/agent-web -M -s /bin/bash -c Claude web research (airlock) -K SUB_UID_COUNT=0 -K SUB_GID_COUNT=0 agent-web" "$LOG"
    grep -q "useradd -u 1102 -g agent-guard -d /home/agent-guard -M -s /bin/bash -c Claude answer gate (airlock) -K SUB_UID_COUNT=0 -K SUB_GID_COUNT=0 agent-guard" "$LOG"
    grep -q "passwd -q -l agent-web" "$LOG"
    grep -q "passwd -q -l agent-guard" "$LOG"
    for f in subuid subgid; do
        grep -qx "agent-web:1200000:65536" "$R/etc/$f"
        grep -qx "agent-guard:1300000:65536" "$R/etc/$f"
    done
    grep -qx "chown -h 1101:1101 $R/home/agent-web" "$LOG"
    grep -qx "chown -h 1102:1102 $R/home/agent-guard" "$LOG"
    for u in agent agent-web agent-guard; do [ "$(/usr/bin/stat -c %a "$R/home/$u")" = 700 ] || { echo "/home/$u not 0700"; return 1; }; done
    # each user's starter dirs as that user, and agent-web/agent-guard get no development/
    grep -q "setpriv --reuid=1101 --regid=1101 --clear-groups $R/usr/local/lib/airlock-agents/bin/install -d -m 0700 $R/home/agent-web/.config" "$LOG"
    grep -q "setpriv --reuid=1102 --regid=1102 --clear-groups $R/usr/local/lib/airlock-agents/bin/install -d -m 0700 $R/home/agent-guard/.config" "$LOG"
    [ ! -e "$R/home/agent-web/development" ]
    [ -d "$R/home/agent/development" ]
    grep -qx "systemd-tmpfiles --create /etc/tmpfiles.d/airlock-agents-queue.conf" "$LOG"
    grep -qx "systemd-tmpfiles --create /etc/tmpfiles.d/airlock-agents-inbox.conf" "$LOG"
    [ "$(/usr/bin/stat -c %a "$R/srv/agent-web/requests")" = 3770 ]
}

@test "provision refuses for agent-web and agent-guard as for agent: uid taken, wrong ids, overlapping subids, extra groups" {
    echo "mallory:x:1101:1101::/home/m:/bin/sh" > "$PASSWD"
    run "$P" --confirm
    [ "$status" -eq 1 ]; [[ "$output" == *"uid 1101 belongs to mallory"* ]]
    echo "mallory:x:1102:" > "$GROUP"; : > "$PASSWD"
    run "$P" --confirm
    [ "$status" -eq 1 ]; [[ "$output" == *"gid 1102 belongs to mallory"* ]]
    : > "$GROUP"; echo "agent-guard:x:1102:1100::/home/agent-guard:/bin/bash" > "$PASSWD"
    run "$P" --confirm
    [ "$status" -eq 1 ]; [[ "$output" == *"user agent-guard exists as uid:gid 1102:1100, not 1102:1102"* ]]
    : > "$PASSWD"; echo "other:1265000:10" >> "$R/etc/subgid"
    run "$P" --confirm
    [ "$status" -eq 1 ]; [[ "$output" == *"/etc/subgid already uses part of 1200000"* ]]
    printf 'alice:100000:65536\n' > "$R/etc/subgid"
    : > "$PASSWD"; : > "$GROUP"; : > "$LOG"
    AGENT_WEB_GROUPS="agent-web agent" run "$P" --confirm
    [ "$status" -eq 1 ]; [[ "$output" == *"agent-web is in other groups (agent)"* ]]
    # the refusals come before anything is changed for any user
    site_file 1G 1G big
    run "$P" --confirm
    [ "$status" -ne 0 ]; [[ "$output" == *"bad home size 'big'"* ]]
}

@test "the queue and inbox ACLs from tmpfiles.d are exactly what provision checks: a provisioned host is ok" {
    fake_queue_state
    run "$P" --check
    [[ "$output" == *"ok   /srv/agent-web: every dir root's, groups, modes and ACLs as listed"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"ok   /srv/agent-inbox root 0755, pastes/ and airlock/ alice:agent 2750, airlock/ readable by agent-web and agent-guard"* ]] || { echo "$output"; return 1; }
}

@test "the queue workers' units: enabled is ok, a missing link is a change provision makes (systemctl --global)" {
    fake_queue_state
    for l in default.target.wants/agent-web-worker.path timers.target.wants/agent-web-worker.timer \
             default.target.wants/agent-guard-worker.path timers.target.wants/agent-guard-worker.timer; do
        mkdir -p "$R/etc/systemd/user/${l%/*}"; ln -sfn "/etc/systemd/user/${l#*/}" "$R/etc/systemd/user/$l"
    done
    run "$P" --check
    [[ "$output" == *"ok   agent-web's and agent-guard's worker path and timer units enabled"* ]] || { echo "$output"; return 1; }
    rm "$R/etc/systemd/user/timers.target.wants/agent-guard-worker.timer"
    run "$P" --check
    [ "$status" -eq 1 ]; [[ "$output" == *"would: enable agent-web's and agent-guard's worker path and timer units"* ]] || { echo "$output"; return 1; }
}

@test "queue drift is caught: an extra ACL entry, a lost sticky bit, a wrong group, a missing default entry, the inbox ACL" {
    fake_queue_state
    k() { printf '%s' "$R$1" | tr / _; }
    for drift in extra sticky group default inbox; do
        fake_queue_state
        case $drift in
            extra)   echo "user:1100:r-x" >> "$ACLS/$(k /srv/agent-web/log)" ;;
            sticky)  echo "0:1100:2770" > "$STATS/$(k /srv/agent-web/requests)" ;;
            group)   echo "0:1101:2770" > "$STATS/$(k /srv/agent-web/answers)" ;;
            default) sed -i '/^default:user:1102/d' "$ACLS/$(k /srv/agent-web/reports)" ;;
            inbox)   echo "user:1101:r-x" >> "$ACLS/$(k /srv/agent-inbox/pastes)" ;;
        esac
        run "$P" --check
        [ "$status" -eq 1 ] || { echo "$drift not caught: $output"; return 1; }
        [[ "$output" == *"drifted from the site file"* ]]
    done
}

@test "a stray default entry on log/ (no defaults wanted, tmpfiles can't remove them there) is not drift" {
    fake_queue_state
    k() { printf '%s' "$R$1" | tr / _; }
    printf 'default:user:1100:r--\ndefault:group::r-x\ndefault:other::---\n' >> "$ACLS/$(k /srv/agent-web/log)"
    run "$P" --check
    [[ "$output" == *"ok   /srv/agent-web: every dir root's"* ]] || { echo "$output"; return 1; }
    # but a stray access entry there is
    echo "user:1100:r-x" >> "$ACLS/$(k /srv/agent-web/log)"
    run "$P" --check
    [[ "$output" != *"ok   /srv/agent-web: every dir root's"* ]]
}

@test "the queue's permission model: who may write and read each dir, and read new files in it (from tmpfiles.d)" {
    python3 -I - "$RENDER/etc/tmpfiles.d/airlock-agents-queue.conf" <<'PY'
import sys
users = {"agent": ("1100", "1100"), "agent-web": ("1101", "1101"), "agent-guard": ("1102", "1102"),
         "alice": ("1000", "alice"), "nobody": ("65534", "65534")}
dirs = {}
for line in open(sys.argv[1]):
    f = line.split()
    if not f or f[0].startswith("#"): continue
    if f[0] == "d": dirs[f[1]] = {"mode": int(f[2], 8), "group": f[4], "acl": {}, "dacl": {}}
    if f[0] == "a":
        for e in f[6].split(","):
            d = e.startswith("d:"); t, who, perm = (e[2:] if d else e).split(":")
            if t == "g" and who == "": dirs[f[1]]["dgroup"] = perm; continue
            if t == "m" and who == "":
                if not d: dirs[f[1]]["mask"] = perm
                continue
            assert t == "u", e
            dirs[f[1]]["dacl" if d else "acl"][who] = perm
def bits(p): return {c for c in p if c != "-"}
def triple(m, shift): return bits("".join(c if m >> (shift + s) & 1 else "-" for c, s in (("r", 2), ("w", 1), ("x", 0))))
def mask(d):
    # What tmpfiles' `a` really writes (seen on the host 2026-10-21): the mask named in the line, or,
    # left out, the union of the named entries alone (the owning group's bits don't count)
    dd = dirs[d]
    if "mask" in dd: return bits(dd["mask"])
    return set().union(*(bits(p) for p in dd["acl"].values())) if dd["acl"] else triple(dd["mode"], 3)
def access(u, d):
    uid, gid = users[u]; m = dirs[d]["mode"]; acl = dirs[d]["acl"]
    other, group = triple(m, 0), triple(m, 3)
    key = u if u in acl else uid
    if key in acl: return bits(acl[key]) & mask(d)
    if dirs[d]["group"] in (gid, u): return group & mask(d)
    return other
def can(u, path):  # every dir on the way needs x
    parts = path.split("/"); out = None
    for i in range(3, len(parts) + 1):
        p = "/".join(parts[:i])
        if p in dirs:
            a = access(u, p)
            if p != path and "x" not in a: return set()
            out = a
    return out
def new_file(d, owner, create):  # {user: rights} on a file `owner` creates in d with mode `create`
    dd = dirs[d]; dacl = dd["dacl"]
    if not dacl: return {}
    dgroup = bits(dd.get("dgroup", "".join(sorted(triple(dd["mode"], 3), key="rwx".index))))
    mask = set().union(dgroup, *(bits(p) for p in dacl.values())) & triple(create, 3)
    out = {}
    for u in users:
        if u == owner: continue
        key = u if u in dacl else users[u][0]
        if key in dacl: r = bits(dacl[key]) & mask
        elif dd["group"] in (users[u][1], u): r = dgroup & mask
        else: r = set()                                   # default:other:: is the dir's: ---
        if r: out[u] = "".join(sorted(r, key="rwx".index))
    return out
W, R = "rwx", "rx"
want = {  # dir: {user: rights}; anyone not listed: nothing
    "/srv/agent-web/requests":   {"agent": W, "alice": W, "agent-web": R, "agent-guard": R},
    "/srv/agent-web/held":       {"agent-web": W, "alice": R},
    "/srv/agent-web/decisions":  {"alice": W, "agent-web": R, "agent-guard": R},
    "/srv/agent-web/reports":    {"agent-web": W, "agent-guard": R},
    "/srv/agent-web/answers":    {"agent-guard": W, "agent": R, "alice": R},
    "/srv/agent-web/quarantine": {"agent-guard": W, "alice": R},
    "/srv/agent-web/log":        {"alice": R, "agent-web": R, "agent-guard": R},
    "/srv/agent-web/log/agent-web":               {"agent-web": W, "alice": R},
    "/srv/agent-web/log/agent-web/transcripts":   {"agent-web": W, "alice": R},
    "/srv/agent-web/log/agent-guard":             {"agent-guard": W, "alice": R},
    "/srv/agent-web/log/agent-guard/transcripts": {"agent-guard": W, "alice": R},
    "/srv/agent-web/lib":        {u: R for u in users},       # root's scripts and prompts, nothing secret
}
LIST_ONLY = {}
# where writers make per-id subdirs (chmod 0750): their readers must traverse them and list them
SUBDIRS = ("/srv/agent-web/reports", "/srv/agent-web/quarantine")
bad = []
assert set(want) | {"/srv/agent-web"} == set(dirs), sorted(dirs)
for d, w in want.items():
    for u in users:
        got = "".join(sorted(can(u, d) or set(), key="rwx".index))
        if got != w.get(u, ""): bad.append(f"{d} {u}: {got or '-'}, want {w.get(u) or '-'}")
    if d in ("/srv/agent-web/log", "/srv/agent-web/lib"): continue   # only root writes in these
    for owner in (x for x in w if w[x] == W):
        # a writer's file, chmod 0640 before its rename (step 4): exactly the dir's readers read it
        got = {u: r for u, r in new_file(d, owner, 0o640).items()}
        want_r = {u: "r" for u in w if u != owner and u not in LIST_ONLY.get(d, ())}
        if got != want_r: bad.append(f"{d} {owner}'s 0640 file: {got}, want {want_r}")
        # created 0666 (an open() without chmod): still nobody but its owner may write it
        wr = [u for u, r in new_file(d, owner, 0o666).items() if "w" in r]
        if wr: bad.append(f"{d} {owner}'s 0666 file writable by {wr}")
        if d in SUBDIRS:
            got = new_file(d, owner, 0o750)
            want_d = {u: "rx" for u in w if u != owner}
            if got != want_d: bad.append(f"{d} {owner}'s 0750 subdir: {got}, want {want_d}")
        # created 0600 (mktemp, no chmod): unreadable to the readers (fails closed)
        if new_file(d, owner, 0o600): bad.append(f"{d} {owner}'s 0600 file readable by {new_file(d, owner, 0o600)}")
    if not (dirs[d]["mode"] & 0o2000): bad.append(f"{d} not setgid")
    if dirs[d]["mode"] & 0o007: bad.append(f"{d} open to others")
if not dirs["/srv/agent-web/requests"]["mode"] & 0o1000: bad.append("requests/ not sticky")
# a dir holding another root-owned dir must be sticky where anyone but root may write it, or that
# writer could rename the inner dir away and put a link in its place
for d in dirs:
    parent = d.rsplit("/", 1)[0]
    if parent in dirs and any("w" in (can(u, parent) or set()) for u in users) and not dirs[parent]["mode"] & 0o1000:
        bad.append(f"{parent} holds {d} but isn't sticky")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
}

@test "agent update installs for agent, then each provisioned one of agent-web and agent-guard, in its own manager" {
    update_stubs
    printf 'agent:x:1100:1100::/home/agent:/bin/bash\nagent-web:x:1101:1101::/home/agent-web:/bin/bash\n' > "$PASSWD"
    HOME="$H" run "$O" update
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"agent has it"*"agent-web has it"*"agent-guard: not provisioned, skipped"* ]]
    grep -q "^machinectl shell -q agent@ $T/nd/sh -c .*install-bundle.sh" "$LOG"
    grep -q "^machinectl shell -q agent-web@ $T/nd/sh -c .*install-bundle.sh" "$LOG"
    if grep -q "agent-guard@" "$LOG"; then echo "should not match (line 755)"; return 1; fi
    grep -qx "bundle.sh --clean $T/inbox/airlock" "$LOG"
}

@test "agent update: a failure for one user keeps the bundle and says whose; the others still install" {
    update_stubs
    printf 'agent-web:x:1101:1101::/home/agent-web:/bin/bash\nagent-guard:x:1102:1102::/home/agent-guard:/bin/bash\n' > "$PASSWD"
    # install-bundle.sh fails only in agent-web's manager (the stub's machinectl passes the user on)
    sed -i 's/^case "${INSTALL:-ok}" in/[ "$(cat "$AS_FILE")" = agent-web@ ] \&\& exit 4\ncase "${INSTALL:-ok}" in/' "$T/inbox/airlock/install-bundle.sh"
    export AS_FILE="$T/as"
    sed -i 's|^echo "machinectl \$\*" >> "\$LOG"$|echo "machinectl $*" >> "$LOG"; printf %s "$3" > "$AS_FILE"|' "$T/bin/machinectl"
    HOME="$H" run "$O" update
    [ "$status" -ne 0 ]
    [[ "$output" == *"agent has it"*"agent-guard has it"*"the install failed for agent-web"*"bundle stays"* ]] || { echo "$output"; return 1; }
    if grep -q -- "--clean" "$LOG"; then echo "should not match (line 769)"; return 1; fi
}

@test "agent-web's and agent-guard's managers: the same sandbox as agent's, their own root-owned airlock config" {
    for u in agent-web:1101 agent-guard:1102; do
        n=${u#*:} u=${u%:*}
        d="$RENDER/etc/systemd/system/user@$n.service.d/10-airlock-agents.conf"
        grep -qx 'PrivateNetwork=yes' "$d"
        grep -qx 'PrivateTmp=yes' "$d"
        grep -qx 'PrivateIPC=yes' "$d"
        grep -qx "RequiresMountsFor=/home/$u" "$d"
        grep -qE '^TemporaryFileSystem=/dev/shm:mode=1777,nosuid,nodev /dev/mqueue:mode=1777,nosuid,nodev$' "$d"
        grep -qx "Environment=AIRLOCK_CONFIG=/etc/claude-airlock/agents/$u.conf" "$d"
        grep -qx 'ProtectProc=invisible' "$d"
        grep -qx 'Environment=CONTAINERS_CONF_OVERRIDE=/usr/local/share/airlock-agents/containers.conf' "$d"
        grep -qx 'ProtectHome=tmpfs' "$d"
        grep -qx "BindPaths=/home/$u /run/user/$n" "$d"
        grep -qx 'ProtectSystem=strict' "$d"
        grep -qx 'TemporaryFileSystem=/run:mode=0755,nosuid,nodev' "$d"
        # writes only to its home, runtime dir and its own queue dirs (the ones the queue model gives it)
        rw="$(sed -n 's/^ReadWritePaths=//p' "$d" | tr ' ' '\n' | sed 's/^-//' | sort | tr '\n' ' ')"
        case $u in
            agent-web)   want="/home/agent-web /run/user/1101 /srv/agent-web/held /srv/agent-web/log/agent-web /srv/agent-web/reports " ;;
            agent-guard) want="/home/agent-guard /run/user/1102 /srv/agent-web/answers /srv/agent-web/log/agent-guard /srv/agent-web/quarantine " ;;
        esac
        [ "$rw" = "$want" ] || { echo "$u writes: $rw"; return 1; }
        grep -q "^InaccessiblePaths=.*user-1100.slice" "$d"
        grep -qE '^MemoryMax=[0-9]+[MG]$' "$RENDER/etc/systemd/system/user-$n.slice.d/10-airlock-agents.conf"
        grep -qE '^CPUQuota=[0-9]+%$' "$RENDER/etc/systemd/system/user-$n.slice.d/10-airlock-agents.conf"
        c="$UC/$u.conf"
        grep -qx 'AIRLOCK_EGRESS_MODE=proxy' "$c"
        grep -qx 'AIRLOCK_PERSIST_LOGIN=1' "$c"
        # no pastes, no repos, no git identity
        if grep -qE '^AIRLOCK_(PASTE_DIR|SHARE_BASE|GIT_[A-Z_]+)=' "$c"; then echo "should not match (line 801)"; return 1; fi
    done
    grep -qx 'AIRLOCK_EGRESS_PROXY=/run/airlock-envoy/agent-web/agent-web-web.sock' "$UC/agent-web.conf"
    grep -qx 'AIRLOCK_EGRESS_PROXY=/run/airlock-envoy/agent-guard/agent-guard-anthropic.sock' "$UC/agent-guard.conf"
    grep -qx 'AIRLOCK_IMAGE=claude-airlock:base' "$UC/agent-guard.conf"   # the reader runs no tools
    grep -qx 'AIRLOCK_IMAGE=claude-airlock:base' "$UC/agent-web.conf"     # research needs no toolchain
    grep -qx 'AIRLOCK_BOX_CLAUDE_MD=none' "$UC/agent-guard.conf"          # cold starts: the system prompt is all
    grep -qx 'AIRLOCK_BOX_CLAUDE_MD=none' "$UC/agent-web.conf"
    if grep -q '^AIRLOCK_BOX_CLAUDE_MD=' "$UC/agent.conf"; then echo "the agent's boxes keep the toolkit's notes"; return 1; fi
}

@test "home mount units: the escaped name is the mount point, the image is provision's, before the user manager" {
    for u in agent-web:1101 agent-guard:1102; do
        n=${u#*:} u=${u%:*}
        m="$RENDER/etc/systemd/system/home-${u/-/\\x2d}.mount"
        [ -f "$m" ] || { echo "no $m"; return 1; }
        grep -qx "Where=/home/$u" "$m"
        grep -qx "What=/var/lib/$u/home.img" "$m"
        grep -qx "ConditionPathExists=/var/lib/$u/home.img" "$m"
        grep -qx "Before=user@$n.service" "$m"
        grep -qx 'Options=loop,nodev,nosuid' "$m"
        grep -qx 'Type=xfs' "$m"
    done
    # the unit names apply enables are those files
    run "$P"
    [[ "$output" == *'would: enable and start home-agent\x2dweb.mount'* ]] || { echo "$output"; return 1; }
    [[ "$output" == *'would: enable and start home-agent\x2dguard.mount'* ]]
}

@test "nftables drops each user's uid and subuid range in the host's namespace, the ranges provision gives them" {
    f="$RENDER/etc/airlock-agents.nft"
    for spec in agent:1100 agent-web:1101 agent-guard:1102; do
        u=${spec%:*} n=${spec#*:}
        start="$(awk -v u="$u" '$2 == u { for (i = 3; i < NF; i++) if ($i == "subuid") print $(i + 1) }' "$E/agents.conf")"
        set="{ $n, $start-$((start + 65535)) }"
        grep -qF "meta skuid $set counter drop" "$f" || { echo "no drop for $u: $set"; return 1; }
        grep -qF "meta skuid $set limit rate" "$f"
    done
    grep -qF 'log prefix "airlock-agents-agent-web-drop: "' "$f"
    grep -qF 'log prefix "airlock-agents-agent-guard-drop: "' "$f"
    # its own table, which its unit loads with nftables and again whenever nftables reloads
    grep -qx 'table inet airlock-agents {' "$f"
    u="$RENDER/etc/systemd/system/airlock-agents-nft.service"
    grep -qx 'PartOf=nftables.service' "$u"; grep -qx 'ExecStart=/usr/sbin/nft -f /etc/airlock-agents.nft' "$u"
}

@test "polkit: alice may open a host shell as agent, agent-web or agent-guard, nobody else and never anyone but alice" {
    command -v node >/dev/null || skip "node not installed: NOT TESTED here (run on the host)"
    node -e '
        const fs = require("fs"); let rule;
        const polkit = { addRule: f => { rule = f }, Result: { YES: "yes" } };
        eval(fs.readFileSync(process.argv[1], "utf8"));
        const a = (id, user) => ({ id, lookup: k => (k === "user" ? user : undefined) });
        const s = (user, local = true, active = true) => ({ user, local, active });
        const want = (r, exp, what) => { if (r !== exp) { console.error("wrong for " + what + ": " + r); process.exit(1) } };
        const hs = "org.freedesktop.machine1.host-shell";
        for (const u of ["agent", "agent-web", "agent-guard"]) want(rule(a(hs, u), s("alice")), "yes", u);
        for (const u of ["root", "alice", "agent-webx", "agent-", "", undefined, "nobody"]) want(rule(a(hs, u), s("alice")), undefined, String(u));
        want(rule(a(hs, "agent-web"), s("mallory")), undefined, "mallory");
        want(rule(a(hs, "agent-web"), s("alice", false)), undefined, "remote alice");
        want(rule(a(hs, "agent-web"), s("alice", true, false)), undefined, "inactive alice");
        want(rule(a("org.freedesktop.machine1.shell", "agent-web"), s("alice")), undefined, "other action");
    ' "$RENDER/etc/polkit-1/rules.d/50-airlock-agents.rules"
}

@test "agent-web.conf: owners root, records aged out after 90 days, ids by number except alice" {
    f="$RENDER/etc/tmpfiles.d/airlock-agents-queue.conf"
    awk '$1 == "d" && $4 != "root" { print "owner not root: " $0; bad = 1 } END { exit bad }' "$f"
    awk '$1 == "d" && $2 != "/srv/agent-web" && $2 != "/srv/agent-web/log" && $2 != "/srv/agent-web/lib" && $6 != "90d" { print "no 90d: " $0; bad = 1 } END { exit bad }' "$f"
    if grep -E '^[da] ' "$f" | grep -qE '(^| |,|:)(agent|agent-web|agent-guard)(:| )'; then echo "should not match (line 861)"; return 1; fi
}

@test "the inbox: agent-web and agent-guard read airlock/ and new bundle files there, never write; pastes/ has no ACL" {
    f="$RENDER/etc/tmpfiles.d/airlock-agents-inbox.conf"
    [ "$(grep -c '^a ' "$f")" = 1 ]
    acl="$(awk '$1 == "a" && $2 == "/srv/agent-inbox/airlock" { print $7 }' "$f")"
    [ "$(printf '%s\n' "${acl//,/$'\n'}" | sort | tr '\n' ' ')" = "d:u:1101:r-- d:u:1102:r-- u:1101:r-x u:1102:r-x " ] || { echo "$acl"; return 1; }
    if grep -E '^a ' "$f" | grep -q pastes; then echo "should not match (line 869)"; return 1; fi
}

@test "every refusal comes before any change: a subgid overlap for agent-guard changes nothing for anyone" {
    echo "other:1300100:10" >> "$R/etc/subgid"
    run "$P" --confirm
    [ "$status" -eq 1 ]; [[ "$output" == *"/etc/subgid already uses part of 1300000"* ]]
    [ ! -s "$LOG" ] || { cat "$LOG"; return 1; }
    if grep -q agent "$R/etc/subuid"; then echo "should not match (line 877)"; return 1; fi
    [ "$(/usr/bin/stat -c %a "$R/home/alice")" = 755 ]
    [ ! -e "$R/var/lib/agent/home.img" ]
    # and a ceiling the disk can't back, counted over all three images
    printf 'alice:100000:65536\n' > "$R/etc/subgid"
    site_file 1G 1G 900000T
    run "$P" --confirm
    [ "$status" -eq 1 ]; [[ "$output" == *"less than the ceilings 1G (agent) + 1G (agent-web) + 900000T (agent-guard)"* ]]
    [ ! -s "$LOG" ]
    [ "$(/usr/bin/stat -c %a "$R/home/alice")" = 755 ]
    # df that fails is no answer: refused, not taken as room
    printf '#!/bin/sh\nexit 1\n' > "$T/bin/df"; chmod +x "$T/bin/df"
    run "$P" --confirm
    [ "$status" -eq 1 ]; [[ "$output" == *"can't tell how much is free"* ]]; [ ! -s "$LOG" ]
}

@test "the managers' drop-ins carry exactly these directives (nothing weakened, nothing added)" {
    d="$RENDER/etc/systemd/system"
    got() { grep -v '^#' "$1" | grep -v '^$'; }
    want1100='[Unit]
RequiresMountsFor=/home/agent
Wants=user-1101.slice user-1102.slice
After=user-1101.slice user-1102.slice
[Service]
PrivateNetwork=yes
PrivateTmp=yes
PrivateIPC=yes
TemporaryFileSystem=/dev/shm:mode=1777,nosuid,nodev /dev/mqueue:mode=1777,nosuid,nodev
TemporaryFileSystem=/run:mode=0755,nosuid,nodev
BindReadOnlyPaths=/run/systemd/notify -/run/systemd/journal/socket -/run/systemd/journal/stdout -/run/systemd/journal/dev-log -/run/systemd/system -/run/airlock-envoy
ProtectProc=invisible
Environment=CONTAINERS_CONF_OVERRIDE=/usr/local/share/airlock-agents/containers.conf
ProtectHome=tmpfs
BindPaths=/home/agent /run/user/1100
ProtectSystem=strict
ReadWritePaths=/home/agent /run/user/1100 -/srv/agent-web/requests
InaccessiblePaths=-/var/lib/sss/pipes
TemporaryFileSystem=/mnt:ro
InaccessiblePaths=-/dev/dxg -/dev/vsock
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
SystemCallArchitectures=native
SystemCallFilter=~io_uring_setup:ENOSYS io_uring_enter:ENOSYS io_uring_register:ENOSYS
InaccessiblePaths=-/sys/fs/cgroup/user.slice/user-1101.slice -/sys/fs/cgroup/user.slice/user-1102.slice
Environment=AIRLOCK_CONFIG=/etc/claude-airlock/agents/agent.conf'
    [ "$(got "$d/user@1100.service.d/10-airlock-agents.conf")" = "$want1100" ] || { diff <(echo "$want1100") <(got "$d/user@1100.service.d/10-airlock-agents.conf"); return 1; }
    for spec in agent-web:1101:"-/srv/agent-web/held -/srv/agent-web/reports -/srv/agent-web/log/agent-web":"-/sys/fs/cgroup/user.slice/user-1100.slice -/sys/fs/cgroup/user.slice/user-1102.slice":"user-1100.slice user-1102.slice" \
                agent-guard:1102:"-/srv/agent-web/answers -/srv/agent-web/quarantine -/srv/agent-web/log/agent-guard":"-/sys/fs/cgroup/user.slice/user-1100.slice -/sys/fs/cgroup/user.slice/user-1101.slice":"user-1100.slice user-1101.slice"; do
        IFS=: read -r u n rw cg af <<<"$spec"
        want="[Unit]
RequiresMountsFor=/home/$u
Wants=$af
After=$af
[Service]
PrivateNetwork=yes
PrivateTmp=yes
PrivateIPC=yes
TemporaryFileSystem=/dev/shm:mode=1777,nosuid,nodev /dev/mqueue:mode=1777,nosuid,nodev
TemporaryFileSystem=/run:mode=0755,nosuid,nodev
BindReadOnlyPaths=/run/systemd/notify -/run/systemd/journal/socket -/run/systemd/journal/stdout -/run/systemd/journal/dev-log -/run/systemd/system -/run/airlock-envoy
ProtectProc=invisible
Environment=CONTAINERS_CONF_OVERRIDE=/usr/local/share/airlock-agents/containers.conf
ProtectHome=tmpfs
BindPaths=/home/$u /run/user/$n
ProtectSystem=strict
ReadWritePaths=/home/$u /run/user/$n $rw
InaccessiblePaths=-/var/lib/sss/pipes
TemporaryFileSystem=/mnt:ro
InaccessiblePaths=-/dev/dxg -/dev/vsock
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
SystemCallArchitectures=native
SystemCallFilter=~io_uring_setup:ENOSYS io_uring_enter:ENOSYS io_uring_register:ENOSYS
InaccessiblePaths=$cg
Environment=AIRLOCK_CONFIG=/etc/claude-airlock/agents/$u.conf"
        f="$d/user@$n.service.d/10-airlock-agents.conf"
        [ "$(got "$f")" = "$want" ] || { diff <(echo "$want") <(got "$f"); return 1; }
    done
}

@test "the agents' podman runs crun (root's config, loaded last); provision wants crun installed" {
    c="$REPO/agents/share/containers.conf"
    [ "$(grep -v '^#' "$c" | grep -v '^$')" = $'[engine]\nruntime = "crun"' ]
    rm "$T/bin/crun"
    export AGENTS_CRUN=crun-not-on-this-path    # a host's own crun (a CI runner's) must not count
    run "$P"
    [ "$status" -eq 1 ]; [[ "$output" == *"paused, nothing changed"*"crun is not installed"* ]] || { echo "$output"; return 1; }
    run "$P" --confirm
    [ "$status" -eq 1 ]; [[ "$output" == *"crun is not installed"* ]]
    [ ! -s "$LOG" ]                                                # refused before any change
}

# ---- R1: the the host-side processes run from execute-only copies ----------------------------

@test "agent runs every the host-side step from the execute-only copies, never a readable original" {
    op_stubs
    run "$O" new k8s; run "$O" stop k8s.main; run "$O" attach k8s.main
    [ -s "$LOG" ]
    if grep -E '^machinectl ' "$LOG" | grep -qE ' (/bin/sh|/usr/bin/systemd-run|/usr/bin/systemctl) '; then
        echo "a readable original in: $(grep -E '^machinectl ' "$LOG" | head -3)"; return 1
    fi
    grep -q "^machinectl shell -q -E SYSTEMD_PAGER=cat -E SYSTEMD_COLORS=0 agent@ $T/nd/sh -c " "$LOG"
    grep -q '"$nd/systemctl" --user --no-pager' "$LOG"
}

@test "agent refuses to run without the copies (no silent fallback to the readable originals)" {
    op_stubs
    rm "$T/nd/systemd-run" "$STATS/$(printf '%s' "$T/nd/systemd-run" | tr / _)"
    : > "$LOG"
    run "$O" stop k8s.main
    [ "$status" -ne 0 ]; [[ "$output" == *"systemd-run missing or not root's 0711: sudo airlock-agents-apply --confirm"* ]]
    if grep -q '^machinectl' "$LOG"; then echo "ran anyway"; return 1; fi
    # there but readable (0755), or not root's: refused too
    ln -sf "$T/bin/systemd-run" "$T/nd/systemd-run"
    echo 0:0:711 > "$STATS/$(printf '%s' "$T/nd/systemd-run" | tr / _)"
    for bad in 0:0:755 1000:1000:711 0:1000:711; do
        echo "$bad" > "$STATS/$(printf '%s' "$T/nd/sh" | tr / _)"
        : > "$LOG"; run "$O" stop k8s.main
        [ "$status" -ne 0 ] || { echo "accepted $bad"; return 1; }
        if grep -q '^machinectl' "$LOG"; then echo "ran with $bad"; return 1; fi
    done
}

@test "nodump-refresh: 0711 copies of bash (as sh), systemd-run, systemctl; same bytes; renamed in" {
    src="$T/src"; nd="$T/ndr"; mkdir -p "$src"
    for b in bash systemd-run systemctl install; do printf '#!/bin/sh\necho %s\n' "$b" > "$src/$b"; chmod 755 "$src/$b"; done
    AGENTS_NODUMP_DIR="$nd" AGENTS_NODUMP_SRC="$src" run "$REPO/agents/lib/nodump-refresh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    for pair in sh:bash systemd-run:systemd-run systemctl:systemctl install:install; do
        [ "$(/usr/bin/stat -c %a "$nd/${pair%%:*}")" = 711 ]
        cmp -s "$src/${pair#*:}" "$nd/${pair%%:*}"
    done
    [ -z "$(find "$nd" -name '.*.new')" ]
    # a failed refresh leaves the old set whole: none renamed in, no .new left behind
    for b in bash systemd-run install; do printf '#!/bin/sh\necho new %s\n' "$b" > "$src/$b"; done
    rm "$src/systemctl"
    AGENTS_NODUMP_DIR="$nd" AGENTS_NODUMP_SRC="$src" run "$REPO/agents/lib/nodump-refresh"
    [ "$status" -ne 0 ]; [[ "$output" == *"no $src/systemctl"* ]]
    if grep -q 'new' "$nd/sh" "$nd/systemd-run" "$nd/install"; then echo "a copy changed on a failed refresh"; return 1; fi
    [ -z "$(find "$nd" -name '.*.new')" ]
}

@test "the pacman hook refreshes the copies after bash or systemd change; provision checks them" {
    h="$REPO/agents/hooks/airlock-agents-nodump.hook"
    grep -qx 'Target = bash' "$h"; grep -qx 'Target = systemd' "$h"; grep -qx 'Target = coreutils' "$h"
    grep -qx 'When = PostTransaction' "$h"; grep -qx 'Exec = /usr/local/lib/airlock-agents/nodump-refresh' "$h"
    [ -x "$REPO/agents/lib/nodump-refresh" ]
    run "$P"
    [[ "$output" == *"would: /usr/local/lib/airlock-agents/bin: execute-only copies of sh, systemd-run, systemctl, install (nodump-refresh)"* ]]
    # current copies (root's, 0711, the same bytes): ok
    mkdir -p "$R/usr/bin" "$R/usr/local/lib/airlock-agents/bin"
    for pair in sh:bash systemd-run:systemd-run systemctl:systemctl install:install; do
        echo "${pair#*:}" > "$R/usr/bin/${pair#*:}"; cp "$R/usr/bin/${pair#*:}" "$R/usr/local/lib/airlock-agents/bin/${pair%%:*}"
        echo 0:0:711 > "$STATS/$(printf '%s' "$R/usr/local/lib/airlock-agents/bin/${pair%%:*}" | tr / _)"
    done
    run "$P"
    [[ "$output" == *"ok   /usr/local/lib/airlock-agents/bin: execute-only copies of sh, systemd-run, systemctl, install, current"* ]] || { echo "$output"; return 1; }
    # right bytes but readable, or not root's: drift (a readable copy would reopen R1)
    for bad in 0:0:755 1000:0:711 0:1000:711; do
        echo "$bad" > "$STATS/$(printf '%s' "$R/usr/local/lib/airlock-agents/bin/systemctl" | tr / _)"
        run "$P" --check
        [ "$status" -eq 1 ] && [[ "$output" == *"would: /usr/local/lib/airlock-agents/bin: execute-only copies"* ]] || { echo "accepted $bad"; return 1; }
    done
    echo 0:0:711 > "$STATS/$(printf '%s' "$R/usr/local/lib/airlock-agents/bin/systemctl" | tr / _)"
    echo stale > "$R/usr/local/lib/airlock-agents/bin/install"                  # a coreutils upgrade the hook missed
    run "$P" --check
    [ "$status" -eq 1 ] || { echo "a stale install copy accepted"; return 1; }
    cp "$R/usr/bin/install" "$R/usr/local/lib/airlock-agents/bin/install"
    echo stale > "$R/usr/local/lib/airlock-agents/bin/systemd-run"              # an upgrade the hook missed
    run "$P" --check
    [ "$status" -eq 1 ]; [[ "$output" == *"would: /usr/local/lib/airlock-agents/bin: execute-only copies"* ]]
}

@test "each agent's boxes get root's managed settings: no inbound messages, artifacts or cloud triggers; agent-web and agent-guard no subagents, messages, agent lists, Bash or login files; agent-guard no Remote Control" {
    for u in agent agent-web agent-guard; do
        f="$REPO/agents/share/managed-settings-${u#agent-}.json"
        grep -qx "AIRLOCK_MANAGED_SETTINGS=/usr/local/share/airlock-agents/managed-settings-${u#agent-}.json" "$UC/$u.conf"
        [ "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("crossSessionInbound"))' "$f")" = refuse ]
        deny="$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["permissions"]["deny"])))' "$f")"
        rc="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("disableRemoteControl", False))' "$f")"
        # every account: no messages in from other sessions, no artifacts (any of the artifact
        # tools, either side of a channel), no cloud triggers; agent keeps SendMessage and ListAgents
        # for its own subagents (other sessions refuse what it sends); agent-web and agent-guard also
        # no messages or agent lists, no subagents (remote ones are account state) and no
        # scheduled tasks, no Bash and no reading or editing ~/.claude (the account's login lives
        # there, and these boxes read the web)
        common="Artifact ArtifactCheck ArtifactComments ArtifactData RemoteTrigger"
        web="Agent Artifact ArtifactCheck ArtifactComments ArtifactData Bash CronCreate Edit(~/.claude/**) ListAgents Read(~/.claude/**) RemoteTrigger SendMessage"
        case $u in
            agent)       [ "$deny" = "$common" ] && [ "$rc" = False ] ;;
            agent-web)   [ "$deny" = "$web" ] && [ "$rc" = False ] ;;
            agent-guard) [ "$deny" = "$web" ] && [ "$rc" = True ] ;;
        esac || { echo "$u: deny='$deny' disableRemoteControl=$rc"; return 1; }
    done
}

@test "agent's boxes mount the queue: requests/ read-write, answers/ and lib/ read-only; agent-web and agent-guard get theirs per run" {
    grep -qx 'AIRLOCK_EXTRA_MOUNTS="/srv/agent-web/requests:rw /srv/agent-web/answers:ro /srv/agent-web/lib:ro"' "$UC/agent.conf"
    for u in agent-web agent-guard; do
        if grep -q '^AIRLOCK_EXTRA_MOUNTS=' "$UC/$u.conf"; then echo "$u mounts the queue for every box"; return 1; fi
    done
}

# ---- agent web ------------------------------------------------------------------------------

web_queue() {  # a queue alice can use, with the real lib/ (web.py)
    export AGENTS_WEB_QUEUE="$T/q"; Q="$AGENTS_WEB_QUEUE"; env_set AGENTS_QUEUE "$Q"
    for d in requests held decisions answers quarantine log/agent-web; do mkdir -p "$Q/$d"; done
    ln -s "$RENDER/srv/agent-web/lib" "$Q/lib"
    ID=20261021T120000Z-a1b2c3
}
req() {  # req <id> <question>
    printf '{"id": "%s", "question": "%s", "why": "w", "asked_by": "agent", "created": "2026-10-21T12:00:00Z"}' "$1" "$2" > "$Q/requests/$1.json"
}

@test "agent web ask: a request as alice that the worker's check accepts" {
    op_stubs; web_queue
    run "$O" web ask "What is SCRAM-SHA-256?"
    [ "$status" -eq 0 ]; id="$output"
    [[ "$id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}$ ]]
    python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["asked_by"] == "alice" and r["question"] == "What is SCRAM-SHA-256?"' "$Q/requests/$id.json"
}

@test "agent web ls: each id's state from what alice can see, the question cleaned of escapes" {
    op_stubs; web_queue
    req 20261021T120001Z-aaaaa1 'answered one';   : > "$Q/answers/20261021T120001Z-aaaaa1.md"
    req 20261021T120002Z-aaaaa2 'held one';       : > "$Q/held/20261021T120002Z-aaaaa2.json"
    req 20261021T120003Z-aaaaa3 'quarantined';    mkdir "$Q/quarantine/20261021T120003Z-aaaaa3"
    req 20261021T120004Z-aaaaa4 'rejected one';   : > "$Q/held/20261021T120004Z-aaaaa4.json"; : > "$Q/decisions/20261021T120004Z-aaaaa4.reject"
    req 20261021T120005Z-aaaaa5 'gave up';        echo '{"ts":"x","user":"agent-web","id":"20261021T120005Z-aaaaa5","stage":"check","result":"failed, gave up","exit":2}' >> "$Q/log/agent-web/stages.jsonl"
    req 20261021T120006Z-aaaaa6 'red \u001b[31mtext\u001b[0m'
    req 20261021T120007Z-aaaaa7 'released'; mkdir "$Q/quarantine/20261021T120007Z-aaaaa7"; : > "$Q/answers/20261021T120007Z-aaaaa7.md"
    req 20261021T120008Z-aaaaa8 'real\n20261021T120009Z-ffffff  answered  forged row'
    printf '{}' > "$Q/requests/not-an-id.json"
    run "$O" web ls
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    for want in "aaaaa1  answered" "aaaaa2  held" "aaaaa3  quarantined" "aaaaa4  rejected" "aaaaa5  failed (check: failed, gave up)" "aaaaa6  queued" "aaaaa7  released by alice"; do
        [[ "$output" == *"$want"* ]] || { echo "no '$want' in: $output"; return 1; }
    done
    { [[ "$output" == *"red text"* ]] && [[ "$output" != *$'\e'* ]]; } || return 1
    [[ "$output" != *not-an-id* ]]
    [ "$(grep -c '^20261021T120009Z-ffffff' <<< "$output")" = 0 ] || { echo "a question forged a row: $output"; return 1; }
}

@test "agent web approve|reject|release: only in the matching state; the marker readable by the workers" {
    op_stubs; web_queue
    req "$ID" q
    run "$O" web approve "$ID"; [ "$status" -ne 0 ]; [[ "$output" == *"is not held"* ]]
    echo '{"question": "q"}' > "$Q/held/$ID.json"
    run "$O" web release "$ID"; [ "$status" -ne 0 ]; [[ "$output" == *"is not quarantined"* ]]
    run "$O" web approve "$ID"; [ "$status" -eq 0 ]
    [ "$(stat -c %a "$Q/decisions/$ID.approve")" = 640 ]
    run "$O" web reject "$ID"; [ "$status" -ne 0 ]                     # approved: no longer held
    run "$O" web approve "../../x"; [ "$status" -ne 0 ]; [[ "$output" == *"not an id"* ]]
    mkdir "$Q/quarantine/$ID"; rm "$Q/decisions/$ID.approve"
    run "$O" web release "$ID"; [ "$status" -eq 0 ]; [ -e "$Q/decisions/$ID.release" ]
}

@test "agent web show: answer, quarantine or held request, through the clean filter" {
    op_stubs; web_queue
    req "$ID" q
    printf 'held \033]52;c;cGF5bG9hZA==\007 text\n' > "$Q/held/$ID.json"
    run "$O" web show "$ID"
    [[ "$output" == *"== held: the request"* && "$output" == *"held  text"* ]] && [[ "$output" != *$'\e'* ]] || { echo "$output"; return 1; }
    mkdir "$Q/quarantine/$ID"; echo '{"findings": []}' > "$Q/quarantine/$ID/findings.json"; echo body > "$Q/quarantine/$ID/normalized.md"
    run "$O" web show "$ID"; [[ "$output" == *"== quarantined: findings"* && "$output" == *body* ]]
    printf 'the answer\n' > "$Q/answers/$ID.md"
    run "$O" web show "$ID"; [ "$output" = "the answer" ]
}

@test "agent web retry: clears a given-up id in each worker's state, nothing else" {
    op_stubs; web_queue
    export HOME="$T/agenthome"
    sw="$HOME/.local/state/agent-web-worker" sg="$HOME/.local/state/agent-guard-worker"
    mkdir -p "$sw" "$sg"
    echo failed > "$sw/$ID"; echo release-failed > "$sg/$ID"
    req "$ID" q
    echo "{\"ts\":\"x\",\"user\":\"agent-web\",\"id\":\"$ID\",\"stage\":\"check\",\"result\":\"failed, gave up\",\"exit\":2}" >> "$Q/log/agent-web/stages.jsonl"
    run "$O" web retry "$ID"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    { [ ! -e "$sw/$ID" ] && [ "$(cat "$sg/$ID")" = quarantined ]; } || return 1
    { grep -q -- " agent-web@ " "$LOG" && grep -q -- " agent-guard@ " "$LOG"; } || return 1
    echo done > "$sw/$ID"; run "$O" web retry "$ID"; [ "$(cat "$sw/$ID")" = done ]   # not a given-up one
    run "$O" web retry 'x;rm -rf /'; [ "$status" -ne 0 ]
}

@test "agent web login: one box per workspace, as its user, through the execute-only helpers; or just the one named" {
    op_stubs; web_queue
    run "$O" web login
    [ "$(grep -c "machinectl shell -q agent-web@ $T/nd/systemd-run --user --pty" "$LOG")" = 2 ]
    [ "$(grep -c "machinectl shell -q agent-guard@ $T/nd/systemd-run --user --pty" "$LOG")" = 1 ]
    { grep -q "agent-guard@ .* bash gate$" "$LOG" && grep -q "agent-web@ .* bash research$" "$LOG" && grep -q "agent-web@ .* bash chat$" "$LOG"; } || return 1
    : > "$LOG"; run "$O" web login gate
    { [ "$(grep -c 'machinectl shell' "$LOG")" = 1 ] && grep -q "agent-guard@ .* bash gate$" "$LOG"; } || return 1
}

@test "agent web: starts and attaches main in agent-web's manager; with several running, a bare stop refuses and touches nothing" {
    op_stubs; web_queue
    REMOTE_OUT="" run "$O" web
    grep -q "agent-web@ .*start agent-web-session@main.service" "$LOG"
    grep -qx "machinectl shell -q agent-web@ $T/nd/systemd-run --user --pty --wait --collect --quiet --same-dir -- /usr/bin/tmux -S /run/user/1101/agent-web-main.sock attach" "$LOG"
    if grep -q " agent@ " "$LOG"; then echo "reached agent's manager"; return 1; fi
    : > "$LOG"
    two=$'agent-web-session@main.service loaded active running x\nagent-web-session@b.service loaded active running x'
    REMOTE_OUT="$two" run "$O" web stop
    [ "$status" -ne 0 ]; [[ "$output" == *"several agent-web sessions run (main b)"* ]]
    if grep -q " stop agent-web-session" "$LOG"; then echo "stopped one"; return 1; fi
    REMOTE_OUT="agent-web-session@b.service loaded active running x" run "$O" web stop
    grep -q "agent-web@ .*stop agent-web-session@b.service" "$LOG"
    REMOTE_OUT="" run "$O" web restart; [ "$status" -ne 0 ]; [[ "$output" == *"no agent-web session is running"* ]]
}

@test "the interactive session: agent-web only, never enabled, 4 h at most; a fresh named conversation, never resumed, recorded" {
    f="$RENDER/etc/systemd/user/agent-web-session@.service"
    grep -qx 'ConditionUser=agent-web' "$f"; grep -qx 'RuntimeMaxSec=12h' "$f"
    if grep -q '^\[Install\]' "$f"; then echo "enableable"; return 1; fi
    [ -x "$REPO/agents/lib/web-session-run" ]
    export AGENTS_WEB_IDLE_POLL=1 AGENTS_WEB_PREV_WAIT=2 HOME="$T/wh" XDG_RUNTIME_DIR="$T/run" AGENTS_WEB_LIB="$RENDER/srv/agent-web/lib" AGENTS_WEB_QUEUE="$T/q"
    mkdir -p "$HOME/.local/bin" "$HOME/chat" "$XDG_RUNTIME_DIR" "$T/q/log/agent-web/transcripts" "$T/tb"
    # the box: records its args, writes its transcript where the launcher shares history
    cat > "$HOME/.local/bin/airlock" <<S
#!/bin/bash
printf '%s\n' "\$@" > "$T/args"
sid=\$(sed -n '/^--session-id\$/{n;p;}' "$T/args")
mkdir -p "$HOME/.claude/projects/-wh-chat"; echo '{"t":1}' > "$HOME/.claude/projects/-wh-chat/\$sid.jsonl"
S
    chmod +x "$HOME/.local/bin/airlock"
    # tmux: a server answers only for a socket with a .live mark
    printf '#!/bin/bash\n[ "$3" = has-session ] && [ -e "$2.live" ]\n' > "$T/tb/tmux"; chmod +x "$T/tb/tmux"
    export PATH="$T/tb:$PATH"
    mem="$HOME/.config/claude-airlock/state/$(printf '%s' "$HOME/chat" | sed 's#[^a-zA-Z0-9]#-#g; s#^-*##')/box-memory"
    mkdir -p "$mem"; echo note > "$mem/MEMORY.md"
    echo old > "$HOME/chat/leftover"
    python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$XDG_RUNTIME_DIR/agent-web-gone.sock"   # an ended chat's socket
    run bash "$REPO/agents/lib/web-session-run" main
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$HOME/chat/leftover" ] || { echo "workspace not emptied (a stale socket counted?)"; return 1; }
    [ ! -e "$mem/MEMORY.md" ] || { echo "memory kept"; return 1; }
    grep -qx -- --remote-control "$T/args"; [ "$(sed -n '/^--name$/{n;p;}' "$T/args")" = agent-web ]
    grep -qx -- --session-id "$T/args"
    if grep -qx -- '--resume\|--continue' "$T/args"; then echo resumed; return 1; fi
    grep -q "Interactive research session" "$T/args"
    ls "$T/q/log/agent-web/transcripts/" | grep -q '^web-[0-9]*\.jsonl$'
    grep -q '"stage":"chat","result":"agent-web ended (exit)"' "$T/q/log/agent-web/stages.jsonl"
    # another chat running in the workspace: its files stay; a second one is named
    : > "$XDG_RUNTIME_DIR/agent-web-gone.sock.live"
    echo theirs > "$HOME/chat/theirs"
    run bash "$REPO/agents/lib/web-session-run" second
    [ -e "$HOME/chat/theirs" ]; [ "$(sed -n '/^--name$/{n;p;}' "$T/args")" = agent-web.second ]
    # its own socket (tmux makes it before the pane runs) is not another chat
    rm "$XDG_RUNTIME_DIR/agent-web-gone.sock.live"
    python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$XDG_RUNTIME_DIR/agent-web-main.sock"; : > "$XDG_RUNTIME_DIR/agent-web-main.sock.live"
    run bash "$REPO/agents/lib/web-session-run" main
    [ ! -e "$HOME/chat/theirs" ]
    run bash "$REPO/agents/lib/web-session-run" '../x'; [ "$status" -eq 2 ]
}

@test "the interactive session: the box can read the terminal; a hangup (stop, restart, 4 h) still leaves the record" {
    export AGENTS_WEB_IDLE_POLL=1 AGENTS_WEB_PREV_WAIT=2 HOME="$T/wh" XDG_RUNTIME_DIR="$T/run" AGENTS_WEB_LIB="$RENDER/srv/agent-web/lib" AGENTS_WEB_QUEUE="$T/q"
    mkdir -p "$HOME/.local/bin" "$HOME/chat" "$XDG_RUNTIME_DIR" "$T/q/log/agent-web/transcripts" "$T/tb"
    printf '#!/bin/bash\nexit 1\n' > "$T/tb/tmux"; chmod +x "$T/tb/tmux"; export PATH="$T/tb:$PATH"
    # a box that reads the terminal (in the background process group it would stop on SIGTTIN)
    printf '#!/bin/bash\nread -r -t 5 line; echo "GOT:$line" > "%s"\n' "$T/got" > "$HOME/.local/bin/airlock"; chmod +x "$HOME/.local/bin/airlock"
    { sleep 1; printf 'hello\n'; } | timeout 20 script -qec "bash $REPO/agents/lib/web-session-run main" /dev/null >/dev/null 2>&1 || true
    [ "$(cat "$T/got" 2>/dev/null)" = GOT:hello ] || { echo "the box couldn't read the terminal: $(cat "$T/got" 2>/dev/null)"; return 1; }
    # a hangup ends the box; the runner still copies the transcript and logs the end
    rm -f "$T/q/log/agent-web/stages.jsonl"
    cat > "$HOME/.local/bin/airlock" <<S
#!/bin/bash
sid=\$(printf '%s\n' "\$@" | sed -n '/^--session-id\$/{n;p;}')
mkdir -p "$HOME/.claude/projects/-wh-chat"; echo '{"t":1}' > "$HOME/.claude/projects/-wh-chat/\$sid.jsonl"
echo \$\$ > "$T/boxpid"; grep '^SigIgn:' /proc/self/status > "$T/sigign"; sleep 30 & wait
S
    # the runner leads its own process group, as the pane's session leader does; the hangup goes to
    # it alone, as the kernel sends it when the tmux server goes
    setsid bash "$REPO/agents/lib/web-session-run" main >/dev/null 2>&1 & runner=$!
    for _ in $(seq 50); do [ -s "$T/boxpid" ] && break; sleep 0.1; done
    sleep 0.3; kill -HUP "$runner"
    for _ in $(seq 50); do kill -0 "$(cat "$T/boxpid")" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$(cat "$T/boxpid")" 2>/dev/null; then kill "$(cat "$T/boxpid")"; echo "the box outlived the hangup"; return 1; fi
    wait "$runner" || true
    pkill -f 'sleep 30' -P "$(cat "$T/boxpid")" 2>/dev/null || true
    grep -q '"stage":"chat","result":"agent-web ended (stop)"' "$T/q/log/agent-web/stages.jsonl" || { echo "no record after a hangup"; return 1; }
    # the box must not inherit an ignored HUP (it would never end at stop or the 4 h limit)
    mask=$(awk '{print $2}' "$T/sigign"); (( (16#$mask & 1) == 0 )) || { echo "HUP ignored in the box: $mask"; return 1; }
    ls "$T/q/log/agent-web/transcripts/" | grep -q '^web-'
}

@test "the interactive session ends after its idle time (warned first); activity keeps it" {
    export AGENTS_WEB_IDLE_POLL=1 AGENTS_WEB_PREV_WAIT=2 HOME="$T/wh" XDG_RUNTIME_DIR="$T/run" AGENTS_WEB_LIB="$RENDER/srv/agent-web/lib" AGENTS_WEB_QUEUE="$T/q"
    export AGENTS_WEB_IDLE=4 AGENTS_WEB_IDLE_WARN=2 AGENTS_WEB_IDLE_POLL=1
    mkdir -p "$HOME/.local/bin" "$HOME/chat" "$XDG_RUNTIME_DIR" "$T/q/log/agent-web/transcripts" "$T/tb"
    printf '#!/bin/bash\n[ "$3" = has-session ] && exit 1\nprintf "%%s\\n" "$*" >> "%s"\n' "$T/tmuxlog" > "$T/tb/tmux"; chmod +x "$T/tb/tmux"
    export PATH="$T/tb:$PATH"
    # a box that keeps its transcript fresh while $T/active exists, then goes quiet
    cat > "$HOME/.local/bin/airlock" <<S
#!/bin/bash
sid=\$(printf '%s\n' "\$@" | sed -n '/^--session-id\$/{n;p;}')
d="$HOME/.claude/projects/-wh-chat"; mkdir -p "\$d"
while [ -e "$T/active" ]; do echo x >> "\$d/\$sid.jsonl"; sleep 0.5; done
sleep 60 & wait
S
    chmod +x "$HOME/.local/bin/airlock"
    touch "$T/active"
    setsid bash "$REPO/agents/lib/web-session-run" main >/dev/null 2>&1 & runner=$!
    sleep 6
    kill -0 "$runner" || { echo "ended while active"; return 1; }
    rm "$T/active"
    for _ in $(seq 120); do kill -0 "$runner" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$runner" 2>/dev/null; then kill -HUP "$runner"; echo "not ended when idle"; return 1; fi
    grep -q '"result":"agent-web ended (idle)"' "$T/q/log/agent-web/stages.jsonl" || { cat "$T/q/log/agent-web/stages.jsonl"; return 1; }
    grep -q 'display-message .*this chat ends in' "$T/tmuxlog"
}

@test "the interactive session: a box that ignores the hangup is stopped by its container, then the record; Ctrl-C at a prompt doesn't lose it" {
    export AGENTS_WEB_IDLE_POLL=1 AGENTS_WEB_PREV_WAIT=2 AGENTS_WEB_STOP_GRACE=2 HOME="$T/wh" XDG_RUNTIME_DIR="$T/run" AGENTS_WEB_LIB="$RENDER/srv/agent-web/lib" AGENTS_WEB_QUEUE="$T/q"
    mkdir -p "$HOME/.local/bin" "$HOME/chat" "$XDG_RUNTIME_DIR" "$T/q/log/agent-web/transcripts" "$T/tb"
    printf '#!/bin/bash\nexit 1\n' > "$T/tb/tmux"
    # podman: lists the box while it lives (as its container would be), stop kills it
    cat > "$T/tb/podman" <<S
#!/bin/bash
alive() { p=\$(cat "$T/boxpid" 2>/dev/null); [ -n "\$p" ] && kill -0 "\$p" 2>/dev/null; }
case "\$1" in
    ps) alive && printf 'c0ffee0c0ffee\\nd00dd00dd00d\\n' ;;
    inspect) alive && printf 'c0ffee0c0ffee ["claude","--remote-control","--name","agent-web","--session-id","%s"]\\n' "\$(cat "$T/boxsid")"
             # a restarted chat of the same name (appearing once this one runs): another run's
             # box, never this one's to stop
             alive && echo 'd00dd00dd00d ["claude","--remote-control","--name","agent-web","--session-id","another-run"]' ;;
    stop) echo "stop \$*" >> "$T/podmanlog"; kill -KILL "\$(cat "$T/boxpid")" ;;
esac
S
    chmod +x "$T/tb/tmux" "$T/tb/podman"; export PATH="$T/tb:$PATH"
    # a box that ignores the hangup, as the launcher waiting on podman does
    printf '#!/bin/bash\ntrap "" HUP\nprintf "%%s\\n" "$@" | sed -n "/^--session-id$/{n;p;}" > "%s"\necho $$ > "%s"\nwhile :; do sleep 1; done\n' "$T/boxsid" "$T/boxpid" > "$HOME/.local/bin/airlock"; chmod +x "$HOME/.local/bin/airlock"
    setsid bash "$REPO/agents/lib/web-session-run" main >/dev/null 2>&1 & runner=$!
    for _ in $(seq 50); do [ -s "$T/boxpid" ] && break; sleep 0.1; done
    sleep 0.3; kill -HUP "$runner"
    for _ in $(seq 100); do kill -0 "$runner" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$runner" 2>/dev/null; then kill -KILL -- -"$runner"; echo "not ended"; return 1; fi
    grep -q 'stop -t 10 c0ffee0c0ffee' "$T/podmanlog"
    if grep -q d00dd00dd00d "$T/podmanlog"; then echo "stopped another run's box"; return 1; fi
    grep -q '"result":"agent-web ended (stop)"' "$T/q/log/agent-web/stages.jsonl"
    # Ctrl-C (SIGINT to the pane's foreground group): the box ends, the runner writes the record
    rm -f "$T/boxpid" "$T/q/log/agent-web/stages.jsonl"
    printf '#!/bin/bash\necho $$ > "%s"\nsed -n "s/^SigIgn:[[:space:]]*//p" /proc/self/status > "%s"\nsleep 30 & wait\n' "$T/boxpid" "$T/boxign" > "$HOME/.local/bin/airlock"
    # started as tmux starts a pane: its own session, no signal ignored (a bats background job
    # starts with INT ignored, which bash can never reset)
    python3 -c 'import os, signal, sys
for s in (signal.SIGINT, signal.SIGQUIT): signal.signal(s, signal.SIG_DFL)
os.setsid(); os.execvp("bash", ["bash"] + sys.argv[1:])' "$REPO/agents/lib/web-session-run" main >/dev/null 2>&1 & runner=$!
    for _ in $(seq 50); do [ -s "$T/boxpid" ] && break; sleep 0.1; done
    sleep 0.3; kill -INT -- -"$runner"
    for _ in $(seq 50); do kill -0 "$runner" 2>/dev/null || break; sleep 0.1; done
    # the box started with INT and QUIT at their defaults (bash 5.3 kept INT ignored after trap -)
    if (( 0x$(cat "$T/boxign") & 0x6 )); then echo "the box started with INT or QUIT ignored: $(cat "$T/boxign")"; return 1; fi
    if kill -0 "$runner" 2>/dev/null; then kill -KILL -- -"$runner"; echo "runner hung after Ctrl-C"; return 1; fi
    grep -q '"result":"agent-web ended (exit)"' "$T/q/log/agent-web/stages.jsonl" || { echo "Ctrl-C lost the record"; return 1; }
}

@test "the interactive session waits for the previous box of its name; a running chat box keeps the workspace" {
    export AGENTS_WEB_IDLE_POLL=1 AGENTS_WEB_PREV_WAIT=2 HOME="$T/wh" XDG_RUNTIME_DIR="$T/run" AGENTS_WEB_LIB="$RENDER/srv/agent-web/lib" AGENTS_WEB_QUEUE="$T/q"
    mkdir -p "$HOME/.local/bin" "$HOME/chat" "$XDG_RUNTIME_DIR" "$T/q/log/agent-web/transcripts" "$T/tb"
    printf '#!/bin/bash\nexit 1\n' > "$T/tb/tmux"
    printf '#!/bin/bash\ncase "$1" in ps) cut -d" " -f1 "%s" 2>/dev/null ;; inspect) cat "%s" 2>/dev/null ;; esac\nexit 0\n' "$T/running" "$T/running" > "$T/tb/podman"
    chmod +x "$T/tb/tmux" "$T/tb/podman"; export PATH="$T/tb:$PATH"
    printf '#!/bin/bash\ntouch "%s"\n' "$T/started" > "$HOME/.local/bin/airlock"; chmod +x "$HOME/.local/bin/airlock"
    echo 'c1c1c1c1c1c1 ["claude","--remote-control","--name","agent-web","--session-id","x"]' > "$T/running"
    echo keep > "$HOME/chat/f"
    run bash "$REPO/agents/lib/web-session-run" main
    [[ "$output" == *"the previous agent-web box is still running"*"podman stop c1c1c1c1c1c1"* ]]; [ ! -e "$T/started" ]
    # a prompt line that merely mentions the name (one argument, quoted) is not a box of it
    echo 'c3c3c3c3c3c3 ["claude","--append-system-prompt","x\\n--name agent-web"]' > "$T/running"
    run bash "$REPO/agents/lib/web-session-run" main
    [ -e "$T/started" ]; rm -f "$T/started"
    # another chat's box (agent-web.b) running: this one starts, the workspace stays
    echo 'c2c2c2c2c2c2 ["claude","--remote-control","--name","agent-web.b","--session-id","y"]' > "$T/running"
    echo keep > "$HOME/chat/f"
    run bash "$REPO/agents/lib/web-session-run" main
    [ -e "$T/started" ]; [ -e "$HOME/chat/f" ]
}

@test "the interactive session: an active chat with a big transcript is not idle; a stale idle mark is not this chat's" {
    export AGENTS_WEB_IDLE=3 AGENTS_WEB_IDLE_WARN=1 AGENTS_WEB_IDLE_POLL=1 AGENTS_WEB_PREV_WAIT=2 HOME="$T/wh" XDG_RUNTIME_DIR="$T/run" AGENTS_WEB_LIB="$RENDER/srv/agent-web/lib" AGENTS_WEB_QUEUE="$T/q"
    mkdir -p "$HOME/.local/bin" "$HOME/chat" "$XDG_RUNTIME_DIR" "$T/q/log/agent-web/transcripts" "$T/tb"
    printf '#!/bin/bash\nexit 1\n' > "$T/tb/tmux"; chmod +x "$T/tb/tmux"; export PATH="$T/tb:$PATH"
    echo idle > "$XDG_RUNTIME_DIR/agent-web-main.why"
    cat > "$HOME/.local/bin/airlock" <<S
#!/bin/bash
sid=\$(printf '%s\n' "\$@" | sed -n '/^--session-id\$/{n;p;}')
d="$HOME/.claude/projects/-wh-chat"; mkdir -p "\$d"; head -c 52000000 /dev/zero > "\$d/\$sid.jsonl"
for _ in \$(seq 12); do echo x >> "\$d/\$sid.jsonl"; sleep 0.5; done
S
    chmod +x "$HOME/.local/bin/airlock"
    # its own session, as in a pane: an idle hangup goes to its group, never to bats'
    setsid bash "$REPO/agents/lib/web-session-run" main >/dev/null 2>&1 & runner=$!
    wait "$runner" || true
    grep -q '"result":"agent-web ended (exit)"' "$T/q/log/agent-web/stages.jsonl" || { cat "$T/q/log/agent-web/stages.jsonl"; return 1; }
}

@test "the chat's transcript copy takes only a regular, single-link file" {
    export AGENTS_WEB_IDLE_POLL=1 AGENTS_WEB_PREV_WAIT=2 HOME="$T/wh" XDG_RUNTIME_DIR="$T/run" AGENTS_WEB_LIB="$RENDER/srv/agent-web/lib" AGENTS_WEB_QUEUE="$T/q"
    mkdir -p "$HOME/.local/bin" "$HOME/chat" "$XDG_RUNTIME_DIR" "$T/q/log/agent-web/transcripts" "$T/tb"
    printf '#!/bin/bash\nexit 1\n' > "$T/tb/tmux"; chmod +x "$T/tb/tmux"; export PATH="$T/tb:$PATH"
    echo secret > "$HOME/creds"
    for kind in symlink hardlink; do
        cat > "$HOME/.local/bin/airlock" <<S
#!/bin/bash
sid=\$(printf '%s\n' "\$@" | sed -n '/^--session-id\$/{n;p;}')
mkdir -p "$HOME/.claude/projects/-wh-chat"
if [ $kind = symlink ]; then ln -s "$HOME/creds" "$HOME/.claude/projects/-wh-chat/\$sid.jsonl"; else ln "$HOME/creds" "$HOME/.claude/projects/-wh-chat/\$sid.jsonl"; fi
S
        chmod +x "$HOME/.local/bin/airlock"
        rm -f "$T/q/log/agent-web/transcripts/"*
        run bash "$REPO/agents/lib/web-session-run" main
        [ -e "$HOME/.claude/projects/-wh-chat" ] || { echo "the box never ran: $output"; return 1; }
        if grep -rqs secret "$T/q/log/agent-web/transcripts/"; then echo "$kind copied"; return 1; fi
    done
}

@test "the interactive session fails closed: no instructions, or a workspace that won't empty, and no box starts" {
    export AGENTS_WEB_IDLE_POLL=1 AGENTS_WEB_PREV_WAIT=2 HOME="$T/wh" XDG_RUNTIME_DIR="$T/run" AGENTS_WEB_QUEUE="$T/q"
    mkdir -p "$HOME/.local/bin" "$HOME/chat" "$XDG_RUNTIME_DIR" "$T/q/log/agent-web/transcripts" "$T/nolib" "$T/tb"
    printf '#!/bin/bash\ntouch "%s"\n' "$T/started" > "$HOME/.local/bin/airlock"; chmod +x "$HOME/.local/bin/airlock"
    printf '#!/bin/bash\nexit 1\n' > "$T/tb/tmux"; printf '#!/bin/bash\n' > "$T/tb/sleep"; chmod +x "$T/tb/tmux" "$T/tb/sleep"
    export PATH="$T/tb:$PATH"
    AGENTS_WEB_LIB="$T/nolib" run bash "$REPO/agents/lib/web-session-run" main
    [[ "$output" == *"no chat instructions"* ]]; [ ! -e "$T/started" ]
    mkdir -p "$HOME/chat/locked/inner"; touch "$HOME/chat/locked/inner/f"; chmod 0500 "$HOME/chat/locked/inner"
    AGENTS_WEB_LIB="$RENDER/srv/agent-web/lib" run bash "$REPO/agents/lib/web-session-run" main
    chmod 0700 "$HOME/chat/locked/inner"
    [[ "$output" == *"could not be emptied"* ]]; [ ! -e "$T/started" ]
}

@test "agent-web's and agent-guard's boxes: no project hooks, and the worker empties the box's memory before a run" {
    for u in agent-web agent-guard; do
        python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["allowManagedHooksOnly"] is True' "$REPO/agents/share/managed-settings-${u#agent-}.json"
    done
    grep -q 'box-memory' "$REPO/agents/lib/worker-common.sh"
}

@test "agent-web's and agent-guard's boxes share no memory between runs" {
    for u in agent-web agent-guard; do grep -qx 'AIRLOCK_SHARE_MEMORY=off' "$UC/$u.conf"; done
}

@test "agent web approve binds the approval to the held text it shows; retry clears old decisions" {
    op_stubs; web_queue
    req "$ID" q; printf '{"question": "held \033[31mtext"}' > "$Q/held/$ID.json"
    run "$O" web approve "$ID"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"approving exactly this request"* && "$output" == *'held \x1b[31mtext'* ]] || { echo "$output"; return 1; }
    [[ "$output" != *$'\e'* ]]
    [ "$(cat "$Q/decisions/$ID.approve")" = "sha256 $(sha256sum < "$Q/held/$ID.json" | cut -d' ' -f1)" ]
    : > "$Q/decisions/$ID.release"
    export HOME="$T/agenthome"; mkdir -p "$HOME"
    rm "$Q/held/$ID.json"           # the worker found it changed after the approval
    echo "{\"ts\":\"x\",\"user\":\"agent-web\",\"id\":\"$ID\",\"stage\":\"check\",\"result\":\"changed after alice approved it; not researched\",\"exit\":12}" >> "$Q/log/agent-web/stages.jsonl"
    run "$O" web retry "$ID"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$Q/decisions/$ID.approve" ]; [ -e "$Q/decisions/$ID.release" ]
}

@test "agent web ls and show never hang on a FIFO or follow a link an agent planted" {
    op_stubs; web_queue
    req "$ID" q
    I2=20261021T120001Z-bbbbbb; mkfifo "$Q/requests/$I2.json"
    echo "alice's secret" > "$T/alicefile"
    ln -s "$T/alicefile" "$Q/answers/$ID.md"
    run timeout 10 "$O" web ls
    [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
    [[ "$output" == *"$I2"*"(unreadable request)"* ]]
    run timeout 10 "$O" web show "$ID"
    [ "$status" -eq 0 ]; [[ "$output" != *"alice's secret"* ]]; [[ "$output" == *"(not a plain file)"* ]]
    rm "$Q/answers/$ID.md"; mkdir "$Q/quarantine/x"; ln -s "$Q/quarantine/x" "$Q/quarantine/$ID"; echo "alice's secret" > "$Q/quarantine/x/findings.json"
    run timeout 10 "$O" web show "$ID"
    [[ "$output" != *"alice's secret"* ]]
    run "$O" web show "../$ID"; [ "$status" -ne 0 ]; [[ "$output" == *"not an id"* ]]
}

@test "agent web ls: the gate's failures show too" {
    op_stubs; web_queue
    req "$ID" q
    echo "{\"ts\":\"x\",\"user\":\"agent-web\",\"id\":\"$ID\",\"stage\":\"publish\",\"result\":\"published\",\"exit\":0}" >> "$Q/log/agent-web/stages.jsonl"
    mkdir -p "$Q/log/agent-guard"
    echo "{\"ts\":\"x\",\"user\":\"agent-guard\",\"id\":\"$ID\",\"stage\":\"scan\",\"result\":\"failed, gave up\",\"exit\":2}" >> "$Q/log/agent-guard/stages.jsonl"
    run "$O" web ls; [[ "$output" == *"gate failed (scan: failed, gave up)"* ]] || { echo "$output"; return 1; }
    mkdir "$Q/quarantine/$ID"
    echo "{\"ts\":\"x\",\"user\":\"agent-guard\",\"id\":\"$ID\",\"stage\":\"release\",\"result\":\"alice's release failed, gave up\",\"exit\":2}" >> "$Q/log/agent-guard/stages.jsonl"
    run "$O" web ls; [[ "$output" == *"quarantined, release failed"* ]] || { echo "$output"; return 1; }
}

@test "agent web <name> attaches only to a running session; agent web new starts one; bad names and agent attach web refused" {
    op_stubs; web_queue
    REMOTE_OUT="" run "$O" web stauts
    [ "$status" -ne 0 ]; [[ "$output" == *"no agent-web session stauts is running (start one: agent web new stauts)"* ]]
    if grep -q "start agent-web-session" "$LOG"; then echo "a typo started a session"; return 1; fi
    REMOTE_OUT="" run "$O" web new research2
    grep -q "agent-web@ .*start agent-web-session@research2.service" "$LOG"
    run "$O" web new '../x'; [ "$status" -ne 0 ]
    run "$O" web 'a;b'; [ "$status" -ne 0 ]
    : > "$LOG"
    REMOTE_OUT="agent-web-session@main.service loaded active running x" run "$O" web restart
    grep -q "agent-web@ .*restart agent-web-session@main.service" "$LOG"
    if grep -q " agent@ .*restart" "$LOG"; then echo "restart reached agent's manager"; return 1; fi
    REMOTE_OUT="" run "$O" attach web; [ "$status" -ne 0 ]; [[ "$output" == *"agent web"* ]]
}

@test "agent web approve shows the request with everything outside ASCII escaped (nothing hidden); retry refuses what isn't failed" {
    op_stubs; web_queue
    req "$ID" q
    printf '{"question": "vega\\u009b10;10m qzx.io and \\u202ereversed"}' > "$Q/held/$ID.json"
    run "$O" web approve "$ID"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *'\u009b10;10m qzx.io'* && "$output" == *'\u202ereversed'* ]] || { echo "$output"; return 1; }
    rm "$Q/decisions/$ID.approve"
    run "$O" web retry "$ID"; [ "$status" -ne 0 ]; [[ "$output" == *"is held: nothing to retry"* ]]
    : > "$Q/decisions/$ID.reject"
    run "$O" web retry "$ID"; [ "$status" -ne 0 ]; [ -e "$Q/decisions/$ID.reject" ]
}

@test "every unit list agent asks for is untruncated (--full): the remote side has a terminal, systemctl would cut names" {
    n=$(grep -c 'octl list-units' "$REPO/agents/operator")
    [ "$n" -ge 3 ]
    [ "$(grep 'octl list-units' "$REPO/agents/operator" | grep -c -- ' --full ')" = "$n" ] || { grep 'octl list-units' "$REPO/agents/operator"; return 1; }
}


# ---- review fixes: ownership, cron/at, nft reloads, image dirs, the FIFO stage log ----------

@test "a file it would write that isn't its own is refused, never overwritten; nothing changes" {
    mkdir -p "$R/usr/local/bin"; echo '#!/bin/sh' > "$R/usr/local/bin/agent"      # someone else's tool
    run "$P" --confirm
    [ "$status" -ne 0 ]; [[ "$output" == *"paused, nothing changed"*"aren't its own"*"/usr/local/bin/agent"* ]] || { echo "$output"; return 1; }
    [ "$(cat "$R/usr/local/bin/agent")" = '#!/bin/sh' ]; [ ! -s "$LOG" ]
    # its own (its header) is fine to replace
    printf '#!/bin/sh\n# Rendered by airlock-agents-apply: old\n' > "$R/usr/local/bin/agent"
    run "$P" --confirm
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -q 'exec /usr/local/lib/airlock-agents/operator' "$R/usr/local/bin/agent"
}

@test "another drop-in for an agent user's manager or slice is refused (it could override the sandbox)" {
    mkdir -p "$R/etc/systemd/system/user@1101.service.d"; echo '[Service]' > "$R/etc/systemd/system/user@1101.service.d/10-old.conf"
    run "$P"
    [ "$status" -ne 0 ]; [[ "$output" == *"/etc/systemd/system/user@1101.service.d/10-old.conf"* ]]
    [ ! -s "$LOG" ]
}

@test "an existing directory keeps its mode; a missing one is made 0755" {
    mkdir -p "$R/etc/polkit-1/rules.d"; chmod 0750 "$R/etc/polkit-1/rules.d"
    run "$P" --confirm
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(/usr/bin/stat -c %a "$R/etc/polkit-1/rules.d")" = 750 ]
    [ "$(/usr/bin/stat -c %a "$R/etc/tmpfiles.d")" = 755 ]
}

@test "cron and at: an existing deny list gets each agent user once; none is created; an allow list naming one is refused" {
    run "$P" --confirm
    [ ! -e "$R/etc/cron.deny" ]         # never created (at would open to everyone)
    [ ! -e "$R/etc/at.deny" ]
    : > "$R/etc/cron.deny"; : > "$R/etc/at.deny"
    run "$P" --confirm
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    for f in cron at; do [ "$(sort "$R/etc/$f.deny" | tr '\n' ' ')" = "agent agent-guard agent-web " ]; done
    run "$P" --confirm
    for f in cron at; do [ "$(wc -l < "$R/etc/$f.deny")" = 3 ]; done
    echo agent-web > "$R/etc/cron.allow"
    run "$P" --confirm
    [ "$status" -ne 0 ]; [[ "$output" == *"/etc/cron.allow names agent-web"* ]] || { echo "$output"; return 1; }
}

@test "the nft file alone changing restarts its unit; the live table must hold every user's drop" {
    NFT_LOADED=1 run "$P" --confirm
    : > "$LOG"
    sed -i 's/subuid 1300000/subuid 1500000/' "$E/agents.conf"
    sed -i 's/^agent-guard:1300000:/agent-guard:1500000:/' "$R/etc/subuid" "$R/etc/subgid"
    NFT_LOADED=1 run "$P" --confirm
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qx 'systemctl restart airlock-agents-nft.service' "$LOG" || { echo "not restarted: $(cat "$LOG")"; return 1; }
    # and with it unchanged, the live table holding every drop is ok, a table missing one is not
    NFT_LOADED=1 run "$P" --check
    [[ "$output" == *"ok   the agents' nftables table is loaded with every user's drop"* ]] || { echo "$output"; return 1; }
    # the live table, apart from the installed file: guard's drop rule gone, its log rule still there
    grep -v '1500000.* counter drop' "$R/etc/airlock-agents.nft" > "$T/live.nft"
    NFT_LIVE="$T/live.nft" NFT_LOADED=1 run "$P" --check
    [[ "$output" == *"would: enable and (re)start airlock-agents-nft.service"* ]] || { echo "$output"; return 1; }
    cp "$R/etc/airlock-agents.nft" "$T/live.nft"
    NFT_LIVE="$T/live.nft" NFT_LOADED=1 run "$P" --check
    [[ "$output" == *"ok   the agents' nftables table is loaded with every user's drop"* ]]
    u="$RENDER/etc/systemd/system/airlock-agents-nft.service"
    grep -qx 'ReloadPropagatedFrom=nftables.service' "$u"
    grep -qx 'ExecReload=/usr/sbin/nft -f /etc/airlock-agents.nft' "$u"
    grep -qx 'Before=user@1100.service user@1101.service user@1102.service ' "$u"
}

@test "/var/lib/<user> that is a link or holds a non-file image is refused before anything changes" {
    mkdir -p "$R/var/lib" "$T/elsewhere"; ln -s "$T/elsewhere" "$R/var/lib/agent-web"
    run "$P" --confirm
    [ "$status" -ne 0 ]; [[ "$output" == *"/var/lib/agent-web is not a plain directory"* ]]
    [ ! -s "$LOG" ]
}

@test "the queue's lib/ holds only what is rendered: anything else pauses the rollout, untouched" {
    fake_queue_state
    echo stale > "$R/srv/agent-web/lib/old_tool.py"
    run "$P" --confirm
    [ "$status" -eq 1 ]; [[ "$output" == *"/srv/agent-web/lib/old_tool.py is not the toolkit's"* ]] || { echo "$output"; return 1; }
    [ -f "$R/srv/agent-web/lib/old_tool.py" ]
}

@test "an own file changed or removed by hand since apply installed it pauses the rollout; a site change is installed" {
    run "$P" --confirm
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run "$P" --confirm; [ "$status" -eq 0 ]                         # converged
    echo "# local edit" >> "$R/etc/profile.d/airlock-agents.sh"
    rm "$R/etc/systemd/system/home-agent\x2dguard.mount"
    run "$P" --confirm
    [ "$status" -eq 1 ]
    [[ "$output" == *"/etc/profile.d/airlock-agents.sh was changed since apply installed it"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"home-agent\x2dguard.mount was removed since apply installed it"* ]]
    grep -q "local edit" "$R/etc/profile.d/airlock-agents.sh"              # left as found
}

# site_ruleset: a live ruleset as `nft -n list ruleset` prints it, the site's own output chain
# dropping each agent user (and, as on a host, the toolkit's own table too)
site_ruleset() {
    export NFT_RULESET="$T/ruleset"
    cat > "$NFT_RULESET" <<'EOF'
table inet filter {
	chain input {
		type filter hook input priority filter; policy drop;
	}
	chain output {
		type filter hook output priority filter; policy accept;
		meta skuid { 1100, 1100000-1165535 } limit rate 10/minute burst 20 packets log prefix "site-drop: " level info
		meta skuid { 1100, 1100000-1165535 } counter packets 0 bytes 0 drop comment "agent"
		meta skuid { 1101, 1200000-1265535 } counter packets 3 bytes 180 drop comment "agent-web"
		meta skuid { 1102, 1300000-1365535 } counter packets 0 bytes 0 drop comment "agent-guard"
	}
}
EOF
}

@test "a part managed elsewhere is never written, and its own copy is withdrawn" {
    run "$P" --confirm; [ "$status" -eq 0 ]
    [ -f "$R/etc/airlock-agents.nft" ]; [ -f "$R/etc/profile.d/airlock-agents.sh" ]
    printf 'external nftables profile\n' >> "$E/agents.conf"
    : > "$LOG"
    site_ruleset
    run "$P" --confirm
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$R/etc/airlock-agents.nft" ]; [ ! -e "$R/etc/profile.d/airlock-agents.sh" ]
    grep -qx 'systemctl disable --now airlock-agents-nft.service' "$LOG"
    [[ "$output" == *"nftables is managed elsewhere"* ]]
    # --render still shows what the site must provide
    "$P" --render "$T/r2" >/dev/null
    [ -f "$T/r2/external/etc/airlock-agents.nft" ]
    [ ! -e "$T/r2/etc/airlock-agents.nft" ]
    # and a file of the site's own at one of those paths is left alone
    echo '# the site' > "$R/etc/profile.d/airlock-agents.sh"
    run "$P" --confirm; [ "$status" -eq 0 ]
    [ "$(cat "$R/etc/profile.d/airlock-agents.sh")" = '# the site' ]
}

@test "accept: a finding the operator accepts no longer pauses; unknown ones are refused" {
    mkdir -p "$R/etc/systemd/system/user@.service.d"; : > "$R/etc/systemd/system/user@.service.d/90-site.conf"
    run "$P"; [ "$status" -eq 1 ]
    printf 'accept generic-dropins\n' >> "$E/agents.conf"
    run "$P"; [[ "$output" != *"paused"* ]] || { echo "$output"; return 1; }
    printf 'accept everything\n' >> "$E/agents.conf"
    run "$P"; [ "$status" -ne 0 ]; [[ "$output" == *"unknown accept 'everything'"* ]]
}

@test "a user's missing claude-airlock config is written from the default; an existing one is kept" {
    rm "$E/agent-guard.conf"
    run "$P" --confirm
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qx 'AIRLOCK_EGRESS_PROXY=/run/airlock-envoy/agent-guard/agent-guard-anthropic.sock' "$E/agent-guard.conf"
    # an agent config of the site's that doesn't mount the queue pauses the rollout, unchanged
    echo "# mine" > "$E/agent.conf"
    run "$P" --confirm
    [ "$status" -eq 1 ]; [[ "$output" == *"paused, nothing changed"*"agent.conf doesn't mount the queue"* ]]
    [ "$(cat "$E/agent.conf")" = "# mine" ]
}

@test "a command name that shadows a system tool is refused" {
    mkdir -p "$R/usr/bin"; : > "$R/usr/bin/agent"
    run "$P"
    [ "$status" -ne 0 ]; [[ "$output" == *"would shadow /usr/bin/agent"* ]]
}

@test "web ls never hangs on a FIFO a worker user left as its stage log" {
    op_stubs; web_queue
    req 20261021T120001Z-aaaaa1 "a question"
    mkdir -p "$Q/log/agent-web"; mkfifo "$Q/log/agent-web/stages.jsonl"
    run timeout 10 "$O" web ls
    [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
    [[ "$output" == *"20261021T120001Z-aaaaa1  queued"* ]]
}

@test "a deny file without a final newline keeps its last entry; the agents are each on a line of their own" {
    printf 'olduser' > "$R/etc/cron.deny"
    run "$P" --confirm
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(cat "$R/etc/cron.deny")" = "$(printf 'olduser\nagent\nagent-web\nagent-guard')" ]
}

@test "the queue, its lib/ or the inbox as a link is refused before anything is written there" {
    mkdir -p "$R/srv" "$T/victim"; echo keep > "$T/victim/keep.txt"
    ln -s "$T/victim" "$R/srv/agent-web"
    run "$P" --confirm
    [ "$status" -ne 0 ]; [[ "$output" == *"/srv/agent-web is not a plain directory"* ]]
    [ -f "$T/victim/keep.txt" ]; [ "$(ls "$T/victim")" = keep.txt ]
    rm "$R/srv/agent-web"; mkdir -p "$R/srv/agent-web"; ln -s "$T/victim" "$R/srv/agent-web/lib"
    run "$P" --confirm
    [ "$status" -ne 0 ]; [[ "$output" == *"/srv/agent-web/lib is not a plain directory"* ]]
    [ "$(ls "$T/victim")" = keep.txt ]
}

@test "/var/lib/<user> holding anything but the image is refused (another program's state)" {
    mkdir -p "$R/var/lib/agent-guard"; : > "$R/var/lib/agent-guard/state.db"
    run "$P"
    [ "$status" -ne 0 ]; [[ "$output" == *"/var/lib/agent-guard holds more than a home image"* ]]
}

@test "a unit file replacing an agent's manager or slice is refused; generic drop-ins are named" {
    mkdir -p "$R/etc/systemd/system/user@.service.d"; : > "$R/etc/systemd/system/user@.service.d/90-site.conf"
    run "$P"
    [ "$status" -eq 1 ]; [[ "$output" == *"/etc/systemd/system/user@.service.d/90-site.conf applies to every user's manager"* ]] || { echo "$output"; return 1; }
    rm "$R/etc/systemd/system/user@.service.d/90-site.conf"
    : > "$R/etc/systemd/system/user@1101.service"
    run "$P"
    [ "$status" -ne 0 ]; [[ "$output" == *"/etc/systemd/system/user@1101.service replaces the system's unit"* ]]
}

@test "the toolkit's checksums: recorded without listing themselves; a fresh install passes, a changed file pauses" {
    mkdir -p "$R/usr/local/lib/airlock-agents" "$R/usr/local/share/airlock-agents/box" "$R/usr/local/sbin"
    cp "$REPO/agents/operator" "$R/usr/local/lib/airlock-agents/operator"
    cp "$REPO/agents/box/web.py" "$R/usr/local/share/airlock-agents/box/web.py"
    cp "$REPO/agents/airlock-agents-apply" "$R/usr/local/sbin/airlock-agents-apply"
    run "$P" --record-toolkit
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run "$P" --record-toolkit                                   # a reinstall: the old list is there now
    s="$R/usr/local/share/airlock-agents/TOOLKIT.sha256"
    grep -q "  /usr/local/share/airlock-agents/box/web.py$" "$s" && grep -q "  /usr/local/sbin/airlock-agents-apply$" "$s"
    run grep -c 'TOOLKIT' "$s"; [ "$output" = 0 ]
    grep -q '  /usr/local/lib/airlock-agents/operator$' "$s"
    run "$P"
    [[ "$output" != *"toolkit files differ"* ]] || { echo "$output"; return 1; }
    echo '# changed' >> "$R/usr/local/lib/airlock-agents/operator"
    run "$P"
    [ "$status" -eq 1 ]; [[ "$output" == *"toolkit files differ from the install"*"operator"* ]]
}

@test "external nftables: the toolkit's own table, or a drop outside an output chain, is not the site's drop" {
    printf 'external nftables\n' >> "$E/agents.conf"
    export NFT_RULESET="$T/ruleset"
    # only the toolkit's own table (still loaded from before)
    { echo 'table inet airlock-agents {'; echo '	chain output {'; echo '		type filter hook output priority filter; policy accept;'
      echo '		meta skuid { 1100, 1100000-1165535 } counter packets 0 bytes 0 drop'; echo '	}'; echo '}'; } > "$NFT_RULESET"
    run "$P"
    [ "$status" -eq 1 ]; [[ "$output" == *"chain drops agent (uid 1100"* ]] || { echo "$output"; return 1; }
    # a drop in a chain no hook reaches
    { echo 'table inet filter {'; echo '	chain spare {'; echo '		meta skuid { 1100, 1100000-1165535 } counter packets 0 bytes 0 drop'; echo '	}'; echo '}'; } > "$NFT_RULESET"
    run "$P"
    [ "$status" -eq 1 ]; [[ "$output" == *"chain drops agent (uid 1100"* ]]
    # an output chain, but: an ip table (IPv6 gets through), an accept or jump before the drop, a dormant table
    out() { printf 'table %s filter {\n%b\tchain output {\n\t\ttype filter hook output priority filter; policy accept;\n%b\t\tmeta skuid { 1100, 1100000-1165535 } counter packets 0 bytes 0 drop\n\t}\n}\n' "$1" "$2" "$3" > "$NFT_RULESET"; }
    for c in "ip||" "inet||\t\toifname \"lo\" accept\n" "inet||\t\tct state established,related accept\n" "inet||\t\tlog prefix \" comment \" accept\n" "inet||\t\tjump site\n" "inet||\t\tqueue num 0 bypass\n" "inet|\tflags dormant\n|"; do
        IFS='|' read -r fam fl pre <<< "$c"
        out "$fam" "$fl" "$pre"
        run "$P"
        [ "$status" -eq 1 ] && [[ "$output" == *"chain drops agent (uid 1100"* ]] || { echo "counted ($c): $(cat "$NFT_RULESET")"; return 1; }
    done
    # a match in front of the uid narrows the drop: not counted
    for pre in 'oifname "eth0" ' 'ip daddr 8.8.8.8 ' 'limit rate 1/minute '; do
        printf 'table inet filter {\n\tchain output {\n\t\ttype filter hook output priority filter; policy accept;\n\t\t%smeta skuid { 1100, 1100000-1165535 } counter packets 0 bytes 0 drop\n\t}\n}\n' "$pre" > "$NFT_RULESET"
        run "$P"
        [ "$status" -eq 1 ] && [[ "$output" == *"chain drops agent (uid 1100"* ]] || { echo "counted: $pre"; return 1; }
    done
    # the same in a working inet table counts (a log rule before it is fine, whatever its comment says)
    out inet "" '\t\tmeta skuid 1100 log prefix "x" comment "log, then accept nothing"\n'
    run "$P"
    [[ "$output" != *"chain drops agent (uid 1100"* ]] || { echo "$output"; return 1; }
}

@test "external: a site's own copy at a part's path is never removed, even where the toolkit's copy was" {
    run "$P" --confirm; [ "$status" -eq 0 ]
    printf 'external nftables\n' >> "$E/agents.conf"; site_ruleset
    "$P" --render "$T/r3" >/dev/null
    cp "$T/r3/external/etc/airlock-agents.nft" "$R/etc/airlock-agents.nft"     # the site installs the rendered copy
    run "$P" --confirm
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$R/etc/airlock-agents.nft" ]; grep -q 'for the site to install and keep' "$R/etc/airlock-agents.nft"
    run "$P" --confirm; [ "$status" -eq 0 ]; [ -f "$R/etc/airlock-agents.nft" ]
}

@test "external nftables: the rendered copy, loaded as the site's only firewall, passes the check" {
    printf 'external nftables\n' >> "$E/agents.conf"
    "$P" --render "$T/r4" >/dev/null
    export NFT_RULESET="$T/ruleset"
    # roughly as nft lists it: the table block of the file, with counters
    sed -n '/^table .* {$/,/^}$/p' "$T/r4/external/etc/airlock-agents.nft" | sed 's/counter drop/counter packets 0 bytes 0 drop/' > "$NFT_RULESET"
    grep -q '^table inet airlock-agents-site {' "$NFT_RULESET"
    run grep -c 'table inet airlock-agents ' "$T/r4/external/etc/airlock-agents.nft"; [ "$output" = 0 ]
    run "$P"
    [[ "$output" != *"chain drops"* ]] || { echo "$output"; cat "$NFT_RULESET"; return 1; }
}

@test "a run that stops before its reloads leaves them pending; the next run does them" {
    cat > "$T/bin/systemctl" <<'S'
#!/bin/bash
case "$1" in is-enabled|is-active) [ -n "${NFT_LOADED:-}" ]; exit ;; esac
echo "systemctl $*" >> "$LOG"
[ "$1" = daemon-reload ] && [ -n "${FAIL_RELOAD:-}" ] && exit 1
exit 0
S
    FAIL_RELOAD=1 run "$P" --confirm
    [ "$status" -ne 0 ]
    grep -qx reload "$E/.pending" && grep -qx nft "$E/.pending" && grep -qx user-units "$E/.pending" || { cat "$E/.pending"; return 1; }
    : > "$LOG"
    run "$P" --confirm
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qx 'systemctl daemon-reload' "$LOG"
    grep -q 'systemctl restart airlock-agents-nft.service' "$LOG"
    [ ! -e "$E/.pending" ]
    # a dry run neither records nor clears
    run "$P"; [ ! -e "$E/.pending" ]
}

@test "a running manager that hasn't read the changed user units: every run says to reload, --check fails, until it has" {
    run "$P" --confirm; [ "$status" -eq 0 ]
    [[ "$output" == *"next: agent reload (the agents' user units changed), then agent update"* ]] || { echo "$output"; return 1; }
    # the managers run, each with a session or worker loaded; UNREAD: those holding old units
    cat > "$T/bin/systemctl" <<'S'
#!/bin/bash
if [ "$1" = --user ]; then
    case "$4" in
        is-active) exit 0 ;;
        list-units) echo "${3%@}-session@k8s.main.service loaded active running x" ;;
        show) case " ${UNREAD:-} " in *" ${3%@} "*) echo yes ;; *) echo no ;; esac ;;
        *) echo "systemctl $*" >> "$LOG" ;;
    esac
    exit 0
fi
case "$1" in is-enabled) [ -n "${NFT_LOADED:-}" ]; exit ;; is-active) case "$3" in user@*) exit 0 ;; esac; [ -n "${NFT_LOADED:-}" ]; exit ;; esac
echo "systemctl $*" >> "$LOG"
S
    for i in 1 2; do
        UNREAD="agent agent-guard" run "$P" --confirm
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        [[ "$output" == *"next: agent reload (the user managers of agent agent-guard haven't read the agents' changed user units yet)"* ]] || { echo "$output"; return 1; }
    done
    # --check: said even when other drift ends the run first (a converged run then fails on it alone)
    UNREAD=agent-web run "$P" --check
    [ "$status" -eq 1 ] && [[ "$output" == *"of agent-web haven't read"* ]] || { echo "$output"; return 1; }
    run "$P" --check
    [[ "$output" != *"next:"* ]] || { echo "$output"; return 1; }
}

@test "clean(): NUL or a bidi control can't split a C1 or ESC sequence past the filter" {
    eval "$(sed -n '/^clean() {/,/^}/p' "$REPO/agents/operator")"
    out="$(printf 'a\xc2\x00\x9b31mb \x1b\xe2\x80\x8e[2Jc \xc2\xe2\x81\xa6\x9d52;c;x\x07d\n' | clean)"
    [ "$out" = "ab c d" ] || { printf '%s' "$out" | od -c; return 1; }
    # nor can a control between the bytes of a bidi control rebuild it
    out="$(printf 'x\xe2\x80\xc2\x9b\xaeevil\n' | clean)"
    [ "$out" = "xevil" ] || { printf '%s' "$out" | od -c; return 1; }
}

@test "external polkit: a rule of the site's must grant the operator a shell as each user; the toolkit's own doesn't count" {
    printf 'external polkit\n' >> "$E/agents.conf"
    run "$P"
    [ "$status" -eq 1 ]; [[ "$output" == *"no rule lets alice open a host shell as agent"* ]]
    mkdir -p "$R/etc/polkit-1/rules.d"
    printf 'polkit.addRule(function(action, subject) { if (action.id == "org.freedesktop.machine1.host-shell" && subject.user == "alice" && ["agent", "agent-web", "agent-guard"].indexOf(action.lookup("user")) >= 0) return polkit.Result.YES; });\n' > "$R/etc/polkit-1/rules.d/50-airlock-agents.rules"
    run "$P"                                                         # the site's own, at the toolkit's path: counted
    [[ "$output" != *"no rule lets alice"* ]] || { echo "$output"; return 1; }
    mv "$R/etc/polkit-1/rules.d/50-airlock-agents.rules" "$R/etc/polkit-1/rules.d/40-site.rules"
    run "$P"
    [[ "$output" != *"no rule lets alice"* ]] || { echo "$output"; return 1; }
}

@test "external polkit: the toolkit's own installed rule is never the site's grant" {
    run "$P" --confirm; [ "$status" -eq 0 ]
    [ -f "$R/etc/polkit-1/rules.d/50-airlock-agents.rules" ]
    printf 'external polkit\n' >> "$E/agents.conf"
    run "$P"
    [ "$status" -eq 1 ]; [[ "$output" == *"no rule lets alice open a host shell as agent"* ]] || { echo "$output"; return 1; }
}

@test "a user the last apply set up and agents.conf no longer has pauses (removing one is by hand)" {
    run "$P" --confirm; [ "$status" -eq 0 ]
    sed -i '/^web /d; /^guard /d' "$E/agents.conf"
    run "$P" --confirm
    [ "$status" -eq 1 ]; [[ "$output" == *"agent-web was set up by an earlier apply"* && "$output" == *"agent-guard was set up"* ]]
    # once the users are gone (removed by hand), the apply withdraws their files
    sed -i '/^agent-web:/d; /^agent-guard:/d' "$PASSWD"
    run "$P" --confirm
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$R/etc/systemd/user/agent-web-worker.service" ]
}

@test "a run that stops half-way leaves a true manifest: the rerun finishes without pausing on its own files" {
    chmod 0555 "$R/etc" 2>/dev/null; mkdir -p "$R/usr/local/bin"; chmod 0555 "$R/usr/local/bin"
    run "$P" --confirm                                                # dies at the first file it can't write
    chmod 0755 "$R/etc" "$R/usr/local/bin"
    run "$P" --confirm
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run "$P" --confirm; [ "$status" -eq 0 ]; [[ "$output" == *"nothing to change"* || "$output" == *"done"* ]]
}

@test "a lib file an earlier toolkit installed and this one doesn't ship is removed, not a pause" {
    fake_queue_state
    run "$P" --confirm; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    echo old > "$R/srv/agent-web/lib/old.py"
    echo "/srv/agent-web/lib/old.py $(sha256sum < "$R/srv/agent-web/lib/old.py" | cut -d' ' -f1)" >> "$E/.installed"
    run "$P" --confirm
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$R/srv/agent-web/lib/old.py" ]
}

@test "--render wants a new directory (it never writes into one that exists)" {
    mkdir -p "$T/r4/etc"; ln -s "$T/victim" "$T/r4/etc/claude-airlock"; mkdir -p "$T/victim"
    run "$P" --render "$T/r4"
    [ "$status" -ne 0 ]; [[ "$output" == *"wants a new directory"* ]]
    [ -z "$(ls -A "$T/victim")" ]
}

@test "clipboard on: the sessions' tmux passes Claude's copy on; off (the default) doesn't" {
    grep -q -- '-f /usr/local/share/airlock-agents/tmux.conf ' "$RENDER/etc/systemd/user/agent-session@.service"
    printf 'clipboard on\n' >> "$E/agents.conf"
    "$P" --render "$T/r5" >/dev/null
    grep -q -- '-f /usr/local/share/airlock-agents/tmux-clipboard.conf ' "$T/r5/etc/systemd/user/agent-session@.service"
    grep -q -- '-f /usr/local/share/airlock-agents/tmux-clipboard.conf ' "$T/r5/etc/systemd/user/agent-web-session@.service"
}

@test "subordinate ids that are someone's real id pause; so does a directory service until its ranges are checked" {
    echo "dom:x:1100005:1100005::/home/dom:/bin/bash" >> "$PASSWD"
    run "$P"
    [ "$status" -eq 1 ]; [[ "$output" == *"user dom has a uid inside agent's subordinate ids"* ]] || { echo "$output"; return 1; }
    : > "$PASSWD"
    mkdir -p "$R/etc/sssd"; : > "$R/etc/sssd/sssd.conf"
    run "$P"
    [ "$status" -eq 1 ]; [[ "$output" == *"users come from a directory service"* ]]
    rm "$R/etc/sssd/sssd.conf"
    printf 'passwd: files winbind\n' > "$R/etc/nsswitch.conf"
    run "$P"
    [ "$status" -eq 1 ]; [[ "$output" == *"users come from a directory service"* ]]
    printf 'passwd:sss files\n' > "$R/etc/nsswitch.conf"
    run "$P"
    [ "$status" -eq 1 ]; [[ "$output" == *"users come from a directory service"* ]]
    printf 'passwd: files systemd  # not sss\n' > "$R/etc/nsswitch.conf"
    run "$P"
    [[ "$output" != *"users come from a directory service"* ]] || { echo "$output"; return 1; }
    printf 'passwd: files ldap\n' > "$R/etc/nsswitch.conf"
    printf 'accept id-ranges\n' >> "$E/agents.conf"
    run "$P"
    [[ "$output" != *"users come from a directory service"* ]]
}

@test "the session unit: its start limit is in [Unit], where systemd reads it" {
    f="$RENDER/etc/systemd/user/agent-session@.service"
    sect="$(awk '/^\[/ { s = $0 } /^StartLimit(IntervalSec|Burst)=/ { print s ":" $0 }' "$f")"
    [ "$sect" = "$(printf '[Unit]:StartLimitIntervalSec=600\n[Unit]:StartLimitBurst=5')" ] || { echo "$sect"; return 1; }
}

@test "the workers: no start limit, and every timer run puts a failed queue watch back" {
    for u in agent-web agent-guard; do
        f="$RENDER/etc/systemd/user/$u-worker.service"
        grep -qx 'StartLimitIntervalSec=0' "$f"
        grep -qx "ExecStartPre=-/usr/bin/systemctl --user reset-failed $u-worker.path" "$f"
        grep -qx "ExecStartPre=-/usr/bin/systemctl --user --no-block start $u-worker.path" "$f"
    done
}

@test "a failed queue watch: --check reports it, --confirm resets and starts it, a running one is left alone" {
    run "$P" --confirm; [ "$status" -eq 0 ]
    # the managers run; agent-web's path unit failed, everything else of theirs is active
    cat > "$T/bin/systemctl" <<'S'
#!/bin/bash
if [ "$1" = --user ]; then
    [ "$4" = is-active ] && { [ "$3" = agent-web@ ] && [ "$6" = agent-web-worker.path ] && exit 3; exit 0; }
    case "$4" in list-units|show) exit 0 ;; esac   # read-only queries
    echo "systemctl $*" >> "$LOG"; exit 0
fi
case "$1" in is-enabled) [ -n "${NFT_LOADED:-}" ]; exit ;; is-active) case "$3" in user@*) exit 0 ;; esac; [ -n "${NFT_LOADED:-}" ]; exit ;; esac
echo "systemctl $*" >> "$LOG"
S
    : > "$LOG"
    run "$P" --check
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *"would: reset and start agent-web's agent-web-worker.path"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"ok   agent-guard: agent-guard-worker.path active"* ]]
    run grep -c -- '--user' "$LOG"; [ "$output" = 0 ]
    run "$P" --confirm
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qx 'systemctl --user -M agent-web@ reset-failed agent-web-worker.path' "$LOG"
    grep -qx 'systemctl --user -M agent-web@ start agent-web-worker.path' "$LOG"
    run grep -c "agent-guard@" "$LOG"; [ "$output" = 0 ] || { cat "$LOG"; return 1; }
}

@test "agent _complete: only well-formed session names and queue ids, states cleaned, filtered per verb" {
    op_stubs; web_queue
    REMOTE_OUT=$'agent-session@proj.main.service loaded active running a\nagent-session@ev;\$(x).y.service loaded active running b\nagent-session@o\e]52;c;eA==\ak.z.service loaded active running e\nagent-session@p2.review.service loaded inactive dead c\nagent-session@nodot.service loaded active running d' \
        run "$O" _complete sessions
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # checked raw: the names with an OSC in them, or ; and $(, are dropped, not cleaned into others
    [ "$output" = "$(printf 'proj.main\tactive/running\np2.review\tinactive/dead')" ] || { printf '%s' "$output" | od -c | head; return 1; }
    req 20261021T120001Z-aaaaa1 'held one';     : > "$Q/held/20261021T120001Z-aaaaa1.json"
    req 20261021T120002Z-aaaaa2 'answered one'; : > "$Q/answers/20261021T120002Z-aaaaa2.md"
    req 20261021T120003Z-aaaaa3 'quarantined';  mkdir "$Q/quarantine/20261021T120003Z-aaaaa3"
    mkdir -p "$Q/log/agent-guard"   # (the guard logs the quarantine, as guard-worker does)
    echo '{"ts":"x","user":"agent-guard","id":"20261021T120003Z-aaaaa3","stage":"release","result":"quarantined","exit":3}' >> "$Q/log/agent-guard/stages.jsonl"
    req 20261021T120004Z-aaaaa4 'gave up'
    echo '{"ts":"x","user":"agent-web","id":"20261021T120004Z-aaaaa4","stage":"check","result":"failed, gave up","exit":2}' >> "$Q/log/agent-web/stages.jsonl"
    printf '{}' > "$Q/requests/not-an-id.json"
    run "$O" _complete ids approve
    [ "$output" = "$(printf '20261021T120001Z-aaaaa1\theld')" ] || { echo "approve: $output"; return 1; }
    run "$O" _complete ids release
    [ "$output" = "$(printf '20261021T120003Z-aaaaa3\tquarantined')" ] || { echo "release: $output"; return 1; }
    run "$O" _complete ids retry
    [ "$output" = "$(printf '20261021T120004Z-aaaaa4\tfailed (check: failed, gave up)')" ] || { echo "retry: $output"; return 1; }
    run "$O" _complete ids show
    [ "$(printf '%s\n' "$output" | wc -l)" = 4 ]
    [ "$(printf '%s\n' "$output" | head -1 | cut -f1)" = 20261021T120004Z-aaaaa4 ]   # newest first
    [[ "$output" != *not-an-id* ]]
    run "$O" _complete nonsense
    [ "$status" -ne 0 ]
    # a flood of newer queued requests doesn't push the held one out of approve's 50
    for i in $(seq 10 69); do req "20991231T0000${i}Z-ffffff" flood; done
    run "$O" _complete ids approve
    [ "$output" = "$(printf '20261021T120001Z-aaaaa1\theld')" ] || { echo "approve after a flood: $output"; return 1; }
    run "$O" _complete ids show
    [ "$(printf '%s\n' "$output" | wc -l)" = 50 ]
    # a flood the size that once buried them (thousands of requests): retry and release still find
    # theirs, quickly (they come from the logs and quarantine/, not from requests/)
    for i in $(seq 1000 2999); do : > "$Q/requests/20991231T00${i}Z-ffffff.json"; done
    SECONDS=0
    run "$O" _complete ids retry
    [ "$output" = "$(printf '20261021T120004Z-aaaaa4\tfailed (check: failed, gave up)')" ] || { echo "retry after a flood: $output"; return 1; }
    [ "$SECONDS" -le 3 ] || { echo "retry took ${SECONDS}s"; return 1; }
    # release: not one whose release the guard gave up on (web release refuses it)
    mkdir -p "$Q/log/agent-guard"
    echo '{"ts":"x","user":"agent-guard","id":"20261021T120003Z-aaaaa3","stage":"release","result":"release failed, gave up","exit":2}' >> "$Q/log/agent-guard/stages.jsonl"
    run "$O" _complete ids release
    [ -z "$output" ] || { echo "release: $output"; return 1; }
    # an id's last stage line counts even when it doesn't fit the pattern (as web ls reads it)
    echo '{"ts":"x","user":"agent-web","id":"20261021T120004Z-aaaaa4","stage":"research","result":"Started"}' >> "$Q/log/agent-web/stages.jsonl"
    run "$O" _complete ids retry
    # (aaaaa4 no longer; aaaaa3, whose release failed above, is retryable now)
    [ "$output" = "$(printf '20261021T120003Z-aaaaa3\tquarantined, release failed (release: release failed, gave u')" ] || { echo "retry after an odd line: $output"; return 1; }
    [[ "$("$O" web ls)" == *"20261021T120004Z-aaaaa4  queued"* ]]
}

@test "agent _complete ids: a worker's own floods (a big stage log, junk in held/) neither bury the real ids nor stall a Tab" {
    op_stubs; web_queue
    req 20261021T120001Z-aaaaa1 held; : > "$Q/held/20261021T120001Z-aaaaa1.json"
    req 20261021T120004Z-aaaaa4 failed
    python3 - "$Q" <<'P'
import sys
q = sys.argv[1]
with open(q + "/log/agent-web/stages.jsonl", "w") as f:
    for i in range(100000):
        f.write('{"ts":"x","user":"agent-web","id":"20990101T%06dZ-ffffff","stage":"check","result":"failed, gave up","exit":2}\n' % i)
    # fields apart, and two ids on one line: read as last_stage reads them
    f.write('{"id":"20261021T120004Z-aaaaa4","user":"agent-web","stage":"check","result":"failed, gave up"}\n')
for i in range(20000):
    open(q + "/held/20990101T%06dZ-eeeeee.json" % i, "w").close()
# the guard's log: millions of tiny lines (no id on them: they must cost nothing)
import os
os.makedirs(q + "/log/agent-guard", exist_ok=True)
with open(q + "/log/agent-guard/stages.jsonl", "wb") as f:
    f.write(b"a\n" * 5000000)
P
    for v in approve retry show; do
        SECONDS=0; out="$("$O" _complete ids "$v")"
        [ "$SECONDS" -le 2 ] || { echo "$v took ${SECONDS}s"; return 1; }
        eval "out_$v=\$out"
    done
    [ "$out_approve" = "$(printf '20261021T120001Z-aaaaa1\theld')" ] || { echo "approve: $out_approve"; return 1; }
    [ "$out_retry" = "$(printf '20261021T120004Z-aaaaa4\tfailed (check: failed, gave up)')" ] || { echo "retry: $out_retry"; return 1; }
    [[ "$("$O" web ls)" == *"20261021T120004Z-aaaaa4  failed (check: failed, gave up)"* ]]
    for v in release; do SECONDS=0; "$O" _complete ids "$v" >/dev/null; [ "$SECONDS" -le 2 ] || { echo "$v took ${SECONDS}s"; return 1; }; done
}

@test "agent web ls: a stage line is read whole, in any locale (a byte before it can't leak into the state)" {
    op_stubs; web_queue
    req 20261021T120005Z-aaaaa5 q
    printf 'x gave up \xff{"id":"20261021T120005Z-aaaaa5","stage":"check","result":"ok"}\n' >> "$Q/log/agent-web/stages.jsonl"
    for l in C C.UTF-8; do
        out="$(LANG=$l LC_ALL=$l "$O" web ls)"
        [[ "$out" == *"20261021T120005Z-aaaaa5  researching (check: ok)"* ]] || { echo "$l: $out"; return 1; }
    done
    run "$O" _complete ids retry
    [ -z "$output" ]
}

# A stand-in operator command for the completion scripts: `agent _complete <what> [verb]` answers
# with fixed names.
# completion_copies: the completion scripts with their two fixed paths pointed at the test's
# (the root copies have no knob for them)
completion_copies() {
    for sh in zsh bash; do
        # (and the test's own uid trusted as an owner, beside root: the stand-in and $T are the test's)
        sed -e "s#/etc/claude-airlock/agents/agents.env#$T/c.env#" -e "s#/usr/local/lib/airlock-agents/operator#$T/clib/operator#" \
            -e "s#^\(typeset -g \)\{0,1\}_airlock_agents_owners=0\$#&\\ $UID#" -e "s#_airlock_agents_owners=0\\ #_airlock_agents_owners='0 #" -e "/_airlock_agents_owners='0 /s#\$#'#" \
            "$REPO/agents/share/completion.$sh" > "$T/completion.$sh"
    done
}
completion_stub() {
    printf 'AGENTS_COMMAND=agent\n' > "$T/c.env"
    completion_copies
    export AIRLOCK_AGENTS_BINDIR="$T/clib"; mkdir -p "$AIRLOCK_AGENTS_BINDIR"; chmod 0755 "$AIRLOCK_AGENTS_BINDIR"
    cat > "$AIRLOCK_AGENTS_BINDIR/operator" <<'S'
#!/bin/bash
[ "$1" = _complete ] || exit 1
case "$2 ${3:-}" in
    "sessions ") printf 'proj.main\tactive/running\np2.review\tinactive/dead\n' ;;
    "web-sessions ") printf 'main\trunning\n' ;;
    "ids approve") printf '20261021T120001Z-aaaaa1\theld\n' ;;
    "ids show") printf '20261021T120001Z-aaaaa1\theld\n20261021T120002Z-aaaaa2\tanswered\n' ;;
    "ids retry") printf 'x$(touch %s)\tbad\nok-name\tfine\n*\tglob\n~root\ttilde\nc:d\tcolon\n' "$PWNED" ;;
esac
S
    export PWNED="$T/pwned"
    sed -i "s#\"\$PWNED\"#$PWNED#" "$AIRLOCK_AGENTS_BINDIR/operator"    # (the call gets a fresh environment)
    chmod 0755 "$AIRLOCK_AGENTS_BINDIR/operator"
    # the same name planted where an agent could write it: never run by a Tab
    mkdir -p "$T/agentdir"; printf '#!/bin/sh\ntouch %s\n' "$T/planted-ran" > "$T/agentdir/agent"; chmod +x "$T/agentdir/agent"
}

@test "zsh completion: registered for the site's command; sessions, web verbs and filtered ids offered" {
    command -v zsh >/dev/null || skip "no zsh"
    completion_stub
    cat > "$T/z.zsh" <<'Z'
compdef() { print -r -- "compdef $*" }
_describe() { local a=${@[-1]}; print -rl -- "${(@P)a}" }
_message() { print -r -- "message: $*" }
_values() { print -r -- "values: ${@[2,-1]}" }
source $T/completion.zsh
t() { words=("$@"); CURRENT=$#; _airlock_agents }
print '== top'; t agent ''
print '== attach'; t agent attach ''
print '== approve'; t agent web approve ''
print '== show'; t agent web show ''
print '== web'; t agent web ''
print '== login'; t agent web login ''
print '== retry'; t agent web retry ''
print '== typed path'; (cd $T/agentdir && t ./agent attach ''); true
Z
    run env AIRLOCK_AGENTS_ENV="$T/c.env" AIRLOCK_AGENTS_BINDIR="$AIRLOCK_AGENTS_BINDIR" PWNED="$PWNED" T="$T" REPO="$REPO" zsh -f "$T/z.zsh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qx 'compdef _airlock_agents agent' <<< "$output"
    grep -qx 'attach:join a session' <<< "$output"
    sed -n '/== attach/,/== approve/p' <<< "$output" | grep -qx 'proj.main:active/running'
    sed -n '/== attach/,/== approve/p' <<< "$output" | grep -qx 'p2.review:inactive/dead'
    [ "$(sed -n '/== approve/,/== show/p' <<< "$output" | grep -c 'T')" = 1 ]
    sed -n '/== approve/,/== show/p' <<< "$output" | grep -qx '20261021T120001Z-aaaaa1:held'
    sed -n '/== show/,/== web/p' <<< "$output" | grep -qx '20261021T120002Z-aaaaa2:answered'
    sed -n '/== web/,/== login/p' <<< "$output" | grep -qx 'main:running'
    grep -qx 'values: research gate chat' <<< "$output"
    # hostile names from the command are dropped, never run
    [ "$(sed -n '/== retry/,/== typed path/p' <<< "$output" | grep -v '^==')" = 'ok-name:fine' ] || { echo "$output"; return 1; }
    [ ! -e "$T/pwned" ]
    # a typed path never runs that file, nor offers names
    [ ! -e "$T/planted-ran" ]
    [ -z "$(sed -n '/== typed path/,$p' <<< "$output" | grep -v '^==')" ]
}

@test "completion runs only a command owned by root or the operator and writable by no one else" {
    command -v zsh >/dev/null || skip "no zsh"
    completion_stub
    chmod 0775 "$AIRLOCK_AGENTS_BINDIR/operator"
    run env T="$T" bash -c '
        source "$T/completion.bash"
        COMP_WORDS=(agent attach ""); COMP_CWORD=2; _airlock_agents; echo "[${COMPREPLY[*]}]"'
    [ "$output" = "[]" ] || { echo "$output"; return 1; }
    chmod 0755 "$AIRLOCK_AGENTS_BINDIR/operator"
    run env T="$T" bash -c '
        source "$T/completion.bash"
        COMP_WORDS=(agent attach ""); COMP_CWORD=2; _airlock_agents; echo "[${COMPREPLY[*]}]"'
    [ "$output" = "[proj.main p2.review]" ] || { echo "$output"; return 1; }
    # its directory writable by others, or the script a link (to any root-owned program): not run
    chmod 0775 "$AIRLOCK_AGENTS_BINDIR"
    run env T="$T" bash -c 'source "$T/completion.bash"; COMP_WORDS=(agent attach ""); COMP_CWORD=2; _airlock_agents; echo "[${COMPREPLY[*]}]"'
    [ "$output" = "[]" ] || { echo "dir: $output"; return 1; }
    chmod 0755 "$AIRLOCK_AGENTS_BINDIR"
    mv "$AIRLOCK_AGENTS_BINDIR/operator" "$T/real-op"; ln -s /bin/bash "$AIRLOCK_AGENTS_BINDIR/operator"
    mkdir -p "$T/cwd"; printf 'touch %s\n' "$T/via-link" > "$T/cwd/_complete"
    run env T="$T" bash -c 'cd "$T/cwd"; source "$T/completion.bash"; COMP_WORDS=(agent attach ""); COMP_CWORD=2; _airlock_agents; echo "[${COMPREPLY[*]}]"'
    [ "$output" = "[]" ]; [ ! -e "$T/via-link" ]
    # the script Tab runs gets a fresh environment: nothing the operator's shell exports reaches it
    rm "$AIRLOCK_AGENTS_BINDIR/operator"
    printf '#!/bin/bash\nenv > %s/stub-env\nprintf "proj.main\\tactive/running\\n"\n' "$T" > "$AIRLOCK_AGENTS_BINDIR/operator"
    chmod 0755 "$AIRLOCK_AGENTS_BINDIR/operator"
    run env T="$T" AIRLOCK_AGENTS_ENV=/x BASH_ENV=/x SHELLOPTS=braceexpand bash -c '
        f() { :; }; export -f f
        source "$T/completion.bash"; COMP_WORDS=(agent attach ""); COMP_CWORD=2; _airlock_agents; echo "[${COMPREPLY[*]}]"'
    [ "$output" = "[proj.main]" ] || { echo "$output"; return 1; }
    run grep -cE '^(AIRLOCK_AGENTS_ENV=|BASH_ENV=|SHELLOPTS=|BASH_FUNC_|T=)' "$T/stub-env"
    [ "$output" = 0 ] || { cat "$T/stub-env"; return 1; }
    grep -qx 'PATH=/usr/bin:/bin' "$T/stub-env"
}

@test "zsh completion: registered under the user's BASH_REMATCH and KSH_ARRAYS too" {
    command -v zsh >/dev/null || skip "no zsh"
    completion_stub
    run env T="$T" zsh -f -c 'setopt bash_rematch ksh_arrays; compdef() { print -r -- "compdef $*" }; source $T/completion.zsh'
    [ "$output" = "compdef _airlock_agents agent" ] || { echo "$output"; return 1; }
}

@test "zsh completion: a command name in agents.env that isn't a plain name is not registered" {
    command -v zsh >/dev/null || skip "no zsh"
    printf 'AGENTS_COMMAND=agent;rm -rf x\nAGENTS_COMMAND=$(touch %s)\n' "$T/pwned" > "$T/c.env"; completion_copies
    run env T="$T" REPO="$REPO" zsh -f -c 'compdef() { print -r -- "compdef $*" }; source $T/completion.zsh'
    [ "$status" -eq 0 ]; [ -z "$output" ] || { echo "$output"; return 1; }
    [ ! -e "$T/pwned" ]
}

@test "bash completion: registered for the site's command; sessions, web verbs and filtered ids offered" {
    completion_stub
    run env AIRLOCK_AGENTS_ENV="$T/c.env" AIRLOCK_AGENTS_BINDIR="$AIRLOCK_AGENTS_BINDIR" PWNED="$PWNED" T="$T" REPO="$REPO" bash -c '
        source "$T/completion.bash"
        complete -p agent
        t() { COMP_WORDS=("$@"); COMP_CWORD=$(($# - 1)); _airlock_agents; echo "${COMPREPLY[*]}"; }
        t agent at; t agent attach ""; t agent web approve ""; t agent web show 2026; t agent web ""; t agent web login g
        t agent web retry ""
        cd "$T/agentdir"; t ./agent attach ""
        IFS=:; COMP_WORDS=(agent ""); COMP_CWORD=1; _airlock_agents; echo "${#COMPREPLY[@]}"'
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "${lines[0]}" = "complete -F _airlock_agents agent" ]
    [ "${lines[1]}" = attach ]
    [ "${lines[2]}" = "proj.main p2.review" ]
    [ "${lines[3]}" = 20261021T120001Z-aaaaa1 ]
    [ "${lines[4]}" = "20261021T120001Z-aaaaa1 20261021T120002Z-aaaaa2" ]
    [[ "${lines[5]}" == *"main"*"approve"* ]]
    [ "${lines[6]}" = gate ]
    [ "${lines[7]}" = ok-name ] || { echo "retry: ${lines[7]}"; return 1; }
    [ ! -e "$T/pwned" ]
    [ ! -e "$T/planted-ran" ]; [ "${#lines[@]}" -ge 9 ]
    [ "${lines[8]}" -ge 12 ]          # a user IFS doesn't collapse the verb list
}

@test "bash completion: a command name in agents.env that isn't a plain name is not registered; the last one counts" {
    printf 'AGENTS_COMMAND=agent;rm -rf x\nAGENTS_COMMAND=$(touch %s)\n' "$T/pwned" > "$T/c.env"; completion_copies
    run env T="$T" REPO="$REPO" bash -c 'source "$T/completion.bash"; complete -p 2>/dev/null | grep _airlock_agents'
    [ -z "$output" ]; [ ! -e "$T/pwned" ]
    printf 'AGENTS_COMMAND=first\nAGENTS_COMMAND=second\n' > "$T/c.env"
    run env T="$T" REPO="$REPO" bash -c 'source "$T/completion.bash"; complete -p | grep _airlock_agents'
    [ "$output" = "complete -F _airlock_agents second" ]
    rm "$T/c.env"; mkfifo "$T/c.env"
    run timeout 5 env T="$T" REPO="$REPO" bash -c 'source "$T/completion.bash"; echo sourced'
    [ "$output" = sourced ]
}

@test "zsh completion in a real interactive zsh (compinit, zpty): names complete; a typed path runs nothing" {
    command -v zsh >/dev/null || skip "no zsh"
    zsh -f -c 'zmodload zsh/zpty' 2>/dev/null || skip "no zsh/zpty"
    completion_stub
    cat > "$T/drive.zsh" <<'Z'
zmodload zsh/zpty
zpty z zsh -f -i
zpty -w z "PS1='> '; export AIRLOCK_AGENTS_BINDIR=$AIRLOCK_AGENTS_BINDIR AIRLOCK_AGENTS_ENV=$T/c.env; autoload -U compinit; compinit -u -D; source $T/completion.zsh; cd $T/agentdir"
sleep 1
zpty -w -n z $'agent attach p2\t'; sleep 1
zpty -w -n z $'\x15agent web approve \t'; sleep 1
zpty -w -n z $'\x15./agent attach p2\t'; sleep 1
zpty -w z $'\x15exit'; sleep 0.5
out=""; while zpty -r -t z line 2>/dev/null; do out+=$line; done
print -r -- "$out" | tr -d '\r'
Z
    run timeout 30 env T="$T" REPO="$REPO" AIRLOCK_AGENTS_BINDIR="$AIRLOCK_AGENTS_BINDIR" zsh -f "$T/drive.zsh"
    [[ "$output" == *"agent attach p2.review"* ]] || { printf '%s' "$output" | cat -v | tail -c 600; return 1; }
    [[ "$output" == *"agent web approve 20261021T120001Z-aaaaa1"* ]]
    [[ "$output" != *"./agent attach p2.review"* ]]
    [ ! -e "$T/planted-ran" ]
}


@test "agent _complete ids: ids sharing a quote, a flood of real-id lines, a dangling request link" {
    op_stubs; web_queue
    A=20261021T120001Z-aaaaa1 B=20261021T120002Z-bbbbb2
    req "$A" a; req "$B" b
    # B's last line is the shared-quote one: grep -F sees B there, and so must completion
    printf '{"id":"%s","stage":"check","result":"failed, gave up"}\n{"id":"%s"id":"%s","stage":"research","result":"running"}\n' "$B" "$A" "$B" \
        >> "$Q/log/agent-web/stages.jsonl"
    [[ "$("$O" web ls)" == *"$B  researching (research: running)"* ]]
    run "$O" _complete ids retry; [ -z "$output" ] || { echo "retry: $output"; return 1; }
    run "$O" _complete ids show
    [[ "$output" == *"$B"$'\t'"researching (research: running)"* ]] || { echo "show: $output"; return 1; }
    # the worker floods its log with lines naming a real request: Tab stays quick
    python3 -c 'import sys; open(sys.argv[1], "ab").write(("{\"id\":\"%s\"}\n" % sys.argv[2]).encode() * 1500000)' "$Q/log/agent-web/stages.jsonl" "$A"
    for v in retry show; do SECONDS=0; "$O" _complete ids "$v" >/dev/null; [ "$SECONDS" -le 2 ] || { echo "$v took ${SECONDS}s"; return 1; }; done
    # a dangling link in requests/ is offered by neither web ls nor completion
    ln -s /nonexistent "$Q/requests/20261021T120009Z-ddddd9.json"
    run "$O" _complete ids show; [[ "$output" != *ddddd9* ]]
}

@test "agent: its internal variables are never taken from the caller's environment" {
    op_stubs; web_queue
    req 20261021T120004Z-aaaaa4 q
    echo '{"ts":"x","user":"agent-web","id":"20261021T120004Z-aaaaa4","stage":"check","result":"failed, gave up","exit":2}' >> "$Q/log/agent-web/stages.jsonl"
    out="$(STAGE_WEB='publish: published' STATE=held "$O" web ls)"
    [[ "$out" == *"20261021T120004Z-aaaaa4  failed (check: failed, gave up)"* ]] || { echo "$out"; return 1; }
    out="$(OCTL_RAW=1 REMOTE_OUT=$'a\e]0;x\ab' "$O" ls)"
    [[ "$out" != *$'\e'* ]]
}

@test "completion: a misbehaving script is bounded (NUL in a name, TERM ignored, a child holding the pipe, one huge line)" {
    command -v zsh >/dev/null || skip "no zsh"
    completion_stub
    op="$AIRLOCK_AGENTS_BINDIR/operator"
    zt() { run timeout 20 env T="$T" zsh -f -c 'compdef() { :; }; _describe() { local a=${@[-1]}; print -rl -- "${(@P)a}"; }
        source $T/completion.zsh; words=(agent attach ""); CURRENT=3; _airlock_agents'; }
    bt() { run timeout 20 env T="$T" bash -c 'source "$T/completion.bash"; COMP_WORDS=(agent attach ""); COMP_CWORD=2; _airlock_agents; echo "[${COMPREPLY[*]}]"'; }
    printf '#!/bin/bash\nprintf "good\\0;touch %s\\tdesc\\nok1\\tfine\\n"\n' "$T/pwn" > "$op"; chmod 0755 "$op"
    zt; [ "$output" = "ok1:fine" ] || { echo "nul: $output"; return 1; }; [ ! -e "$T/pwn" ]
    for body in "trap '' TERM; exec sleep 30" "setsid sleep 30 & echo held" "head -c 300000000 /dev/zero | tr '\\0' a"; do
        printf '#!/bin/bash\n%s\n' "$body" > "$op"; chmod 0755 "$op"
        SECONDS=0; zt; [ "$SECONDS" -le 8 ] || { echo "zsh, $body: ${SECONDS}s"; return 1; }
        SECONDS=0; bt; [ "$SECONDS" -le 8 ] || { echo "bash, $body: ${SECONDS}s"; return 1; }
    done
    pkill -f "^sleep 30$" -U "$UID" 2>/dev/null || true
}

@test "bash completion: set -u with USER unset, a TMOUT, and an agents.env with no final newline" {
    completion_stub
    printf 'AGENTS_COMMAND=agent' > "$T/c.env"
    run env -u USER -u LOGNAME T="$T" TMOUT=1 bash -c 'set -u; source "$T/completion.bash"; COMP_WORDS=(agent attach ""); COMP_CWORD=2; _airlock_agents; echo "[${COMPREPLY[*]}]"; echo "rematch=${BASH_REMATCH[*]-}"'
    [ "${lines[0]}" = "[proj.main p2.review]" ] || { echo "$output"; return 1; }
    [ "${lines[1]}" = "rematch=" ]
}


@test "agent _complete ids: a worker's worst floods stay quick; far-future ids and stale flags can't take over" {
    op_stubs; web_queue
    mkdir -p "$Q/log/agent-guard"
    for i in $(seq 10 59); do req "20261021T1200${i}Z-aaaa${i}" q; mkdir -p "$Q/quarantine/20261021T1200${i}Z-aaaa${i}"; done
    R=20261021T120005Z-ccccc5; req "$R" real
    echo "{\"id\":\"$R\",\"stage\":\"publish\",\"result\":\"published\"}" >> "$Q/log/agent-web/stages.jsonl"
    echo "{\"id\":\"$R\",\"stage\":\"gate\",\"result\":\"failed, gave up\"}" >> "$Q/log/agent-guard/stages.jsonl"
    [[ "$("$O" web ls)" == *"$R  gate failed"* ]]
    # stale flags: newer ids once flagged, ok now (they must not fill retry's list)
    for i in $(seq 10 59); do printf '{"id":"20261021T1200%sZ-aaaa%s","note":"changed"}\n{"id":"20261021T1200%sZ-aaaa%s","stage":"check","result":"ok"}\n' $i $i $i $i; done >> "$Q/log/agent-web/stages.jsonl"
    run "$O" _complete ids retry
    [[ "$output" == *"$R"* ]] || { echo "retry: $output"; return 1; }
    # far-future names from the agent don't push the real ones out of show
    for n in $(seq 10 70); do req "20991231T2359${n}Z-ffffff" junk; done
    sleep 1; touch "$Q/requests/$R.json"; req 20261021T120006Z-ddddd6 newest
    run "$O" _complete ids show
    [[ "$output" == *20261021T120006Z-ddddd6* ]] || { echo "show: $output"; return 1; }
    # the floods from round 6, ~24 MB each: many distinct flagged ids, a buffer of id prefixes,
    # one endless line of gave up
    python3 - "$Q" <<'P'
import sys
q = sys.argv[1]
with open(q + "/log/agent-web/stages.jsonl", "ab") as f:
    f.write(b"".join(b'gave up"id":"20990101T%06dZ-%06x"\n' % (i, i) for i in range(600000)))
with open(q + "/log/agent-guard/stages.jsonl", "ab") as f:
    f.write(b'"id":"20261021T' * 1500000 + b"\n" + b'{"id":"20261021T120005Z-ccccc5"}' + b" gave up" * 3000000)
P
    for v in retry show release; do
        SECONDS=0; "$O" _complete ids "$v" >/dev/null; [ "$SECONDS" -le 2 ] || { echo "$v took ${SECONDS}s"; return 1; }
    done
}

@test "bash completion: a Tab leaves the user's BASH_REMATCH as it was" {
    completion_stub
    run env T="$T" bash -c '[[ xy =~ (x)(y) ]]; source "$T/completion.bash"; COMP_WORDS=(agent attach ""); COMP_CWORD=2; _airlock_agents; echo "${COMPREPLY[*]}|${BASH_REMATCH[*]}"'
    [ "$output" = "proj.main p2.review|xy x y" ] || { echo "$output"; return 1; }
}


@test "agent _complete ids: release and approve offer only what the command accepts (scrolled-out failures, decided records)" {
    op_stubs; web_queue
    mkdir -p "$Q/log/agent-guard"
    X=20261021T120001Z-aaaaa1; req "$X" x; mkdir "$Q/quarantine/$X"
    echo "{\"id\":\"$X\",\"stage\":\"release\",\"result\":\"release failed, gave up\"}" >> "$Q/log/agent-guard/stages.jsonl"
    python3 -c 'import sys; open(sys.argv[1], "ab").write(b"{\"note\":\"filler\"}\n" * 70000)' "$Q/log/agent-guard/stages.jsonl"
    run "$O" _complete ids release; [ -z "$output" ] || { echo "release: $output"; return 1; }
    run "$O" web release "$X"; [ "$status" -ne 0 ]
    # a pending quarantine and a pending held id still show among many newer decided ones
    P=20261021T120002Z-bbbbb2; req "$P" p; mkdir "$Q/quarantine/$P"
    echo "{\"id\":\"$P\",\"stage\":\"release\",\"result\":\"quarantined\"}" >> "$Q/log/agent-guard/stages.jsonl"
    H=20261021T120003Z-ccccc3; req "$H" h; : > "$Q/held/$H.json"
    sleep 1
    for i in $(seq 10 70); do
        d="20261021T1300${i}Z-dddd${i}"; req "$d" done; mkdir "$Q/quarantine/$d"; : > "$Q/answers/$d.md"
        : > "$Q/held/$d.json"; : > "$Q/decisions/$d.approve"
        echo "{\"id\":\"$d\",\"stage\":\"release\",\"result\":\"quarantined\"}" >> "$Q/log/agent-guard/stages.jsonl"
    done
    run "$O" _complete ids release; [[ "$output" == "$P"$'\t'quarantined ]] || { echo "release: $output"; return 1; }
    run "$O" _complete ids approve; [[ "$output" == "$H"$'\t'held ]] || { echo "approve: $output"; return 1; }
}


@test "polkit: the rule asks for a local, active session, except on WSL (whose terminals have none)" {
    f="$RENDER/etc/polkit-1/rules.d/50-airlock-agents.rules"
    grep -qF 'subject.user == "alice" && subject.local && subject.active &&' "$f"
    mkdir -p "$R/proc/sys/kernel"; echo 6.18.33.2-microsoft-standard-WSL2 > "$R/proc/sys/kernel/osrelease"
    "$P" --render "$T/rw" >/dev/null
    w="$T/rw/etc/polkit-1/rules.d/50-airlock-agents.rules"
    grep -qF 'subject.user == "alice" &&' "$w"
    run grep -c 'subject.local\|subject.active' "$w"; [ "$output" = 1 ]      # (the comment only)
    grep -qF '["agent", "agent-web", "agent-guard"].indexOf(action.lookup("user")) >= 0' "$w"
    # /run/WSL alone also says WSL (a custom kernel's release string may not)
    rm "$R/proc/sys/kernel/osrelease"; mkdir -p "$R/run/WSL"
    "$P" --render "$T/rw2" >/dev/null
    run grep -cF 'subject.local && subject.active &&' "$T/rw2/etc/polkit-1/rules.d/50-airlock-agents.rules"; [ "$output" = 0 ]
    run grep -c ' $' "$f" "$w"; [[ "$output" != *:[1-9]* ]]                 # no trailing spaces
}


@test "before systemd 255 the managers get no RestrictAddressFamilies (it would imply NoNewPrivileges and stop newuidmap)" {
    for v in 254 252; do
        AIRLOCK_AGENTS_SYSTEMD_VERSION=$v "$P" --render "$T/r$v" >/dev/null
        run grep -cE '^(RestrictAddressFamilies|SystemCallArchitectures|SystemCallFilter)=' "$T/r$v/etc/systemd/system/user@1100.service.d/10-airlock-agents.conf"
        [ "$output" = 0 ] || { echo "$v: $output"; return 1; }
    done
    AIRLOCK_AGENTS_SYSTEMD_VERSION=255 "$P" --render "$T/r255" >/dev/null
    grep -qx 'SystemCallArchitectures=native' "$T/r255/etc/systemd/system/user@1100.service.d/10-airlock-agents.conf"
    # the version hook is a test root's only: a real run asks systemctl (here a stub saying 252)
    printf '#!/bin/sh\necho "systemd 252 (252.1)"\n' > "$T/bin/systemctl"; chmod +x "$T/bin/systemctl"
    env -u AIRLOCK_AGENTS_ROOT AIRLOCK_AGENTS_SYSTEMD_VERSION=999 "$P" --render "$T/rreal" "$E/agents.conf" >/dev/null
    run grep -c '^RestrictAddressFamilies=' "$T/rreal/etc/systemd/system/user@1100.service.d/10-airlock-agents.conf"; [ "$output" = 0 ]
    f="$T/r252/etc/systemd/system/user@1100.service.d/10-airlock-agents.conf"
    grep -q 'No RestrictAddressFamilies, SystemCallArchitectures or SystemCallFilter: before systemd 255' "$f"
    grep -qx 'TemporaryFileSystem=/mnt:ro' "$f"
    grep -qx 'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK' "$RENDER/etc/systemd/system/user@1100.service.d/10-airlock-agents.conf"
}
