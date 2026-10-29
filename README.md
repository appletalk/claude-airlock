# claude-airlock

Run Claude Code in a container sandbox (a "box") with a **default-DROP egress firewall**,
so auto mode, `--dangerously-skip-permissions` and internet access are contained.

- By default the box sees only the project you launch it in.
- Only Anthropic is reachable by default. Anything more is a grant you approve on the host.
- The common case needs no per-project config.

The container and firewall are the moat. The launcher, `airlock`, assembles the container
command line and keeps grants on the host, where the box cannot tamper with them.

## What it protects against

Assume the agent may misbehave: a prompt injection, a bad tool call.

- **Contained: escape and exfiltration.** The agent cannot reach the network beyond a small
  allowlist, cannot touch other projects, and runs as a non-root user with a minimal set of
  Linux capabilities.
- **Not contained: destructive actions it is authorized to take** (`terraform destroy`, a
  bad commit). Keep write credentials out of the box (read-only or CI-scoped), use branch
  protection, and review pushes by hand.
- **Not contained: files the host later trusts.** Whatever the box writes into your project
  or its shared memory, the unsandboxed host may later run or read. Review a repo a box has
  worked in before host tools run in it.

Details: [docs/security-model.md](docs/security-model.md). To report a weakness:
[SECURITY.md](SECURITY.md).

## Requirements

- Linux with **Podman (rootless, recommended)** or **Docker**. Images are Debian-based.
  Developed on WSL2 and native Arch. Choose with `AIRLOCK_ENGINE`.
- `systemd`, for the one-time module preload under rootless Podman (step 1). On WSL2 that
  means `systemd=true` under `[boot]` in `/etc/wsl.conf`.
- A Claude subscription (auth is a long-lived OAuth token; step 4).
- `zsh`, for the shell integration (`airlock`, `alpaste` and the `claude` guard).
- `~/.local/bin` on your `PATH`.

## Setup

```sh
git clone git@github.com:appletalk/claude-airlock.git
cd claude-airlock          # run the commands below from the repo root
```

### 1. Rootless Podman prerequisites (one-time, needs root)

Skip this with Docker; its root daemon does both for you. That convenience is what you
give up by going rootless, and it is worth giving up.

**Load the netfilter modules.** The kernel will not *autoload* netfilter modules for a
process in a user namespace (which a rootless container is), so the box's firewall cannot
load them itself. Install the list so systemd loads them at every boot, then load them now
so you don't have to reboot:

```sh
sudo install -m 0644 config/modules-load.d/airlock.conf /etc/modules-load.d/airlock.conf
grep -v '^#' config/modules-load.d/airlock.conf | xargs -r sudo modprobe
```

Modules built into your kernel are a harmless no-op. On WSL2, `modprobe` may refuse if the
kernel lacks them; run `wsl --shutdown` from Windows to reboot instead.

**Check your subuid/subgid ranges,** which the box needs to map users. Most distros set
them up at install. Check with `grep $USER /etc/subuid /etc/subgid`. If that prints
nothing:

```sh
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER
```

### 2. Install the launcher and build the images

```sh
make install-airlock          # or: ./bin/install.sh
```

This links `airlock` into `~/.local/bin`, writes a default host config, builds the images
(`claude-airlock:base` and `:dev`), and finishes with `airlock doctor`. The doctor starts a
real throwaway box and makes it *prove* containment: an allowed host must be reachable and
a denied host must not be. If that fails, the install says so loudly.

This is level 1 of [docs/setup.md](docs/setup.md), which
lists the optional levels above it: airlock-envoy, then agent users. It also covers locking down
the Claude you run directly on the host, which every level relies on.

What the install does in detail, and how updates work: [docs/install.md](docs/install.md).

### 3. Shell integration

Add this to `~/.zshrc` (or `~/.zshrc.local`) and reload:

```sh
source "$HOME/.local/share/claude-airlock/current/shell/claude-airlock.zsh"
```

It gives you:

- `airlock`: Claude Code in the box;
- `alpaste`: a shortcut for `airlock paste --copy`;
- `claude`: your normal host Claude, which asks first when it would open a conversation a
  live airlock or host session of the same project has open (below). `command claude`
  bypasses the guard.

### 4. Auth (one-time)

Generate a long-lived (about one year) token on the host and save it:

```sh
command claude setup-token          # copy the printed sk-ant-oat... value
printf %s 'PASTE_TOKEN' > ~/.config/claude-airlock/token
chmod 600 ~/.config/claude-airlock/token
```

Every box shares this token. For a long-lived box that should log itself in (for Remote
Control), use `airlock login persist` in that project; see
[docs/install.md](docs/install.md#one-project-that-logs-itself-in).

> **Billing:** the `setup-token` path uses your **subscription quota**, not pay-per-token
> API credits. The TUI may show "Claude API"; that is cosmetic, so confirm with `/usage`.
> **Never** set `ANTHROPIC_API_KEY` in the box: it silently switches to metered API
> billing.

### 5. Use it

```sh
cd ~/some/project
airlock               # Claude Code, contained, for this directory
```

The box mounts the project read-write at its real path. By default it can reach only
Anthropic until you grant more.

Several sessions on one project at once are fine: boxes and host sessions share its
conversation history, and each conversation is its own transcript. They also share the
project's Claude settings, and only the first box installs into `.venv` and `node_modules`
(later ones get them read-only, and say so). What forks a history is two sessions writing
the same conversation, so that alone asks first: `--continue` while another session is
live, or `--resume <id>` of a conversation another session has open. `--fork-session` starts
a new one and never asks; the `/resume` picker inside a session is not checked.

## Why rootless Podman

Membership in the `docker` group is equivalent to root on the host (`docker run -v
/:/host` owns the machine). Under Docker, the tool that exists to contain a misbehaving
agent is itself reachable through a root-equivalent socket. Rootless Podman has no daemon
and no privileged socket: the box cannot exceed your own unprivileged user's authority,
whatever happens inside it.

Podman is the default. Set `AIRLOCK_ENGINE=docker` only if Podman is unavailable. Images
live in each engine's own store, so switching engines later means rebuilding.

## Updating

Run `make install-airlock` again. It picks up a new Claude Code release at once, and
refreshes the Debian packages once a week (`make refresh` forces it now). Run
`airlock doctor` again after kernel or engine changes. Details, including the vendored Claude Code
installer and old-image cleanup: [docs/install.md](docs/install.md#updating).

## Commands

```
airlock                         Claude Code in the box for $PWD
airlock shell                   interactive shell in the box (no session lock)
airlock exec -- CMD [ARG...]    run one command in the box; its exit status
airlock -p "PROMPT" ...         Claude Code headless (any claude flags pass through)
airlock --dangerously-skip-permissions   auto mode, contained

airlock egress                  show this project's egress posture
airlock egress minimal|dev      Anthropic only  |  + npm, PyPI and GitHub
airlock egress github pypi      an explicit subset of groups (replaces)
airlock egress add|rm <groups>  edit the group set
airlock egress proxy [SOCKET]   no network at all; everything through a host proxy

airlock secret set KEY VALUE|pass:PATH   give this project's box an env secret
airlock secret list | rm KEY             (pass:PATH is resolved with `pass` at launch)

airlock share list              review approved folder shares (ro/rw)
airlock share rm RELPATH        revoke a share approval

airlock mount add DIR           mount a host directory READ-ONLY into this project's box
airlock mount list | rm DIR

airlock socket add SOCKET       bind-mount a host Unix socket into this project's box
airlock socket list | rm SOCKET

airlock mode [show|MODE|reset]  the permission mode this project's box starts in
airlock login [show|persist|token]   shared token, or a login the box keeps
airlock telemetry show          always off

airlock tmp                     print (and create) this project's $AIRLOCK_TMP
airlock paste                   save the clipboard IMAGE where a box can read it
airlock paste --copy            ...and put the path on the clipboard (what `alpaste` does)
airlock paste list [N]          list recent pastes, newest first
airlock doctor                  prove this host can contain a box (live test)

alpaste                         zsh shortcut for `airlock paste --copy`
command claude                  raw host Claude (bypasses the airlock guard)
```

Every grant above is host-only and per project. The box cannot read or change the grants
(a secret's value is, of course, readable inside the box: that is what it is for).

Scripts, service units and prompts without a terminal:
[docs/configuration.md](docs/configuration.md#scripts-and-service-units).

**Secrets: prefer `pass:PATH`** (`airlock secret set KEY pass:mcp/foo`). A literal value is
stored in plaintext in the host state dir (mode 600) and lands in your shell history.
More in [docs/configuration.md](docs/configuration.md#secrets-airlock-secret).

## Reference

| Topic | Where |
| --- | --- |
| Host config (`~/.config/claude-airlock/config`): every key | [docs/configuration.md](docs/configuration.md#host-config-configclaude-airlockconfig) |
| Per-project config (`.airlock/config`): `egress =`, `share =`, `share_rw =`, `artifact_dirs =`, `image =` | [docs/configuration.md](docs/configuration.md#project-config-projectairlockconfig) |
| Secrets, read-only host mounts (`airlock mount`), host sockets (`airlock socket`), permission mode (`airlock mode`) | [docs/configuration.md](docs/configuration.md) |
| Egress through a host proxy (`airlock egress proxy`), and plain HTTP through the proxy (git, gh, tea, kubectl without a credential in the box) | [docs/egress-proxy.md](docs/egress-proxy.md) |
| Scratch files (`$AIRLOCK_TMP`) and pasting images into a box (`airlock paste`) | [docs/scratch-and-pastes.md](docs/scratch-and-pastes.md) |
| Installing and updating, signing in (`airlock login`), telemetry, statusline | [docs/install.md](docs/install.md) |
| Running boxes as a dedicated user, and installing from a bundle | [docs/dedicated-user.md](docs/dedicated-user.md) |
| Agent users with their own sessions (`make install-agents`) | [docs/agents.md](docs/agents.md) |
| Images, offline config validators, corporate CA certs | [docs/images.md](docs/images.md) |
| Security model, known limitations, host hardening | [docs/security-model.md](docs/security-model.md) |
| Reporting a vulnerability | [SECURITY.md](SECURITY.md) |
| Security reviews | [docs/SECURITY-REVIEW.md](docs/SECURITY-REVIEW.md), [docs/security-review-2026-09-22.md](docs/security-review-2026-09-22.md) |

## Development

```sh
make bootstrap   # vendor the pinned shellcheck (sha256) + bats (commit) into .tooling/; re-run to re-verify
make hooks       # install the git hooks (lint + tests, and no site details: see below)
make lint        # shellcheck the launcher, firewall and helper scripts (+ zsh -n on the integration)
make test        # run the bats suite against both engines (podman + docker)
make check       # lint + test (what the hook runs)
make image-smoke # prove the dev image's validators work offline (needs a built :dev)
make doctor      # live containment test on this host
```

This repository is public. Keep site details out of it, commit messages included: names of
people and hosts, domains, addresses, anything from one site's config. Use stand-ins (`alice`,
`example.org`, `10.0.0.10`). `scripts/private-names-check` (run by the hooks and a test) checks
against your own list of patterns, kept outside the repo: one regex per line in
`~/.config/claude-airlock/private-names`, or the file `AIRLOCK_PRIVATE_NAMES` or
`git config airlock.privateNames` names. Before publishing, run it over what you're about to
push: `scripts/private-names-check --range origin/main..main`.

`make help` lists every target. The launcher is Bash on purpose: it composes the engine,
`iptables`, `pass` and `jq`. Keep it shellcheck-clean and covered by the bats suite, which
drives the real launcher with a stubbed engine.

`make lint` and `make test` prefer a system shellcheck and bats over `.tooling/`. That
directory is gitignored and inside a checkout a box can write, so re-run `make bootstrap`
with no box open on the checkout to re-verify it (see [SECURITY.md](SECURITY.md)).

## License

Copyright (C) 2026 Appletalk.

Licensed under the **GNU Affero General Public License v3.0 or later**; see
[LICENSE](LICENSE). If you run a modified version of this as a network service, the AGPL
requires you to offer its source to the users of that service.
