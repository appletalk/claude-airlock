# Configuration

There are two config files, and a set of host-only grants made with `airlock` commands.

| Where | Who writes it | Trusted? |
| --- | --- | --- |
| `~/.config/claude-airlock/config` (host config) | you | Yes. Sourced as bash. |
| `<project>/.airlock/config` (project config) | committed with the project; **the box can write it too** | No. Safe-parsed, never sourced. It can only *request*; you approve on the host. |
| Per-project state dir (secrets, approvals, posture, mounts, sockets, modes) | `airlock` subcommands on the host | Yes. Never mounted into a box. |

## Host config: `~/.config/claude-airlock/config`

Your machine's defaults. `make install-airlock` writes one; `config/config.example`
documents each key. `AIRLOCK_CONFIG` names a different file (for example one root owns;
see [dedicated-user.md](dedicated-user.md)).

| Key | Default | Effect |
| --- | --- | --- |
| `AIRLOCK_ENGINE` | `podman` | `podman` (rootless, recommended) or `docker`. |
| `AIRLOCK_PODMAN_NETWORK` | `pasta` | Rootless podman's network stack: `pasta` or `slirp4netns`. Extra pasta options may follow a colon (`pasta:--mtu,1400`). Leave it alone unless pasta misbehaves. |
| `AIRLOCK_DNS` | empty (automatic) | Resolvers for the box, space-separated. Set it when a box has no usable resolver, e.g. docker on a host whose only resolver is loopback. See [security-model.md](security-model.md#dns-is-pinned-which-narrows-exfiltration-but-does-not-close-it). |
| `AIRLOCK_IMAGE` | `claude-airlock:dev` | Image to run. See [images.md](images.md). |
| `AIRLOCK_MODEL` | `opus` | Default model in the box: `opus`, `sonnet`, `haiku`, `opusplan` or a full model id. `""` uses Claude Code's default. Override per session with `airlock --model sonnet`. |
| `AIRLOCK_EGRESS_MODE` | `minimal` | Default egress posture for projects that have not set one: `minimal`, `dev` or `proxy`. An unrecognised value refuses every launch. |
| `AIRLOCK_EGRESS_PROXY` | empty | The proxy socket for the `proxy` posture, and the default for `airlock egress proxy` with no argument. See [egress-proxy.md](egress-proxy.md). |
| `AIRLOCK_EXTRA_EGRESS` | empty | Domains always allowed, in every posture but `proxy`. Host-trusted, not prompted. Space or comma separated. |
| `AIRLOCK_GIT_SSH_PORTS` | empty | Extra ssh ports git remotes name; rewritten in the proxy posture. See [egress-proxy.md](egress-proxy.md#plain-http-through-the-proxy). |
| `AIRLOCK_SHARE_BASE` | `~/development` | Base for project `share =` / `share_rw =` paths. |
| `AIRLOCK_ROOTS` | empty | Broad read-only trees mounted at `/roots/<name>` in every box. Host-trusted, not prompted. Space or colon separated. Gets the same protected-location check as shares. |
| `AIRLOCK_PROTECTED_PATHS` | empty | Extra host paths (absolute or `~/`) no share or mount may contain or sit inside. A relative entry fails closed. |
| `AIRLOCK_ARTIFACT_DIRS` | `.venv node_modules` | Build-output directories kept container-local (shadow-mounted with per-project storage), relative to the project. |
| `AIRLOCK_SHARE_MEMORY` | `rw` | Share this project's Claude memories with the host: `rw`, `ro` or `off`. See [security-model.md](security-model.md#shared-memory-is-an-influence-channel). |
| `AIRLOCK_SHARE_HISTORY` | `1` | `0` shares no sessions or memories with the host at all. |
| `AIRLOCK_PERSIST_LOGIN` | `0` | `1` skips the shared token so the box logs itself in. Normally set per project with `airlock login persist` instead; see [install.md](install.md#one-project-that-logs-itself-in). |
| `AIRLOCK_TOKEN_FILE` | `~/.config/claude-airlock/token` | Where the shared OAuth token is read from (a `CLAUDE_CODE_OAUTH_TOKEN` in the environment wins). |
| `AIRLOCK_PERMISSION_MODE` | empty | Starting permission mode for this one launch; beats `airlock mode`, loses to `--permission-mode` on the command line. |
| `AIRLOCK_PIDS_LIMIT` | `4096` | Process-count cap for the box. `0` or empty uses the engine default (podman 2048, docker unlimited). |
| `AIRLOCK_MEMORY` | empty (no limit) | Host RAM ceiling for the box, e.g. `8g`. Too low a cap breaks real builds, so set it deliberately. |
| `AIRLOCK_TZ` | `$TZ`, else the host's zone, else UTC | The box's timezone, a zone name such as `Europe/Berlin`. The host's zone comes from `timedatectl` or `/etc/localtime`. |
| `AIRLOCK_GIT_NAME`, `AIRLOCK_GIT_EMAIL` | your host's global git `user.name` / `user.email` | Git identity in the box. A repo's own `.git/config` still wins. |
| `AIRLOCK_GIT_RO` | `1` | Bind the git config and hooks of read-write repos read-only. `0` turns it off. See [security-model.md](security-model.md#git-config-and-hooks-are-read-only-in-the-box). |
| `AIRLOCK_SECRET_DENY` | empty | `pass` entries never injected into a box, as space-separated globs. See [Secrets](#secrets-airlock-secret). |
| `AIRLOCK_PASTE_PROJECT` | none | The project `airlock paste` writes into. Required to use paste. See [scratch-and-pastes.md](scratch-and-pastes.md). |
| `AIRLOCK_PASTE_DIR` | none | A read-only paste drop box instead. See [scratch-and-pastes.md](scratch-and-pastes.md#a-drop-box-instead-airlock_paste_dir). |
| `AIRLOCK_EXTRA_MOUNTS` | empty | Operator-only shared directories (`DIR:ro` / `DIR:rw`). Also read from the launching environment. See [dedicated-user.md](dedicated-user.md). |
| `AIRLOCK_MANAGED_SETTINGS` | empty | A Claude Code managed-settings drop-in for every box. See [dedicated-user.md](dedicated-user.md). |

Environment only (refused, or not read, from the config file):

| Variable | Effect |
| --- | --- |
| `AIRLOCK_TMP_BASE` | Moves the scratch base from `/tmp/airlock-<user>`. Set in the config file it stops the launch, because the host `claude` wrapper reads only the environment. See [scratch-and-pastes.md](scratch-and-pastes.md). |
| `AIRLOCK_CONFIG` | Path of the host config file. |
| `CLAUDE_CODE_VERSION` | For `make install-airlock`: `stable`, or a specific `x.y.z`, instead of the latest release. |

## Project config: `<project>/.airlock/config`

Committed with the project. It is **safe-parsed** as `key = value` lines, never sourced,
because the project directory is untrusted. Unknown keys are ignored. See
`config/project-config.example`.

| Key | Effect |
| --- | --- |
| `egress = example.com, 192.0.2.10:8428` | Extra egress grants. **Approved once on the host**, because the box can write this file. |
| `share = <relpath> ...` | Mount a sibling folder **read-only** at its real path (approved on the host). |
| `share_rw = <relpath> ...` | Mount it **read-write**. Louder prompt; a separate approval from read. |
| `artifact_dirs = venv frontend/node_modules` | Extra build-output directories kept container-local, added to the default. Relative paths only. |
| `image = claude-airlock:playwright` | Use a heavier image. Must be a `claude-airlock:*` tag. |

Deliberately **not** settable here, because the box can write this file: the egress
posture, secrets, mounts, sockets, the login mode and the permission mode. Those are
host-only grants.

### Approvals

At launch you are prompted for each new `egress =` entry and each new share. Approved
entries apply silently after that. An unexpected entry, say one added by a compromised
session, prompts and is skipped unless you approve it. Approvals live in the host state
dir. Approving a read share never grants write.

Prompts are asked only of a terminal on stdin. Without one the answer is no, so piped input
cannot approve anything.

### `egress =` entries

Entries are separated by spaces **or** commas. Each may be:

- a hostname;
- a bare IPv4 address (port 443 only);
- an IPv6 literal;
- `IPv4:port`, which opens exactly that one host and port. It is the tightest form, and the
  right one for an internal datasource on a non-standard port.

These abort the launch rather than being skipped:

- **An entry that matches none of those shapes.** A grant that can never apply would leave
  the box looking configured while having no access.
- **An entry that points at this host:** loopback, pasta's `169.254.0.0/16`, slirp4netns'
  `10.0.2.0/24`, or any address on a host interface. A project file cannot grant the
  sandbox the machine it is sandboxed from, and such an entry is never even prompted for.
  The firewall refuses the same addresses inside the box, including a hostname that
  resolves to one. If you really mean it, use `AIRLOCK_EXTRA_EGRESS` in the host config.

`egress =` entries are ignored in the proxy posture (the proxy decides), but a malformed
entry or one that points at the host still stops the launch.

### Shares

Share paths are relative to `AIRLOCK_SHARE_BASE` (default `~/development`), so committed
configs never contain absolute `/home` paths. `..` and absolute paths are rejected.

Every launch re-checks each share, approved or not. A share is skipped, with no override,
when:

- any part of it below the share base is a symlink (the box can write `.airlock/config`
  and every `share_rw` directory, so an approved path could otherwise be swapped for a
  link to anywhere);
- it overlaps a protected dot-dir;
- it contains or sits inside your ssh agent socket, gpg's home or socket directory
  (located with `gpgconf`, so a custom `GNUPGHOME` counts), or a path in
  `AIRLOCK_PROTECTED_PATHS`.

A share inside one of the project's own `share_rw` folders is refused outright, since the
box could swap it.

Every check runs again just before the engine starts, and a share that changed in between
stops the launch. `-v` still resolves the path once more, so this narrows the window to
milliseconds rather than closing it. Nesting across projects (project A has `share_rw =
X`, project B has `share = X/sub`) is only narrowed this way, not refused: avoid it.

`AIRLOCK_ROOTS` entries and `airlock mount` get the same protected-location check.

## Egress posture: `airlock egress`

Host-only, per project. The box cannot change it.

```
airlock egress                  # show this project's posture (also: show, list)
airlock egress minimal          # Anthropic only (the default)
airlock egress dev              # + npm, PyPI and GitHub
airlock egress github pypi      # an explicit subset of groups (replaces the set)
airlock egress add npm          # add groups
airlock egress rm pypi          # remove groups
airlock egress proxy [SOCKET]   # no network; everything through a host proxy
```

The groups are `github`, `npm` and `pypi`. Anthropic is always on and is not a group.
`egress =` domains a project declares are added in every posture except `proxy`. Opening a
registry group widens the CDN co-tenancy gap; see
[security-model.md](security-model.md#the-allowlist-matches-ip-addresses-not-names).

The proxy posture is covered in [egress-proxy.md](egress-proxy.md).

## Secrets: `airlock secret`

```
airlock secret set KEY VALUE        # a literal value
airlock secret set KEY pass:PATH    # resolved from `pass` at launch
airlock secret list
airlock secret rm KEY
```

A secret is injected as an environment variable into this project's box. Your committed
`.mcp.json` or configs reference it by name (e.g. `${MCP_HUB_TOKEN}`). Keep injected
credentials read-only and scoped.

**Prefer `pass:PATH`** (`airlock secret set KEY pass:mcp/foo`). A literal value is stored
in plaintext in the host state dir (mode 600) and lands in your shell history when you type
it. `pass:PATH` keeps the secret encrypted at rest and resolves it only at launch, into the
mode-0600 env file, never onto the command line.

`airlock secret` refuses `AIRLOCK_*` and `*_PROXY` keys, and a launch skips any already
stored (see [egress-proxy.md](egress-proxy.md#guarantees)).

**`AIRLOCK_SECRET_DENY`** in the host config lists `pass` entries that must never reach a
box, as space-separated globs (`AIRLOCK_SECRET_DENY="github/*"`).

- `secret set` refuses a matching `pass:` entry.
- A launch whose store holds one stops before the box starts.
- Names are normalised first (`/a`, `./a` and `a//b` are the entries pass would read), but
  the match is on the name: a symlinked `.gpg` alias in the store is not caught.

Use it for credentials another tool holds on the box's behalf, such as a token a credential
proxy fronts. It is empty by default.

## Read-only host mounts: `airlock mount`

```
airlock mount add DIR
airlock mount list
airlock mount rm DIR
```

`share` only reaches folders under `AIRLOCK_SHARE_BASE`, and the box can write
`.airlock/config`, so neither can hand a box a credential that lives elsewhere. `airlock
mount add DIR` can. It is a host-only, per-project grant (stored in the host state dir,
with no `.airlock/config` key), always **read-only**, mounted at its real path.

The intended use is a scoped, short-lived credential you re-mint on the host, such as a
read-only kubeconfig whose `tokenFile` sits in the same directory:

```
airlock mount add ~/.kube-ro
airlock secret set KUBECONFIG /home/alice/.kube-ro/config
```

The whole directory is mounted, not the file, so a token replaced on the host with `mv` is
visible to a running box on its next read. No relaunch when it expires.

Refused, with **no override**, at `add` and again at every launch:

- anything that is not an existing directory under `$HOME` once symlinks are resolved;
- `$HOME` itself;
- anything inside a credential directory (`~/.ssh`, `~/.gnupg`, `~/.kube`,
  `~/.config/sops`, `~/.password-store`, `~/.claude`, `~/.config/claude-airlock`, keyrings,
  cloud CLIs, ...) or an ancestor of one (so `~/.config` is refused);
- a directory not owned by you, or writable by group or others;
- a directory holding a hard-linked file (a hard link to a key is the same inode, so a
  mount would expose it);
- a directory with a mount point inside it (the bind is recursive, and the hard-link scan
  cannot see across a filesystem boundary);
- the workspace;
- a protected location (as for shares).

At launch, an approved path that now resolves somewhere else is skipped too. Skipping only
removes access, so it warns rather than aborts.

The deny list is a guard against habit, not an inventory of where credentials live. So
`mount add` also prints every file the box will be able to read. Read that list: it is the
grant.

Never mount a container engine socket this way (see
[security-model.md](security-model.md#no-container-api-socket)).

## Host sockets: `airlock socket`

```
airlock socket add SOCKET
airlock socket list
airlock socket rm SOCKET
```

`airlock socket add SOCKET` bind-mounts one host Unix socket into this project's box, at
its real path. Like `mount` it is host-only: stored in the host state dir, with no
`.airlock/config` key. The intended use is a proxy that holds a credential outside the box
and injects it into requests, such as
[airlock-cred-proxy](https://github.com/appletalk/airlock-cred-proxy), so the box can use
GitHub without ever holding a token.

**A socket is a capability, not data.** The owner rule below tells a service account from
a person, not a safe service from a dangerous one. Grant a socket only if you would let
the box do everything that service allows.

### The box connects as you

With rootless podman, keep-id maps the box user to your uid, and your supplementary groups
do not survive the user namespace. So a socket restricted to a group you are in is still
refused inside the box. Grant your uid instead, for example with `setfacl -m u:$USER:rw
SOCKET`. Do that in the service's unit (an `ExecStartPost=` on a systemd `.socket` unit),
not by hand: the ACL is lost whenever the socket is recreated. (Under Docker the box
connects as uid 1000.)

### The socket rule

Checked with **no override** at `add` and again at every launch:

- The socket is owned by a dedicated service account: not you, not root, not `nobody`, and
  below `UID_MIN` in `/etc/login.defs`.
- Every directory from the socket up to `/` is owned by root and writable by nobody else.
  A directory above the socket's own may be world-writable only if it is sticky, like
  `/tmp`.
- The socket is on tmpfs, ext4, xfs or btrfs. A FUSE filesystem can report any owner.
- The path has no `:`, `,` or control characters, and is not on a deny list of well-known
  sockets (a second layer).

So put the socket in a root-owned directory (a systemd `.socket` unit does this), not in a
`RuntimeDirectory=` owned by the service user. Services run with systemd `DynamicUser=` get
uids above `UID_MIN`, so their sockets cannot be granted; give such a service a static
system user instead.

Why an owner rule and not a list of bad paths: the sockets that hand over the host (your
session bus and systemd manager, SSH and gpg agents, `screen` and `tmux`, credential
caches, WSL's Windows interop, libvirt, snapd) are owned by you or by root. WSL also exposes
the same files under several paths (`/mnt/wslg/...`), which no path list can keep up with.
Root-owned directories also mean nothing running as you, the box included, can swap the
socket after approval.

The socket's device, inode, change time, owner and mode are checked again immediately
before the engine starts. If any changed, the launch stops. An idempotent `chmod` during
the launch (a config-management run, say) also changes the change time; just retry such a
launch. This re-check sees the host's view. Rootless podman resolves the path in its own
mount namespace, which the box cannot reach, so the check guards against the box, not
against another process running as you.

### One file, not its directory

Only the socket file is mounted, so a second socket beside it is not exposed. If the
service's socket is recreated (restarting a systemd `.socket` unit does this; restarting
only the service does not), relaunch the box to pick up the new one.

## Starting permission mode: `airlock mode`

```
airlock mode                # show (also: show)
airlock mode auto           # set: acceptEdits, auto, bypassPermissions, manual, dontAsk, plan
airlock mode reset          # unset; Claude uses its own default
```

Sets the permission mode this project's box *starts* in, passed through as `claude
--permission-mode`. Shift-Tab still switches modes in a session. It is per project and
host-only: a box that could raise its own permission mode would choose how much it gets
asked.

Precedence, most specific first: `--permission-mode` on the command line, then
`AIRLOCK_PERMISSION_MODE` in the environment (one launch only), then the stored `airlock
mode`. The mode is not added when you run a `claude` subcommand (a first word that is not
a flag). An invalid stored value is ignored with a warning.
