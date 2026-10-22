# Setup, by level

Each level builds on the one before. Stop at the first one that gives you what you need. The
details live in the README sections linked from each step; this page is the order and the checks.

| Level | What you get | Who installs | Needs |
|---|---|---|---|
| 1. claude-airlock | Claude in a rootless box, an in-box firewall (Anthropic only, or a dev allowlist) | you | rootless Podman (or Docker) |
| 2. + airlock-envoy | boxes with **no network**, only a host proxy socket: per-listener allowlists, an audit log, credentials injected outside the box (gh, git, kubectl) | root | level 1 |
| 3. + agents | the agent in **Unix users of its own** (default `claude`), sandboxed user managers, named sessions you attach to | root | level 2, running |
| 4. + agent web research | a second agent user researches the web; a third gates its answers before the first sees them | root | level 3 |

There is no plain `make install`: each level has its own target, so nothing is installed by
accident.

## 1. claude-airlock (you)

```
make install-airlock      # launcher + images, as yourself; ends with `airlock doctor`
```

- Prerequisites, shell integration, auth: README § Setup.
- Check: `airlock doctor` passes (a real box proves an allowed host is reachable and a denied one is not).
- Update: rerun `make install-airlock` (Claude Code and Debian security updates; README § 2).

## 2. airlock-envoy (root)

From a clean clone of [airlock-envoy](https://github.com/appletalk/airlock-envoy), as its README § Install says:

```
sudo install/install-envoy.sh 1.40.0      # the release binary, signature-checked
sudo install/install-service.sh           # account, units, airlock-envoy-apply
```

- Write `/etc/airlock-envoy/site.conf`: a listener per profile, each with its one `client` user
  (airlock-envoy README § Site listeners); apply with `sudo airlock-envoy-apply`.
- Credentials the box must never hold (a GitHub token, a Forgejo bot, a Kubernetes token):
  `sudo airlock-envoy-cred set <name>` and an `http` line (§ Plain HTTP and credentials). The
  box gets its gh, tea and kubectl config from the proxy at launch (README § Plain HTTP
  through the proxy).
- Point boxes at a socket: `airlock egress proxy /run/airlock-envoy/<you>/<listener>.sock`, or
  as the default in your host config (README § Egress through a host proxy).
- Check: `airlock egress show` names the socket and its check; `sudo airlock-envoy-apply --status`.

## 3. Agents (root) and 4. agent web research

Not part of this version yet.
