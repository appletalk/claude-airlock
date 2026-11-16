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
| `claude-agent` | list sessions (and a line when web research waits on you) |
| `claude-agent new <project>` | start a session (kept across reboots) |
| `claude-agent attach <project>` | join it; Ctrl-b d to leave it running (no name: the one running) |
| `claude-agent stop` / `restart <project>` | stop or restart it (no name: the one running) |
| `claude-agent paste` | hand the agent the image on your clipboard |
| `claude-agent update` | give the agents your current claude-airlock |
| `claude-agent web ...` | web research (below) |
| `claude-agent halt` / `resume` | emergency stop of everything (below) / back to normal |
| `claude-agent audit denies` | Envoy's recent refusals, with who and which site file line (with `audit on`, below) |
| `claude-agent audit events` | what the store rated high or medium in the last day (`--severity`, `--kind`, `--agent`, `--since`) |
| `claude-agent audit ui` | the audit store's web UI in your browser, for you alone, until Ctrl-C |

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
what each part must provide, under `external/`. It renders for the machine it runs on: its systemd
version decides the user managers' drop-ins (from 258 a cgroup namespace each; before, hidden paths
that need the operator's uid), so render on the host the files are for.

Files the toolkit owns aren't edited locally: changes come with a toolkit update.

### gVisor (runsc)

`runsc on` (the default; install writes the line) has `make install-agents` install gVisor's
`runsc` into `/usr/local/bin` when there is none, and otherwise only report a waiting update: it
never updates on its own, because an update replaces the runtime under running boxes (stop the
sessions, then `sudo update-runsc`). `runsc off` installs none; `external runsc` says your config
repo provides it. Either way apply pauses on a runsc anyone but root can write.
Boxes don't run under it yet: [gvisor.md](gvisor.md) has the plan and the benchmark to run first.

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
   `~/.local/state/airlock-agents/halt-<time>.log`. This takes at most 3 s, and goes only to the
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
python3 /srv/claude-web/lib/web.py answer <id> --wait 30   # in the background
```

The agent's box instructions tell it to fetch the answer as a background command and carry on,
so a wait never blocks the session. `--wait` is in minutes, 0 to 60; a larger value is refused
(an agent once passed seconds).

Each question goes through three steps:

1. **Check.** Questions that look like they carry secrets or your internal names (listed in
   `agents.conf`) wait for you: `claude-agent web approve` or `reject`.
2. **Research.** A fresh box with web access only writes a report.
3. **Gate.** A scanner and a second Claude with no tools read the report. Anything suspicious is
   held for you: `claude-agent web show` and `release`.

`claude-agent web` alone opens a research chat for you. Keeping up with the queue:

| Command | What it does |
|---|---|
| `claude-agent web ls` | the last 24 hours, plus whatever waits on you (held, quarantined, failed), newest first |
| `claude-agent web ls --waiting` | only what waits on you; `--since 7d` or `--since 2026-10-25`, `--all` for more |
| `claude-agent web show [id]` | an answer, quarantine findings or a held question; no id: the newest |
| `claude-agent web approve`, `reject`, `release`, `retry <id>` | act on one; with no id they list the candidates and stop |
| `claude-agent web purge` | delete finished entries older than 7 days (`--older-than 3d` for another age) |
| `claude-agent web purge --waiting` | delete what waits on you instead of deciding it, leaving the answers |
| `claude-agent web purge --all` | delete every finished entry, waiting ones included |

An id can be given by its last 6 characters (`c2dfbe`). `purge` never touches a question still
being worked on, lists what it will delete, and asks sudo once (the files are the web and guard
users'); the stage logs keep their lines. The queue keeps entries 30 days anyway.

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

## Audit (optional)

`audit on` in `agents.conf` keeps a local record of what the agents did, for review on this
machine (nothing leaves it):

- **What goes in, all from the journal:** airlock-envoy's access log lines (turn on its
  `log-journal on`: Envoy then writes each line to the journal too, where journald names the
  unit), and only the agents' other lines: their users, their boxes' subordinate ids and their
  managers (minus box output; an agent's own `sudo` or `su` counts, as it runs in the agent's
  cgroup), airlock-envoy's units, logind, machined, polkit and sshd lines that name an agent (logind's also by its own `USER_ID` field, so its logout lines too) (nobody
  else's `sudo` is even read), the kernel's drops starting with the agents' nft log prefixes, journald's
  notices when it suppressed any of these, and the store's own units. Who wrote a line is decided
  only by the fields journald itself sets (uid, process, unit), never by what the sender says. The rest of the journal stays where it is.
  Envoy's files are never read: Envoy's own account can write that directory.
- **Classified as it is stored** (fields a sender can't set: journald takes only uppercase field
  names, and Envoy's own JSON sits under `envoy.*`):
  - `audit.kind`: which rule kept the line: `envoy-refused`, `envoy-allowed`, `envoy-web-refused`,
    `envoy-web-allowed` (the same refusal rules as `audit denies`), `privilege` (an agent's own
    sudo, su, pkexec or doas, by its setuid binary, and run0 by the system's binary under that
    name; polkit naming an agent. A refused attempt shows only if it logs: polkit writes no line
    when no authentication agent could be asked), `login` (logind or machined
    naming an agent), `session` (the agents' managers and their units), `nft-drop`,
    `journald-suppressed`, `envoy-service` (Envoy's units' other lines), `store` (the store's
    own units), `agent-process` (anything else an agent or its boxes logged);
  - `audit.agent`: the agent the line is about (by uid, a box's subordinate id, the session's
    owner, the manager's uid, logind's own `USER_ID` field, or the `(owned by unix-user:X)` tail
    of polkit's "Operator of ..." lines: the subject's own text comes before it, and polkit's
    other lines end in text the subject chooses, so they name no agent; for Envoy, the
    listener's user when it is an agent);
  - `audit.session`: the session (`<project>.<name>`) from the session unit's name, where the
    line comes from one of that agent's own sessions. The unit name can be set by the line's own
    sender, so it labels, it never decides what is kept;
  - `level` (vmui's colour): journald's priority; for Envoy's lines, what happened (a refusal a
    warning, an error Envoy answered itself an error);
  - `audit.severity`, a security rating apart from syslog's: `high` for an agent's privilege
    attempt (polkit only when it refused; `pam_systemd_home`'s "no system bus" line within it
    low, a known complaint the agents' sandbox causes) or a dropped packet; `medium` for a refusal, an
    unusual login, journald suppressing the agents' lines or the store's own errors; `low` for a
    failing session, Envoy service or agent process, and for logind's new `user`/`tty` sessions
    (the shape of the operator command's `machinectl shell`; an SSH login with a terminal looks
    the same in logind's line, and is flagged by sshd's own: `high` when sshd accepts an agent,
    `medium` for its other lines naming one);
    `info` for the rest, a user manager's session and every session's end included;
  - `audit.redacted: true` when redaction changed the line (a box sent something
    credential-shaped: flagged, not only hidden).

  Lines stored before an update that adds fields don't have them: `sudo airlock-audit reset`
  reads the journal back in with them (only what the journal still holds: compare its oldest
  entry, `journalctl --list-boots | head -2`, with `airlock-audit status`'s oldest line first).
- **Redacted before it is stored**, in every field: standard credential shapes (the values of
  query parameters named like `token`, `key`, `secret`, `password`, `sig` or `code`, cloud
  signature parameters; JSON keys, command-line flags and environment-style names of the same
  kind; `Bearer`/`Basic` values, `Authorization`, API key and token headers, cookies;
  credentials in URLs; common vendor key formats (GitHub, GitLab, Slack, Anthropic, OpenAI,
  Stripe, Hugging Face, npm, Docker Hub, PyPI, Google, AWS); JWTs; private key blocks), then
  every field cut at 8192 characters. A key printed line by line reaches the journal as separate
  lines: only its first line is recognised. The parameter name stays, so a refused `?token=` still shows. Envoy
  never logs the credentials it adds; this is for secrets a box sends itself, since whatever
  reads the store (an auditor's model included) may send it on. The raw lines stay in Envoy's
  files and the journal.
- **Nothing is dropped for volume:** a rate limit would let a box hide one request behind a burst
  of others. The cost, plainly: a flood is cheap and can push old days out of the disk cap within
  the hour (the store keeps the last two days whatever happens), and it costs the journal too
  (its own size cap). VictoriaLogs logs each day it drops, among the store's own lines, so a
  flood is visible, not prevented. The store is a copy for querying: the journal and Envoy's
  files stay the record.
- **Not covered:** an Envoy line over journald's line limit (48 KiB, a request with a huge path)
  arrives split, as plain journal lines without Envoy's fields; lines from airlock-envoy's socket
  relays (`airlock-envoy-proxy@`); and, when Vector itself restarts, the lines it held but hadn't
  stored yet (a VictoriaLogs restart loses nothing: Vector waits and retries).
- **Where:** a VictoriaLogs under its own account `airlock-audit`, data in `/var/lib/airlock-audit`,
  kept 90 days up to 5 GB (`audit on retention 180d max-disk 10G` to change). Vector 0.57 or later (your distribution's package) feeds it without
  reading the journal itself: a small reader unit (a dynamic user, the only one in
  `systemd-journal`, no network) runs `journalctl` with fixed matches, and systemd hands its output
  to a pipe made at boot that only Vector reads, so Vector only ever sees the candidate lines. `make install-agents` installs
  VictoriaLogs and vmauth from images pinned by digest (`sudo update-victorialogs`).
- **Access:** the store has no network port. It, vmauth and Vector run in a network namespace of
  their own; the only way in is the socket `/run/airlock-audit/vl.sock`, which only
  `airlock-audit`, `airlock-envoy` (for an auditor's listener), you and root can connect to, and
  which leads to vmauth: queries (`/select/`) pass, nothing else (no inserts, no deletes; vmauth's
  own endpoints take a random key made at each start that nobody holds). To query by hand:
  `curl --unix-socket /run/airlock-audit/vl.sock http://x/select/logsql/query -d 'query=_time:1h | limit 10'`.
- **With external nftables**, name your drop rules' log prefixes, 16 characters or more before
  any colon (a process name is at most 15, and the kernel starts some lines with it):
  `audit-nft-prefix myhost-agent-drop: myhost-agentweb-drop:`.
- **What was refused:** `claude-agent audit denies [--since 7d] [--limit 200]` (yours, no sudo):
  Envoy's own refusals, newest first (the last 24 hours, 50 by default), each with its time, user
  and listener, status, what was asked (method and host, or the TLS name in a tunnel), Envoy's
  route, and which site file line would change it (a listener's destinations, a host's `http`
  line, an internal name, a locked credential, a protected branch). It also lists web failing
  to reach a name (its kernel filter refuses internal addresses that way). A refused TLS name has
  no user in Envoy's line: it is taken from the CONNECT that opened that tunnel (the one with the
  same connection id from 20 seconds before it to 3 seconds after, as ids restart with Envoy and
  a TLS name comes within 15 seconds), and shown as `?` when there is none, never a guess.
  Upstream's own errors (a 403 from the server itself), a tunnel's or plain-HTTP host's failed
  connection, and timeouts are not refusals and stay out.
  One fixed query, no model; what it prints is the agents' text (hosts, paths, names), cleaned of
  control characters, never acted on. It works while the agents are halted.
- **By severity:** `claude-agent audit events [--severity high|medium|low|info] [--kind <kind>]
  [--agent <name>] [--since 7d] [--limit 200]` lists the lines the store rated at that severity and
  above (medium and the last 24 hours by default), newest first: time, severity, kind, agent and
  session, what happened (a redacted line says so), then a count by severity. Kind and agent are
  checked against their shape before they go into the fixed query, and matched exactly (`--agent
  agent` is not also `agent-web`). Lines stored before the store
  rated them don't show (a reset reads them in again).
- **Browsing it:** `claude-agent audit ui` serves the store's web UI (VictoriaLogs' vmui) at
  `http://127.0.0.1:9429/select/vmui/` until Ctrl-C (`--port <n>` for another), and closes by
  itself after 30 minutes without a request or 4 hours in all, so it isn't left open. A loopback port
  is open to every process on the host, so each connection's owner is looked up in the kernel's
  socket table and only yours is served (it names any other uid it refused, once each). A web
  page in your own browser runs as you, so the UI serves only itself: a `Host` of
  `127.0.0.1:<port>` or `localhost:<port>` (no name pointed at 127.0.0.1), no request another
  site started (an `Origin` or `Sec-Fetch-Site` that isn't this one's is refused before anything
  reaches the store), and no CORS (VictoriaLogs allows any origin; those headers are dropped).
  A browser too old to send either header can still send a blind query, but can't read the
  answer. Refused requests don't count as use. The store's door still allows only queries.
- **Day to day:** `sudo airlock-audit status` (units, what the store holds, seccomp kills),
  `restart`, `check` (the guarantees above, live: exit 1 on any failure), and `reset` (empties the
  store and reads the retention window back in from the journal; asks first).
- `audit off` stops and disables the units; the data in `/var/lib/airlock-audit` stays until you
  remove it.

## Good to know

- Each box is named after its session: `airlock-<project>.<name>` (a web session's, its label),
  so `podman ps`, podman's events in the journal and `htop` say which session a box is. A name still taken (a box
  still being removed after a crash) gets a suffix (`-2`, `-3`, ...); nothing is replaced.
  Boxes outside a session take `airlock-<project>`.
- The engine keeps no copy of a box's output (`--log-driver none`, with a terminal or
  without), so it no longer reaches the journal on its own: an interactive box's screen stays
  in the terminal, and a headless box's output goes where its caller sends it (a worker's result
  file; what a worker leaves on stdout or stderr is its unit's log, which is the journal).
  `podman logs` shows nothing.
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
