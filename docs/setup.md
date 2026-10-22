# Setup

Install in levels. Stop at the one that gives you what you need.

| Level | You get | Install |
|---|---|---|
| 1. claude-airlock | Claude in a sandboxed container, with a firewall | `make install-airlock` |
| 2. airlock-envoy | boxes with no network except a proxy you control; credentials kept outside the box | airlock-envoy's install |
| 3. Agent users | the agent in its own Unix account, with sessions you attach to | `sudo make install-agents` |
| 4. Web research | a separate user researches the web for the agent; answers are checked first | the same install, answering yes |

## 1. claude-airlock

```
make install-airlock
```

It finishes by running `airlock doctor`, which checks the sandbox really works. Run it again to
update. Details are in the README.

## 2. airlock-envoy

Follow airlock-envoy's README. In short:

```
sudo install/install-envoy.sh 1.40.0
sudo install/install-service.sh
```

Then add a listener for yourself in `/etc/airlock-envoy/site.conf`, run
`sudo airlock-envoy-apply`, and point a project at it with
`airlock egress proxy /run/airlock-envoy/<you>/<listener>.sock`.

## 3 and 4. Agent users and web research

See [agents.md](agents.md).
