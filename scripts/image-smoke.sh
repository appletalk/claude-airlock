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

if ! command -v "$ENGINE" >/dev/null 2>&1; then
  echo "image-smoke: '$ENGINE' not on PATH." >&2
  exit 1
fi
if ! "$ENGINE" image exists "$IMAGE" 2>/dev/null && ! "$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "image-smoke: image '$IMAGE' not found -- run 'make install' first." >&2
  exit 1
fi

printf '\033[1mimage smoke: %s (engine %s, egress minimal)\033[0m\n' "$IMAGE" "$ENGINE"

# Same capability set the launcher and airlock-doctor use: enough to program
# netfilter and drop privileges, nothing more. The firewall is raised as root and
# the checks then run as the unprivileged dev user, exactly as a real session does.
"$ENGINE" run --rm \
  --cap-drop=ALL \
  --cap-add=NET_ADMIN --cap-add=NET_RAW --cap-add=SETUID --cap-add=SETGID \
  --security-opt=no-new-privileges \
  -e AIRLOCK_EGRESS_GROUPS="" \
  -v "$REPO_DIR/test/fixtures/validators:/fixtures:ro" \
  -v "$REPO_DIR/scripts/validator-checks.sh:/usr/local/bin/validator-checks:ro" \
  --entrypoint /bin/bash "$IMAGE" -c \
  '/usr/local/bin/init-firewall.sh >/dev/null 2>&1 || { echo "image-smoke: firewall failed to come up" >&2; exit 1; }
   exec gosu dev /usr/local/bin/validator-checks /fixtures'
