# Security model

How claude-airlock contains a box, what it does not contain, and how to harden the host
around it. To report a weakness, see [SECURITY.md](../SECURITY.md).

## Threat model

Assume the agent may misbehave: a prompt injection, a bad tool call. The goal is to bound
the blast radius.

| Class | What it is | Does airlock contain it? |
| --- | --- | --- |
| **A: escape and exfiltration** | The agent reaching the network beyond a small allowlist, touching other projects, or gaining privilege | **Yes.** This is what the container and firewall are for. |
| **B: destructive but authorized actions** | `terraform destroy`, a bad commit, a force-push, done with a credential the box holds | **No.** Isolation is the wrong tool. Keep write credentials out of the box (read-only or CI-scoped), use branch protection, review pushes by hand. |
| **Influence** | Files and memories the box writes that the unsandboxed host later runs or reads | **No.** See [Known limitations](#known-limitations). |

The container and firewall are the moat. The launcher only assembles the engine command
line and manages host-side grants the box cannot tamper with.

In short: run untrusted code in the box, keep real credentials scoped and out of it, and
review what the box wrote before the host acts on it.

## What the box enforces

### Egress: minimal by default

- Only Anthropic is reachable by default (Claude cannot run without it).
- npm, PyPI and GitHub are opt-in *groups* (`airlock egress dev`, or a subset). Other
  domains are per project and approved on the host.
- An in-container iptables/ipset firewall enforces this, default-DROP, on **both IPv4 and
  IPv6**. One unfiltered address family would be a total bypass, so a box with a global
  IPv6 address it cannot filter refuses to start.
- Or take the network away entirely with `airlock egress proxy`: the box has loopback
  only and reaches out through one host proxy socket, whose allowlist decides by name. An
  SNI-aware proxy closes the CDN gap below. See [egress-proxy.md](egress-proxy.md).

### The allowlist matches IP addresses, not names

The firewall resolves each allowed domain to its IPs and permits TCP/443 to those IPs. It
does not, and at that layer cannot, inspect the TLS SNI. So **any** site that resolves to
an IP already on the allowlist is reachable, approved or not.

This matters most when you open a registry group. npm and PyPI sit behind large shared
CDNs, so `airlock egress dev` in effect allows a slice of that CDN's address space, and an
agent can reach an attacker's service hosted on the same edge IP. Treat an enabled
registry group as a broad, if legitimate-looking, exfiltration surface.

- Prefer keeping projects `minimal` and adding narrow `egress =` domains over turning on
  the whole `dev` group.
- Closing the gap fully needs an SNI-aware filtering proxy, such as the proxy posture
  above.

### DNS is pinned, which narrows exfiltration but does not close it

DNS goes only to the box's configured resolvers, not to any server on the internet. The
agent cannot point queries at a server it chooses (`dig @attacker-ns ...`). It can still
tunnel data as query *names* through your legitimate resolver to a hostile authoritative
server. No resolver allowlist can prevent that. Treat DNS as a low-bandwidth channel that
stays open.

"Configured" means configured by the *host*. When the host's only resolver is loopback,
podman and docker add Google Public DNS as a fallback. So the launcher points podman boxes
at the network stack's forwarder to your host resolver (`--dns`), and the firewall never
pins a public resolver the host itself does not list. `AIRLOCK_DNS` overrides both (see
`lib/host-dns.sh`).

The box's own `CLAUDE_CODE_OAUTH_TOKEN` is in scope for this channel: a compromised box
can read its token and drip it out over DNS. If you believe a box was compromised, rotate
the token (`command claude setup-token` again, then save it again). The token grants
subscription API access, not host or billing access, so the blast radius is bounded.

### Grants live on the host, out of the box's reach

Secrets, share approvals and the egress posture live in a per-project state directory that
is **never mounted into the box**. A compromised session can *request* more through the
box-writable `.airlock/config`, but cannot approve it. Approving a read share never grants
write, and widening anything always prompts on the host.

### Least-privilege container

- All Linux capabilities are dropped except the few the firewall and privilege drop need.
- The agent runs as the non-root user `dev`, with `--security-opt=no-new-privileges`.
- A process-count cap (`AIRLOCK_PIDS_LIMIT`, default 4096) guards against a fork bomb.
- An optional RAM ceiling (`AIRLOCK_MEMORY`) can be set per host.

### No new namespaces (seccomp)

The box runs under `image/seccomp.json`: the engine's default profile, with `unshare`,
`setns` and any `clone` that carries a namespace flag refused. `clone3` answers ENOSYS so
libc falls back to the filtered `clone`.

Why: with the default profile the agent could `unshare -Ur` and hold a full capability set
as root inside a nested user namespace. That is the precondition for most
container-to-host kernel exploits.

Nothing the box runs needs a new namespace (checked):

- Claude Code's own Bash sandbox (bubblewrap) is opt-in, not in the image, and falls back
  to unsandboxed with a warning.
- Chromium runs with `--no-sandbox`.
- git, node, python, pwsh, kubectl, the validators and Postgres are unaffected.

The profile also closes kernel interfaces nothing in the box uses:

- Keyrings (`keyctl`, `add_key`, `request_key`) and `memfd_secret` answer ENOSYS.
- `socket` accepts only unix, inet, inet6 and netlink, each matched by exact value (so a
  family with high bits set does not slip past). `socketpair` accepts only unix. `AF_ALG`
  (the kernel crypto API), `AF_VSOCK`, `AF_PACKET` and the rest answer ENOSYS.
- On x86_64 (the only architecture this is checked on), i386 and x32 syscalls kill the
  process. `socketcall` hides its arguments from seccomp, and the compat layer is attack
  surface of its own.

`airlock doctor` and the image smoke test run under the same profile, and the smoke test
checks each of these by behaviour, as `dev`.

### The host is not on the box's network

Under pasta the launcher passes `--map-guest-addr none`, so `169.254.1.2`
(`host.containers.internal`) reaches nothing. Podman already declines to map the gateway
address and forwards no ports. Host loopback services were never reachable. This is a
layer *under* the firewall: the box has no route to the host even if its own rules are
wrong.

### No host credentials unless you mount them

- Auth is an OAuth token. The host's `~/.claude` credentials, the container engine socket
  and other projects are never exposed.
- The one way a host credential gets in is `airlock mount add`: read-only, guarded, and
  listed when you grant it (see [configuration.md](configuration.md#read-only-host-mounts-airlock-mount)).
- The token and injected secrets reach the engine through a mode-0600 `--env-file`, removed
  on exit, **not** as `-e KEY=VALUE`. So they do not sit in the host process table (`ps
  auxe`, `/proc/<pid>/cmdline`) for the life of the container.

### The box's `~/.claude.json` is seeded by allowlist

A new project gets the theme and a few UI preferences from your host file, nothing else.
Not the account profile, not the host install's `userID` / `machineID` (Claude generates
fresh ones per box), and not `githubRepoPaths`, the map of every other repo on the machine.

Projects created before the allowlist are cleaned at launch:

- the repo map, always;
- the install identifiers, only while they still equal the host's, so identifiers a box
  generated for itself are never churned.

The account profile is left alone in an existing file. A login done inside the box writes
one that can be identical to the host's, and removing email and org IDs the box can learn
from its token anyway is not worth risking a box's login.

### A private CA chain stays out of Claude's own TLS

An optional private CA chain ([images.md](images.md#corporate-or-internal-ca-certificates))
is trusted by *external tooling* (curl, git, Python) only. It is never added to Node's
trust, so Claude's own TLS to `api.anthropic.com` stays on its vetted built-in roots.

## Known limitations

### Files a box writes can run on the host

The firewall contains the *network*. It does nothing about files.

Your project is mounted **read-write at its real path**, because the box does real work.
So the box can write any file the host will later run **itself, unsandboxed, with your
real credentials**. Three of them run **with no build step and without asking** (verified
on the host, not inferred):

- **`.git/config`.** `core.fsmonitor` runs on every host `git status`; `core.pager` on
  anything that pages; `core.hooksPath`, `core.sshCommand` (next fetch or push),
  `diff.external`, `filter.*` and `alias.*` likewise. Git cannot ignore a repo's own
  config, and its ownership check does not fire because keep-id makes the files yours.
  `.git/hooks/*` is the same channel, narrower: commit, push and merge only.
- **`.claude/settings.json` and `.claude/settings.local.json`.** Hooks in them run when
  you next open host `claude` in the repo, with no approval dialog. **`.mcp.json`** is the
  same: the host launches whatever server binary it names. **`CLAUDE.md`** is the
  no-execution variant: instructions the host agent follows.
- **Everything that runs when you build or enter the tree:** `Makefile`, `package.json`
  scripts, `pyproject.toml` / `setup.py`, `conftest.py`, `.vscode/tasks.json`, pre-commit
  configs, `node_modules/.bin` shims, and `.envrc` once you `direnv allow` it again (direnv
  refuses a changed file until you do; the risk is the reflexive re-allow).

None of these touch the network, so containment never sees them. A writable workspace is
the product, so beyond the git binds below there is no mechanism for this. It is a rule:

- **Treat a repo a box has worked in like a PR from a stranger.** Before you run host
  `git`, host `claude` or a build in that tree, read the diff. Also read `.git/config` and
  `.claude/`, since `git diff` does not show them.
- **Run untrusted code in the box**, and keep host tooling out of that tree until you have
  reviewed it.

#### Git config and hooks are read-only in the box

`AIRLOCK_GIT_RO=1` (the default; `0` turns it off) makes **every config file host git
reads for a repo in a read-write root read-only in the box.** That covers everything a
config can name: `credential.helper`, `core.editor`, `core.fsmonitor`, `diff.external`,
filter and merge drivers, `remote.*.uploadpack`, aliases, hooks.

In the workspace and every `share_rw`, these are read-only:

- `.git/config`, and its includes that lie in a read-write root (followed by hand, 10
  deep);
- `config.worktree`, for the repo and each worktree, when `extensions.worktreeConfig` is
  on;
- `commondir`: created as `.` where git would look for one, so a box cannot add one that
  points git at a config it wrote;
- the `.git` pointer files of in-root linked worktrees and submodule checkouts, and the
  configs of submodule gitdirs, nested ones included;
- the hooks, an in-root `core.hooksPath` (resolved per worktree), and the in-root target
  of a hook that is a symlink.

How it holds:

- Each git directory is bound onto itself, so it cannot be renamed away and replaced.
- The checks run on canonical paths and the binds land where the box sees them, so a
  symlinked parent or share base changes nothing.
- A symlink, a hard link, an unreadable git directory, or a `commondir` pointing elsewhere
  stops the launch: a box may have planted it.
- Config is read hermetically (no repository discovery, no system or global config), and a
  read error refuses rather than reading as empty.
- Linked worktrees must check out: each `worktrees/*/commondir` has to lead back to the
  repo, and each `gitdir` file has to name a `.git` file that points back to it.
- A bare repo shared read-write is guarded as a git directory.
- A hook symlink whose target does not exist yet in a read-write root refuses (the box
  could create it).

**What binding does not close, so also neutralise git on the host.** While a box runs it
can create a repo that host git then enters: a `.git` file or directory in a submodule
path (upstream's or one it adds, populated or not), a new submodule, a new worktree. That
repo's config is the box's, so hooks, `core.fsmonitor`, and filter and diff drivers in it
can all run on a plain host `git status` or `diff`. (The next launch guards whatever exists
by then.) Also not covered:

- paused rebase, `am` and cherry-pick state, which can hold `exec` lines that `--continue`
  runs;
- hook managers (husky, pre-commit, lefthook), which read tracked files;
- global or system config that points into a share;
- independent repos nested in the workspace.

Host environment config outranks every config file. Set this in your shell (child
processes inherit it) to keep host git out of submodules and hooks:

```
GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
GIT_CONFIG_KEY_1=core.fsmonitor GIT_CONFIG_VALUE_1=false
GIT_CONFIG_KEY_2=diff.ignoreSubmodules GIT_CONFIG_VALUE_2=all
```

Then run a repo's hooks by hand when you want them, look into submodules with explicit
`git -C <sub>` commands, and abort (do not continue) a rebase or `am` a box left paused.

**What it costs in the box.** Commit, branch, checkout, stash, rebase, `gc` and new
worktrees work. Anything that writes config fails, sometimes after doing half its work:

- `remote add`, `branch --set-upstream` / `push -u`;
- `switch -c x origin/x` (the branch is made, its tracking is not);
- `branch -D` (the branch is deleted, then a config error);
- `submodule add` and `submodule update` (even a no-op on an initialised submodule);
- `config --worktree`, `maintenance register`.

Also:

- Removing or pruning a worktree that existed at launch fails on its bound gitdir.
- Edit a tracked hooks directory on the host.
- An include that goes through a symlink into a read-write root refuses the launch: point
  it at the real path.
- With a workspace reached through a symlinked path, in-root worktrees do not work in the
  box (git records the real path, which the box does not see).

Still open after all this: `.claude/`, `.mcp.json`, `.envrc`, build scripts, and any script
you later run by hand. Review a touched repo before host tooling runs in it.

### Shared memory is an influence channel

The egress firewall **cannot see this and will not stop it.**

The project's `~/.claude/projects/<slug>/` is mounted **read-write** into the box, so
sessions and memories flow both ways. That is what makes `--resume` and saved memories
work on both sides. The directory contains `memory/`, and host Claude **loads those files
into its context every session, unprompted.**

So a compromised box can write a memory file that the **unsandboxed host agent** later
reads and acts on, with your real credentials and no firewall. Nothing touches the
network; the box just writes a file you have already told the host to trust. Containment
holds against escape and exfiltration (Class A). This is a different thing: influence.

Read-write is still the default, on purpose. The box is meant to be the primary workspace;
read-only memory would mean the agent can never save a memory where you actually work, and
the feature would quietly die. Tighten it when the code is untrusted:

| `AIRLOCK_SHARE_MEMORY` | Behaviour |
| --- | --- |
| `rw` *(default)* | Box reads **and writes** host memories. Convenient; channel open. |
| `ro` | Box reads host memories, cannot author them. **Closes the memory channel.** |
| `off` | Box neither reads nor writes them; it gets empty container-local storage. |

Transcripts stay read-write in every mode: a box that cannot write its transcript cannot
hold a session. Set `AIRLOCK_SHARE_HISTORY=0` to share nothing.

**Symlinks are refused.** Host Claude follows symlinks when it loads this directory. A box
that turned `memory/MEMORY.md` into a link to `~/.ssh/id_ed25519` would have the key read
into the host's context and written back into the shared transcript, where the next box
reads it: exfiltration with no network involved. So both the launcher and the host
`claude` wrapper refuse to start while any symlink exists under
`~/.claude/projects/<slug>/`, and name it. They never delete it: a link there is either an
attack you need to know about or something you did on purpose.

## Host hardening for rootless Podman (optional, recommended)

The box cannot exceed your own user's authority, so a container escape lands as *you*, not
root. Hardening the host does three things: it makes an escape harder (less kernel attack
surface), makes an escape worth less (less that your user can reach), and keeps the
runtime patched. None of this is required for airlock to work, and none of it relaxes
anything airlock does inside the box.

### Kernel sysctls

A drop-in such as `/etc/sysctl.d/60-hardening.conf`:

```ini
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 2
# optional, see below
kernel.io_uring_disabled = 2
```

Apply with `sudo sysctl --system`, then run `airlock doctor` again. Trade-offs:

- `ptrace_scope = 2` also stops `strace -p` / `gdb -p` without sudo, on the host and in
  every box.
- `io_uring_disabled = 2` is belt and braces: the box's seccomp profile already refuses
  `io_uring_setup`, and this extends that to every process on the host. It breaks the few
  host programs that need io_uring. `1` limits io_uring to the `kernel.io_uring_group`
  group instead.

### Leave unprivileged user namespaces on

Rootless Podman *is* a user namespace, so `kernel.unprivileged_userns_clone = 0` or
`user.max_user_namespaces = 0` disables airlock altogether. The risky part, a process
creating a *nested* namespace to get a full capability set, is already refused inside the
box by `image/seccomp.json`.

### Keep the runtime patched

Almost every container escape is a bug in the kernel, the OCI runtime (`crun`/`runc`),
`conmon`, or the network helper (`pasta`/`passt`). Update them with the rest of the
system, reboot for kernel updates, then run `airlock doctor`, which proves the firewall
still holds on the new kernel. `make install-airlock` rebuilds the images, so the userland
inside the box stays current too.

### Set a memory ceiling

Check that your user's systemd instance delegates the cgroup controllers (systemd does
this by default on cgroup v2):

```sh
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers
# expect at least: memory pids
```

Then set `AIRLOCK_MEMORY` in `~/.config/claude-airlock/config` to a generous cap, for
example about a third of host RAM. The pids cap is on by default. Without a memory cap, a
runaway build or a compromised agent can push the whole host into swap or the OOM killer.

### No container API socket

Stay out of the `docker` group (it is root-equivalent; see
[Why rootless Podman](../README.md#why-rootless-podman)), and leave the rootless
`podman.socket` user unit disabled unless something needs it (`systemctl --user
is-enabled podman.socket`). Airlock never mounts either socket. Do not add one with
`airlock mount`: a box holding the socket can start a sibling container without any of
airlock's restrictions.

### Make an escape worth less

An escape runs as you, so anything your user can read without a prompt is in reach:
`~/.ssh`, `~/.gnupg`, cloud and cluster credentials, browser profiles. The controls that
help are the ones that need a human at each use:

- SSH keys on a hardware token, or passphrase-protected with agent confirmation
  (`ssh-add -c`);
- secrets in `pass`/gpg behind an agent with a short cache;
- admin credentials that step up interactively (OIDC with WebAuthn, not a static token in a
  config file);
- **no `NOPASSWD` sudo**, which turns an escape as you into root.

### Bind host services to loopback

A box cannot reach host loopback, and under pasta the launcher removes the host mapping
(`--map-guest-addr none`). A development server listening on `0.0.0.0` is still reachable
at your LAN address by anything the box's firewall lets through. Give local services
`127.0.0.1` unless they need the LAN.

### LSMs: don't add one just for airlock

The confinement a default container profile gives (no mounts, no ptrace, no `/proc/sys`
writes) is already enforced by the dropped capabilities, seccomp and the user namespace.
Enabling AppArmor or SELinux for airlock alone buys little. Airlock is developed and tested
on hosts without an enforcing LSM. On an SELinux-enforcing host the launcher does not
relabel its bind mounts (no `:z`), so expect denials on the workspace; that combination is
untested.
