# shellcheck shell=bash
#
# Which resolvers a box is told to use, and which the firewall may pin port 53 to.
# Sourced by bin/claude-airlock and scripts/airlock-doctor.sh, so a doctor box is judged
# by the same rule as a real one.
#
# The problem: when the host's only resolver is loopback (a local Unbound or dnsmasq on
# 127.0.0.1/::1), a container cannot use it, so podman and docker both fall back to
# Google Public DNS and append 8.8.8.8/8.8.4.4 (and the v6 pair) to the box's
# resolv.conf. The firewall pins port 53 to whatever resolv.conf names, so the box could
# send plaintext queries to a third party the host never chose, bypassing the host
# resolver entirely.
#
# Two layers:
#   * airlock_dns_forwarders - passed to the engine as --dns, so the box's resolv.conf
#     names the network stack's forwarder to the HOST resolver and nothing else.
#   * airlock_host_nameservers - passed to the firewall as AIRLOCK_HOST_DNS: the only
#     PUBLIC resolvers it may pin. Local ones (loopback, link-local, RFC1918, CGNAT, ULA)
#     are engine forwarders or the host's own LAN and are always allowed; a public one
#     the host is not configured with is an engine fallback, and is skipped.

# Resolvers to hand the engine as --dns, one per line. AIRLOCK_DNS (host config) wins on
# either engine. Docker's default bridge has no forwarder, so it gets none and keeps its
# own list, which the firewall then filters.
airlock_dns_forwarders() {  # ENGINE PODMAN_NETWORK
  if [ -n "${AIRLOCK_DNS:-}" ]; then
    # shellcheck disable=SC2086  # word-split on purpose: a space-separated list
    printf '%s\n' $AIRLOCK_DNS
    return 0
  fi
  [ "$1" = podman ] || return 0
  case "${2:-}" in
    pasta)       echo 169.254.1.1 ;;   # podman's default pasta --dns-forward address
    slirp4netns) echo 10.0.2.3 ;;      # slirp4netns' built-in DNS forwarder
  esac
}

# Every nameserver the host itself is configured with, space-separated. The
# systemd-resolved upstream file is read too: when /etc/resolv.conf is the 127.0.0.53
# stub, that file is what docker copies into the box instead. AIRLOCK_HOST_RESOLV_FILES
# exists for the test suite.
airlock_host_nameservers() {
  {
    # shellcheck disable=SC2086
    awk '/^[[:space:]]*nameserver[[:space:]]/ {print $2}' \
      ${AIRLOCK_HOST_RESOLV_FILES:-/etc/resolv.conf /run/systemd/resolve/resolv.conf} 2>/dev/null || true
    # shellcheck disable=SC2086
    [ -z "${AIRLOCK_DNS:-}" ] || printf '%s\n' $AIRLOCK_DNS
  } | sort -u | tr '\n' ' ' | sed 's/ *$//'
}
