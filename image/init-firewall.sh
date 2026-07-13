#!/usr/bin/env bash
#
# claude-airlock egress firewall.
#
# Default-DROP on OUTPUT, for BOTH IPv4 AND IPv6. Allow only: the baked allowlist
# (firewall.conf, whose CORE lines are always on and whose GROUP-tagged lines apply only
# when their group is active), GitHub's published CIDR ranges (the "github" group), and
# any domains passed at run time via AIRLOCK_EXTRA_EGRESS. Active groups come from the
# host via AIRLOCK_EGRESS_GROUPS (empty = minimal / core-only). Runs as root from the
# entrypoint before Claude starts; the agent user cannot change this.
#
# IPv6 IS NOT OPTIONAL. This firewall was IPv4-only until a container on an
# IPv6-enabled host walked straight out to example.com over IPv6 while every iptables
# rule sat there looking correct: curl prefers AAAA, ip6tables was untouched, and the
# default v6 policy is ACCEPT. A single unfiltered address family is a total bypass —
# an agent could exfiltrate to anything with an AAAA record and the firewall would
# never see the packet. Both families are therefore programmed identically, and if
# IPv6 is reachable but unfilterable we ABORT rather than run half-contained.
#
# Known limitation (MVP): allowlist domains are resolved once, here. If an allowed host
# rotates IPs mid-session, new IPs won't be permitted until the next container start.
set -euo pipefail
IFS=$'\n\t'

CONF_FILE="/etc/airlock/firewall.conf"
IP_REGEX='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
CIDR_REGEX='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$'
IP6_REGEX='^[0-9a-fA-F:]+$'
CIDR6_REGEX='^[0-9a-fA-F:]+/[0-9]{1,3}$'

log() { echo "[airlock-fw] $*"; }
die() { log "ERROR: $*"; exit 1; }

# --- Can we filter IPv6, and do we even have it? -----------------------------------
# The dangerous combination is "the box can reach the v6 internet" + "we cannot program
# ip6tables". That is a silent fail-open, so it is a hard error. Having no IPv6 at all
# is fine (nothing to contain); we still install the v6 DROP policy defensively in case
# an address appears later.
HAVE_V6_ADDR=0
ip -6 addr show scope global 2>/dev/null | grep -q inet6 && HAVE_V6_ADDR=1
HAVE_IP6TABLES=0
if command -v ip6tables >/dev/null 2>&1 && ip6tables -L -n >/dev/null 2>&1; then
  HAVE_IP6TABLES=1
fi
if [ "$HAVE_IP6TABLES" = 0 ]; then
  if [ "$HAVE_V6_ADDR" = 1 ]; then
    die "this box has global IPv6 but ip6tables is unusable — cannot contain v6 egress. Refusing to start half-contained."
  fi
  log "WARN: ip6tables unavailable; no global IPv6 on this box, so nothing to contain."
fi

# Run an ip6tables command only when v6 filtering is available.
ip6() { [ "$HAVE_IP6TABLES" = 1 ] && ip6tables "$@"; return 0; }

# Active egress groups (host-set; empty = minimal / core-only). A group-tagged
# firewall.conf line is honored only when its group is listed here. NB: do NOT name
# this GROUPS — that's a bash special variable (the user's gid array); assigning to
# it trips errexit and reading it returns a gid, not our list.
_egroups="${AIRLOCK_EGRESS_GROUPS:-}"
ACTIVE_GROUPS=" ${_egroups//,/ } "
group_active() { case "$ACTIVE_GROUPS" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
log "egress groups: ${AIRLOCK_EGRESS_GROUPS:-<none: minimal>}"
log "ipv6: address=$([ "$HAVE_V6_ADDR" = 1 ] && echo yes || echo no) filtering=$([ "$HAVE_IP6TABLES" = 1 ] && echo yes || echo no)"

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
# A no-op under podman (which has no 127.0.0.11 resolver); harmless to keep for Docker.
DOCKER_DNS_RULES="$(iptables-save -t nat | grep '127\.0\.0\.11' || true)"
iptables -F; iptables -X
iptables -t nat -F; iptables -t nat -X
iptables -t mangle -F; iptables -t mangle -X
ip6 -F; ip6 -X
ipset destroy allowed-domains    2>/dev/null || true
ipset destroy allowed-domains-v6 2>/dev/null || true
ipset destroy github-ranges      2>/dev/null || true
ipset destroy github-ranges-v6   2>/dev/null || true
if [ -n "$DOCKER_DNS_RULES" ]; then
  iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
  iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
  echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
fi

# --- Baseline: loopback + DNS (needed to resolve the allowlist), both families ---
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A INPUT  -p udp --sport 53 -j ACCEPT
ip6 -A OUTPUT -o lo -j ACCEPT
ip6 -A INPUT  -i lo -j ACCEPT
ip6 -A OUTPUT -p udp --dport 53 -j ACCEPT
ip6 -A OUTPUT -p tcp --dport 53 -j ACCEPT
ip6 -A INPUT  -p udp --sport 53 -j ACCEPT

# --- Resolve allowlist domains into per-family ipsets ---
# A and AAAA both: a domain reachable over v6 must be allowed over v6, or Claude breaks
# on an IPv6-preferring host. A domain with no AAAA simply contributes nothing to the v6
# set — which is correct, not an error.
ipset create allowed-domains    hash:net
ipset create allowed-domains-v6 hash:net family inet6
for dom in "${DOMAINS[@]}"; do
  resolved=0
  ips="$(dig +short A "$dom" | grep -E "$IP_REGEX" || true)"
  if [ -n "$ips" ]; then
    resolved=1
    while read -r ip; do
      # A duplicate IP (two allowlisted names resolving to the same host) makes `ipset add`
      # fail; that is benign, so it must not abort the run under errexit.
      if [ -n "$ip" ]; then ipset add allowed-domains "$ip" 2>/dev/null || true; fi
    done <<< "$ips"
  fi
  ips6="$(dig +short AAAA "$dom" | grep -E "$IP6_REGEX" || true)"
  if [ -n "$ips6" ]; then
    resolved=1
    while read -r ip6addr; do
      if [ -n "$ip6addr" ]; then ipset add allowed-domains-v6 "$ip6addr" 2>/dev/null || true; fi
    done <<< "$ips6"
  fi
  [ "$resolved" = 0 ] && log "WARN: could not resolve $dom"
done

# --- GitHub published CIDR ranges (git + api + web) — only in the "github" group ---
# The ipsets are always created (the rules below reference them); they just stay empty
# when the group is inactive, so GitHub is unreachable in minimal mode. GitHub publishes
# both v4 and v6 CIDRs; we used to `grep -v ':'` the v6 ones away, which — combined with
# an unfiltered v6 stack — meant GitHub was reachable over v6 even in minimal mode.
ipset create github-ranges    hash:net
ipset create github-ranges-v6 hash:net family inet6
if group_active github; then
  gh_meta="$(curl -fsS https://api.github.com/meta || true)"
  if echo "$gh_meta" | jq -e '.git and .api and .web' >/dev/null 2>&1; then
    gh_cidrs="$(echo "$gh_meta" | jq -r '(.git + .api + .web)[]')"
    # `aggregate` collapses IPv4 ranges only; feed it just the v4 set.
    while read -r cidr; do
      if [[ "$cidr" =~ $CIDR_REGEX ]]; then ipset add github-ranges "$cidr" 2>/dev/null || true; fi
    done < <(echo "$gh_cidrs" | grep -v ':' | aggregate -q 2>/dev/null || true)
    while read -r cidr; do
      if [[ "$cidr" =~ $CIDR6_REGEX ]]; then ipset add github-ranges-v6 "$cidr" 2>/dev/null || true; fi
    done < <(echo "$gh_cidrs" | grep ':' || true)
    log "github ranges loaded (v4: $(ipset list github-ranges | grep -c '^[0-9]' || true), v6: $(ipset list github-ranges-v6 | grep -c ':' || true))"
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

# --- Default DROP + established, BOTH families ---
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ip6 -P INPUT DROP
ip6 -P FORWARD DROP
ip6 -P OUTPUT DROP
ip6 -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
ip6 -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# --- Permit HTTPS (and git-ssh to GitHub) to the allowed sets, both families ---
iptables -A OUTPUT -p tcp --dport 443 -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -p tcp --dport 443 -m set --match-set github-ranges  dst -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22  -m set --match-set github-ranges  dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
ip6 -A OUTPUT -p tcp --dport 443 -m set --match-set allowed-domains-v6 dst -j ACCEPT
ip6 -A OUTPUT -p tcp --dport 443 -m set --match-set github-ranges-v6   dst -j ACCEPT
ip6 -A OUTPUT -p tcp --dport 22  -m set --match-set github-ranges-v6   dst -j ACCEPT
ip6 -A OUTPUT -j REJECT --reject-with icmp6-adm-prohibited

# --- Self-verify: containment must hold on EVERY family the box can actually use ---
# Both directions matter. A firewall that blocks everything would pass a block-only
# check while being useless; one that allows everything would pass a reachability check
# while containing nothing. And the check must be per-family: this whole class of bug
# existed because the v4 test passed while v6 walked out the back door.
if curl -4 --connect-timeout 5 -s https://example.com >/dev/null 2>&1; then
  die "egress NOT contained over IPv4 — reached example.com"
fi
log "OK: example.com blocked (IPv4)"

if [ "$HAVE_V6_ADDR" = 1 ]; then
  if curl -6 --connect-timeout 5 -s https://example.com >/dev/null 2>&1; then
    die "egress NOT contained over IPv6 — reached example.com. The v6 rules did not take effect."
  fi
  log "OK: example.com blocked (IPv6)"
else
  log "OK: no global IPv6 on this box (nothing to contain)"
fi

if ! curl --connect-timeout 5 -s https://api.anthropic.com >/dev/null 2>&1; then
  log "WARN: api.anthropic.com unreachable — Claude may not work"
else
  log "OK: api.anthropic.com reachable"
fi
log "firewall ready"
