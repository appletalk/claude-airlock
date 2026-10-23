#!/bin/bash
# The agents' host checks (docs/agents.md): what the toolkit's tests can't run in a box. As root,
# after `airlock-agents-apply --confirm` and `<command> update`, with an attach open for the R1
# probes:
#
#   sudo /usr/local/lib/airlock-agents/host-test.sh
#
# Acts as each user against the real queue and inbox: who may create, list, read and write
# files, delete another's, chmod or move a dir. Each access is a probe that answers ok, denied
# (EACCES/EPERM) or error; an error is always a FAIL, so a broken check never passes as a
# denial. Then the kernel side: nftables drops each user's uid and subuids in the host's
# namespace, each user manager has its own network namespace (loopback only), /tmp and a /proc
# without other users' processes, no cron, its boxes still run there, the home mounts, the units.
# Changes nothing but its own probe files (dot-files, removed at the end; the workers ignore
# dot-files), and re-runs systemd-tmpfiles at the end so a failed chmod or ACL check leaves
# nothing changed. Prints PASS/FAIL per check; exit 1 on any FAIL.
#   AGENTS_PROBE_HOST  an outside address:port to try connecting to (default 1.1.1.1:443)
#   AGENTS_WAN_V4      this site's public IPv4, to check the web user can't reach it back (optional)
#   AGENTS_TEST_RELOAD=1  also reload nftables and check the agents' table survives it
# shellcheck disable=SC2016,SC2015  # sh -c '...' sh args on purpose; pass never fails
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root (sudo $0)" >&2; exit 2; }
for c in python3 setpriv nsenter systemd-run systemd-tmpfiles setfacl journalctl nft; do
    command -v "$c" >/dev/null || { echo "host-test: $c not found" >&2; exit 2; }
done
# shellcheck source=/dev/null
. "${AIRLOCK_AGENTS_ENV:-/etc/claude-airlock/agents/agents.env}"
A=$AGENTS_AGENT W=$AGENTS_WEB G=$AGENTS_GUARD OP=$AGENTS_OPERATOR CMD=$AGENTS_COMMAND
AU=$AGENTS_AGENT_UID WU=$AGENTS_WEB_UID GU=$AGENTS_GUARD_UID
Q=$AGENTS_QUEUE IN=$AGENTS_INBOX
TAG=".hostcheck-$$"
fails=0 passes=0 opens=0
pass() { passes=$((passes + 1)); echo "PASS $*"; }
fail() { fails=$((fails + 1)); echo "FAIL $*"; }
open_() { opens=$((opens + 1)); echo "OPEN $*"; }   # a known, registered residual that is still there
expect() {  # expect yes|no <what> <command...>: the command must succeed (yes) or fail (no)
    local want=$1 what=$2; shift 2
    if "$@" >/dev/null 2>&1; then got=yes; else got=no; fi
    if [ "$got" = "$want" ]; then pass "$what"; else fail "$what (expected $want, got $got)"; fi
}
as() {  # as <user> <command...>: that user with its own groups, umask 022
    local u=$1; shift
    setpriv --reuid="$u" --regid="$(id -g "$u")" --init-groups -- /bin/sh -c 'umask 022; exec "$@"' sh "$@"
}
# probe <user> read|write|create|list|unlink|chmod|stat|connect <path> | rename <from> <to>:
# prints ok, denied (EACCES, EPERM), rofs (EROFS), missing (ENOENT) or error:<reason>
PROBE='
import errno, os, sys
op, p = sys.argv[1], sys.argv[2]
try:
    if op == "read": os.close(os.open(p, os.O_RDONLY | os.O_NOFOLLOW))
    elif op == "write": os.close(os.open(p, os.O_WRONLY | os.O_NOFOLLOW))
    elif op == "create": os.close(os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644))
    elif op == "list": os.listdir(p)
    elif op == "unlink": os.unlink(p)
    elif op == "chmod": os.chmod(p, 0o777)
    elif op == "rename": os.rename(p, sys.argv[3])
    elif op == "stat": os.stat(p)
    elif op == "connect":
        import socket; c = socket.socket(socket.AF_UNIX); c.connect(p)
    elif op == "empty":
        if os.listdir(p): print("error:not-empty"); sys.exit()
    elif op == "vsock":
        import socket; socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM).close()
    else:
        print("error:unknown-op"); sys.exit()
    print("ok")
except OSError as e:
    print("denied" if e.errno in (errno.EACCES, errno.EPERM) else "rofs" if e.errno == errno.EROFS else
          "refused" if e.errno == errno.EAFNOSUPPORT else
          "missing" if e.errno == errno.ENOENT else "error:" + errno.errorcode.get(e.errno, str(e.errno)))
'
probe() { as "$1" python3 -I -c "$PROBE" "$2" "$3" "${4:-}" 2>&1 | tail -1; }
check() {  # check ok|denied|missing <what> <user> <op> <path> [<to>]
    local want=$1 what=$2 got; got="$(probe "$3" "$4" "$5" "${6:-}")"
    if [ "$got" = "$want" ]; then pass "$what"; else fail "$what (expected $want, got $got)"; fi
}
cleanup() {
    find "$Q" "$IN" -type f -name "$TAG*" -delete 2>/dev/null
    find "$Q" -mindepth 2 -maxdepth 2 -type d -name "$TAG-sub" -exec rm -rf --one-file-system {} + 2>/dev/null
    systemd-tmpfiles --create /etc/tmpfiles.d/airlock-agents-queue.conf /etc/tmpfiles.d/airlock-agents-inbox.conf >/dev/null 2>&1
}
trap cleanup EXIT

USERS="$A${W:+ $W $G}"
OP_HOME="$(getent passwd "$OP" | cut -d: -f6)"
for u in $USERS $OP nobody; do
    id "$u" >/dev/null 2>&1 || { echo "no user $u: provision first" >&2; exit 2; }
done
ALL="$USERS $OP nobody"
yn() { [[ " $2 " == *" $1 "* ]] && echo ok || echo denied; }

if [ -n "$W" ]; then   # web research: its queue
echo "== the queue: who may create, list, read and write in each dir"
# dir|writers|readers (who aren't writers)
matrix=(
    "requests|$A $OP|$W $G"
    "held|$W|$OP"
    "decisions|$OP|$W $G"
    "reports|$W|$G"
    "answers|$G|$A $OP"
    "quarantine|$G|$OP"
    "log||$OP $W $G"
    "log/$W|$W|$OP"
    "log/$W/transcripts|$W|$OP"
    "log/$G|$G|$OP"
    "log/$G/transcripts|$G|$OP"
)
for row in "${matrix[@]}"; do
    IFS='|' read -r d writers readers <<<"$row"
    for u in $ALL; do
        check "$(yn "$u" "$writers")" "$d: $u create" "$u" create "$Q/$d/$TAG-$u"
        check "$(yn "$u" "$writers $readers")" "$d: $u list" "$u" list "$Q/$d"
    done
    first=${writers%% *}
    [ -n "$first" ] || continue
    # A writer's file the way step 4 writes them (mktemp, chmod 0640, rename); one left 0600; and
    # one its owner made world-readable (0644): only the dir's own readers ever get in.
    as "$first" sh -c 'cd "$1" && t="$(mktemp -p . "$2.XXXXXX")" && echo probe > "$t" && chmod 0640 "$t" && mv "$t" "$2"' sh "$Q/$d" "$TAG-new" \
        || fail "$d: $first could not write its probe"
    as "$first" sh -c 'cd "$1" && t="$(mktemp -p . "$2.XXXXXX")" && echo probe > "$t" && mv "$t" "$2"' sh "$Q/$d" "$TAG-0600"
    as "$first" sh -c 'cd "$1" && echo probe > "$2" && chmod 0644 "$2"' sh "$Q/$d" "$TAG-0644"
    for u in $ALL; do
        [ "$u" = "$first" ] && continue
        check "$(yn "$u" "$writers $readers")" "$d: $u read $first's 0640 file" "$u" read "$Q/$d/$TAG-new"
        check "$(yn "$u" "$writers $readers")" "$d: $u read $first's 0644 file" "$u" read "$Q/$d/$TAG-0644"
        check denied "$d: $u write $first's file" "$u" write "$Q/$d/$TAG-new"
        check denied "$d: $u read $first's 0600 file" "$u" read "$Q/$d/$TAG-0600"
    done
    check denied "$d: $first chmod the dir" "$first" chmod "$Q/$d"
    out="$(as "$first" setfacl -m "u:nobody:rwx" "$Q/$d" 2>&1)" && fail "$d: $first changed the dir's ACL" \
        || { [[ "$out" == *"Operation not permitted"* ]] && pass "$d: $first can't change the dir's ACL" || fail "$d: setfacl failed otherwise: $out"; }
    if as "$first" mv "$Q/$d" "$Q/$d.$TAG-moved" >/dev/null 2>&1; then
        mv "$Q/$d.$TAG-moved" "$Q/$d"; fail "$d: $first moved the dir away (moved back)"
    else pass "$d: $first can't move the dir away"; fi
done
# Subdirs (reports/<id>/, quarantine/<id>/): made 0750 by their writer, traversable by the readers.
for row in "reports|$W|$G" "quarantine|$G|$OP"; do
    IFS='|' read -r d w r <<<"$row"
    as "$w" sh -c 'mkdir -m 0750 "$1" && echo probe > "$1/f" && chmod 0640 "$1/f"' sh "$Q/$d/$TAG-sub" || fail "$d: $w could not make a subdir"
    check ok "$d: $r reads a file in $w's subdir" "$r" read "$Q/$d/$TAG-sub/f"
    check denied "$d: $A can't read a file in $w's subdir" "$A" read "$Q/$d/$TAG-sub/f"
    rm -rf --one-file-system "${Q:?}/$d/$TAG-sub"
done

echo "== requests/: nobody rewrites, removes or replaces another's request"
as "$A" sh -c 'echo q > "$1" && chmod 0640 "$1"' sh "$Q/requests/$TAG-$A-req" || fail "$A could not write its request probe"
as "$OP" sh -c 'echo q > "$1" && chmod 0660 "$1"' sh "$Q/requests/$TAG-$OP-req" || fail "$OP could not write a request probe"
check denied "$A write $OP's request (even one $OP left 0660)" "$A" write "$Q/requests/$TAG-$OP-req"
check denied "$OP write $A's request" "$OP" write "$Q/requests/$TAG-$A-req"
check denied "$A delete $OP's request" "$A" unlink "$Q/requests/$TAG-$OP-req"
check denied "$OP delete $A's request" "$OP" unlink "$Q/requests/$TAG-$A-req"
check denied "$A rename over $OP's request" "$A" rename "$Q/requests/$TAG-$A-req" "$Q/requests/$TAG-$OP-req"
check ok "$A delete its own request" "$A" unlink "$Q/requests/$TAG-$A-req"

fi

echo "== the queue dir itself and the inbox"
if [ -n "$W" ]; then
    check denied "$A create in $Q" "$A" create "$Q/$TAG-top"
    check denied "$W create in $Q" "$W" create "$Q/$TAG-top"
fi
f=$IN/airlock/$TAG-bundle
as "$OP" sh -c 'echo b > "$1" && chmod 0640 "$1"' sh "$f" || fail "$OP could not write $f"
for u in $A $W $G; do check ok "$u read a bundle file in airlock/" "$u" read "$f"; done
check denied "nobody read a bundle file" nobody read "$f"
for u in $W $G; do
    check denied "$u create in airlock/" "$u" create "$IN/airlock/$TAG-$u"
    check denied "$u list pastes/" "$u" list "$IN/pastes"
done

echo "== tmpfiles and provision agree, and a re-run changes nothing"
systemd-tmpfiles --create /etc/tmpfiles.d/airlock-agents-queue.conf /etc/tmpfiles.d/airlock-agents-inbox.conf \
    && pass "systemd-tmpfiles --create is clean" || fail "systemd-tmpfiles --create reported errors (above)"
out="$(airlock-agents-apply --check 2>&1)"
grep -q "^ok   $Q: every dir root's" <<<"$out" && pass "airlock-agents-apply --check: the queue is ok" \
    || fail "airlock-agents-apply --check doesn't call the queue ok: $(grep -A12 "$Q" <<<"$out" | head -14)"
grep -q "^ok   $IN " <<<"$out" && pass "airlock-agents-apply --check: the inbox is ok" || fail "airlock-agents-apply --check: the inbox isn't ok"
grep -q "nothing to change" <<<"$out" && pass "airlock-agents-apply --check: nothing to change" || fail "airlock-agents-apply --check: $(grep -E '^(would|airlock-agents-apply):' <<<"$out")"
echo "   getfacl of the queue, for the record:"; getfacl -Rpn "$Q" 2>/dev/null | grep -v "$TAG" | sed 's/^/     /'

echo "== nftables: no network for their uids and subuids in the host's namespace"
nft_external=0; [[ " ${AGENTS_EXTERNAL:-} " == *" nftables "* ]] && nft_external=1
if [ "$nft_external" = 0 ]; then
    expect yes "the agents' table is loaded (inet airlock-agents)" nft list table inet airlock-agents
    if [ -n "${AGENTS_TEST_RELOAD:-}" ]; then   # opt in: reloads the host's firewall
        systemctl reload nftables
        expect yes "the agents' table survives an nftables reload" nft list table inet airlock-agents
    fi
else echo "     (nftables is managed elsewhere: the drops below are probed, not the table)"; fi
probe_host="${AGENTS_PROBE_HOST:-1.1.1.1:443}"
export probe_host   # read by tcp() in the shells below
tcp() { timeout 4 bash -c "exec 3<>/dev/tcp/${probe_host%:*}/${probe_host##*:}"; }
if setpriv --reuid=65534 --regid=65534 --clear-groups -- bash -c "$(declare -f tcp); tcp"; then
    ids=""
    for u in $USERS; do
        s0="$(awk -F: -v u="$u" '$1 == u { print $2 }' /etc/subuid | head -1)"
        ids="$ids $(id -u "$u") $s0 $((s0 + 65535))"
    done
    for id in $ids; do
        expect no "uid $id can't connect out" setpriv --reuid="$id" --regid="$id" --clear-groups -- bash -c "$(declare -f tcp); tcp"
    done
    [ "$nft_external" = 1 ] || for u in $USERS; do
        expect yes "$u's drops are logged with its prefix" sh -c 'journalctl -k --since "-2 min" | grep -q "airlock-agents-$1-drop: "' sh "$u"
    done
else
    fail "control: nobody (65534) can't connect to $probe_host either, so the nftables checks are inconclusive"
fi

echo "== web can't reach our own services: the host can't connect to our WAN v4 (NAT reflection off)"
# $W's web Envoy refuses internal names and ranges, but our WAN v4 is public and rotates, so
# it isn't listed; the router not reflecting it is what keeps $W's web (and the logs $A
# reads, which would record the request) off our own services.
# No outside service to learn it: pass it in (AGENTS_WAN_V4=<addr> sudo -E ...), else skipped.
wan="${AGENTS_WAN_V4:-}"
if [[ "$wan" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
    if timeout 6 bash -c "exec 3<>/dev/tcp/$wan/443" 2>/dev/null; then
        fail "the host reaches our WAN v4 ($wan:443): NAT reflection is on, so $W's web can reach our services (add the WAN v4 to internal-net, or turn reflection off)"
    else pass "the host can't connect to our WAN v4 ($wan:443): no reflection"; fi
else
    echo "     (AGENTS_WAN_V4 not given: reflection probe skipped)"
fi

echo "== the user managers: their own network, /tmp, /proc, homes, runtime dirs; no system bus"
echo "   (a manager gets a new drop-in only once user@<uid> has restarted: reboot first)"
users="$A:$AU"; [ -z "$W" ] || users="$users $W:$WU $G:$GU"
# mgr <user> <op> <path> [<to>]: the probe run as a unit in that user's manager (its namespaces)
mgr() { systemd-run --user -M "$1@" --wait --pipe --quiet --collect --expand-environment=no -- python3 -I -c "$PROBE" "$2" "$3" "${4:-}" 2>&1 | tail -1; }
mcheck() {  # mcheck <want...> <what> <user> <op> <path>: the result must be one of the wants
    local wants=() got
    while [[ "$1" =~ ^(ok|denied|missing|rofs|refused)$ ]]; do wants+=("$1"); shift; done
    got="$(mgr "$2" "$3" "$4")"
    if [[ " ${wants[*]} " == *" $got "* ]]; then pass "$1"; else fail "$1 (expected ${wants[*]}, got ${got:-nothing})"; fi
}
declare -A img=([$A]=claude-airlock:dev [$W]=claude-airlock:base [$G]=claude-airlock:base)
for spec in $users; do
    u=${spec%:*} n=${spec#*:}
    pid="$(systemctl show -p MainPID --value "user@$n.service")"
    if [ -z "$pid" ] || [ "$pid" = 0 ]; then fail "user@$n.service isn't running (linger on? loginctl enable-linger $u)"; continue; fi
    [ "$(readlink "/proc/$pid/ns/net")" != "$(readlink /proc/1/ns/net)" ] && pass "user@$n: its own network namespace" || fail "user@$n: the host's network namespace"
    links="$(nsenter -t "$pid" -n ip -o link | awk -F': ' '{print $2}' | tr '\n' ' ')"
    [ "$links" = "lo " ] && pass "user@$n: loopback only" || fail "user@$n: links $links"
    [ "$(readlink "/proc/$pid/ns/mnt")" != "$(readlink /proc/1/ns/mnt)" ] && pass "user@$n: its own mount namespace" || fail "user@$n: no private mounts"
    # controls: the probe runs there, and its own things are there
    mcheck ok "user@$n: control: its own /proc/self" "$u" stat /proc/self/cmdline
    mcheck ok "user@$n: control: its own home" "$u" list "/home/$u"
    mcheck ok "user@$n: control: its own runtime dir" "$u" list "/run/user/$n"
    # ProtectProc=invisible (with crun as the box runtime): no one else's processes
    mcheck missing denied "user@$n: pid 1 (root's) invisible" "$u" stat /proc/1/cmdline
    for other in $users; do
        o=${other%:*} on=${other#*:}; [ "$o" = "$u" ] && continue
        opid="$(systemctl show -p MainPID --value "user@$on.service")"
        [ -n "$opid" ] && [ "$opid" != 0 ] && mcheck missing denied "user@$n: $o's manager (pid $opid) invisible" "$u" stat "/proc/$opid/cmdline"
    done
    rt="$(systemd-run --user -M "$u@" --wait --pipe --quiet --collect --expand-environment=no -- podman info --format '{{.Host.OCIRuntime.Name}}' 2>/dev/null)"
    [ "$rt" = crun ] && pass "user@$n: podman's runtime is crun" || fail "user@$n: podman's runtime is '$rt', not crun"
    mcheck missing denied "user@$n: no system bus" "$u" connect /run/dbus/system_bus_socket
    # its own /run: no host socket that answers anyone (resolved can reach the network for its caller)
    for sk in /run/systemd/resolve/io.systemd.Resolve /run/nscd/socket /var/lib/sss/pipes/nss /run/avahi-daemon/socket; do
        [ -e "$sk" ] && mcheck missing denied "user@$n: no $sk" "$u" connect "$sk"
    done
    # ...but its airlock-envoy sockets are there (its only way out)
    for sk in /run/airlock-envoy/"$u"/*.sock; do
        [ -S "$sk" ] && mcheck ok "user@$n: reaches its Envoy socket ${sk##*/}" "$u" connect "$sk"
    done
    for other in $users; do
        o=${other%:*} on=${other#*:}
        [ "$o" = "$u" ] && continue
        mcheck missing denied "user@$n: no /home/$o" "$u" list "/home/$o"
        mcheck missing denied "user@$n: no /run/user/$on" "$u" list "/run/user/$on"
        mcheck missing denied "user@$n: $o's cgroups hidden" "$u" list "/sys/fs/cgroup/user.slice/user-$on.slice"
    done
    mcheck missing denied "user@$n: no $OP's home" "$u" list "$OP_HOME"
    # Nothing of /mnt (WSL: the Windows drives, WSLg's sockets), no hypervisor devices, no vsock
    [ -d /mnt ] && mcheck ok "user@$n: /mnt is empty here (on WSL: no drives, no WSLg sockets)" "$u" empty /mnt
    for dv in /dev/dxg /dev/vsock; do
        [ -e "$dv" ] && mcheck missing denied "user@$n: no $dv" "$u" stat "$dv"
    done
    if ! grep -q '^RestrictAddressFamilies=' "/etc/systemd/system/user@$n.service.d/10-airlock-agents.conf" 2>/dev/null; then
        echo "     (no RestrictAddressFamilies for $u: systemd before 255, see its drop-in; vsock is open to it)"
    elif python3 -I -c 'import socket; socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM).close()' 2>/dev/null; then
        mcheck refused "user@$n: no AF_VSOCK socket (WSL interop rides vsock to Windows)" "$u" vsock -
    else
        echo "     (AF_VSOCK isn't available to root here either: that probe would mean nothing, skipped)"
    fi
    if [ "$u" != "$A" ]; then
        # ProtectSystem=strict: read-only outside its paths (EROFS, not merely a permission)
        if [ "$(stat -c %a /var/spool/mail 2>/dev/null)" = 1777 ]; then
            mcheck rofs "user@$n: /var/spool/mail (world-writable on the host) is read-only here" "$u" create "/var/spool/mail/$TAG-$u"
        else
            echo "     (/var/spool/mail isn't world-writable on this host: that probe would mean nothing, skipped)"
        fi
        other_q=$([ "$u" = "$W" ] && echo answers || echo held)
        # the permission check comes before the read-only mount's, so a dir it can't write says denied
        mcheck rofs denied "user@$n: no writing into $Q/$other_q" "$u" create "$Q/$other_q/$TAG-mgr"
        # ...and its own paths really are writable (a mistyped ReadWritePaths entry would not be)
        mcheck ok "user@$n: writes its home" "$u" create "/home/$u/$TAG-w"
        mcheck ok "user@$n: writes its runtime dir" "$u" create "/run/user/$n/$TAG-w"
        mcheck ok "user@$n: writes its private /var/tmp" "$u" create "/var/tmp/$TAG-w"
        if [ "$u" = "$W" ]; then rw="held reports log/$W"; else rw="answers quarantine log/$G"; fi
        for q in $rw; do mcheck ok "user@$n: writes $q/" "$u" create "$Q/$q/$TAG-w"; done
        rm -f "/home/$u/$TAG-w" "/run/user/$n/$TAG-w"
    fi
    expect yes "user@$n: a rootless podman box runs (${img[$u]})" \
        systemd-run --user -M "$u@" --wait --pipe --quiet --collect --expand-environment=no -- podman run --rm --network none --entrypoint /bin/true "${img[$u]}"
    expect yes "user@$n: AIRLOCK_CONFIG=/etc/claude-airlock/agents/$u.conf" sh -c "systemctl show -p Environment --value user@$n.service | grep -q 'AIRLOCK_CONFIG=/etc/claude-airlock/agents/$u.conf'"
    # no cron or at jobs: the spool read-only in its manager, and the user denied
    for sp in /var/spool/cron /var/spool/at; do
        [ -d "$sp" ] && mcheck rofs denied "user@$n: $sp read-only" "$u" create "$sp/$TAG-$u"
    done
    for f in cron at; do
        if [ -f "/etc/$f.allow" ]; then expect no "$u not in /etc/$f.allow" grep -qxF "$u" "/etc/$f.allow"
        elif [ -f "/etc/$f.deny" ]; then expect yes "$u in /etc/$f.deny" grep -qxF "$u" "/etc/$f.deny"
        else echo "     (no /etc/$f.allow or $f.deny: $f's default applies, as apply leaves it)"; fi
    done
    expect yes "user-$n.slice: memory ceiling set" sh -c "[ \"\$(systemctl show -p MemoryMax --value user-$n.slice)\" != infinity ]"
    opts="$(findmnt -no SOURCE,OPTIONS "/home/$u")"
    [[ "$opts" == /dev/loop* && "$opts" == *nodev* && "$opts" == *nosuid* ]] && pass "/home/$u: its image, nodev,nosuid" || fail "/home/$u: $opts"
    expect yes "/home/$u: $u's, 0700" sh -c "[ \"\$(stat -c %U:%a /home/$u)\" = $u:700 ]"
done

if [ -n "$W" ]; then
echo "== step 4: the in-box scripts and the queue workers"
for u in $A $W $G; do
    check denied "$u create in lib/" "$u" create "$Q/lib/$TAG-$u"
    check ok "$u read lib/agent_web.py" "$u" read "$Q/lib/agent_web.py"
done
expect yes "lib/ root's, 0755" sh -c "[ \"\$(stat -c %U:%G:%a $Q/lib)\" = root:root:755 ]"
for l in default.target.wants/$W-worker.path timers.target.wants/$W-worker.timer \
         default.target.wants/$G-worker.path timers.target.wants/$G-worker.timer; do
    [ "$(readlink "/etc/systemd/user/$l")" = "/etc/systemd/user/${l#*/}" ] && pass "$l enabled" \
        || fail "$l not enabled (sudo airlock-agents-apply --confirm)"
done
# Enabled isn't running: a failed watch leaves questions to the 10-minute timer.
for u in $W $G; do
    for unit in "$u-worker.path" "$u-worker.timer"; do
        expect yes "$u: $unit active in its manager" systemctl --user -M "$u@" is-active --quiet "$unit"
    done
done

fi

echo "== R1: $A's the host-side processes run from execute-only copies (non-dumpable)"
for pair in sh:bash systemd-run:systemd-run systemctl:systemctl install:install; do
    c=/usr/local/lib/airlock-agents/bin/${pair%%:*}
    [ "$(stat -c %U:%G:%a "$c" 2>/dev/null)" = root:root:711 ] && cmp -s "/usr/bin/${pair#*:}" "$c" \
        && pass "$c: root's, 0711, current" || fail "$c: missing, not 0711 root's, or stale (sudo /usr/local/lib/airlock-agents/nodump-refresh)"
done
check denied "$A read its copy of systemd-run" "$A" read /usr/local/lib/airlock-agents/bin/systemd-run
[ "$(cat /proc/sys/fs/suid_dumpable)" != 1 ] && pass "fs.suid_dumpable is not 1 (an unreadable exec stays non-dumpable)" \
    || fail "fs.suid_dumpable is 1: every process stays dumpable and the copies protect nothing"
# Every agent-user process in the host's own mount namespace right now must be non-dumpable (its
# /proc/<pid>/fd root-owned; /proc/<pid> itself always shows the owner). Scope: processes in
# the host's mount namespace by real uid of an agent user, i.e. what `$CMD` and a host shell start. Run this while an attach (and, ideally, an $A update) is open.
init_mnt="$(readlink /proc/1/ns/mnt)" seen=0
for d in /proc/[0-9]*; do
    uid="$(awk '/^Uid:/ {print $2}' "$d/status" 2>/dev/null)"
    [[ " $AU $WU $GU " == *" $uid "* ]] || continue
    [ "$(readlink "$d/ns/mnt" 2>/dev/null)" = "$init_mnt" ] || continue
    seen=$((seen + 1)); p=${d#/proc/}; comm="$(cat "$d/comm" 2>/dev/null)"
    owner="$(stat -c %U "$d/fd" 2>/dev/null)" || continue   # exited meanwhile
    if [ "$owner" = root ]; then pass "R1: $p ($comm, uid $uid) in the host's namespaces is non-dumpable"
    elif [ "$comm" = systemd-stdio-b ]; then open_ "R1: $p (systemd-stdio-bridge of a 'systemd-run -M', uid $uid) is dumpable: admin-only window"
    else fail "R1: $p ($comm, uid $uid) in the host's namespaces is dumpable"; fi
done
[ "$seen" -gt 0 ] || echo "     (no agent-user process in the host's namespaces right now: re-run with '$CMD attach' open)"
echo "   (an attach through '$CMD' now leaves no reachable process below; a hand-typed"
echo "    'machinectl shell <user>@' or 'systemd-run -M <user>@' still does, as does this script's own"
echo "    systemd-stdio-bridge: admin-only windows, R1 in docs/agents.md)"
echo "== R1 (registered residual): a user process in the host's namespaces opens the host's view to the user"
# While `$CMD attach`/`$CMD shell` (or orun during `$CMD update`, or a host shell as the user)
# runs, a process of the user's sits in the host's mount namespace; same uid and dumpable, so code in
# the manager reaches the host's tree through /proc/<pid>/root. OPEN until fixed.
# The marker is the admin's home: in the host's own tree it is there, in every manager's view (and in
# podman's namespaces, which are copies of it) /home is a tmpfs without it. A different mount
# namespace alone proves nothing (podman's pause process and conmon live in copies of the view).
admin_home="$OP_HOME"
[ -d "$admin_home" ] || { fail "R1 probe: no $admin_home on the host to use as the marker"; admin_home=""; }
for spec in $users; do
    [ -n "$admin_home" ] || break
    u=${spec%:*}
    found="$(systemd-run --user -M "$u@" --wait --pipe --quiet --collect --expand-environment=no -- sh -c \
        'me=$(readlink /proc/self/ns/mnt); for p in /proc/[0-9]*; do m=$(readlink $p/ns/mnt 2>/dev/null) || continue; [ "$m" != "$me" ] && [ -d "$p/root$1" ] && echo "${p#/proc/}:$(cat $p/comm 2>/dev/null)"; done' sh "$admin_home" 2>/dev/null | head -5 | tr '\n' ' ')"
    if [ -n "$found" ]; then open_ "R1: $u's manager reaches the host's tree through /proc/<pid>/root of $found(a process of $u in the host's namespaces)"
    else pass "R1: no $u process in the host's namespaces reachable from its manager right now (re-run during '$CMD attach' to see R1)"; fi
done

echo "== an agent that opens its own home or runtime dir still hands $A nothing"
for spec in $users; do
    [ "${spec%:*}" != "$A" ] || continue
    u=${spec%:*} n=${spec#*:}
    systemd-run --user -M "$u@" --wait --pipe --quiet --collect --expand-environment=no -- sh -c \
        'chmod 0755 "$HOME" "$XDG_RUNTIME_DIR" && echo x > "$HOME/'"$TAG"'" && echo x > "$XDG_RUNTIME_DIR/'"$TAG"'" && chmod 0644 "$HOME/'"$TAG"'" "$XDG_RUNTIME_DIR/'"$TAG"'"' \
        || fail "$u: could not plant its probe"
    mcheck missing denied "$A: $u's opened home file unreachable" "$A" read "/home/$u/$TAG"
    mcheck missing denied "$A: $u's opened runtime-dir file unreachable" "$A" read "/run/user/$n/$TAG"
    rm -f "/home/$u/$TAG" "/run/user/$n/$TAG"; chmod 0700 "/home/$u" "/run/user/$n"
done

for u in $USERS; do
    m="/etc/systemd/system/home-${u//-/\\x2d}.mount"
    expect yes "systemd-analyze verify $m" systemd-analyze verify "$m"
done

echo
echo "host-test: $passes passed, $fails failed, $opens open (registered residuals, see the OPEN lines)"
[ "$fails" = 0 ]
