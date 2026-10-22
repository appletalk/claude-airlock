# Agent users (optional)

Run the agent as its own Unix user instead of as you. If something escapes the box, it lands
in an account that can't read your files, keys or sessions.

This is optional. `make install-airlock` never touches it. It needs
[airlock-envoy](https://github.com/appletalk/airlock-envoy) running first, because the agent's
boxes have no network except Envoy's sockets.

You get:

- **The agent** (user `claude` by default). Its Claude sessions run in its own account and keep
  running when you log out. You attach from a terminal or use the Claude app.
- **Web research** (optional). A second user searches the web for the agent; a third checks each
  answer before the agent sees it. The agent itself never gets the web.

## How it's contained

Each agent user has:

- its own uid, no groups, a locked password, and a fixed-size home (it can't fill your disk);
- a sandboxed user manager: no network, its own `/tmp`, can't see other users' processes or homes;
- memory and CPU limits;
- a firewall rule dropping any traffic from it on the host;
- its own airlock-envoy listeners, so you decide what it can reach;
- root-owned config it can't change.

You can open a shell as the agent users, and nothing more.

## Install

Install the packages:

```
sudo apt install podman crun tmux systemd-container acl xfsprogs python3 nftables polkitd   # Ubuntu
sudo pacman -S --needed podman crun tmux acl xfsprogs python nftables polkit                # Arch
```

Then, from a clone of claude-airlock that no box mounts:

```
sudo make install-agents
```

The first run asks a few questions (names, sizes) and offers defaults. It saves the answers in
`/etc/claude-airlock/agents/agents.conf`. Keep a copy in your config repo.

Next, give each agent user an Envoy listener. The install prints the lines to add to
`/etc/airlock-envoy/site.conf`, for example:

```
claude-anthropic  @anthropic
client claude-anthropic claude
```

Finally, as yourself (the command is `claude-agent` unless you picked another name):

```
claude-agent update      # copies your installed claude-airlock to the agent users
claude-agent reload
claude-agent shell       # once: run `airlock` in a project folder and /login
claude-agent new myproject
claude-agent attach myproject
```

## Day to day

| Command | What it does |
|---|---|
| `claude-agent` | list sessions |
| `claude-agent new <project>` | start a session (kept across reboots) |
| `claude-agent attach <project>` | join it; Ctrl-b d to leave it running |
| `claude-agent stop` / `restart <project>` | stop or restart it |
| `claude-agent paste` | hand the agent the image on your clipboard |
| `claude-agent update` | give the agents your current claude-airlock |
| `claude-agent web ...` | web research (below) |

To change names, sizes or limits: edit `agents.conf`, then `sudo airlock-agents-apply` to see
the change and `--confirm` to apply it. `--check` reports drift.

## Web research

The agent asks a question from its box:

```
python3 /srv/claude-web/lib/web.py ask "question" --why "reason"
python3 /srv/claude-web/lib/web.py answer <id> --wait 15
```

Each question goes through three steps:

1. **Check.** Questions that look like they carry secrets or your internal names (listed in
   `agents.conf`) wait for you: `claude-agent web approve` or `reject`.
2. **Research.** A fresh box with web access only writes a report.
3. **Gate.** A scanner and a second Claude with no tools read the report. Anything suspicious is
   held for you: `claude-agent web show` and `release`.

`claude-agent web` alone opens a research chat for you. `claude-agent web ls` shows every question.

## Good to know

- The agent users must use `crun`, not `runc`. The install sets this up.
- Switching an agent user from `runc` to `crun` leaves stale containers behind. Before removing
  `runc`, run `podman ps -a` as each agent user and `podman rm -f` the old ones.
- On WSL2, turn on systemd (`systemd=true` under `[boot]` in `/etc/wsl.conf`). Everything else
  works as on Linux, including `paste` through WSLg.
- Moving an existing hand-built setup over: write `agents.conf` with the same names and uids. Unit
  names and state follow the user names, so sessions and history carry over.
