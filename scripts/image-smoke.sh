#!/usr/bin/env bash
#
# image smoke test -- prove the dev image's config validators actually work
# INSIDE a box, with the egress firewall up and no groups active.
#
# This exists because of a specific failure mode: a validator that needs the
# network degrades silently in a sandbox. terraform validate without providers,
# ansible-lint without collections, tflint without its ruleset plugin -- each can
# exit 0 while checking nothing. So the test runs the real image, raises the real
# firewall at MINIMAL egress (the default a project gets), and makes every tool
# reject a known-bad fixture. Passing the good fixture proves nothing on its own.
#
# Run: make image-smoke   (or AIRLOCK_IMAGE=... scripts/image-smoke.sh)
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${AIRLOCK_ENGINE:-podman}"
IMAGE="${AIRLOCK_IMAGE:-claude-airlock:dev}"
# The two keys that shape a box's network, resolved as bin/claude-airlock and the doctor do:
# the default, then the host config on top (install.sh passes neither). Only these two.
PODMAN_NETWORK="${AIRLOCK_PODMAN_NETWORK:-pasta}"
AIRLOCK_DNS="${AIRLOCK_DNS:-}"
CONFIG_FILE="${AIRLOCK_CONFIG:-$HOME/.config/claude-airlock/config}"
if [ -f "$CONFIG_FILE" ]; then
  # in a subshell without -u (a config may build on a default this script doesn't set); taken
  # only if the config ran to the end, as in scripts/airlock-doctor.sh
  _cfg="$(
    set +u
    AIRLOCK_PODMAN_NETWORK="$PODMAN_NETWORK" AIRLOCK_ENGINE="$ENGINE"
    # shellcheck disable=SC1090
    { source "$CONFIG_FILE"; } >/dev/null 2>&1
    trap - EXIT
    printf '%s\n%s\nend\n' "$AIRLOCK_PODMAN_NETWORK" "$AIRLOCK_DNS"
  )"
  if [ "${_cfg##*$'\n'}" = end ]; then
    { IFS= read -r PODMAN_NETWORK; IFS= read -r AIRLOCK_DNS; } <<< "$_cfg"
  fi
  unset _cfg
fi
export AIRLOCK_DNS
# shellcheck disable=SC1091  # linted on its own (Makefile SHELL_SCRIPTS)
source "$REPO_DIR/lib/host-dns.sh"

if ! command -v "$ENGINE" >/dev/null 2>&1; then
  echo "image-smoke: '$ENGINE' not on PATH." >&2
  exit 1
fi
if ! "$ENGINE" image exists "$IMAGE" 2>/dev/null && ! "$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "image-smoke: image '$IMAGE' not found -- run 'make install-airlock' first." >&2
  exit 1
fi

printf '\033[1mimage smoke: %s (engine %s, egress minimal)\033[0m\n' "$IMAGE" "$ENGINE"

# The same network and resolvers as a real box and the doctor's (lib/host-dns.sh). Without
# --dns, a host whose only resolver is loopback gets podman's fallback, Google Public DNS, in
# the box's resolv.conf, and every validator that resolves a name sends plain queries to
# 8.8.8.8 and 8.8.4.4 (seen on a host's audit store: pasta dropping a burst per smoke test).
net_args=()
if [ "$ENGINE" = podman ]; then
  case "$PODMAN_NETWORK" in pasta|pasta:*|'') airlock_podman_probe ;; esac
  net_args+=( "$(airlock_podman_network_arg "$PODMAN_NETWORK")" )
fi
while IFS= read -r ns; do
  if [ -n "$ns" ]; then net_args+=( "--dns=$ns" ); fi
done < <(airlock_dns_forwarders "$ENGINE" "$PODMAN_NETWORK")

# Same capability set the launcher and airlock-doctor use: enough to program
# netfilter and drop privileges, nothing more. The firewall is raised as root and
# the checks then run as the unprivileged dev user, exactly as a real session does.
"$ENGINE" run --rm --log-driver none \
  "${net_args[@]}" \
  -e "AIRLOCK_HOST_DNS=$(airlock_host_nameservers)" \
  --cap-drop=ALL \
  --cap-add=NET_ADMIN --cap-add=NET_RAW --cap-add=SETUID --cap-add=SETGID \
  --security-opt=no-new-privileges \
  --security-opt "seccomp=$REPO_DIR/image/seccomp.json" \
  -e AIRLOCK_EGRESS_GROUPS="" \
  -v "$REPO_DIR/test/fixtures/validators:/fixtures:ro" \
  -v "$REPO_DIR/scripts/validator-checks.sh:/usr/local/bin/validator-checks:ro" \
  -v "$REPO_DIR/scripts/seccomp-checks.py:/usr/local/lib/seccomp-checks.py:ro" \
  --entrypoint /bin/bash "$IMAGE" -c \
  '/usr/local/bin/init-firewall.sh >/dev/null 2>&1 || { echo "image-smoke: firewall failed to come up" >&2; exit 1; }
   printf "\033[1mseccomp profile, by behaviour\033[0m\n"
   gosu dev python3 -I /usr/local/lib/seccomp-checks.py || exit 1
   exec gosu dev /usr/local/bin/validator-checks /fixtures'
