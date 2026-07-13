#!/usr/bin/env bash
#
# Runs as root: raise the egress firewall, then drop to the unprivileged agent
# user before exec'ing the requested command (Claude by default).
set -euo pipefail

/usr/local/bin/init-firewall.sh

export HOME=/home/dev
exec gosu dev "$@"
