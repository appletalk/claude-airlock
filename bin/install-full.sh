#!/usr/bin/env bash
# make install: everything claude-airlock puts on this host, in order, as the user who works here
# (sudo for the machine-wide steps). Safe to rerun: a step with nothing to do says so.
#
#   make install          says what each step does and asks [Y/n/q] before it (n skips it,
#                         q stops); a step already current skips itself
#   make install YES=1    every step, no questions (scripts, or when you know)
#
# The steps:
#   1. the launcher and images, for you            (bin/install.sh; make install-airlock alone)
#   2. the agents toolkit, then its apply           (sudo; agents/install.sh; make install-agents
#                                                    alone). Only where agents are set up, or if
#                                                    you choose to set them up now
#   3. the audit store's binaries to their pins     (sudo update-victorialogs; with audit on),
#      then the store restarted if one changed      (sudo airlock-audit restart)
#   4. the agents get your launcher                 (<command> update: long, it builds their
#                                                    images)
#   5. the agents' user units reread                (<command> reload)
#   6. the audit store checked                      (sudo airlock-audit check; with audit on)
# gVisor's runsc is only reported here (an update replaces the runtime under running boxes):
# sudo update-runsc when the sessions are stopped.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${AIRLOCK_AGENTS_ENV:-/etc/claude-airlock/agents/agents.env}"   # test hook: another agents.env
SBIN="${AIRLOCK_SBIN:-/usr/local/sbin}"                                # test hook: stubs instead
YES="${YES:-}"
[ "$(id -u)" != 0 ] || { echo "make install: run it as yourself (it uses sudo where it must)" >&2; exit 1; }

n=0
# ask <what>: 0 to run the step, 1 to skip it; q stops everything.
ask() {
    n=$((n + 1))
    printf '\n==> %d. %s\n' "$n" "$1"
    [ "$YES" != 1 ] || return 0
    { exec 3</dev/tty; } 2>/dev/null || { echo "make install: no terminal to ask on; rerun with YES=1 to answer yes to every step" >&2; exit 1; }
    local a
    read -r -u 3 -p "    run it? [Y/n/q] " a || a=q
    exec 3<&-
    case "$a" in ''|[yY]*) return 0 ;; [qQ]*) echo "stopped; rerun make install to go on"; exit 0 ;; *) echo "    skipped"; return 1 ;; esac
}
# The agents' names as the toolkit's apply rendered them (none: no agents here).
agents_env() { [ -r "$ENV_FILE" ] && grep -E "^$1=[A-Za-z0-9_./-]*$" "$ENV_FILE" | cut -d= -f2; }

if ask "the launcher and images for $(id -un) (bin/install.sh)"; then
    bash "$REPO_DIR/bin/install.sh"
fi

if [ -r "$ENV_FILE" ]; then
    if ask "the agents toolkit and its apply (sudo bash agents/install.sh)"; then
        sudo bash "$REPO_DIR/agents/install.sh"
    fi
elif [ "$YES" != 1 ]; then
    n=$((n + 1))
    printf '\n==> %d. agent users: none set up here (docs/agents.md)\n' "$n"
    { exec 3</dev/tty; } 2>/dev/null && read -r -u 3 -p "    set them up now (sudo make install-agents asks its questions)? [y/N] " a && exec 3<&- || a=n
    case "${a:-n}" in [yY]*) sudo bash "$REPO_DIR/agents/install.sh" ;; *) echo "    skipped" ;; esac
fi

COMMAND="$(agents_env AGENTS_COMMAND || true)" OPERATOR="$(agents_env AGENTS_OPERATOR || true)" AUDIT="$(agents_env AGENTS_AUDIT || true)"

if [ "$AUDIT" = on ]; then
    if ask "the audit store's binaries to their pins (sudo update-victorialogs), and the store restarted if one changed"; then
        rc=0; out="$(sudo "$SBIN/update-victorialogs" 2>&1)" || rc=$?
        printf '%s\n' "$out"
        [ "$rc" = 0 ] || { echo "make install: update-victorialogs failed (above)" >&2; exit 1; }
        if grep -q '^==> installed ' <<< "$out"; then sudo "$SBIN/airlock-audit" restart
        else echo "    nothing changed: the store keeps running"; fi
    fi
fi

if [ -n "$COMMAND" ]; then
    if [ "$OPERATOR" != "$(id -un)" ]; then
        echo; echo "==> the agents' own steps are $OPERATOR's: as $OPERATOR, $COMMAND update, then $COMMAND reload"
    else
        if ask "the agents get your launcher ($COMMAND update: long, it builds their images)"; then
            "$COMMAND" update
        fi
        if ask "the agents' user units reread ($COMMAND reload)"; then
            "$COMMAND" reload
        fi
    fi
fi

if [ "$AUDIT" = on ]; then
    if ask "the audit store checked (sudo airlock-audit check)"; then
        sudo "$SBIN/airlock-audit" check
    fi
fi

if [ -x "$SBIN/update-runsc" ] && [ -n "$COMMAND" ]; then
    rc=0; sudo "$SBIN/update-runsc" --check >/dev/null 2>&1 || rc=$?
    [ "$rc" != 10 ] || echo "note: a gVisor (runsc) update is waiting: stop the agents' sessions, then sudo update-runsc"
fi
echo; echo "==> make install: done"
