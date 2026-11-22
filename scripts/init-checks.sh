#!/usr/bin/env bash
#
# init checks -- run as a box's command, through the image's real entrypoint (image-smoke.sh):
# prove the box's init is in place and nothing kept root.
#
#   - PID 1 is dumb-init, running as dev (real, effective, saved and fs uid all 1000);
#   - no process in the box has a uid or gid of 0 in any of its four slots or among its
#     supplementary groups (or lacks a Uid or Gid line), holds an
#     inheritable, permitted, effective or ambient capability, or runs without no_new_privs;
#     a process whose status can't be read (but still exists) counts as a failure;
#   - this command is a session leader (dumb-init's default mode, the place the command had as
#     PID 1: DUMB_INIT_SETSID=0 from the environment must not switch it off) and sees no
#     DUMB_INIT_* variable;
#   - no file on the box's root filesystem is setuid or setgid (the images strip every bit) or
#     carries file capabilities;
#   - an orphaned process is reaped: no zombie is left behind.
#
# PROC (default /proc) lets test/init-checks.bats run the same checks against a made-up tree;
# the orphan step needs the real one and is skipped when PROC is not /proc. ROOTFS (default /)
# is the tree searched for setuid and setgid files, for the same reason.
set -uo pipefail

PROC="${PROC:-/proc}"
while [ "$PROC" != / ] && [ "${PROC%/}" != "$PROC" ]; do PROC="${PROC%/}"; done   # /proc/ is /proc (the orphan step compares the name)
ROOTFS="${ROOTFS:-/}"
GETCAP="${GETCAP:-getcap}"
SELF="${SELF_PID:-$$}"
fail=0
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }
pass() { printf '  ok    %s\n' "$1"; }
# is <got> <want> <ok message> <fail message>
is() { if [ "$1" = "$2" ]; then pass "$3"; else bad "$4"; fi; }

# field <pid> <Name:> from <proc>/<pid>/status: every value on the line (Uid: and Gid: have
# four: real, effective, saved, filesystem)
field() { awk -v k="$2" '$1 == k { $1 = ""; sub(/^ +/, ""); print; exit }' "$PROC/$1/status" 2>/dev/null; }
comm() { cat "$PROC/$1/comm" 2>/dev/null || printf '?'; }
Z16=0000000000000000

comm1="$(comm 1)"
is "$comm1" dumb-init "PID 1 is dumb-init" "PID 1 is '${comm1:-?}', not dumb-init"
uid1="$(field 1 Uid:)"
is "$uid1" "1000 1000 1000 1000" "PID 1 runs as uid 1000 (all four slots)" "PID 1's uids are '${uid1:-?}'"

root=0 capped=0 nnp=0 unread=0 seen=0
for d in "$PROC"/[0-9]*; do
  p="${d##*/}"
  if [ ! -r "$d/status" ]; then
    # gone between the glob and now is fine; there but unreadable hides what it runs as
    [ ! -e "$d" ] || { unread=$((unread + 1)); printf '        unreadable: pid %s\n' "$p"; }
    continue
  fi
  seen=$((seen + 1))
  # four uids, four gids and the supplementary groups; a status without its Uid or Gid line
  # shows nothing to trust, so it counts as root
  u="$(field "$p" Uid:)" g="$(field "$p" Gid:)" grp="$(field "$p" Groups:)"
  case " $u $g $grp " in *" 0 "*) r=1 ;; *) r="" ;; esac
  [ -n "$u" ] && [ -n "$g" ] || r=1
  [ -z "$r" ] || { root=$((root + 1)); printf '        root: pid %s (%s) Uid %s Gid %s Groups %s\n' "$p" "$(comm "$p")" "${u:-?}" "${g:-?}" "${grp:--}"; }
  held=""
  for c in CapInh CapPrm CapEff CapAmb; do
    v="$(field "$p" "$c:")"; [ "${v:-x}" = "$Z16" ] || held="$held $c ${v:-?}"
  done
  [ -z "$held" ] || { capped=$((capped + 1)); printf '        caps: pid %s (%s)%s\n' "$p" "$(comm "$p")" "$held"; }
  [ "$(field "$p" NoNewPrivs:)" = 1 ] || { nnp=$((nnp + 1)); printf '        no_new_privs off: pid %s (%s)\n' "$p" "$(comm "$p")"; }
done
[ "$seen" -gt 0 ] || bad "no process readable under $PROC"
is "$unread" 0 "every process's status is readable" "$unread process(es) with an unreadable status"
is "$root" 0 "no process has uid or gid 0 ($seen seen)" "$root process(es) with uid or gid 0"
is "$capped" 0 "no process holds an inheritable, permitted, effective or ambient capability" "$capped process(es) hold capabilities"
is "$nnp" 0 "every process runs with no_new_privs" "$nnp process(es) without no_new_privs"

# The command's session: field 6 of stat, counted after the ") " that ends the comm field.
sid="$(sed 's/^.*) //' "$PROC/$SELF/stat" 2>/dev/null | awk '{ print $4 }')"
is "$sid" "$SELF" "the command is a session leader" "the command's session is '${sid:-?}', not its own ($SELF)"
if env | grep -q '^DUMB_INIT_'; then bad "the command sees DUMB_INIT_* variables"; else pass "no DUMB_INIT_* in the command's environment"; fi

# setuid/setgid: the root filesystem only (-xdev), so the workspace and other host mounts are not
# searched. find exits non-zero on directories dev can't read (/root and the like); a file in one
# of those can't be executed by dev either, so only what it can reach counts.
sx="$(find "$ROOTFS" -xdev -type f -perm /6000 -print 2>/dev/null || true)"
n="$(printf '%s' "$sx" | grep -c . || true)"
[ "$n" = 0 ] || printf '%s\n' "$sx" | head -20 | sed 's/^/        setuid\/setgid: /'
is "$n" 0 "no setuid or setgid file on the root filesystem" "$n setuid or setgid file(s) on the root filesystem"

# File capabilities are the other way a binary gains privilege without the bit. getcap prints
# only the files that carry some; without getcap there is nothing to vouch for it, so that fails.
if command -v "$GETCAP" >/dev/null 2>&1; then
  fc="$(find "$ROOTFS" -xdev -type f -exec "$GETCAP" {} + 2>/dev/null || true)"
  n="$(printf '%s' "$fc" | grep -c . || true)"
  [ "$n" = 0 ] || printf '%s\n' "$fc" | head -20 | sed 's/^/        file capabilities: /'
  is "$n" 0 "no file carries file capabilities" "$n file(s) carry file capabilities"
else
  bad "getcap is not available, so file capabilities were not checked"
fi

if [ "$PROC" = /proc ]; then
  # A child that backgrounds a sleep and exits: the sleep is reparented to PID 1 and, once it
  # ends, only PID 1 can reap it.
  sh -c 'sleep 0.2 &'
  sleep 1
  z=0
  for d in /proc/[0-9]*; do
    s="$(sed 's/^.*) //' "$d/stat" 2>/dev/null | awk '{ print $1 }')"
    [ "$s" != Z ] || z=$((z + 1))
  done
  is "$z" 0 "an orphan is reaped (no zombie left)" "$z zombie(s) left after an orphan"
fi

exit "$fail"
