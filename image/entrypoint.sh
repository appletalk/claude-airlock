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

/usr/local/bin/init-firewall.sh

export HOME=/home/dev
export PATH="$AGENT_PATH"
exec gosu dev "$@"
