# claude-airlock — zsh shell integration.
#
# Source this from ~/.zshrc or ~/.zshrc.local:
#     source /path/to/claude-airlock/shell/claude-airlock.zsh
#
# Provides:
#   airlock          run Claude Code inside the sandbox for the current project
#   alpaste          put the clipboard image where a box can read it (short for
#                    `airlock paste --copy`; `alpaste list [N]` shows recent ones)
#   claude           your normal host Claude, plus a cross-session lock warning
#   command claude   always bypasses the guard to reach the raw binary
#
# This is the canonical copy of the `claude` override. If you pasted it directly
# into your rc file, consider replacing that with a `source` of this file so
# there is a single source of truth.

# Resolve the repo's launcher relative to THIS file, so `airlock` works whether
# or not bin/claude-airlock is on PATH. Kept (not unset) because `alpaste` needs it:
# an alias would not expand inside a function body defined here.
_AIRLOCK_LAUNCHER="${${(%):-%x}:A:h:h}/bin/claude-airlock"
if [[ -x "$_AIRLOCK_LAUNCHER" ]]; then
  alias airlock="$_AIRLOCK_LAUNCHER"
else
  _AIRLOCK_LAUNCHER='claude-airlock'   # fall back to PATH (installed by bin/install.sh)
  alias airlock='claude-airlock'
fi

# Short name for the clipboard bridge, with --copy on by default: after it runs, the
# PATH is on your clipboard, so Ctrl+V into the agent's prompt pastes text and the agent
# opens the file. `alpaste list [N]` lists recent pastes and must NOT copy anything.
alpaste() {
  emulate -L zsh
  if [[ "${1:-}" == list ]]; then
    "$_AIRLOCK_LAUNCHER" paste "$@"
  else
    "$_AIRLOCK_LAUNCHER" paste --copy "$@"
  fi
}

# Lock-aware host Claude (guard only — runs your normal claude, no sandbox).
# Warns if an airlock (or another host) session is already live for this project,
# so you don't run the same session twice and corrupt shared --resume history.
# Kernel start-time token for a pid (field 22 of /proc/<pid>/stat), empty if it is gone.
# Mirrors _airlock_proc_start in the launcher: comm can contain spaces and parens, so
# strip through the FINAL ") " before indexing.
_airlock_pstart() {
  emulate -L zsh
  local s
  s="$(</proc/$1/stat)" 2>/dev/null || return 0
  s="${s##*\) }"
  print -r -- "${${(z)s}[20]}"
}

claude() {
  emulate -L zsh
  local slug lock pid kind start ans rc
  # Must match the launcher's `sed 's#^-*##'` exactly - it strips ALL leading dashes and
  # zsh's `#-` strips only one. They diverged on any path whose second character is not
  # alphanumeric (/.cache/proj -> -cache-proj here vs cache-proj there), which put this
  # session's scratch dir and lock under a different slug than the registry and than
  # every box on the same project.
  slug="${PWD//[^a-zA-Z0-9]/-}"
  while [[ "$slug" == -* ]]; do slug="${slug#-}"; done
  lock="$HOME/.config/claude-airlock/state/$slug/session.lock"
  if [[ -f "$lock" ]]; then
    read -r pid kind _ start < "$lock"
    # Identity, not just a number: a recycled pid would otherwise prompt on every launch
    # forever. Locks from older versions carry no 4th field, so fall back to a bare check.
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null \
       && { [[ -z "$start" ]] || [[ "$start" == "$(_airlock_pstart $pid)" ]] }; then
      print -u2 "claude: a ${kind} session for this project may already be open (pid $pid)."
      print -u2 "Two live sessions on one project can corrupt shared --resume history."
      print -n -u2 "Continue anyway? [y/N] "
      if ! read -r ans || [[ "$ans" != (y|Y|yes|YES) ]]; then
        print -u2 "Aborted."; return 1
      fi
    fi
  fi
  mkdir -p "${lock:h}" || return 1
  print "$$ host $(date +%s) $(_airlock_pstart $$)" > "$lock"
  # Same per-project scratch dir the box gets, at the same path, exported the same way.
  # Sessions are shared host<->box, so both sides must agree on where persistent scratch
  # lives — otherwise host Claude writes to bare /tmp and the box can't see it.
  # AIRLOCK_TMP_BASE mirrors the launcher's own default; both read it from the
  # environment so an override cannot make the two sides disagree.
  export AIRLOCK_TMP="${AIRLOCK_TMP_BASE:-/tmp/airlock}/$slug"
  # Not `mkdir -p ... && chmod ...`: a failing mkdir there was silent, and the session
  # then ran with a scratch path that does not exist.
  if ! mkdir -p "$AIRLOCK_TMP" 2>/dev/null; then
    print -u2 "claude: cannot create the per-project scratch dir $AIRLOCK_TMP"
    print -u2 "  Check ownership of ${AIRLOCK_TMP_BASE:-/tmp/airlock}."
    return 1
  fi
  chmod 700 "$AIRLOCK_TMP"
  # Join the SAME refcount the boxes use. A host session mounts nothing, but it holds
  # $AIRLOCK_TMP under the same name, so without this it is invisible to every box's
  # cleanup and its scratch dir is removed out from under it while it is still running.
  # Failure here is REPORTED, not swallowed. Suppressing stderr is fine; ignoring the
  # status is not - a launcher that is missing, non-executable, or refusing to run (no
  # container engine on PATH, AIRLOCK_TMP_BASE set in the config) leaves this session
  # unregistered, and a box may then remove $AIRLOCK_TMP out from under it. That is the
  # exact failure this registration exists to prevent, so it must not be invisible.
  if ! "$_AIRLOCK_LAUNCHER" session register $$ 2>/dev/null; then
    print -u2 "claude: could not join the shared-mount refcount for this project."
    print -u2 "  A box may remove $AIRLOCK_TMP while this session is still using it."
    print -u2 "  Check: $_AIRLOCK_LAUNCHER session peers"
  fi
  # `always` runs on interrupt as well as on normal return. Without it, Ctrl-C killing
  # the foreground child makes zsh abandon the rest of this function: the lock and the
  # pidfile both survive, and because that pidfile records THIS interactive shell - alive
  # for days, start time still matching - nothing ever prunes it and every box on the
  # project skips its cleanup permanently.
  {
    command claude "$@"
    rc=$?
  } always {
    # Only drop the lock if it is still OURS. A session that started after us overwrote
    # it with its own pid, and deleting that leaves the live session with no lock at all.
    if [[ -f "$lock" ]]; then
      read -r pid _ < "$lock"
      [[ "$pid" == "$$" ]] && rm -f "$lock"
    fi
    # Deregister and let the launcher decide whether we were the last one out; it owns
    # the rmdir now. Doing it here unconditionally is what stranded live boxes on an
    # orphaned inode - reads empty, writes ENOENT - every time a host session exited.
    if ! "$_AIRLOCK_LAUNCHER" session release $$ 2>/dev/null; then
      print -u2 "claude: could not deregister from the shared-mount refcount."
      print -u2 "  Stale entry: ${HOME}/.config/claude-airlock/state/${slug}/sessions/$$"
    fi
  }
  return $rc
}
