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
| `claude-agent halt` / `resume` | emergency stop of everything (below) / back to normal |

Tab completion (sessions, web commands, the queue's ids by state): add to your `~/.zshrc`, after
`compinit`, or to `~/.bashrc` with `completion.bash`:

```
source /usr/local/share/airlock-agents/completion.zsh
```

Source this root-owned copy, never one in a checkout a box can write.

To change limits: edit `agents.conf`, then `sudo airlock-agents-apply` to see the change and
`--confirm` to apply it. `--check` reports drift; `sudo /usr/local/lib/airlock-agents/host-test.sh`
checks the whole setup live, as each user.

When an apply changes the agents' user units, it ends with `next: claude-agent reload`, and says
so on every later run (`--check` fails) until each running agent manager has read them. `new`,
`restart` and the `web` commands that start a session reload first by themselves when that
session's unit (or a drop-in of it) changed, so it doesn't start on the old one.

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

#### Terminals

- **foot**: copy works with `clipboard on`; Shift+Enter is a new line in Claude's prompt.
- **Windows Terminal** (WSL): copy works with `clipboard on` (tmux knows `xterm*` terminals take
  OSC 52). Clipboard reads stay off: tmux doesn't pass them on, and Windows Terminal doesn't
  answer them. Shift+Enter arrives as a plain Enter, so Claude would submit; bind it to send
  ESC CR, which Claude reads as a new line. In `settings.json`, recent versions:

  ```json
  "actions":     [ { "command": { "action": "sendInput", "input": "\u001b\r" }, "id": "User.claudeNewline" } ],
  "keybindings": [ { "id": "User.claudeNewline", "keys": "shift+enter" } ]
  ```

  Older versions take `"keys": "shift+enter"` on the action itself. The binding applies to every
  profile (in a plain shell ESC CR is harmless). Without it, Ctrl+Enter is a new line; Alt+Enter
  is Windows Terminal's fullscreen.

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

### Emergency stop: halt and resume

When something has gone wrong and every agent should stop now:

```
claude-agent halt
```

1. It records what the agent users are running, in
   `~/.local/state/airlock-agents/halt-<time>.log`. This takes at most 2 s, and goes only to the
   log, so a flood can't hold up the kill. Box processes under subordinate uids aren't listed.
   If the directory can't be written (a full disk, say), halt goes on without the record.
2. At once, with no prompt, each agent user kills every process it may signal: its sessions, its
   boxes (their uids are mapped in a user namespace it owns) and its user manager. This runs
   through the same host shell as the other commands. It then shows the first lines of the record.
3. It says what root will do, and asks sudo for your password. Root masks each agent user's
   manager (`user@<uid>.service`), so nothing starts it again: not a login, lingering or a
   reboot. Root then kills the manager and every session of the user. If airlock-envoy is
   installed, root also turns on its kill switch (`airlock-envoy-apply --stop`, which cuts every
   box's egress, your own boxes' included) and locks its credentials, each step if its tool is
   there. The managers' stop comes last.

Every step runs even if one before it failed. Run `halt` again if a root step failed; the record
of what the first run found is kept. From the kill on, even if sudo is refused, the other
commands refuse and point at `resume`, and tab completion offers no sessions. Apply refuses while
the managers are masked, and says to resume.

```
claude-agent resume
```

As root, `resume` first lifts airlock-envoy's kill switch, but only if a `halt` turned it on and
it hasn't been rewritten since. halt writes a random value into the switch file, and resume checks
it is still there. A switch that was already on stays on. So does one rewritten by hand during
the halt (a `--stop`, or a `--start` that failed); resume says so and names `--start`. If
`airlock-envoy-apply` is gone while the halt's switch is on, or lifting it fails, the agents stay
halted and resume fails. Reinstall airlock-envoy (or fix what failed) and resume again, or give
the switch up.

Then root unmasks and starts the agents' managers, and their sessions come back by themselves.
Finally, if the credentials were unlocked when you halted, resume runs `airlock-envoy-cred unlock`
as you: your pass prompt, for the usual lifetime (`unlock.conf`). Credentials that were locked when
you halted stay locked.
Your own boxes on Envoy's sockets need a relaunch, because the sockets are new files.

Locking revokes the tokens of a GitHub App whose key is in pass. airlock-envoy's mint timer keeps
running, so a revoke that failed is retried. A file-key App's tokens stay valid at GitHub until
they expire, within the hour. Nothing can use them while Envoy is stopped.

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
either file is missing, unreadable, not root's, writable by others or over 16 KiB, they are left
out. The web and guard users' boxes get no base (`AIRLOCK_BOX_CLAUDE_MD=none`), so with no
additions of their own their CLAUDE.md is empty: their system prompts say all they need, and
every run starts cold. Your own additions for the
agent's boxes go in a root-owned file (in a root-owned tree, such as `/etc/claude-airlock/agents/`)
named by `AIRLOCK_BOX_CLAUDE_EXTRA` in its config
([configuration.md](configuration.md#the-boxs-claudemd)).

A user config is yours once written: a later apply never changes it, but names any setting a
newer default has that it lacks (`note ... has no ...`). Add the line, or a commented-out one to
say you've decided.

## Good to know

- Each box is named after its session: `airlock-<project>.<name>` (a web session's, its label),
  so `podman ps`, the journal and `htop` say which session a box is. A name still taken (a box
  still being removed after a crash) gets a suffix (`-2`, `-3`, ...); nothing is replaced.
  Boxes outside a session take `airlock-<project>`.
- An interactive box's screen doesn't go to the journal (`--log-driver none` when it has a
  terminal); the terminal is the only copy.
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
