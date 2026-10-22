#!/bin/bash
# agents/install.sh (make install-agents): the optional agent users (docs/agents.md, docs/setup.md
# level 3). As root, from a clean clone that no airlock box mounts (it installs code that runs as
# root). Needs airlock-envoy installed and running: the agents' boxes have no other way out.
#
#   sudo make install-agents                 install or update; asks for the names on the first run
#   sudo bash agents/install.sh --defaults   first run without questions (the defaults below)
#   sudo bash agents/install.sh --site FILE  first run with your own site file (agents.conf.example)
#
# First run: asks who operates the agents, the agent's name (default claude), whether to add web
# research (a web user and a guard user, default <agent>-web and <agent>-guard), their uids and
# subordinate id ranges (the next free ones), home image sizes and the operator command's name,
# then writes /etc/claude-airlock/agents/agents.conf. Later runs keep that file and update the
# installed toolkit. Every run ends with `airlock-agents-apply --confirm` (it renders and
# provisions; see its --help).
set -euo pipefail
umask 022
export LC_ALL=C

ETC=/etc/claude-airlock/agents
SHARE=/usr/local/share/airlock-agents
LIBDIR=/usr/local/lib/airlock-agents
SRC="$(cd "$(dirname "$0")" && pwd)"
die() { echo "install-agents: $*" >&2; exit 1; }

defaults=0 site=""
while [ $# -gt 0 ]; do
    case "$1" in
        --defaults) defaults=1 ;;
        --site) [ $# -ge 2 ] || die "--site needs a file"; site=$2; shift ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument $1 (see --help)" ;;
    esac
    shift
done
[ "$(id -u)" = 0 ] || die "run as root: sudo make install-agents"

# ---- prerequisites ----------------------------------------------------------------------------
systemctl is-active --quiet airlock-envoy 2>/dev/null \
    || die "airlock-envoy is not running. Install it first (docs/setup.md, level 2): the agents' boxes have no network but its sockets"
missing=""
for c in podman crun tmux machinectl getfacl setfacl mkfs.xfs python3 nft loginctl setpriv; do
    command -v "$c" >/dev/null || missing="$missing $c"
done
[ -d /etc/polkit-1/rules.d ] || missing="$missing polkit(0.106+: JavaScript rules; Ubuntu 22.04's 0.105 has none)"
if [ -n "$missing" ]; then
    echo "install-agents: missing:$missing" >&2
    echo "  Ubuntu/Debian: apt install podman crun tmux systemd-container acl xfsprogs python3 nftables polkitd wl-clipboard" >&2
    echo "  Arch:          pacman -S --needed podman crun tmux acl xfsprogs python nftables polkit" >&2
    exit 1
fi

# ---- the site file (first run) ------------------------------------------------------------------
ask() {  # ask <prompt> <default>: the answer, or the default (on --defaults, the default)
    local a
    if [ "$defaults" = 1 ]; then printf '%s' "$2"; return; fi
    [ -t 0 ] || die "no terminal to ask on: run it in one, or pass --defaults or --site FILE"
    read -r -p "$1 [$2]: " a </dev/tty
    printf '%s' "${a:-$2}"
}
free_uid() {  # free_uid <from> <taken...>: the first uid and gid from <from> no one has
    local n=$1; shift
    while getent passwd "$n" >/dev/null || getent group "$n" >/dev/null || [[ " $* " == *" $n "* ]]; do n=$((n + 1)); done
    printf '%s' "$n"
}
next_sub() {  # next_sub <taken starts...>: the next 100000-aligned start past every range in use
    local top=1000000 s
    top="$(awk -F: -v t="$top" '$2 + $3 > t { t = $2 + $3 } END { print t }' /etc/subuid /etc/subgid 2>/dev/null || echo "$top")"
    for s in "$@"; do [ $((s + 65536)) -le "$top" ] || top=$((s + 65536)); done
    printf '%s' $(( (top + 99999) / 100000 * 100000 ))
}
name_ok() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
size_ok() { [[ "$1" =~ ^[1-9][0-9]{0,5}[GT]$ ]]; }

install -d -m 0755 /etc/claude-airlock "$ETC"
if [ -n "$site" ]; then
    [ -f "$site" ] || die "no site file $site"
    [ ! -e "$ETC/agents.conf" ] || die "$ETC/agents.conf exists: edit it there (then: sudo airlock-agents-apply --confirm)"
    "$SRC/airlock-agents-apply" --env "$site" >/dev/null || die "$site is refused (above); nothing was installed"
    install -m 0644 -o root -g root "$site" "$ETC/agents.conf"
elif [ ! -e "$ETC/agents.conf" ]; then
    echo "==> First run: the agent users. Defaults in brackets; Enter takes them."
    op="$(ask "Operator (the user who runs the agents)" "${SUDO_USER:-}")"
    { name_ok "$op" && getent passwd "$op" >/dev/null; } || die "no such user '$op'"
    agent="$(ask "Agent user name" claude)"; name_ok "$agent" || die "bad name '$agent'"
    web_on="$(ask "Web research too (a web user and a guard user)? y/n" y)"
    users=("$agent"); roles=(agent)
    if [[ "$web_on" =~ ^[Yy] ]]; then
        w="$(ask "Web research user" "$agent-web")"; name_ok "$w" || die "bad name '$w'"
        g="$(ask "Guard user (the gate on its answers)" "$agent-guard")"; name_ok "$g" || die "bad name '$g'"
        users+=("$w" "$g"); roles+=(web guard)
    fi
    cmd_default=$agent; [ "$agent" != claude ] || cmd_default=claude-agent
    cmd="$(ask "Operator command name" "$cmd_default")"
    lines=() taken_u=() taken_s=()
    for i in "${!users[@]}"; do
        u=${users[$i]} r=${roles[$i]}
        if getent passwd "$u" >/dev/null; then id="$(id -u "$u")"   # an existing user keeps its uid
        else id="$(free_uid 1100 "${taken_u[@]}")"; fi
        id="$(ask "uid for $u" "$id")"
        sub="$(grep -E "^$u:" /etc/subuid 2>/dev/null | cut -d: -f2 | head -1)"
        [ -n "$sub" ] || sub="$(next_sub "${taken_s[@]}")"
        sub="$(ask "subordinate id start for $u (65536 ids)" "$sub")"
        sz=30G; [ "$r" = agent ] || sz=10G
        sz="$(ask "home image size for $u (a ceiling; sparse)" "$sz")"; size_ok "$sz" || die "bad size '$sz' (like 30G)"
        taken_u+=("$id") taken_s+=("$sub")
        lines+=("$(printf '%-6s %-14s uid %s subuid %s home %s' "$r" "$u" "$id" "$sub" "$sz")")
    done
    {
        echo "# The agent users on this host (docs/agents.md; agents.conf.example lists every line)."
        echo "# Written by agents/install.sh; edit it, then: sudo airlock-agents-apply --confirm"
        echo "operator $op"
        echo "command  $cmd"
        printf '%s\n' "${lines[@]}"
        [ "${#users[@]}" = 1 ] || echo "# internal-name example.com      # your domains: a research question carrying them waits for you"
    } > "$ETC/agents.conf.new"
    chmod 0644 "$ETC/agents.conf.new"
    # The parser checks it before it takes the name.
    "$SRC/airlock-agents-apply" --env "$ETC/agents.conf.new" >/dev/null || { rm -f "$ETC/agents.conf.new"; die "the answers made a site file the parser refuses (above)"; }
    mv -f "$ETC/agents.conf.new" "$ETC/agents.conf"
    echo "==> wrote $ETC/agents.conf"
fi

# ---- the toolkit ----------------------------------------------------------------------------------
echo "==> installing the toolkit"
put() { install -D -m "$1" -o root -g root "$2" "$3.new" && mv -f "$3.new" "$3"; }
for f in session-run session-stop web-session-run web-worker guard-worker nodump-refresh; do put 0755 "$SRC/lib/$f" "$LIBDIR/$f"; done
put 0755 "$SRC/host-test.sh" "$LIBDIR/host-test.sh"
put 0644 "$SRC/lib/worker-common.sh" "$LIBDIR/worker-common.sh"
put 0755 "$SRC/operator" "$LIBDIR/operator"
put 0755 "$SRC/airlock-agents-apply" /usr/local/sbin/airlock-agents-apply
for f in containers.conf tmux.conf managed-settings-agent.json managed-settings-web.json managed-settings-guard.json; do put 0644 "$SRC/share/$f" "$SHARE/$f"; done
for f in "$SRC"/box/* "$SRC"/templates/*; do d=${f%/*}; put 0644 "$f" "$SHARE/${d##*/}/${f##*/}"; done
put 0644 "$SRC/agents.conf.example" "$SHARE/agents.conf.example"
# The execute-only copies' refresh after package upgrades: whichever package manager this is.
if [ -d /etc/pacman.d ]; then put 0644 "$SRC/hooks/airlock-agents-nodump.hook" /etc/pacman.d/hooks/airlock-agents-nodump.hook; fi
if [ -d /etc/apt/apt.conf.d ]; then put 0644 "$SRC/hooks/80airlock-agents-nodump" /etc/apt/apt.conf.d/80airlock-agents-nodump; fi
# What was installed, so the apply notices any later change to it (drift: put back by reinstalling).
{ find "$LIBDIR" -maxdepth 1 -type f ! -name TOOLKIT.sha256; find "$SHARE" -type f ! -name TOOLKIT.sha256; echo /usr/local/sbin/airlock-agents-apply; } \
    | LC_ALL=C sort | xargs sha256sum > "$SHARE/TOOLKIT.sha256.new"
chmod 0644 "$SHARE/TOOLKIT.sha256.new" && mv -f "$SHARE/TOOLKIT.sha256.new" "$SHARE/TOOLKIT.sha256"

# Each user's default claude-airlock config is written by the apply (once; the site's afterwards).
eval "$("$SRC/airlock-agents-apply" --env "$ETC/agents.conf" | grep -E '^AGENTS_[A-Z_]+=[A-Za-z0-9_./-]*$')"

echo "==> airlock-agents-apply --confirm"
/usr/local/sbin/airlock-agents-apply --confirm
cat <<EOF

Next (docs/agents.md):
  1. airlock-envoy listeners for the agent users, if apply named any missing (above).
  2. As $AGENTS_OPERATOR: $AGENTS_COMMAND update      (gives them your installed claude-airlock)
  3. As $AGENTS_OPERATOR: $AGENTS_COMMAND reload      (their user units; starts the web research workers)
  4. Log each in once: $AGENTS_COMMAND shell, then in a project folder \`airlock\` and /login$([ -z "$AGENTS_WEB" ] || printf '; and %s web login' "$AGENTS_COMMAND")
  5. $AGENTS_COMMAND new <project>, then $AGENTS_COMMAND attach <project>
EOF
