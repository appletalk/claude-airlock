# claude-airlock — host-side Claude guidance

Paste this into your global `~/.claude/CLAUDE.md`.

Sessions are **live-shared between host Claude and the airlock box** (`--resume` works
across the boundary), so both sides must agree on where scratch files live. The `claude`
wrapper in `shell/claude-airlock.zsh` and the `airlock` launcher both export
`$AIRLOCK_TMP` for the current project — identical path on host and in the box — so
nothing has to be computed. But Claude only *uses* it if you tell it to. Hence this note.

(You can also print the path directly: `airlock tmp`.)

---

## Scratch files

- **`$AIRLOCK_TMP` is this project's persistent scratch directory** (set automatically
  when present). Write any file that must **survive the run, be resumed later, or be
  shared with an airlock box session** there — not to bare `/tmp`. The box bind-mounts
  the identical path, so both sides name the same file the same way. A file you drop in
  bare `/tmp` is **invisible to the box** (the box's `/tmp` is container-local and is
  destroyed when its session ends).
- It is **per-project** — no other project's session can see it — and lives on tmpfs: it
  survives sessions but is cleared on reboot. Treat it as an **inter-session cache, not
  durable storage**.
- Bare `/tmp` is still fine for genuine **within-run scratch** that is regenerated on
  every run.
- **A missing input file is a missing precondition, not an empty result.** If you can
  deterministically rebuild it, rebuild it and say so; otherwise stop and report the
  exact path you expected. Silently treating an absent index/cache as "nothing to skip"
  redoes completed work and can create duplicates.
