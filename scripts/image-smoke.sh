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
  else
    echo "image-smoke: $CONFIG_FILE did not run to the end; testing the default network and resolvers" >&2
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
box_args=(
  --rm --log-driver none
  "${net_args[@]}"
  -e "AIRLOCK_HOST_DNS=$(airlock_host_nameservers)"
  --cap-drop=ALL
  --cap-add=NET_ADMIN --cap-add=NET_RAW --cap-add=SETUID --cap-add=SETGID
  --security-opt=no-new-privileges
  --security-opt "seccomp=$REPO_DIR/image/seccomp.json"
  -e AIRLOCK_EGRESS_GROUPS=""
)

# The box's init, through the image's real entrypoint (the checks below bypass it), in both
# postures: PID 1 is dumb-init as dev, no process has uid or gid 0 or a usable capability,
# every one runs with no_new_privs, an orphan is reaped, and a DUMB_INIT_SETSID from the
# environment does not change the init's mode. The user namespace is the launcher's
# (keep-id under podman, with --user=0:0 as the launcher passes it: keep-id alone would start
# the entrypoint as dev, keeping the added capabilities in the ambient set, and the checks
# would rightly fail), so the uids are a real box's.
init_tmp="$(mktemp -d)"
trap 'rm -rf "$init_tmp"' EXIT
userns_args=()
[ "$ENGINE" != podman ] || userns_args=( "--userns=keep-id:uid=1000,gid=1000" --user=0:0 )
init_mount=( -v "$REPO_DIR/scripts/init-checks.sh:/usr/local/bin/init-checks:ro" -e DUMB_INIT_SETSID=0 )
# init_box <title> <run args...>: the checks as the box's command; the box's stderr (the
# firewall's log, the entrypoint's refusals) is shown only if it fails.
init_box() {
  local title=$1; shift
  printf '\033[1mbox init, through the entrypoint (%s)\033[0m\n' "$title"
  if ! "$ENGINE" run "$@" "$IMAGE" bash /usr/local/bin/init-checks 2>"$init_tmp/err"; then
    sed 's/^/  stderr: /' "$init_tmp/err" >&2
    echo "image-smoke: the box init checks FAILED in the $title posture (see above)" >&2
    exit 1
  fi
}
init_box firewall "${box_args[@]}" "${userns_args[@]}" "${init_mount[@]}"
# The proxy posture as the launcher starts it: no network, no firewall capabilities, a host
# Unix socket bridged inside by socat (started as dev by the entrypoint). The socket here is
# a bound one that nothing serves: the bridge only has to start, not reach a proxy.
sock="$init_tmp/proxy.sock"
command -v python3 >/dev/null 2>&1 || { echo "image-smoke: python3 is needed on the host to make the proxy box's throwaway socket" >&2; exit 1; }
python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$sock"
[ -S "$sock" ] || { echo "image-smoke: could not make the proxy box's socket at $sock" >&2; exit 1; }
init_box proxy --rm --log-driver none --network=none \
  --cap-drop=ALL --cap-add=SETUID --cap-add=SETGID --security-opt=no-new-privileges \
  --security-opt "seccomp=$REPO_DIR/image/seccomp.json" \
  -v "$sock:$sock:ro" -e "AIRLOCK_EGRESS_PROXY=$sock" \
  "${userns_args[@]}" "${init_mount[@]}"

"$ENGINE" run "${box_args[@]}" \
  -v "$REPO_DIR/test/fixtures/validators:/fixtures:ro" \
  -v "$REPO_DIR/scripts/validator-checks.sh:/usr/local/bin/validator-checks:ro" \
  -v "$REPO_DIR/scripts/seccomp-checks.py:/usr/local/lib/seccomp-checks.py:ro" \
  --entrypoint /bin/bash "$IMAGE" -c \
  '/usr/local/bin/init-firewall.sh >/dev/null 2>&1 || { echo "image-smoke: firewall failed to come up" >&2; exit 1; }
   printf "\033[1mseccomp profile, by behaviour\033[0m\n"
   gosu dev python3 -I /usr/local/lib/seccomp-checks.py || exit 1
   exec gosu dev /usr/local/bin/validator-checks /fixtures'
