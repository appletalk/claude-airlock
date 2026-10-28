# Setup

Install in levels. Stop at the one that gives you what you need.

| Level | You get | Install |
|---|---|---|
| 1. claude-airlock | Claude in a sandboxed container, with a firewall | `make install-airlock` |
| 2. airlock-envoy | boxes with no network except a proxy you control; credentials kept outside the box | airlock-envoy's install |
| 3. Agent users | the agent in its own Unix account, with sessions you attach to | `sudo make install-agents` |
| 4. Web research | a separate user researches the web for the agent; answers are checked first | the same install, answering yes |

## Before any level: the host's own Claude

The boxes are only as safe as the Claude you run directly on the host, which runs as you and
outside every boundary. Lock it down once, as root:

```
sudo install -D -m 0644 config/host-managed-settings.json /etc/claude-code/managed-settings.json
```

If that file already exists, merge these keys into it instead. They do three things:

- **No Remote Control on the host** (`disableRemoteControl`). Claude's cross-session messaging
  runs over Remote Control and links every session on your account, so without this a session in
  a box (or an agent user's session) can list your host session and send it messages.
- **No messages from other sessions** (`crossSessionInbound: refuse`), for the same reason.
- **No artifacts or cloud triggers** (the `deny` list): they are account-level state any session
  on the account can read or start.

Your boxes and agent sessions can still use Remote Control; only the host session can't.

One habit matters as much: **never run an interpreter or build tool on the host with its working
directory in a checkout a box or an agent user can write** (`python3 -`, `node`, `make`, `npx`,
`direnv`). Python puts the current directory first on its import path, so a `json.py` committed
there runs as you. Run them from elsewhere and pass paths, or use `python3 -I`. A host Claude
working in such a checkout should follow the same rule.

## 1. claude-airlock

```
make install-airlock
```

It finishes by running `airlock doctor`, which checks the sandbox really works. Run it again to
update. Details are in the README.

## 2. airlock-envoy

Follow airlock-envoy's README. In short:

```
sudo install/install-envoy.sh 1.40.2
sudo install/install-service.sh
```

Then add a listener for yourself in `/etc/airlock-envoy/site.conf`, run
`sudo airlock-envoy-apply`, and point a project at it with
`airlock egress proxy /run/airlock-envoy/<you>/<listener>.sock`.

## 3 and 4. Agent users and web research

See [agents.md](agents.md).
