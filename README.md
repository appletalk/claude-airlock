# claude-airlock

Run Claude Code inside a Docker sandbox with a **default-DROP egress firewall**, so
`--dangerously-skip-permissions` / auto mode and internet access are contained. The
goal is to make the *contained* box the default safe way to run Claude on a project —
zero per-project config for the common case, explicit host-approved grants when a
project needs more.

## Why

Assume the agent may misbehave (prompt injection, a bad tool call) and bound the blast
radius:

- **Class A — escape / exfil.** A misbehaving agent can't reach the network beyond a
  small allowlist, can't touch other projects, and runs as a non-root user with a
  minimal Linux capability set inside the container.
- **Class B — destructive but *authorized* actions** (e.g. `terraform destroy`, a bad
  commit) are **not** solved by isolation. Mitigate by keeping write credentials out of
  the box (read-only / CI-scoped), branch protection, and human-reviewed pushes.

The container + firewall is the moat; the launcher just assembles the invocation and
manages host-side, tamper-proof grants.

## Requirements

- Linux with **Podman (rootless, recommended)** or **Docker**. Container images are
  Debian; developed on WSL2 and on native Arch. Select with `AIRLOCK_ENGINE`.
- `systemd`, for the one-time module preload under rootless Podman (step 1). On WSL2
  that means `systemd=true` under `[boot]` in `/etc/wsl.conf`.
- A Claude subscription (auth is a long-lived OAuth token — step 4).
- `zsh` for the shell integration (the `airlock` / `claude` helpers).
- `~/.local/bin` on your `PATH` — that's where the launcher is symlinked.

### Why rootless Podman

Belonging to the `docker` group is equivalent to having root on the host (`docker run -v
/:/host` trivially owns the machine), so running the sandbox under Docker means the tool
that exists to contain a misbehaving agent is itself reachable through a root-equivalent
socket. Rootless Podman has no daemon and no privileged socket: the box cannot exceed
your own unprivileged user's authority, no matter what happens inside it.

It's the default. Set `AIRLOCK_ENGINE=docker` only if Podman is unavailable — and note
that images live in the engine's own store, so switching engines later means rebuilding.

## Setup

```sh
git clone git@github.com:appletalk/claude-airlock.git
cd claude-airlock          # the commands below are run from the repo root
```

### 1. Rootless Podman prerequisites (one-time, needs root)

Skip this section entirely if you're using Docker — its root daemon already does both of
these for you. That convenience is exactly what you give up by going rootless, and it is
worth giving up.

**Netfilter modules must be resident.** The kernel refuses to *autoload* netfilter
modules for a process in a user namespace — which is what a rootless container is — so
the box's firewall cannot bring them up itself. Install the module list to have systemd
load them at every boot, then load them into the running kernel so you don't have to
reboot to use the box today:

```sh
sudo install -m 0644 config/modules-load.d/airlock.conf /etc/modules-load.d/airlock.conf
grep -v '^#' config/modules-load.d/airlock.conf | xargs -r sudo modprobe
```

(Modules already built into your kernel are a harmless no-op. On WSL2, `modprobe` may
refuse if the kernel lacks them — reboot with `wsl --shutdown` from Windows instead.)

**`subuid`/`subgid` ranges must exist** for your user, so the box can map users. Most
distros configure these at install — check with `grep $USER /etc/subuid /etc/subgid`, and
if it comes back empty:

```sh
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER
```

### 2. Install the launcher and build the images

```sh
make install          # or: ./bin/install.sh
```

That symlinks the launcher into `~/.local/bin`, writes a default host config to
`~/.config/claude-airlock/config`, builds `claude-airlock:base` + `:dev`, and finishes by
running `airlock doctor` — which stands up a real throwaway box and makes it *prove*
containment: an allowed host must be reachable and a denied host must not be. If that
check fails, the install says so loudly rather than leaving you with a sandbox that
isn't one. Re-run it any time with `make doctor` (or `airlock doctor`), especially after
changing engines or upgrading the kernel.

### 3. Shell integration

Add to `~/.zshrc` (or `~/.zshrc.local`) and reload:

```sh
source "$PWD/shell/claude-airlock.zsh"
```

This gives you `airlock` (Claude Code in the box) and a lock-aware `claude` on the host
that warns if an airlock session for the same project is already open.

### 4. Auth (one-time)

Generate a long-lived (~1yr) token on the host and save it:

```sh
command claude setup-token          # copy the printed sk-ant-oat... value
printf %s 'PASTE_TOKEN' > ~/.config/claude-airlock/token
chmod 600 ~/.config/claude-airlock/token
```

### 5. Use it

```sh
cd ~/some/project
airlock               # Claude Code, contained, for this directory
```

> **Billing:** the `setup-token` path uses your **subscription quota** (included), not
> pay-per-token API credits. The TUI may show "Claude API" — that's cosmetic; confirm
> with `/usage`. **Never** set `ANTHROPIC_API_KEY` in the box — it silently switches to
> metered API billing.

## Commands

```
airlock                         Claude Code in the box for $PWD
airlock shell                   interactive shell in the box (no session lock)
airlock --dangerously-skip-permissions   auto mode, contained

airlock secret set KEY VALUE|pass:PATH   grant an env secret to this project's box
airlock secret list | rm KEY             (pass:PATH resolves via `pass` at launch)

airlock share list              review approved folder shares (ro/rw)
airlock share rm RELPATH        revoke a share approval

airlock egress                  show this project's egress posture
airlock egress minimal|dev      Anthropic-only  |  + npm/PyPI/GitHub
airlock egress github pypi      an explicit subset (replaces)
airlock egress add|rm <groups>  edit the group set incrementally

airlock tmp                     print (and create) this project's $AIRLOCK_TMP scratch dir
airlock doctor                  verify this host can actually contain a box (live test)

command claude                  raw host Claude (bypasses the airlock guard)
```

`airlock doctor` is the one to run after changing engines or rebooting: it checks the
rootless prerequisites and then makes a real throwaway box prove containment — an allowed
host must be reachable *and* a denied host must not be.

`claude` on the host is a lock-aware guard: it warns if an airlock session for the same
project is already open (two live sessions can corrupt shared `--resume` history).

For **secrets, prefer the `pass:PATH` form** (`airlock secret set KEY pass:mcp/foo`) over a
literal value. A literal is stored plaintext in the host state dir (mode 600) and also
lands in your shell history when you type it; `pass:PATH` keeps the secret encrypted at
rest and is only resolved — into the mode-0600 env-file, never the command line — at
launch.

## Per-project config — `<project>/.airlock/config`

Committed with the project, **safe-parsed** (never sourced) since the project dir is
untrusted. Keys (see `config/project-config.example`):

| Key | Effect |
| --- | --- |
| `egress = a.com b.com` | extra egress domains; **host-approved once** (box-writable, so TOFU-gated) |
| `share = <relpath> ...` | mount a sibling folder **read-only** at its real path (host-approved) |
| `share_rw = <relpath> ...` | mount it **read-write** (louder prompt; separate approval from read) |
| `artifact_dirs = venv frontend/node_modules` | extra env-built dirs kept container-local |
| `image = claude-airlock:playwright` | opt into a heavier image (must be a `claude-airlock:*` tag) |

Share paths are relative to `AIRLOCK_SHARE_BASE` (default `~/development`), so committed
configs never contain absolute `/home` paths, and `..`/absolute are rejected.

## Host config — `~/.config/claude-airlock/config`

Your machine's defaults (see `config/config.example`): `AIRLOCK_IMAGE`,
`AIRLOCK_SHARE_BASE`, `AIRLOCK_EGRESS_MODE` (default posture for new projects),
`AIRLOCK_MODEL`, `AIRLOCK_GIT_NAME/EMAIL`, `AIRLOCK_ROOTS`, `AIRLOCK_EXTRA_EGRESS`.

## Scratch files — `$AIRLOCK_TMP`

The box's `/tmp` is destroyed with the container (`--rm`, including on Ctrl+C) and is
never shared with the host, so anything written there is silently lost between sessions —
and a host-written `/tmp` file is invisible to the box.

Each project instead gets `/tmp/airlock/<slug>`, bind-mounted into its box at the **same
path** and exported as `$AIRLOCK_TMP` by *both* the `airlock` launcher and the host
`claude` wrapper. Host and box therefore name the same file identically (`airlock tmp`
prints and creates it). Sessions are shared across the boundary, so both sides must agree
on where scratch lives.

- **Per-project.** Only that project's own directory is mounted (mode `0700`) — never
  `/tmp/airlock`, never bare `/tmp` — so nothing leaks between projects.
- **An inter-session cache, not durable storage.** It lives on the host's `tmpfs`: it
  survives sessions but is cleared on reboot, so it never becomes an unmanaged junk
  drawer. Anything that must truly persist belongs in the project (gitignored if it
  shouldn't be committed).
- **Bare `/tmp` stays ephemeral** on purpose, so `pip` / `pytest` / build temp files stay
  container-local rather than consuming the host's RAM-backed `tmpfs`.

Claude only *follows* the convention if told to. The box is briefed automatically
(`config/box-CLAUDE.md` is copied in on every launch). For **host** Claude, paste
[`config/host-CLAUDE.md`](config/host-CLAUDE.md) into your global `~/.claude/CLAUDE.md`.

## Security model

- **Egress: minimal by default.** Only Anthropic is reachable (Claude can't run without
  it). npm / PyPI / GitHub are opt-in *groups*; other domains are per-project,
  host-approved. Enforced by an in-container iptables/ipset default-DROP firewall, on
  **both IPv4 and IPv6** — a single unfiltered address family is a total bypass, so if
  the box has a global v6 address it cannot filter, it refuses to start.
- **The allowlist matches destination IPs, not names — so it inherits CDN co-tenancy.**
  The firewall resolves each allowed domain to its IPs and permits TCP/443 to those IPs;
  it does not (and at that layer cannot) inspect the TLS SNI. So **any** site that resolves
  to an IP already on the allowlist is reachable, approved or not. This matters most when
  you open a registry group: npm and PyPI front through large shared CDNs, so
  `airlock egress dev` effectively allows a slice of that CDN's address space, and an agent
  can reach an attacker's service co-hosted on the same edge IP. Prefer keeping projects
  `minimal` and adding narrow `egress =` domains over flipping the whole `dev` group on.
  Closing this fully would require an SNI-aware filtering proxy (a possible future
  direction); today, treat an enabled registry group as a broad, if legitimate-looking,
  exfil surface.
- **DNS is pinned to the box's configured resolvers**, not open to the internet. This
  narrows, and does not close, DNS exfiltration: the agent can no longer point queries at
  a server it chooses (`dig @attacker-ns …`), but data can still be tunnelled as query
  *names* through your legitimate resolver to a hostile authoritative server. No resolver
  allowlist can prevent that. Treat DNS as a low-bandwidth channel that remains open — and
  note that the box's own `CLAUDE_CODE_OAUTH_TOKEN` is in scope for it: a compromised box
  can read its own token and drip it out this way. If you believe a box was compromised,
  rotate the token (`command claude setup-token` again, then re-save it). The token grants
  subscription API access, not host or billing access, so the blast radius is bounded.
- **Host-controlled, tamper-proof grants.** Secrets, share approvals, and egress posture
  live in a per-project state dir that is **never mounted into the box**. A compromised
  session can request more (via the box-writable `.airlock/config`) but can't approve it
  — approving read never grants write; widening always prompts on the host.
- **Least-privilege container.** Drops all Linux capabilities except the few the firewall
  and privilege-drop need; runs as non-root `dev`; `--security-opt=no-new-privileges`. A
  process-count cap (`AIRLOCK_PIDS_LIMIT`, default 4096) guards against a fork-bomb, and an
  optional RAM ceiling (`AIRLOCK_MEMORY`) can be set per host.
- **No mounted credentials, and secrets stay off the process table.** Auth is an OAuth
  token; the host `~/.claude` credentials, container socket, and other projects are never
  exposed. The token and any injected secrets are handed to the engine via a mode-0600
  `--env-file` (removed on exit), **not** as `-e KEY=VALUE` — so they don't sit in the host
  process table (`ps auxe`, `/proc/<pid>/cmdline`) for the life of the container.
- **Optional private CA chain** (see below) is trusted by *external tooling*
  (curl/git/Python) only — never added to Node's trust, so Claude's own TLS to
  `api.anthropic.com` stays on its vetted built-in roots.

### Known limitation: a workspace the box has touched runs on the host

The firewall contains the *network*. It does nothing about files. Your project is mounted
**read-write at its real path** (that's the point — the box does real work), so the box can
write any file the host will later execute **itself, unsandboxed, with your real
credentials**:

- `.git/hooks/*` — run on your next host `git commit` / `push` / `merge`
- `.envrc` — run by direnv the next time you `cd` in
- `Makefile`, `package.json` scripts, `pyproject.toml` / `setup.py`, `conftest.py`,
  `.vscode/tasks.json`, pre-commit configs, `node_modules/.bin` shims …

None of these touch the network, so containment never sees them. This is the same class as
the memory channel below, just broader: **treat a repo a box has worked in the way you'd
treat a PR from a stranger** — review it before you build, commit, or `cd` into it on the
host with direnv active. Running untrusted code? Do it in the box, and don't run host-side
build/commit tooling in that tree until you've looked at the diff.

### Known limitation: shared memory is an influence channel

Worth understanding, because the egress firewall **cannot see it and will not stop it.**

This project's `~/.claude/projects/<slug>/` is mounted **read-write** into the box, so
sessions and memories flow in and out (that's what makes `--resume` and saved memories
work on both sides). That directory contains `memory/` — and host Claude **auto-loads
those files into its context every session, unprompted.**

So a compromised box can write a memory file that the **unsandboxed host agent** later
reads and acts on, with your real credentials and no firewall. It never touches the
network; it just writes a file you have already told the host to trust. Containment holds
against *escape and exfil* (Class A); this is a different thing — **influence**.

It is read-write by default anyway, deliberately: the box is meant to be the primary
workspace, so read-only memory would mean the agent can never *save* a memory where you
actually do the work, and the feature would quietly die. We take the friction win and
name the exposure. Tighten it when the code is untrusted:

| `AIRLOCK_SHARE_MEMORY` | Behaviour |
| --- | --- |
| `rw` *(default)* | Box reads **and writes** host memories. Convenient; channel open. |
| `ro` | Box reads host memories, cannot author them. **Closes the channel.** |
| `off` | Box neither reads nor writes them; it gets empty container-local storage. |

Transcripts stay read-write in every mode — a box that cannot write its transcript cannot
hold a session at all. Set `AIRLOCK_SHARE_HISTORY=0` to share nothing.

## Corporate / internal CA certs (optional)

If you sit behind a TLS-inspecting proxy, or need to reach internal HTTPS services whose
certs chain to a private PKI, drop the CA chain into `image/certs/` and rebuild:

```sh
cp /path/to/your-root-ca.crt image/certs/
make install          # rebuild the images
```

Public CA certificates only — **never private keys**. The directory is empty by default
and the CA layer is a no-op without it, so nothing here is needed on a normal home
network.

## Images

Layered, built by `make install`:

- `claude-airlock:base` — Debian + Claude Code + git/gh + the egress firewall + core CLIs.
- `claude-airlock:dev` *(default)* — base + Python, Node, build tools, PostgreSQL, yaml
  tooling. Start Postgres in-box with `airlock-pg-start` (localhost:5432, ephemeral).
- `claude-airlock:playwright` — dev + headless Chromium + the Playwright MCP. Opt in via
  `image = claude-airlock:playwright`. Build on demand:
  `docker build -t claude-airlock:playwright image/playwright`.

## Development

```sh
make bootstrap   # vendor shellcheck + bats into .tooling/ (no sudo) — or install them
make hooks       # install the git pre-commit hook (runs lint + tests)
make lint        # shellcheck the launcher + firewall scripts
make test        # run the bats suite
make check       # lint + test (what the hook runs)
```

The launcher is intentionally Bash — it composes `docker`/`iptables`/`pass`/`jq`. Keep
it shellcheck-clean and covered by the bats suite (which drives the real launcher with a
stubbed `docker`). `make help` lists all targets.

## License

Copyright (C) 2026 Appletalk.

Licensed under the **GNU Affero General Public License v3.0 or later** — see
[LICENSE](LICENSE). If you run a modified version of this as a network service, the AGPL
requires you to offer its source to the users of that service.
