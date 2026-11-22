#!/bin/bash
#
# A fixed interpreter, not `/usr/bin/env bash`: this runs as root with the environment the box was
# started with, and env would look bash up in that environment's PATH (a secret can set PATH).
#
# Runs as root: raise the egress firewall, then drop to the unprivileged agent
# user before exec'ing the requested command (Claude by default).
set -euo pipefail

# The image's PATH puts /home/dev/.local/bin FIRST so the agent finds `claude`, and the
# firewall used to inherit it as root: every `iptables`, `ipset`, `dig`, `curl` and `jq`
# it ran was looked up in a directory owned by the user it is about to drop to. Nothing
# exploited that - the directory lives in the ephemeral overlay and dev never runs before
# the firewall - but it is the wrong order to bet on, and it stops being safe the day
# anything under /home/dev outside .claude is persisted. Root gets the system PATH; the
# agent gets the image's back at the exec.
AGENT_PATH="$PATH"
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# The drop below only takes capabilities away if it starts from root: a change from uid 0
# clears them, a change from dev to dev changes nothing. A box started as another user
# (podman's --userns=keep-id without --user=0:0, an older launcher, a hand-run engine
# command) would skip it and hand dev whatever capabilities the engine added, in the ambient
# set, enough to setuid(0). Refuse rather than start that box.
# The kernel's view, not bash's $UID/$EUID (bash takes those from the environment when they
# are set there): real, effective, saved and filesystem uid all 0.
uids="$(awk '/^Uid:/ { print $2, $3, $4, $5 }' /proc/self/status)"
if [ "$uids" != "0 0 0 0" ]; then
  echo "[airlock] ERROR: the box must start as root to drop to dev (uids: ${uids:-unknown}). Update the launcher (make install); a hand-run podman box with --userns=keep-id also needs --user=0:0. Not starting." >&2
  exit 1
fi

if [ -n "${AIRLOCK_EGRESS_PROXY:-}" ]; then
  # Proxy posture: no firewall, because there is no network to filter. That only holds
  # while it is true, so prove it: any interface besides loopback means this box was
  # started some other way, and Claude does not start in it.
  # /proc/net/dev lists every interface in this namespace (a glob would miss dot-names).
  ifaces="$(awk -F: 'NR > 2 { gsub(/ /, "", $1); print $1 }' /proc/net/dev)"
  if [ "$ifaces" != lo ]; then
    echo "[airlock] ERROR: proxy mode, but the box has network interfaces ($(printf %s "$ifaces" | tr "\n" " ")); not starting" >&2
    exit 1
  fi
  [ -S "$AIRLOCK_EGRESS_PROXY" ] || { echo "[airlock] ERROR: proxy socket $AIRLOCK_EGRESS_PROXY is missing" >&2; exit 1; }
  # Run as dev, the uid the host granted on the socket (root here is a subuid there). It
  # needs no protecting from dev: killing it only cuts this box off. Its messages go to a
  # file, not the terminal Claude draws on, and its own session keeps the terminal's
  # signals off it (one Ctrl-C at a shell prompt killed it otherwise).
  setsid /usr/sbin/gosu dev socat -lf /tmp/airlock-proxy.log \
    TCP-LISTEN:3128,bind=127.0.0.1,reuseaddr,fork "UNIX-CONNECT:$AIRLOCK_EGRESS_PROXY" </dev/null &
  # Wait for the listener in /proc rather than by connecting: a test connection would be
  # relayed to the proxy and land in its audit log. Port 3128 (0C38) listening (0A); the
  # address field is byte-order dependent, so it is not matched.
  i=0
  until grep -q ':0C38 00000000:0000 0A' /proc/net/tcp; do
    i=$((i + 1))
    [ "$i" -lt 100 ] || { echo "[airlock] ERROR: the proxy bridge did not start (see /tmp/airlock-proxy.log)" >&2; exit 1; }
    sleep 0.05
  done
  export HTTPS_PROXY=http://127.0.0.1:3128 https_proxy=http://127.0.0.1:3128
  export HTTP_PROXY=http://127.0.0.1:3128 http_proxy=http://127.0.0.1:3128
  export NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1
else
  # Its log goes to stderr: the box's stdout is the command's alone (`airlock exec`, `claude -p`).
  # The firewall runs as root before anything else is in place, so it gets an environment of
  # its own: the system PATH, root's HOME (curl reads .curlrc from HOME, CURL_HOME or
  # XDG_CONFIG_HOME) and only the three settings it reads. Whatever else the box was started
  # with (a secret, an engine -e) never reaches it.
  fw_env=( PATH="$PATH" HOME=/root )
  for v in AIRLOCK_EGRESS_GROUPS AIRLOCK_EXTRA_EGRESS AIRLOCK_HOST_DNS; do
    [ -z "${!v+set}" ] || fw_env+=( "$v=${!v}" )
  done
  env -i "${fw_env[@]}" /usr/local/bin/init-firewall.sh >&2
fi

# Prove the drop before trusting it: a process started the way the command will be (the same
# gosu, by its full path) must show all four of its inheritable, permitted, effective and
# ambient sets, each empty, and no_new_privs set. The bounding set keeps the box's list; with
# those empty and no_new_privs set, nothing in the box can raise one. Missing lines (a runtime
# whose status lacks one) fail too: a check that saw nothing proves nothing.
# shellcheck disable=SC2016  # an awk program: its $1/$2 are awk fields
held="$(/usr/sbin/gosu dev awk '
  /^Cap(Inh|Prm|Eff|Amb):/ { n++; if ($2 !~ /^0+$/) printf "%s%s ", $1, $2 }
  /^NoNewPrivs:/ { nnp = $2 }
  END { if (n != 4) printf "%d of 4 capability lines ", n
        if (nnp != 1) printf "NoNewPrivs %s ", (nnp == "" ? "missing" : nnp) }' /proc/self/status)"
if [ -n "$held" ]; then
  echo "[airlock] ERROR: the drop to dev is not clean (${held% }); not starting" >&2
  exit 1
fi

export HOME=/home/dev
export PATH="$AGENT_PATH"
# The command runs under an init, started after the drop, so it runs as dev with no
# usable capability and no root process outlives this script. Without one the command itself
# is PID 1: it reaps nothing, so every orphan stays a zombie until the box ends and counts
# against the pid limit, and a signal it has no handler for is ignored. dumb-init reaps,
# passes signals on and exits with the command's status. Its default mode makes the
# command a session leader that keeps the terminal, the place the command had as PID 1,
# so the terminal behaves as before (job control in `airlock shell` included).
# DUMB_INIT_SETSID=0 would switch that mode off and DUMB_INIT_DEBUG would write to the
# terminal: the box's environment (secrets included) does not configure its init.
while IFS= read -r _v; do unset "$_v"; done < <(compgen -e DUMB_INIT_ || true)
exec /usr/sbin/gosu dev /usr/bin/dumb-init -- "$@"
