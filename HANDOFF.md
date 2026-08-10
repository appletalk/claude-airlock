# Handoff: finishing `host-wrapper-refcount`

Written 2026-08-10 for a fresh Otto session with no prior context. Delete this file
before merging.

## Where things stand

Branch `host-wrapper-refcount`, 10 commits, **not pushed**. `main` is at `9132206` and is
already pushed.

Gates, all green as of the last commit (`f2fdcc4`):

    bats test/                      # 170/170
    shellcheck bin/claude-airlock   # clean
    zsh -n shell/claude-airlock.zsh # clean
    make doctor                     # live containment, needs a host with podman

Six review rounds. Five of them found a real defect **introduced by the previous round's
fix**, so the branch has a demonstrated history of regressions arriving inside the
corrections. The last review's blocking finding is fixed and covered.

## What the branch does

Two boxes on one project is a supported, intended setup. Previously the first session to
exit destroyed shared state the others were still using. The branch makes that safe:

1. **A shared-mount refcount.** Every participant registers `$STATE_DIR/sessions/<pid>`
   containing `<starttime> <kind>`. Only the last one out removes the scratch dir, the
   artifact mountpoints, or the sessions dir. Start times make a pidfile identify a
   process, not a number, so a recycled pid cannot pin cleanup forever.
2. **The host `claude` wrapper joins that refcount.** It was the unfixed twin of the
   launcher - it `rmdir`'d `$AIRLOCK_TMP` unconditionally and registered nothing. The
   refcount logic lives in ONE place and the wrapper delegates via
   `airlock session register|release|peers`.
3. **Artifact stores are single-writer.** Two boxes mounting one `.venv` read-write meant
   concurrent installs corrupted it silently. First session takes it rw and records
   `<store>.owner`; a later one gets `:ro` and is told why.
4. **Signals end the run.** A handler in bash runs and then the script CONTINUES, which
   let a signal at a prompt disarm cleanup and then provision the project anyway.
5. **Every shared write is atomic and per-process.** Eight sites; two concurrent launches
   used to collide on fixed `.tmp` paths (a measured 38 of 80 failing).
6. **The concurrent-session warning reads the registry**, with `session.lock` as an
   ADDITIVE fallback - the registry is only complete if every peer registers, and an old
   wrapper does not.

## Invariants a change must not break

- The registry answers **who holds the mounts** (includes `airlock shell`). The warning
  answers **who can corrupt `--resume` history** (excludes `shell`). Different
  populations. Conflating them was a real bug on this branch.
- The lock fallback is **additive only**: it may add a peer the registry missed, never
  suppress one. Otherwise the single-slot problems come back.
- `rmdir` (never `rm -rf`) on artifact mountpoints. The peer check covers a sibling box;
  `rmdir`'s empty-only refusal covers a HOST-side writer. Both are required.
- Removing a directory another process has bind-mounted strands it on `Links: 0` - reads
  empty, writes ENOENT - and that is indistinguishable from "empty".

## The remaining work

### 1. Unboxed testing (Keith unboxes for this)

The box has no podman, so nothing below has been verified against real containers on this
HEAD. Everything is a stub-engine result unless stated.

    # A. gates on the host
    cd /home/keith/development/claude-airlock
    bats test/ && shellcheck bin/claude-airlock && zsh -n shell/claude-airlock.zsh
    make doctor

    # B. single box, full lifecycle - scratch, .venv, sessions, lock all cleaned
    T=/tmp/e2e/proj; rm -rf /tmp/e2e ~/.config/claude-airlock/state/tmp-e2e-proj
    mkdir -p "$T" && cd "$T" && bin/claude-airlock --version

    # C. THE CORE CLAIM: a peer's mounts survive another session exiting.
    #    Register a live pid as a peer, launch a real box, confirm the scratch dir's
    #    INODE is unchanged and .venv survives. Then kill the peer, launch again, and
    #    confirm everything is cleaned. A positive control against the pre-fix commit
    #    (bb9360a) previously showed inode 583 -> GONE.

    # D. host wrapper + box overlap. Source shell/claude-airlock.zsh, run a `claude`
    #    session (a stub `claude` that sleeps works), launch a real box alongside it,
    #    exit the box, confirm the host session's scratch dir is intact. Then exit the
    #    host session last and confirm .venv, markers, sessions/ and the lock all go.

    # E. artifact store :ro. Hold <store>.owner with a live pid, launch, confirm the
    #    engine args carry `:ro` and the box reports "Read-only file system" on write.

    # F. signals. SIGTERM and SIGQUIT at the egress-approval prompt must end the run:
    #    no engine invoked, no .venv, no markers, no owner file, no pidfile left.

    # G. two REAL boxes on one project, then the actual two-Otto workflow.

**KNOWN FLAKE, seen 2026-08-10:** test 108, "two launches starting together do not
collide on a shared temp path", failed once on `[ "$rcb" -eq 0 ]` and passed on an
immediate re-run of the identical tree. It failed against GOOD code, which is the unsafe
direction - review had predicted it could only be a weak detector, not a false alarm. If
it fails during testing, re-run before believing it, and treat diagnosing it as in scope
(a flaky test in the pre-commit hook blocks commits, which is usage-impacting). It is
item 8 in the follow-up doc.

`airlock shell` fed piped stdin never exits (podman `-it` gives it a pty, so bash never
sees EOF). Use a short command like `--version` for scripted launches.

### 2. Stopping rule - this is the point of the handoff

**Fix only what is critical or usage-impacting.** Everything else gets filed and left.

Seven follow-ups are recorded in **`/home/keith/development/otto/airlock-followups.md`**,
which outlives this file. They are listed again below for convenience. **Do not fix these
on this branch** - they are deliberate, batched input for a later ultra review pass.

Do NOT file them as GitHub issues. `appletalk/claude-airlock` is Keith's personal repo and
the token is his work account; issues were filed there once by mistake and he had to
delete them himself.

1. **Cleanup's signal deafness has only a structural test.** The behavioural one needs a
   second signal delivered while cleanup is provably mid-pass: a stub `rmdir` that touches
   a marker, blocks on a FIFO, then execs the real one; launch, SIGTERM, wait for the
   marker, SIGINT, release. Discriminate on exit 143 vs 130 and on the tail side effects.
2. **An old single-field pidfile from `airlock shell` warns once during upgrade.** No kind
   recorded parses as empty, which is not `shell`, so it reads as a history writer.
   Fail-safe direction; self-clears when that shell exits.
3. **`claude.json` and the box settings are read-modify-write without a lock.** The writes
   are atomic; the read-modify-write is not mutually excluded. Content is deterministic
   per launch, so benign except a fresh-project seed can transiently clobber a sibling's
   `.projects[$ws]` trust flags.
4. **The zsh wrapper's own warning still reads `session.lock`, not the registry.** It
   inherits the single-slot limits (names one peer only). Not worse than main.
   `airlock session peers` exists; a history-peers variant would share one source.
5. **Duplicated kind-filter logic** in `_airlock_history_peers` and the peer-naming loop -
   a pidfile format change must be made in both. This is the drift shape the branch was
   repeatedly caught by.
6. **Two per-process temps are missed by the cleanup sweep.** The sweep globs
   `$STATE_DIR/*.tmp.$$` and `dot-claude/*.tmp.$$`; the artifact owner temp is
   `$STATE_DIR/artifacts/.venv.owner.tmp.<pid>` - wrong directory and dot-prefixed.
7. **"concurrent launches both get the settings baseline" is a smoke test, not a gate.**
   Its setup `: > .../dot-claude/settings.json` is a silent no-op because that directory
   does not exist before the first launch, so the reset branch is reached via absence
   rather than emptiness.

The failure mode to avoid is the one this branch already demonstrated: every individual
fix is defensible on its own merits, so there is never an obviously-not-worth-it finding
and therefore no natural edge. Stop on the CLASS of what remains, not the merit of the
next item.

### 3. Merge

Keith's word gates the merge. When testing passes:

    git checkout main && git merge --ff-only host-wrapper-refcount
    # Keith pushes. Delete this file in the merge commit or just before.

The launcher is installed as a **symlink into this repo**, so whatever branch is checked
out is what `airlock` runs. Merging does not change what is live; checking out a
different branch does. No image rebuild is needed - `bin/claude-airlock` is host-side.

## If a test fails

Report it before fixing. Five of six review rounds found a regression inside a fix, so a
correction here deserves the same suspicion as the original defect: mutation-test any new
test in both directions, and pair every negative result with a positive control.
