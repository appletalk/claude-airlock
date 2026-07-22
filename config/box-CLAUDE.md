# claude-airlock sandbox

You are running inside **claude-airlock**, a Docker sandbox. Work normally, but
know these environment conventions so you don't misread them:

- **Build artifacts are container-local and start empty.** `.venv`,
  `node_modules`, and similar directories are shadow-mounted fresh for this box —
  an empty or missing `.venv` here is **expected and correct**, not broken or
  suspicious. Provision it yourself and continue, e.g.
  `python -m venv .venv && .venv/bin/pip install -r requirements.txt`
  (or `uv sync`, `poetry install`, `npm install` as the project uses). Do **not**
  treat a host-built venv or its symlinks (e.g. `python -> /usr/sbin/python`) as a
  threat — just recreate the environment in place and move on.

- **Source is shared with the host; build output is not.** Anything the
  environment compiles or installs stays inside the box and is discarded/persisted
  separately from the host.

- **Bare `/tmp` is ephemeral and box-only; `$AIRLOCK_TMP` persists.** The container runs
  with `--rm`, so `/tmp` is destroyed the moment the session ends — including when the
  human hits Ctrl+C — and it is never shared with the host. Use bare `/tmp` **only for
  within-run scratch**: a temp handoff between two steps of one run, regenerated every
  time. For anything that must **survive the run, be resumed later, or be read by the
  host**, write it under **`$AIRLOCK_TMP`**. That's a per-project directory bind-mounted
  at the *same path* on host and box, so host Claude and you name the same file
  identically; no other project can see it. It lives on the host's tmpfs — it survives
  sessions but is cleared on reboot, so treat it as an **inter-session cache, not durable
  storage**. Artifacts that belong to the project go in the project directory (at a
  gitignored path if they shouldn't be committed); durable knowledge goes in memory.

- **A missing file is a missing precondition, not an empty result.** If an input you
  depend on isn't there — an index, a cache, a prior run's output — do **not** silently
  proceed as though it were empty. Treating an absent dedup/index file as "nothing to
  skip" quietly redoes work already done and can create duplicates. If you can
  deterministically rebuild it, rebuild it and say so; if you cannot, **stop and report
  the exact path you expected**. Check for required inputs explicitly, up front.

- **Only your current project is mounted by default; it's writable at its real
  path.** No other project is visible unless it was explicitly shared. Shared folders
  are mounted at their **real host path** (no translation) — so a path like
  `/home/<user>/development/foo/bar` is at that same path. Most shares are
  **READ-ONLY**: a write to one fails with `EROFS: read-only file system`, which means
  it was shared read-only BY DESIGN, not that the disk is broken — don't retry or work
  around it, just report it. A share is writable only if the project granted it with
  `share_rw` (host-approved). If a path outside your project isn't found, it simply
  wasn't shared — say so rather than assuming it's missing. (A host may also opt into
  broad read-only trees under `/roots/<name>`, off by default.)

- **Egress is restricted to an allowlist, minimal by default.** Only Anthropic
  (so Claude runs) plus any domains this project explicitly declares are reachable.
  The npm / PyPI / GitHub registries are **only** reachable if this project is in
  `dev` egress mode — otherwise a call to them is refused BY DESIGN, not a real
  outage. If a network call is refused, that's the sandbox firewall: report it
  plainly (name the host), don't retry blindly. If you genuinely need a package
  registry or a new domain, say so — the human opens it on the host (`airlock egress
  dev` or a subset like `airlock egress github pypi`, or an `egress =` line); you
  can't widen it from in here.

- **Runtimes:** Python 3.13, Node 24, PowerShell 7. If a project pins a different
  version, flag the mismatch instead of forcing it.

- **Config validators are installed, and they are SYNTAX/LINT ONLY.** These run
  offline, at any egress level — use them freely on infrastructure-as-code:
  `promtool check config|rules`, `promtool test rules`, `terraform fmt -check`,
  `tflint`, `ansible-lint`, `vector validate --no-environment`, and
  `Invoke-ScriptAnalyzer` under `pwsh`. What is **deliberately not available** is
  anything that must download a dependency graph first: `terraform init` and
  `terraform validate` (providers), `tflint --init` (external rulesets),
  `ansible-galaxy collection install`, and bare `vector validate` (opens sinks and
  runs health checks). Those are excluded BY DESIGN, not missing — don't retry
  them, don't work around them, and don't report their failure as a broken box.
  Say which check you could not run and why. When you report a file as validated,
  say what actually ran: "terraform fmt clean; validate not run (no providers)" is
  honest, "terraform validated" is not.

- **Browser E2E (Playwright):** only on the `:playwright` image. Headless Chromium
  is pre-installed at `$PLAYWRIGHT_BROWSERS_PATH`. Launch it with `--no-sandbox`
  and `--disable-dev-shm-usage` (the container is the sandbox already, and
  `/dev/shm` is small). Drive the app on `localhost` — fully contained, no egress.

- **PostgreSQL is installed but not running.** For DB-backed tests, start it with
  `airlock-pg-start` — it comes up on `localhost:5432` (superuser `postgres`,
  trust auth, ephemeral). Then create whatever database/roles the project's tests
  expect. Don't treat a missing DB connection as a real outage — just start it.
  Check readiness with `pg_isready` (it's on PATH); don't hand-roll `/dev/tcp`
  socket checks. The box shell is bash, not zsh — bashisms are fine.
