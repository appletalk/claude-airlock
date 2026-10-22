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
- its own airlock-envoy listeners, so you decide what it can reach (the agent's own listeners
  never get the open web: apply refuses that);
- no cron or at jobs, which would run outside its sandbox;
- root-owned config that Claude in its box can't change.

You can open a shell as the agent users, and nothing more.

## Install

Install the packages:

```
sudo apt install podman crun tmux systemd-container acl xfsprogs python3 nftables polkitd wl-clipboard   # Ubuntu 23.10+, Debian 12+
sudo pacman -S --needed podman crun tmux acl xfsprogs python nftables polkit wl-clipboard                # Arch
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

To change limits: edit `agents.conf`, then `sudo airlock-agents-apply` to see the change and
`--confirm` to apply it. `--check` reports drift; `sudo /usr/local/lib/airlock-agents/host-test.sh`
checks the whole setup live, as each user.

### When apply stops

Apply never overwrites a file it didn't write, and never changes anything when something looks
wrong. It stops, says "paused, nothing changed", and lists what it found, for example:

- a file it would write that someone else wrote (move it away, or mark that part external);
- one of its own files changed or deleted by hand (put it back; make changes in `agents.conf`);
- a home image whose size no longer matches `agents.conf`;
- on WSL, interop on or Windows drives readable by the agents.

A few findings you can decide to live with: add `accept wsl-interop`, `accept wsl-drives` or
`accept generic-dropins` to `agents.conf`.

### Parts you manage yourself

If your config repo already manages the firewall, polkit or shell profile, say so in
`agents.conf`, for example `external nftables`. Apply then never writes that part and checks the
live result instead (the firewall must drop each agent user; polkit must let you open a shell as
them). `sudo airlock-agents-apply --render /tmp/out` shows what each part must provide, under
`/tmp/out/external/`.

Files the toolkit owns aren't edited locally: changes come with a toolkit update.

### Renaming and resizing

Renaming a user isn't supported. A home image only grows by hand: `truncate -s 50G
/var/lib/<user>/home.img`, `losetup -c /dev/loopN`, `xfs_growfs /home/<user>`, then update
`agents.conf` to match. XFS can't shrink.

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
- **WSL2** (not yet tested there). Turn on systemd (`systemd=true` under `[boot]` in
  `/etc/wsl.conf`). Two WSL defaults undo the separation, and apply warns about both:
  - `/mnt/c` is readable by every Linux user. Restrict it: `options = "uid=1000,gid=1000,umask=077"`
    under `[automount]`.
  - Interop lets any Linux user run Windows programs as you. Turn it off with `enabled=false`
    under `[interop]`, or decide you accept it.
- **Moving a hand-built setup over:** write `agents.conf` with the same names and uids. Unit names
  and state follow the user names, so sessions and history carry over. Move your old drop-ins
  and units away first: apply stops on files at its own paths and on other drop-ins for the
  agent users. Old files under other names (a polkit rule, tmpfiles entries) it can't recognise:
  remove those yourself, or keep them and mark that part external.
