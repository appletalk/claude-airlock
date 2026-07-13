#!/usr/bin/env bash
#
# claude-airlock egress firewall.
#
# Default-DROP on OUTPUT. Allow only: the baked allowlist (firewall.conf, whose
# CORE lines are always on and whose GROUP-tagged lines apply only when their group
# is active), GitHub's published CIDR ranges (the "github" group), and any domains
# passed at run time via AIRLOCK_EXTRA_EGRESS. Active groups come from the host via
# AIRLOCK_EGRESS_GROUPS (empty = minimal / core-only). Runs as root from the
# entrypoint before Claude starts; the agent user cannot change this.
#
# Known limitation (MVP): allowlist domains are resolved once, here. If an
# allowed host rotates IPs mid-session, new IPs won't be permitted until the
# next container start.
set -euo pipefail
IFS=$'\n\t'

CONF_FILE="/etc/airlock/firewall.conf"
IP_REGEX='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
CIDR_REGEX='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$'

log() { echo "[airlock-fw] $*"; }

# Active egress groups (host-set; empty = minimal / core-only). A group-tagged
# firewall.conf line is honored only when its group is listed here. NB: do NOT name
# this GROUPS — that's a bash special variable (the user's gid array); assigning to
# it trips errexit and reading it returns a gid, not our list.
_egroups="${AIRLOCK_EGRESS_GROUPS:-}"
ACTIVE_GROUPS=" ${_egroups//,/ } "
group_active() { case "$ACTIVE_GROUPS" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
log "egress groups: ${AIRLOCK_EGRESS_GROUPS:-<none: minimal>}"

# --- Assemble allowed domains: core (always) + active groups + AIRLOCK_EXTRA_EGRESS ---
DOMAINS=()
if [ -f "$CONF_FILE" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | xargs || true)"
    [ -z "$line" ] && continue
    case "$line" in
      *:*)                                  # "group:domain" — only if group active
        grp="${line%%:*}"; dom="${line#*:}"
        group_active "$grp" || { log "skip $dom (group '$grp' inactive)"; continue; }
        DOMAINS+=("$dom") ;;
      *) DOMAINS+=("$line") ;;              # untagged core line — always
    esac
  done < "$CONF_FILE"
fi
if [ -n "${AIRLOCK_EXTRA_EGRESS:-}" ]; then
  for d in ${AIRLOCK_EXTRA_EGRESS//,/ }; do DOMAINS+=("$d"); done
fi
log "allowlist domains: ${#DOMAINS[@]}"

# --- Preserve Docker embedded DNS (127.0.0.11) before flushing ---
DOCKER_DNS_RULES="$(iptables-save -t nat | grep '127\.0\.0\.11' || true)"
iptables -F; iptables -X
iptables -t nat -F; iptables -t nat -X
iptables -t mangle -F; iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true
ipset destroy github-ranges 2>/dev/null || true
if [ -n "$DOCKER_DNS_RULES" ]; then
  iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
  iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
  echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
fi

# --- Baseline: loopback + DNS (needed to resolve the allowlist) ---
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A INPUT  -p udp --sport 53 -j ACCEPT

# --- Resolve allowlist domains into an ipset ---
ipset create allowed-domains hash:net
for dom in "${DOMAINS[@]}"; do
  ips="$(dig +short A "$dom" | grep -E "$IP_REGEX" || true)"
  if [ -z "$ips" ]; then log "WARN: could not resolve $dom"; continue; fi
  while read -r ip; do
    # A duplicate IP (two allowlisted names resolving to the same host) makes `ipset add`
    # fail; that is benign, so it must not abort the run under errexit.
    if [ -n "$ip" ]; then ipset add allowed-domains "$ip" 2>/dev/null || true; fi
  done <<< "$ips"
done

# --- GitHub published CIDR ranges (git + api + web) — only in the "github" group ---
# The ipset is always created (the iptables rules below reference it); it just
# stays empty when the group is inactive, so GitHub is unreachable in minimal mode.
ipset create github-ranges hash:net
if group_active github; then
  gh_meta="$(curl -fsS https://api.github.com/meta || true)"
  if echo "$gh_meta" | jq -e '.git and .api and .web' >/dev/null 2>&1; then
    while read -r cidr; do
      # Skip anything that isn't a v4 CIDR, and tolerate a duplicate/overlapping range
      # (`aggregate` should collapse those, but a failed add must not abort under errexit).
      if [[ "$cidr" =~ $CIDR_REGEX ]]; then ipset add github-ranges "$cidr" 2>/dev/null || true; fi
    done < <(echo "$gh_meta" | jq -r '(.git + .api + .web)[]' | grep -v ':' | aggregate -q 2>/dev/null || true)
    log "github ranges loaded"
  else
    log "WARN: could not load GitHub ranges"
  fi
else
  log "github group inactive — GitHub unreachable"
fi

# --- NO blanket allow for the container's own /24 ---
# There is deliberately no rule accepting the subnet derived from the default route.
# Do not add one back. It is unnecessary, and it is dangerous:
#
#   * Unnecessary — DNS is already covered by the explicit port-53 rules above, and
#     Docker's embedded resolver (127.0.0.11) by the loopback rule. Nothing else in the
#     box has any business talking to the gateway.
#   * Dangerous — the container's default route is not always a private bridge. Under
#     rootless podman with pasta the box INHERITS THE HOST'S NETWORK CONFIG, so the
#     default gateway is the host's real LAN gateway; deriving a /24 from it and
#     ACCEPTing it hands the sandbox a slice of your actual local network. That is the
#     lateral movement this firewall exists to prevent.
#
# The allowlist below is the only way out of this box.

# --- Default DROP + established ---
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# --- Permit HTTPS (and git-ssh to GitHub) to the allowed sets ---
iptables -A OUTPUT -p tcp --dport 443 -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -p tcp --dport 443 -m set --match-set github-ranges  dst -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22  -m set --match-set github-ranges  dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# --- Self-verify: containment holds, Claude reachable ---
if curl --connect-timeout 5 -s https://example.com >/dev/null 2>&1; then
  log "ERROR: egress NOT contained — reached example.com"; exit 1
fi
log "OK: example.com blocked"
if ! curl --connect-timeout 5 -s https://api.anthropic.com >/dev/null 2>&1; then
  log "WARN: api.anthropic.com unreachable — Claude may not work"
else
  log "OK: api.anthropic.com reachable"
fi
log "firewall ready"
