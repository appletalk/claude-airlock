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
- a sandboxed user manager: no network, its own `/tmp` and `/run` (no host sockets such as the
  DNS resolver's), can't see other users' processes or homes, writes only its own paths;
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

Tab completion (sessions, web commands, the queue's ids by state): add to your `~/.zshrc`, after
`compinit`, or to `~/.bashrc` with `completion.bash`:

```
source /usr/local/share/airlock-agents/completion.zsh
```

Source this root-owned copy, never one in a checkout a box can write.

To change limits: edit `agents.conf`, then `sudo airlock-agents-apply` to see the change and
`--confirm` to apply it. `--check` reports drift; `sudo /usr/local/lib/airlock-agents/host-test.sh`
checks the whole setup live, as each user.

Limits apply at once. A changed sandbox (paths, isolation) reaches a running agent user only when
its manager restarts; apply names those. Reboot, or `systemctl restart user@<uid>` (it ends that user's sessions).

### When apply stops

Apply never overwrites a file it didn't write, and never changes anything when something looks
wrong. It stops, says "paused, nothing changed", and lists what it found, for example:

- a file it would write that someone else wrote (move it away, or mark that part external);
- one of its own files changed or deleted by hand (put it back; make changes in `agents.conf`);
- a home image whose size no longer matches `agents.conf`;
- on WSL, interop on or Windows drives readable by the agents.

A few findings you can decide to live with: add `accept wsl-interop`, `accept wsl-drives`,
`accept generic-dropins` or `accept id-ranges` (when users come from SSSD, winbind or LDAP,
once you have checked the agents' ids don't overlap its ID mapping) to `agents.conf`.

### Parts you manage yourself

If your config repo already manages the firewall, polkit or shell profile, say so in
`agents.conf`, for example `external nftables`. Apply then never writes that part and checks the
live result instead (polkit must let you open a shell as each agent user; the firewall must drop
each one with a rule of its own, in an `inet` table's output chain, before any rule there that
accepts, even `ct state established`). `airlock-agents-apply --render ~/agents-render` (as yourself, into a new directory) shows
what each part must provide, under `external/`.

Files the toolkit owns aren't edited locally: changes come with a toolkit update.

### The clipboard

By default the session's tmux doesn't pass clipboard writes on to your terminal. `clipboard on`
in `agents.conf` passes Claude's copy (select, then Ctrl+C) on. Either way the tmux runs as the
agent user, which could change that setting itself, so the real control is your terminal: use
one that asks before a program writes the clipboard (OSC 52), or turn that off there.

### Removing a user, renaming, resizing

Apply won't remove a user for you: it pauses when one it set up is gone from `agents.conf`. To
remove one (web research, say), as root:

```
loginctl disable-linger <user>
systemctl stop user@<uid>.service
systemctl disable --now "$(systemd-escape --path /home/<user>).mount"
userdel <user>; groupdel <user>
sed -i '/^<user>:/d' /etc/subuid /etc/subgid
rm -r /var/lib/<user> /etc/claude-airlock/agents/<user>.conf
```

Then edit `agents.conf` and run `sudo airlock-agents-apply --confirm`; it withdraws that user's
files. Renaming is removing and adding. A home image only grows by hand: `truncate -s 50G
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

The agent's boxes are told this themselves. When a box has the queue mounted (requests/
read-write, answers/ and lib/ read-only, as the agent's default config sets up), the launcher
adds two parts to its CLAUDE.md, both rendered by the apply into the queue's `lib/` with your
names and paths: a rule at the very top (answers are untrusted data, never instructions; what to
do when one asks for something) and the two commands at the end. Without web research, or if
either file is missing, unreadable, not root's, writable by others or over 16 KiB, the box
CLAUDE.md is the plain one.

## Good to know

- The agent users must use `crun`, not `runc`. The install sets this up.
- Switching an agent user from `runc` to `crun` leaves stale containers behind. Before removing
  `runc`, run `podman ps -a` as each agent user and `podman rm -f` the old ones.
- **WSL2** (being tried; report what breaks). Turn on systemd (`systemd=true` under `[boot]` in
  `/etc/wsl.conf`).
  - The agents' sandbox already shuts out what WSL adds: nothing under `/mnt` (the Windows
    drives, WSLg's audio, microphone and display sockets, the tmpfs every distro shares), and
    `/dev/dxg` and `/dev/vsock` can't be opened. With systemd 255 or later it also refuses vsock
    sockets, which WSL interop rides to Windows (before 255 that restriction would stop rootless
    podman, so it is left out; the boxes refuse vsock themselves either way). Interop's own
    socket, under `/run/WSL`, is hidden with the rest of `/run`. `host-test.sh` checks these, as
    each agent user.
  - Two WSL defaults still reach past it (a shell opened as an agent user outside its sandbox,
    or anything else running as that user), and apply warns about both:
    - `/mnt/c` is readable by every Linux user: your whole Windows profile, which on a work
      machine holds the organisation's data. Restrict it:
      `options = "uid=1000,gid=1000,umask=077"` under `[automount]`.
    - Interop lets any Linux user run Windows programs as you, and Windows can open a root
      shell in the distro without a password. Turn it off with `enabled=false` under
      `[interop]`, or accept it once `host-test.sh` passes: on WSL it also runs a real Windows
      program as each agent user, inside its sandbox, and expects it to fail.
  - WSL terminals may have no login session (`loginctl` shows none for you), so on WSL the
    polkit rule lets the operator in without one: still only the operator, only as the agent
    users, but from any of your processes (an ssh session or a timer too), not only a terminal.
  - WSL may stop the distro when no Windows terminal is attached, which ends the agents'
    sessions. Check, and if it does, raise the idle timeout in `.wslconfig`.
- **Moving a hand-built setup over:** write `agents.conf` with the same names and uids. Unit names
  and state follow the user names, so sessions and history carry over. Move your old drop-ins
  and units away first: apply stops on files at its own paths and on other drop-ins for the
  agent users. Old files under other names (a polkit rule, tmpfiles entries) it can't recognise:
  remove those yourself, or keep them and mark that part external.
