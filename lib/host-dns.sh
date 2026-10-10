# shellcheck shell=bash
#
# Which network and resolvers a box is given, and which the firewall may pin port 53 to.
# Sourced by bin/claude-airlock and scripts/airlock-doctor.sh, so a doctor box gets the
# same network, the same resolv.conf and the same pinning rule as a real one.
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

# The probe's cache is these shell variables: never one inherited from the environment.
unset _AIRLOCK_PODMAN_PROBED _AIRLOCK_PODMAN_VER _AIRLOCK_PODMAN_REMOTE _AIRLOCK_PASTA_EXE \
  _AIRLOCK_PASTA_VER

# What a pasta box's network depends on, from ONE podman query, cached in the calling
# shell (call it there first; the functions below also call it, in their subshells):
# podman's version, whether it is remote, and the pasta binary it actually runs and that
# binary's version line. That pasta is podman's helper_binaries_dir one, not whatever
# `pasta` is first on PATH. `podman info` costs ~0.4s, so only pasta launches ask.
airlock_podman_probe() {
  [ -n "${_AIRLOCK_PODMAN_PROBED:-}" ] && return 0
  _AIRLOCK_PODMAN_PROBED=1 _AIRLOCK_PODMAN_VER="" _AIRLOCK_PODMAN_REMOTE="" _AIRLOCK_PASTA_EXE=""
  _AIRLOCK_PASTA_VER=""
  local info
  # .Host.Pasta.Version is pasta's whole multi-line --version: last, so `read` keeps line 1.
  info="$(podman info --format \
    '{{.Version.Version}}|{{.Host.ServiceIsRemote}}|{{.Host.Pasta.Executable}}|{{.Host.Pasta.Version}}' \
    2>/dev/null)" || return 0
  IFS='|' read -r _AIRLOCK_PODMAN_VER _AIRLOCK_PODMAN_REMOTE _AIRLOCK_PASTA_EXE _AIRLOCK_PASTA_VER <<< "$info"
}

# --map-guest-addr is passed only to a pasta that has it (2024-08 and later; before
# 2025-04 such a pasta also rejects `none`, so the box does not start, loudly). An older
# one rejects the option and no box starts at all - Ubuntu 24.04 ships passt 2024-02-20 -
# and it has no such mapping to remove: measured there (podman 4.9.3), a box with no
# firewall reached a host listener on 0.0.0.0 through none of 169.254.1.2,
# host.containers.internal or the host's own address. Fails closed: the flag is dropped
# only when podman is local and the very pasta it runs lists no such option. That path
# is podman's view: under a wrapper (toolbox, distrobox) it names the OUTER host's pasta,
# and the same path here may be another binary, so it is asked only if its version line
# is the one podman reported. Never "retry without it": that would fail open on the
# pastas that list it but reject `none`.
airlock_pasta_maps_guest_addr() {
  airlock_podman_probe
  [ "$_AIRLOCK_PODMAN_REMOTE" = false ] || return 0
  case "$_AIRLOCK_PASTA_EXE" in /*) ;; *) return 0 ;; esac
  [ -x "$_AIRLOCK_PASTA_EXE" ] && [ -n "$_AIRLOCK_PASTA_VER" ] || return 0
  local help ver
  ver="$("$_AIRLOCK_PASTA_EXE" --version 2>&1)" || true   # captured, not piped: pipefail-proof
  [ "${ver%%$'\n'*}" = "$_AIRLOCK_PASTA_VER" ] || return 0
  help="$("$_AIRLOCK_PASTA_EXE" --help 2>&1)" || true
  case "$help" in *--map-guest-addr*) return 0 ;; esac
  return 1
}

# The podman --network argument for PODMAN_NETWORK. Under pasta it also removes pasta's
# 169.254.1.2 mapping to the host (why: bin/claude-airlock, engine args). Kept beside the
# --dns forwarder choice below, which must agree with it. Empty means pasta in both: an
# `AIRLOCK_PODMAN_NETWORK=` in the host config outlives the launcher's default, and a bare
# --network= is podman's own default, which keeps the mapping and gets no forwarder.
airlock_podman_network_arg() {  # PODMAN_NETWORK
  case "${1:-pasta}" in
    pasta)   if airlock_pasta_maps_guest_addr; then echo "--network=pasta:--map-guest-addr,none"
             else echo "--network=pasta"; fi ;;
    pasta:*) if airlock_pasta_maps_guest_addr; then echo "--network=$1,--map-guest-addr,none"
             else echo "--network=$1"; fi ;;
    *)       echo "--network=$1" ;;
  esac
}

# The DNS forwarder podman gives a pasta box, by podman version (containers/common's
# dnsForwardIpv4 at the version each podman release pins): 5.3 and later 169.254.1.1,
# 5.0.1 to 5.2.x 169.254.0.1, 5.0.0 and older none - naming one there leaves the box with
# no DNS (measured on 4.9.3: --dns=169.254.1.1 resolved nothing; podman's default, a copy
# of the host's resolvers, worked). An unreadable version is taken as current; the
# doctor shows a box without DNS as a failed reachability check, not as contained.
airlock_podman_pasta_dns_forward() {
  airlock_podman_probe
  local maj min pat
  IFS=. read -r maj min pat <<< "${_AIRLOCK_PODMAN_VER%%[!0-9.]*}"
  pat="${pat%%[!0-9]*}"
  case "$maj:$min" in *[!0-9:]*|:*|*:) echo 169.254.1.1; return 0 ;; esac
  if [ "$maj" -gt 5 ] || { [ "$maj" -eq 5 ] && [ "$min" -ge 3 ]; }; then echo 169.254.1.1
  elif [ "$maj" -eq 5 ] && { [ "$min" -gt 0 ] || [ "${pat:-0}" -ge 1 ]; }; then echo 169.254.0.1
  fi
}

# Resolvers to hand the engine as --dns, one per line. AIRLOCK_DNS (host config) wins on
# either engine. Docker's default bridge has no forwarder, so it gets none and keeps its
# own list, which the firewall then filters; so does a podman too old for pasta's.
airlock_dns_forwarders() {  # ENGINE PODMAN_NETWORK
  if [ -n "${AIRLOCK_DNS:-}" ]; then
    # shellcheck disable=SC2086  # word-split on purpose: a space-separated list
    printf '%s\n' $AIRLOCK_DNS
    return 0
  fi
  [ "$1" = podman ] || return 0
  case "${2:-pasta}" in
    pasta|pasta:*) airlock_podman_pasta_dns_forward ;;
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
