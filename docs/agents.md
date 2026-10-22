# Agent users (optional)

The box is the inner wall. Agent users add an outer one: the agent runs as Unix users of its own,
each with a sandboxed user manager, so a container or runtime escape lands as a user who can read
none of your files, keys or sessions. You reach its sessions with one command; its work comes
back to you only through what you pull (git branches, say).

This is level 3 of [setup.md](setup.md), and optional: `make install-airlock` never installs or
changes any of it. It needs [airlock-envoy](https://github.com/appletalk/airlock-envoy) installed
and running first: the agents' boxes have no network but its sockets.

- **The agent** (default user `claude`): your sessions, named `<project>.<name>`, each a boxed
  Claude in a tmux server in the agent's user manager, kept across reboots, reachable from a
  terminal (`<command> attach`) or the Claude app (Remote Control).
- **Web research** (optional, level 4): a **web** user researches questions the agent queues,
  each in a fresh box with the web and nothing else; a **guard** user gates each report before the
  agent reads it. The agent itself never gets the web: it holds the data (repos, memories, its
  credentials), and data, untrusted content and an outbound channel in one agent is the risk.

## What bounds each agent user

| Layer | What it does |
|---|---|
| The user | its own uid, no groups, a locked password, a fixed-size home image (a runaway can't fill `/home`) |
| Its user manager | `PrivateNetwork` (loopback only), private `/tmp`, `/var/tmp`, `/dev/shm`, `/dev/mqueue`, `ProtectProc=invisible` (no other user's processes), `ProtectHome=tmpfs` (no other home), no system bus, the other agents' cgroups hidden; web and guard also `ProtectSystem=strict` with writes only to their home and queue dirs |
| A slice | memory, task and CPU ceilings |
| nftables | its uid and subordinate ids dropped in the host's namespace (a table of its own, beside your firewall) |
| airlock-envoy | its own listeners and sockets (`client <listener> <user>`): only what you allow, credentials injected outside the box |
| The box | as for any claude-airlock box, proxy posture: no network of its own |
| Root's configs | its claude-airlock config, managed settings, podman runtime and tmux config are root's (it can't loosen them) |

The operator (you) gets one polkit right: a host shell as the agent users, and nothing else. Every
agent-side step the operator command takes runs through execute-only copies of `sh`,
`systemd-run`, `systemctl` and `install` (root's, 0711): the agent can't read them, so the kernel
makes those processes non-dumpable and the agent's code can't reach your unsandboxed tree through
`/proc/<pid>/root`. A package manager hook (pacman or apt) refreshes the copies after upgrades.

## Install

Prerequisites (besides claude-airlock and a running airlock-envoy):

```
sudo apt install podman crun tmux systemd-container acl xfsprogs python3 nftables polkitd   # Ubuntu/Debian
sudo pacman -S --needed podman crun tmux acl xfsprogs python nftables polkit                # Arch
```

From a clean clone that no box mounts (it installs code that runs as root):

```
sudo make install-agents
```

The first run asks, defaults in brackets: the operator (you), the agent's user name (`claude`),
whether to add web research (`claude-web`, `claude-guard`), each user's uid and subordinate id
range (the next free ones), home image sizes (30G for the agent, 10G for the others: a ceiling,
not a reservation) and the operator command's name (the agent's name, or `claude-agent` for
`claude`, so it doesn't shadow Claude Code). It writes `/etc/claude-airlock/agents/agents.conf`
(see [agents.conf.example](../agents/agents.conf.example)), each user's claude-airlock config
(`/etc/claude-airlock/agents/<user>.conf`, yours to edit: git identity, other listeners), installs
the toolkit and runs `sudo airlock-agents-apply --confirm`. `--defaults` takes every default
without asking; `--site FILE` uses a site file you wrote (keep it in your host config repo).

Then give each agent user an airlock-envoy listener (apply names any that are missing), in
`/etc/airlock-envoy/site.conf`:

```
claude-anthropic  @anthropic
client claude-anthropic claude
claude-web-web  @anthropic web            # web research only
client claude-web-web claude-web
claude-guard-anthropic  @anthropic        # web research only
client claude-guard-anthropic claude-guard
```

and a listener with the hosts a project needs (git, metrics, a Kubernetes API server, with
credentials injected) for the projects that need them; a project picks it in the agent's shell
with `airlock egress proxy /run/airlock-envoy/claude/<listener>.sock`. Never give the agent's own
listeners `web`.

As the operator:

```
claude-agent update      # your installed claude-airlock, bundled through the inbox, installed by each agent user
claude-agent reload      # their user units; starts the web research workers
claude-agent shell       # once: cd into a project folder, run `airlock`, /login, /exit
claude-agent web login   # once, with web research: /login in each research workspace
claude-agent new <project>; claude-agent attach <project>
```

## Changing it

Edit `agents.conf`, then `sudo airlock-agents-apply` (a dry run: what would change), `--confirm`
to apply, `--check` as a drift check (exit 1 on any change; for your audit). It renders every
system file from the site file (`--render DIR` shows them), installs the ones that differ,
removes the ones it no longer renders, and provisions users, images, subordinate ids, linger, the
inbox and the queue. Refusals come before any change: a uid or range someone else has, an
existing user with other numbers or groups, ceilings the disk can't back. Updating the toolkit is
`sudo make install-agents` again (the site file is kept).

## The operator command

| Command | Does |
|---|---|
| `<command>` / `ls` | the sessions and their state |
| `new <project> [name]` | start one (`main`), enabled across reboots |
| `attach <project>[.name]` | join its tmux (Ctrl-b d leaves it running) |
| `stop` / `restart <session>` | a bare `<project>` only while it has one session; with several it refuses and names them |
| `paste` | the clipboard image into the inbox (Wayland, X11); its path on your clipboard for the box |
| `update` | your installed claude-airlock to every agent user (a bundle; they build nothing) |
| `shell` | a shell as the agent, inside its user manager |
| `reload` | their user units after an apply; starts the web research workers |
| `web ...` | the web research commands (below) |

Everything from the agents' side is cleaned of escape sequences and control characters before it
reaches your terminal.

## Web research

```
agent box ── web.py ask ──► <queue>/requests ──► web user (fresh box per question, web only) ──► reports
                                                                                                  │
agent box ◄── answers (ro) ◄── release ◄── guard user: deterministic scan + cold reader ◄────────┘
                                              └──► quarantine (the operator reads)
```

In the agent's box: `python3 <queue>/lib/web.py ask "<question>" --why "<one line>"` (prints an id),
then `web.py answer <id> --wait 15`. An answer is untrusted data: facts and sources only.

1. **Question check** (deterministic): secrets, encoded data, your internal names
   (`internal-name`, `internal-host` in agents.conf) and private addresses, invisible
   characters. Clean questions go straight to research; a tripped one is held for you
   (`<command> web approve|reject <id>`; an approval covers exactly the text it showed you).
2. **Research**: a fresh box, `claude -p`, web search and fetch only, two files out, capped in
   time, turns and runs a day (`daily-cap`).
3. **Gate**: a deterministic scanner (injection shapes, controls, invisible text, links, encoded
   data), then a cold reader in a box with no tools that must answer a fixed JSON verdict. High
   findings or anything but `pass` quarantines (`<command> web show|release <id>`).

Every byte from the agent, the web or a Claude run is parsed in a box, never by the host-side
workers. The queue (`/srv/<web>`) is root's: each directory's writer and readers are set by group
and ACL, so the web user can't write answers and the agent can't read held questions or reports.
Records are kept 90 days. `<command> web` is an interactive research chat with the web user (a
fresh box, ended after an hour idle). Commands: `web ask|ls|show|approve|reject|release|retry|login|new|stop|restart`.

## Facts the setup carries (each a check, not a story)

- `ProtectProc=invisible` needs crun: runc's rootless detection reads the bus owner through
  `/proc` and fails every box. The toolkit pins crun for the agent users (root's podman config,
  loaded last); apply wants it installed.
- tmpfiles ACL lines name their mask (`m::`); left out, tmpfiles masks away the owning group's
  write. The queue's tmpfiles file and apply's check come from one table.
- Log dirs a writer shares with a root-owned subdir are sticky (or the writer could swap it).
- Switching an agent user's runtime (runc to crun) leaves the old runtime's container records:
  before removing the old runtime, as each agent user `podman ps -a`, `podman rm -f` the stale
  ones and `podman image prune`.
- machinectl's terminal makes systemctl cut long unit names: the operator command asks for `--full`.
- A chat runner must forward the hangup itself: the kernel sends it only to the session leader.

## WSL

WSL2 with systemd (`[boot] systemd=true` in `/etc/wsl.conf`) runs all of this: user managers,
machinectl, polkit, nftables and loop-mounted XFS images. WSLg's Wayland serves `paste`. The
boxes' boundary is the WSL kernel's.

## Adopting a setup you built by hand

Write a site file with your users' names, uids and subordinate ranges, `--render DIR` it, and
compare with what you have. Unit names, state directories, sockets and log dirs derive from the
user names (`<agent>-session@`, `<web>-worker`, `/srv/<web>`), so the same names keep sessions,
conversation ids and queue records. The paths of root's configs move to
`/etc/claude-airlock/agents/`, `/usr/local/share/airlock-agents/` and `/usr/local/lib/airlock-agents/`.
