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
    export AIRLOCK_AGENTS_ROOT="$T/root" LOG="$T/calls"
    R="$AIRLOCK_AGENTS_ROOT"
    # The site file and each user's claude-airlock config, where apply reads them (under the root).
    E="$R/etc/claude-airlock/agents"; mkdir -p "$E"
    site_file 1G 1G 1G
    for u in agent agent-web agent-guard; do echo "# $u" > "$E/$u.conf"; done
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
db=$1 key=$2; f=$PASSWD; [ "$db" = group ] && f=$GROUP
{ [ "$db" = group ] && echo "alice:x:1000:" || echo "alice:x:1000:1000::/home/alice:/bin/zsh"; cat "$f"; } \
    | awk -F: -v k="$key" '$1 == k || $3 == k { print; found = 1 } END { exit !found }'
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
[ "$1" = list ] && { [ -n "${NFT_LOADED:-}" ]; exit; }
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
    grep -qx 'InaccessiblePaths=-/run/dbus/system_bus_socket' "$d"
    grep -qx 'InaccessiblePaths=-/sys/fs/cgroup/user.slice/user-1101.slice -/sys/fs/cgroup/user.slice/user-1102.slice' "$d"
    grep -qx 'After=user@1101.service user@1102.service' "$d"
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
    grep -qx 'set -g set-clipboard on' "$c"                     # Claude's copy goes on to foot
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
        grep -qx 'InaccessiblePaths=-/run/dbus/system_bus_socket' "$d"
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
After=user@1101.service user@1102.service
[Service]
PrivateNetwork=yes
PrivateTmp=yes
PrivateIPC=yes
TemporaryFileSystem=/dev/shm:mode=1777,nosuid,nodev /dev/mqueue:mode=1777,nosuid,nodev
ProtectProc=invisible
Environment=CONTAINERS_CONF_OVERRIDE=/usr/local/share/airlock-agents/containers.conf
ProtectHome=tmpfs
BindPaths=/home/agent /run/user/1100
InaccessiblePaths=-/run/dbus/system_bus_socket
InaccessiblePaths=-/sys/fs/cgroup/user.slice/user-1101.slice -/sys/fs/cgroup/user.slice/user-1102.slice
Environment=AIRLOCK_CONFIG=/etc/claude-airlock/agents/agent.conf'
    [ "$(got "$d/user@1100.service.d/10-airlock-agents.conf")" = "$want1100" ] || { diff <(echo "$want1100") <(got "$d/user@1100.service.d/10-airlock-agents.conf"); return 1; }
    for spec in agent-web:1101:"-/srv/agent-web/held -/srv/agent-web/reports -/srv/agent-web/log/agent-web":"-/sys/fs/cgroup/user.slice/user-1100.slice -/sys/fs/cgroup/user.slice/user-1102.slice" \
                agent-guard:1102:"-/srv/agent-web/answers -/srv/agent-web/quarantine -/srv/agent-web/log/agent-guard":"-/sys/fs/cgroup/user.slice/user-1100.slice -/sys/fs/cgroup/user.slice/user-1101.slice"; do
        IFS=: read -r u n rw cg <<<"$spec"
        want="[Unit]
RequiresMountsFor=/home/$u
[Service]
PrivateNetwork=yes
PrivateTmp=yes
PrivateIPC=yes
TemporaryFileSystem=/dev/shm:mode=1777,nosuid,nodev /dev/mqueue:mode=1777,nosuid,nodev
ProtectProc=invisible
Environment=CONTAINERS_CONF_OVERRIDE=/usr/local/share/airlock-agents/containers.conf
ProtectHome=tmpfs
BindPaths=/home/$u /run/user/$n
ProtectSystem=strict
ReadWritePaths=/home/$u /run/user/$n $rw
InaccessiblePaths=-/run/dbus/system_bus_socket
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
    run "$P"
    [[ "$output" == *"would: install crun (apt install crun / pacman -S crun)"* ]] || { echo "$output"; return 1; }
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
    printf '#!/bin/bash\necho $$ > "%s"\nsleep 30 & wait\n' "$T/boxpid" > "$HOME/.local/bin/airlock"
    # started as tmux starts a pane: its own session, no signal ignored (a bats background job
    # starts with INT ignored, which bash can never reset)
    python3 -c 'import os, signal, sys
for s in (signal.SIGINT, signal.SIGQUIT): signal.signal(s, signal.SIG_DFL)
os.setsid(); os.execvp("bash", ["bash"] + sys.argv[1:])' "$REPO/agents/lib/web-session-run" main >/dev/null 2>&1 & runner=$!
    for _ in $(seq 50); do [ -s "$T/boxpid" ] && break; sleep 0.1; done
    sleep 0.3; kill -INT -- -"$runner"
    for _ in $(seq 50); do kill -0 "$runner" 2>/dev/null || break; sleep 0.1; done
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

