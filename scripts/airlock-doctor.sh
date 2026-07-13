#!/usr/bin/env bash
#
# airlock doctor — verify this host can run the sandbox, and that the egress
# firewall actually comes up under the selected engine.
#
# The interesting check is the last one. "The modules are loaded" and "a rootless
# box can raise a default-DROP firewall" are different claims, and only the second
# one matters. So we run a real throwaway container and make it prove containment:
# an allowed host must be reachable and a denied host must not be.
set -uo pipefail

ENGINE="${AIRLOCK_ENGINE:-podman}"
IMAGE="${AIRLOCK_IMAGE:-claude-airlock:base}"
fail=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$1"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

hdr "engine"
if ! command -v "$ENGINE" >/dev/null 2>&1; then
  bad "$ENGINE not on PATH"
  echo; echo "airlock doctor: cannot continue without a container engine." >&2
  exit 1
fi
ok "$ENGINE found ($("$ENGINE" --version 2>/dev/null | head -1))"

if [ "$ENGINE" = "docker" ]; then
  warn "docker: membership in the 'docker' group is root-equivalent on this host."
  warn "        prefer AIRLOCK_ENGINE=podman (rootless) — see README."
fi

if [ "$ENGINE" = "podman" ]; then
  hdr "rootless prerequisites"
  if [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ]; then
    ok "podman is running rootless (no daemon, no privileged socket)"
  else
    bad "podman is NOT rootless — the main reason to use it is lost"
  fi

  if grep -q "^${USER}:" /etc/subuid 2>/dev/null && grep -q "^${USER}:" /etc/subgid 2>/dev/null; then
    ok "subuid/subgid ranges present for $USER"
  else
    bad "no subuid/subgid range for $USER — rootless containers cannot map users"
    warn "     sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER"
  fi

  # The kernel will not autoload netfilter modules for a userns, so anything the
  # firewall needs must already be resident. Builtins are fine and report as such.
  hdr "netfilter modules (must be resident — a userns cannot autoload them)"
  missing=()
  for m in nft_compat ip_set ip_set_hash_net xt_set xt_conntrack; do
    if grep -qE "^${m} " /proc/modules 2>/dev/null || [ -d "/sys/module/${m}" ]; then
      ok "$m"
    else
      bad "$m not resident"
      missing+=("$m")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    warn "     # persist across reboots (needs systemd):"
    warn "     sudo install -m 0644 config/modules-load.d/airlock.conf \\"
    warn "         /etc/modules-load.d/airlock.conf"
    warn "     # and load them now, so you don't have to reboot:"
    warn "     grep -v '^#' config/modules-load.d/airlock.conf | xargs -r sudo modprobe"
    warn "     (on WSL2: set systemd=true under [boot] in /etc/wsl.conf, then wsl --shutdown)"
  fi
fi

hdr "image"
if "$ENGINE" image exists "$IMAGE" 2>/dev/null || "$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1; then
  ok "$IMAGE present"
else
  bad "$IMAGE not built — run: make install"
  echo; exit 1
fi

# The real test: containment must hold in a live box.
#
# init-firewall.sh already self-verifies in BOTH directions and on EVERY address family
# the box can use — a denied host must be unreachable and an allowed host reachable, over
# IPv4 and (where present) IPv6. So we simply run it and report what it says.
#
# We deliberately do NOT swallow its output. An earlier version redirected it to
# /dev/null, caught the non-zero exit, and printed "the firewall could not start" with a
# guess that the netfilter modules were missing — while the modules check directly above
# had just passed, and the true cause was an IPv6 egress leak the firewall had correctly
# detected and reported. A diagnostic that hides the error and then guesses is worse than
# no diagnostic: it sends you off fixing the wrong thing. Show the real message.
hdr "live containment test (throwaway box)"
if fw_out="$("$ENGINE" run --rm \
  --cap-drop=ALL \
  --cap-add=NET_ADMIN --cap-add=NET_RAW --cap-add=SETUID --cap-add=SETGID \
  --security-opt=no-new-privileges \
  -e AIRLOCK_EGRESS_GROUPS="" \
  --entrypoint /bin/bash "$IMAGE" -c '/usr/local/bin/init-firewall.sh' 2>&1)"; then
  # Surface each thing the firewall proved, rather than a bare "passed".
  while IFS= read -r line; do
    case "$line" in
      *"OK: "*)   ok   "${line#*OK: }" ;;
      *"WARN: "*) warn "${line#*WARN: }" ;;
    esac
  done <<< "$fw_out"
else
  bad "the box FAILED its containment check — it is NOT safe to run the agent in it"
  echo
  printf '%s\n' "$fw_out" | sed 's/^/        /'
  echo
  warn "     read the ERROR line above — that is the real cause."
  warn "     'egress NOT contained' means traffic escaped: the box could reach the"
  warn "     internet despite the firewall. Do not use the sandbox until it is fixed."
fi

hdr ""
if [ "$fail" -eq 0 ]; then
  printf '\033[32mall checks passed\033[0m — %s is ready.\n' "$ENGINE"
else
  printf '\033[31mchecks failed\033[0m — see above.\n'
fi
exit "$fail"
