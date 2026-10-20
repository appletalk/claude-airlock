#!/usr/bin/env bash
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
  setsid gosu dev socat -lf /tmp/airlock-proxy.log \
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
  /usr/local/bin/init-firewall.sh
fi

# A tea login the launcher wrote for this box (a Forgejo host behind the proxy): tea reads only
# ~/.config/tea, so it goes there. Its token is a placeholder the proxy replaces. Done as dev:
# the mount is the launching user's (dev here) and 0700, which root without capabilities can't
# even look into, and dev writing its own home never follows a link anywhere dev couldn't write.
# shellcheck disable=SC2016  # expanded by dev's shell, not here
HOME=/home/dev gosu dev sh -c 'f=/etc/airlock-box/tea/config.yml
  [ -f "$f" ] || exit 0
  mkdir -p -m 0700 "$HOME/.config/tea" && install -m 0600 "$f" "$HOME/.config/tea/config.yml"' \
  || echo "[airlock] WARNING: could not install the box tea login (tea will have no login)" >&2

export HOME=/home/dev
export PATH="$AGENT_PATH"
exec gosu dev "$@"
