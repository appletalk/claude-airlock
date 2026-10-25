# Egress through a host proxy: `airlock egress proxy`

The third egress posture, beside `minimal` and `dev`. The box gets **no network at all**.
Its only way out is one host proxy's Unix socket, and the proxy decides what is reachable
(and can log every connection).

## Use it

For one project:

```
airlock egress proxy /run/airlock-envoy/alice/main.sock   # this project
airlock egress show                                       # posture, socket, and its check
airlock egress minimal                                    # back to the in-box firewall
```

Or as the default for every project, in the host config:

```
AIRLOCK_EGRESS_MODE=proxy
AIRLOCK_EGRESS_PROXY=/run/airlock-envoy/alice/main.sock
```

A project that sets another posture is named at each launch, so a box running outside the
proxy is never silent.

The socket must pass the same [socket rule](configuration.md#the-socket-rule) as `airlock
socket add`. The box connects as you (under Docker, as uid 1000), so grant that uid on the
socket.

[airlock-envoy](https://github.com/appletalk/airlock-envoy) is one such proxy: Envoy behind
a systemd socket unit, an allowlist per listener, and an audit log of every connection.
Anything that speaks HTTP `CONNECT` on a socket that passes the rule works too. Install
order is in [setup.md](setup.md).

## How it works

- The box starts with `--network none`: loopback and nothing else, no route, no resolver.
- The proxy socket is mounted at its real path. The entrypoint bridges it to
  `127.0.0.1:3128` and points `HTTPS_PROXY` and `HTTP_PROXY` there.
- Sockets you granted with `airlock socket add` stay mounted too. They bypass the proxy, so
  each launch and `airlock egress show` name them.

Everything in the box has to go through the proxy, so tools that ignore the proxy
variables fail rather than leak. The box has no DNS, and SSH remotes or raw TCP have no
route. Images built before this posture are refused with a message to rebuild them.

## Guarantees

- **The network namespace enforces it, not the proxy variables.** A box that unsets
  `HTTPS_PROXY`, kills the bridge or starts its own relay gains nothing: there is still no
  route out except the sockets mounted into it. The entrypoint also refuses to start Claude
  if it finds any interface besides loopback.
- **It fails closed.** If the socket is missing, or fails the socket rule at launch, the
  box does not start. It never falls back to a network. A posture the launcher does not
  recognise (`AIRLOCK_EGRESS_MODE=Proxy`, say) refuses the launch too, rather than being
  read as `minimal`.
- **The box cannot change it.** The posture lives in the host state dir, and there is no
  `.airlock/config` key for it.
- **One policy: the proxy's.** Egress groups, `egress =` lines and `AIRLOCK_EXTRA_EGRESS`
  do not apply while it is set. A launch says so if any are present, and `airlock egress
  add|rm` are refused. An `egress =` entry that is malformed or points at the host still
  stops the launch, as in every posture. To widen what a box can reach, widen the proxy's
  allowlist, or give the project a socket for a different listener.
- **Secrets cannot steer it.** `airlock secret` refuses `AIRLOCK_*` and `*_PROXY` keys,
  and a launch skips any already stored. That includes a corporate `HTTPS_PROXY` for a
  networked project: set such a proxy in the host config's `AIRLOCK_EXTRA_EGRESS` and the
  tool's own config instead, or use this posture with that proxy behind the socket.
- **No firewall capabilities.** With no network to filter, the box also drops `NET_ADMIN`
  and `NET_RAW`.

## Plain HTTP through the proxy

A proxy can serve some hosts by **plain HTTP**: the box sends `http://<host>/...`, and the
proxy checks the request, adds the credential and does the TLS (airlock-envoy's `http`
lines). This is how a box uses git, gh, tea and kubectl without holding a credential.

If the proxy writes a client manifest next to its socket (`<name>.clients` beside
`<name>.sock`; airlock-envoy does), each launch points the box's clients at those hosts.

### git

In the box's own `~/.gitconfig`, remotes on each git host (rules `git`, `git-read`,
`forgejo` or `any`) are rewritten to `http://<host>/`. These forms are rewritten:

- `https://<host>/`, `https://<host>:443/`
- `git@<host>:`, `<host>:`
- `ssh://git@<host>/`, `ssh://git@<host>:22/`, `ssh://<host>/`, `git+ssh://git@<host>/`
- `git://<host>/`
- `ssh://git@<host>:PORT/` for each port in `AIRLOCK_GIT_SSH_PORTS` (host config, e.g.
  `AIRLOCK_GIT_SSH_PORTS=2222`)

The repo's own config, which your host git also reads, keeps its ssh or https URLs.

Not rewritten, because git matches the prefix exactly, so these fail with no route out:

- a host in another case (`git@GitHub.com:`);
- a user in an https URL (`https://user@<host>/`);
- another ssh user;
- an `~/.ssh/config` alias;
- other names of the host (`www.`).

These rewrites win over a repo's own `insteadOf` for the same host, so such a repo also
goes through the proxy, with the proxy's identity.

### gh

If `api.github.com` is one of the hosts and the proxy has a credential for it, a read-only
box gh config (`GH_CONFIG_DIR=/etc/airlock-box/gh`) sends gh's requests over the proxy
socket itself (`http_unix_socket`), with a placeholder `GH_TOKEN` the proxy replaces.

- Without a credential gh is not set up (GitHub refuses the placeholder, and gh will not
  run without a token).
- Under rules other than `github-api` (say `github-issues`), the launch says which writes
  will get 403.
- gh's telemetry and update checks are off.
- gh reaches only `api.github.com` this way. Uploads and other GitHub hosts are refused by
  the proxy.
- If the proxy scopes the host to some repos (airlock-envoy's `repos`), it refuses GraphQL,
  which most `gh pr` and `gh issue` commands use. The manifest doesn't say which hosts are
  scoped, so the box's CLAUDE.md section for GitHub and git hosts says what a 403 for another
  repo or for `/graphql` means, and gives the `gh api` (REST) forms for PRs, issues, comments
  and checks.

### tea

For each Forgejo host (rules `forgejo`) the proxy has a credential for, the box gets a tea
login at `http://<host>` with a placeholder token the proxy replaces with the bot's. tea
matches a repo's ssh or https remote to it by host.

The launcher mounts it read-only and the entrypoint copies it to `~/.config/tea` (tea reads
nothing else), so an image built before this has no tea login. Your own tea config is never
mounted (`.config/tea` is on the deny list).

### kubectl

For each Kubernetes API server (rules `kubernetes-read`) the proxy has a credential for,
the box gets a read-only kubeconfig (`KUBECONFIG=/etc/airlock-box/kube/config`) with
`server: http://<host>` and no user or token. kubectl goes through the proxy variables and
the proxy adds the token. There is one context per server; the first is current.

- A `KUBECONFIG` secret takes its place (the launch says so).
- When the proxy's token has expired, kubectl reports "the server has asked for the client
  to provide credentials". Renew it on the host.

### curl and the rest

Use `http://<host>/` URLs. The proxy variables already point there.

### Tokens in the box anyway

While the proxy holds any credential, the launch names every secret that looks like a
GitHub token, by key (`GH_TOKEN`, `GITHUB_*_TOKEN`, `*_PAT`, ...) or by value (`ghp_`,
`github_pat_`, ...), never printing it. It warns and launches; remove them with `airlock
secret rm`. A `GH_TOKEN` secret also takes the placeholder's place.

### The box's CLAUDE.md

The box CLAUDE.md ([configuration.md](configuration.md#the-boxs-claudemd)) gets a section listing these hosts: how to reach each
(`http://`, never `https://`), what its rules allow and refuse, and which client is set up
for it. So boxed Claude neither tries `https://` nor guesses at the limits. It is written
each launch from the manifest. With no hosts (or no usable manifest), there is no section.

### Per session, and which images

Each session gets its own copy of the git and gh config, removed when it ends, so a later
launch in another posture never changes what a running box's git does. If the launcher is
killed while its box runs on, the next launch sweeps that copy: the box keeps its git
config but its gh config empties, so gh fails closed (no network) until the box is
relaunched.

The clients (git, gh, tea, kubectl) are in `:dev` and the images built on it. A `:base` box
gets the same config files but has no client to read them.

### The manifest is checked

`airlock egress show` lists the hosts. The manifest ends up in git config, so it is used
only if:

- it is owned by root, writable only by root, and in a root-owned directory;
- it is at most 64 KiB;
- every line is `<host> <port> <rules> yes|no`, with a valid lowercase host name or IPv4
  address.

Otherwise the launch says why and goes on with no client set up. No manifest, nothing
changes.
