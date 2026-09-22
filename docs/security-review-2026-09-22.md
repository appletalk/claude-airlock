# Security review — claude-airlock (2026-09-22)

*Scope: everything in the repo at `6430250`, with the closest look at `ce7e94f` (airlock
mount), `9853d3b` (DNS pinning) and `4afb4c8` (infra clients). Method: code reading, plus
live tests against the real `claude-airlock:base` / `:dev` images on titan (podman 6.1.2,
pasta 2026_07_28, runc 1.5.1, kernel 7.2.6-arch2-1, rootless, cgroup v2), and the launcher
driven through its bats stubs. Report only; nothing was fixed. No host config was changed,
`~/.config/claude-airlock` was not written, and no containers were left running (the one
box that was up throughout, `vigorous_ganguly`, is your own `claude --resume` session on
`kubernetes-glz-migration` and was not touched).*

*Not done: I did not read `~/.claude.json` or `~/.kube-claude/config` (the read was
declined), so "what the seeded claude.json leaks into the box" and "what the read-only
kube token can actually do" are listed as checks for you rather than findings. One side
effect to know about: the host-Claude test in F1/F2 ran `claude -p` once in a throwaway
project under `/tmp`; its `~/.claude/projects/` entry was removed, but `~/.claude.json`
may still carry a `projects` key for that path.*

Severity is what an adversarial box gains. Effort is what a fix costs: **T** under an hour,
**S** half a day, **M** one to three days, **L** a week or more.

## Summary

The moat holds where the docs say it holds. From the `dev` user in a live box: no
capabilities, `no-new-privileges`, podman's default seccomp, root unreachable (`su`,
`gosu`, setuid binaries all fail), iptables unreadable, every non-allowlisted TCP
destination rejected on both families, DNS only to pasta's forwarder, ICMP impossible
(no `ping` binary, no `NET_RAW`, `ping_group_range` is `0 0`), the host's loopback
services unreachable, `example.com` blocked over v4 and v6 while `api.anthropic.com`
answers over both. I found no network escape and no privilege gain.

What I did find is that the **file-side channels are wider than documented and one of
them is a full read-back path**:

1. Host Claude Code follows a symlink at `memory/MEMORY.md`. A box with the default
   `AIRLOCK_SHARE_MEMORY=rw` can point that symlink at any file your user can read, the
   host loads it into context on its next session, and the host's transcript, which is
   mounted read-write into the box, carries the content back. That is exfiltration of
   arbitrary host files with no network involved. Proven live (F1).
2. Host Claude Code runs hooks from the project's `.claude/settings.json` with no prompt,
   and the project is mounted read-write. A box can plant a `SessionStart` hook that
   runs on the host the next time you open `claude` there. Proven live (F2).
3. `.git/config` is box-writable and `core.fsmonitor` runs on the host on a plain
   `git status`. The README only lists `.git/hooks` and commit/push/merge. Proven (F3).

On the network side the interesting results are that pasta already passes `--no-map-gw`,
that `--map-guest-addr none` is a cheap and working second layer for the host mapping
(F8), that nested user namespaces are available to the agent (F6), and that TCP DNS to
`169.254.1.1` works fine here, so the first-launch observation did not reproduce (§5.3).

The image side has one real problem: `make install` does not refresh anything below the
Claude Code layer. The apt layer in your `:base` dates from 2026-07-13, the local
`debian:trixie-slim` is the 2026-06-23 build while the registry serves 2026-09-18, and a
box built an hour ago has 37 upgradable packages, 17 of them from `stable-security`
(openssl, bind9, util-linux, jq). SECURITY.md's "rebuild to pick up security updates" is
not true as written (F5).

The design question you flagged (IP-based egress, shared Traefik VIP) is real and the
only complete answer is a name-aware egress point. A CONNECT proxy inside the box, with
an `-m owner` rule so only the proxy's uid may open port 443, closes the VIP problem, the
CDN co-tenancy problem **and** the DNS exfiltration channel at once, because the box then
needs no DNS at all. It is the largest item here (L) and the one with the most value (§9).

## 1. Threat model versus reality

### 1.1 Claim-by-claim

| Claim (README / SECURITY.md) | Verdict | Evidence / note |
|---|---|---|
| Default-DROP egress on both families; refuses to start with unfilterable v6 | **Holds** | Live box on a host with global v6: `example.com blocked (IPv4)`, `(IPv6)`, `api.anthropic.com` reachable over v6. `curl -6 https://example.com` fails, `curl -6 https://api.anthropic.com` 404. |
| Allowlist matches IPs, inherits CDN co-tenancy | **Holds, understated** | The text says "CDN". Your live case is an internal shared ingress VIP (10.44.0.10), which is the same problem with a worse blast radius: every internal service behind that VIP, not just co-tenants on an edge. Say "any shared IP: CDN edge, reverse proxy, ingress VIP, load balancer". |
| DNS pinned to configured resolvers; names still tunnel data | **Holds** | `dig @8.8.8.8` → `host unreachable`; UDP and TCP to `169.254.1.1` answer. Honest wording. |
| The OAuth token is in scope for DNS exfil; rotate if compromised | **Holds** | `env` in the box shows `CLAUDE_CODE_OAUTH_TOKEN`. Any allowed 443 destination that shares an IP is a far faster channel than DNS; say so. |
| Grants live host-side, box cannot approve | **Holds** | `.airlock/config` has no mount key (bats: `a project .airlock/config cannot request a mount` passes); state dir never mounted (checked the real `podman run` argv of your live box). |
| Least privilege: no caps, non-root, NNP | **Holds** | `CapEff 0`, `NoNewPrivs 1`, `Seccomp 2`. `CapBnd` still holds the four granted caps but nothing can re-acquire them under NNP. |
| No mounted credentials | **Stale** | True until `ce7e94f`. `airlock mount` is documented, but this bullet should now read "no *host* credentials except what `airlock mount` grants". |
| Secrets stay off the process table | **Holds** | `--env-file` at mode 0600 (bats hardening tests). |
| "Files the box writes … git hooks, `.envrc`, Makefile …" | **Incomplete** | Missing the three that run *automatically* with no build step: `.claude/settings.json` hooks, `.mcp.json`, `.git/config` (`core.fsmonitor`, `core.pager`, `core.hooksPath`, `core.sshCommand`, `diff.external`, filters). See F2, F3. |
| `.envrc` runs "the next time you cd in" | **Overstated** | direnv refuses a changed `.envrc` until `direnv allow`; the risk is the reflexive re-allow. direnv is not installed on titan. |
| `AIRLOCK_SHARE_MEMORY=ro` "closes the channel" | **Overstated** | It closes memory *authoring*. Transcripts remain rw (a box can forge prior turns a host `--resume` will trust), the workspace channels above remain, and in `rw` mode the symlink read-back (F1) is open. |
| Transcripts read-write "in every mode" | **Holds, under-explained** | Say what that means: a box can rewrite the conversation the host resumes. |
| "The box cannot exceed your unprivileged user's authority" | **Holds** | Correct, and worth keeping. Add that this authority includes `~/.ssh`, `~/.gnupg`, the docker socket if you are in `docker` (you are not), etc. so an escape is still total for you. |
| Rootless Podman is the default engine | **Holds** | `podman info` rootless=true, no daemon; your user is not in `docker` even though dockerd exists. |
| "Rebuild the images (`make install`) after pulling to pick up base-image and toolchain security updates" (SECURITY.md) | **False as written** | See F5. Only the Claude Code layer is cache-busted. |

### 1.2 The six named channels, honestly

**Shared memory directory.** Documented, with the right framing (influence, not exfil).
It is worse than documented: with `rw`, a symlink in `memory/` makes the host read any
file (F1). The docs should say "read-write memory also lets the box choose *which host
files* the host agent reads and then see the result", and the `ro` default should be
reconsidered or paired with the pre-launch symlink check in F1.

**Session transcripts.** Documented as rw in every mode. The docs do not say that this is
an influence channel of its own (forged turns) or that it is the *return path* for F1.
Proposed wording is in F1/F4.

**DNS query names.** Documented accurately. Bandwidth note: TCP DNS to the forwarder
works, so neither queries nor responses are limited to 512 bytes. Only the CONNECT-proxy
design (§9) actually closes it.

**OAuth token.** Documented accurately (readable, reusable from anywhere, subscription
scope, rotate on suspicion). The `persist` mode bounds the blast radius to one project and
the docs say so. What is missing: the token is a one-year credential and there is no
rotation cadence; and a root-held credential proxy (F13) would keep it out of `dev`'s
reach entirely.

**Egress by IP.** Documented for CDNs, not for internal shared VIPs. Your titan case is
the cleaner example and should be the one in the README. Design answer in §9.

**Writable shared repos.** Documented for hooks/envrc/build files. Missing `.git/config`,
`.claude/settings.json`, `.mcp.json`, `CLAUDE.md` (prompt injection into the host session
with no execution needed). Your live box has `share_rw` on five infrastructure repos
(`glz.ca/k8s`, `infrastructure`, `dns-zones`, `opnsense`, `titan`), which is the largest
Class-B surface on this host; nothing in airlock can bound it, only credential scoping
and review.

Proposed README replacement for the "Known limitation" pair is in §10.

## 2. Findings

### F1. Symlinked memory: a box can make host Claude read any host file, and read the result back — **High**, effort **S**

**What.** `~/.claude/projects/<slug>/` is bind-mounted rw. The box can replace
`memory/MEMORY.md` (or any memory file) with a symlink to a path outside the mount. Host
Claude Code follows it. The host's transcript for that session is written into the same
project directory, which the next box reads.

**Evidence.**
```
$ ln -sfn "$W/ev/canary.md" ~/.claude/projects/<throwaway-slug>/memory/MEMORY.md
$ claude -p --model haiku --max-turns 1 'Quote verbatim the first line of the memory index ...'
CANARY-MEMORY-7731: this line lives OUTSIDE the memory dir, at /tmp/claude-1000/airlock-review.Muwr/ev/canary.md
```
(Run on the host, Claude Code 2.1.278, throwaway project under `/tmp`, cleaned up
afterwards.) Symlink creation from inside a box needs nothing special: the mount is rw
and `ln -s` is a plain file operation; the launcher never inspects the directory.

**Cost of fixing.**
- `AIRLOCK_SHARE_MEMORY=ro` as the default: closes F1 and the memory influence channel;
  cost is that box sessions cannot save memories (the trade-off already discussed in
  the README). A read-only bind mount refuses symlink creation and cannot be replaced
  from inside.
- Keep `rw` but have the host `claude` wrapper (and the launcher, before mounting) run
  `find ~/.claude/projects/<slug> -type l` and refuse to start, or unlink, if anything is
  a symlink. T to implement, no functional cost, closes the read-back for memory *and*
  any other file Claude Code may read from that directory. Recommended either way.

### F2. Host Claude Code executes project-settings hooks the box can write, with no prompt — **High**, effort **S** (docs T)

**Evidence.**
```
$ cat .claude/settings.json
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"touch $W/ev/hook-canary"}]}]}}
$ claude -p --model haiku ...       # on the host
$ ls -la ev/hook-canary
-rw-r--r-- 1 keith keith 0 Sep 22 06:53 ev/hook-canary
```
No approval dialog; `-p` mode. `.mcp.json` is the same class (host launches the server
binary), and `CLAUDE.md` is the no-execution variant (instructions the host follows).

**Cost of fixing.** Cannot be closed while the workspace is rw and the host also uses
Claude there; that is the product. Mitigations, cheapest first: document it next to the
memory warning; have the host `claude` wrapper hash `.claude/settings*.json`, `.mcp.json`,
`CLAUDE.md`, `.git/config` at box exit (store in `STATE_DIR`) and warn on the next host
launch if they changed; consider the same for `.git/hooks`. S. No functional cost beyond a
warning you can dismiss.

### F3. `.git/config` runs box-chosen commands on the host on `git status` — **Medium**, effort **T** (docs)

**Evidence.**
```
$ git config core.fsmonitor "$W/ev/fsmon.sh"     # what a box can do to a mounted repo
$ git status >/dev/null                            # on the host
$ ls ev/git-canary
ev/git-canary
```
Other keys with the same effect: `core.pager` (any output command), `core.hooksPath`,
`core.sshCommand` (next fetch/push), `diff.external`, `filter.*.smudge/clean`,
`alias.*`. Git offers no way to ignore repo-local config; the ownership check
(`safe.directory`) does not fire because keep-id makes the files yours.

**Cost.** Documentation only, plus include `.git/config` in the F2 change-detection list.

### F4. Transcripts are a forgeable influence channel and the return path for F1 — **Medium**, effort **T** (docs)

The box can append or rewrite turns in `<session>.jsonl`; a host `--resume` presents
them as history. Nothing to fix cheaply (transcripts must be rw), but the docs should
say this is what "rw in every mode" costs, and that `ro` memory does not close it.

### F5. Images do not get security updates from `make install` — **Medium**, effort **S**

**Evidence.**
```
$ podman history claude-airlock:base       # built "46 minutes ago"
2026-09-22T05:46  234MB  curl -fsSL https://claude.ai/install.sh | bash      <- CLAUDE_CODE_VERSION busts this
2026-09-22T05:37  ...    COPY firewall.conf / init-firewall.sh
2026-07-13T12:01  231MB  apt-get update && apt-get install ...               <- cached since July
$ podman image inspect debian:trixie-slim --format '{{.Created}}'   -> 2026-06-23
$ skopeo inspect docker://debian:trixie-slim | jq .Created           -> 2026-09-18
$ (inside a throwaway box) apt-get update && apt list --upgradable | wc -l
37     # 17 from stable-security: openssl 3.5.6->3.5.7, bind9 9.20.23->9.20.29, util-linux, jq, ...
```
`podman build` never re-pulls a base tag it already has and never re-runs an unchanged
`RUN`. The dependency-bump commits (2026-08-09, 08-31, 09-09) bump *pinned upstream
binaries*, which is the one layer that already floats correctly; the Debian layer is the
one nobody bumps.

**Fix.** In `bin/install.sh`: `build --pull` and a `--build-arg APT_DATE=$(date +%F)`
consumed before the apt `RUN` (or `apt-get upgrade -y` in a final layer, which makes
"rebuild = patched" true regardless of cache). Add `make refresh` and a note in SECURITY.md
with a cadence (weekly is fine for a stable base; trixie security uploads are frequent but
small). Functional cost: a full rebuild takes minutes and a larger download; validators are
pinned so nothing else moves. Recommend against digest-pinning `FROM`: it gives
reproducibility but freezes CVEs, and you would then need Renovate to bump it. A moving
tag plus `--pull` plus a cadence is the right shape for "stay on stable".

### F6. Nested user namespaces are available to the agent — **Medium**, effort **S**

**Evidence** (as `dev`, firewall up):
```
$ unshare -Ur id
uid=0(root) gid=0(root) groups=0(root)
CapEff: 000001ffffffffff
$ unshare -Ur unshare -m sh -c 'mount -t tmpfs none /mnt && echo ok'   -> tmpfs-mounted-in-nested-ns
$ unshare -Urn curl https://example.com/                                  -> Could not resolve host (empty netns, no bypass)
```
Podman's default profile allows `unshare`, `clone`, `clone3` unconditionally
(`/usr/share/containers/seccomp.json`). This is not an escape: the nested netns is empty,
the firewall is in the outer one. It is kernel attack surface: most container-to-host
kernel bugs of the last years needed exactly a user namespace with a full cap set
(netfilter, overlayfs, io_uring, keyrings). Everything else I probed is already closed:
`io_uring_setup` ENOSYS (seccomp), `bpf` EPERM (`unprivileged_bpf_disabled=1`),
`ptrace` EPERM (`ptrace_scope=2`, and no `CAP_SYS_PTRACE`), `add_key` EINVAL-only.

**Fix.** Ship `image/seccomp.json`: the podman default with `unshare`, `setns` removed
and `clone`/`clone3` restricted (deny `CLONE_NEWUSER`), passed as
`--security-opt seccomp=...`. **Functional cost to verify before adopting:** Claude Code's
own Bash sandboxing (bubblewrap) needs userns and would fail inside a box; it is
unnecessary there, but check that Claude Code degrades gracefully rather than refusing
tool calls. Chromium in `:playwright` already runs `--no-sandbox`. Node/Python builds are
unaffected. `podman`/`docker`-in-box was never supported.

### F7. The egress prompt will happily grant the host's own addresses — **Medium**, effort **T**

**Evidence** (bats, stubbed engine, box-writable config):
```
egress = 169.254.1.2:22, 172.16.50.51:22
Allow the sandbox to reach 169.254.1.2:22? [y/N]
Allow the sandbox to reach 172.16.50.51:22? [y/N]
```
A bare IP is all the operator sees. `169.254.1.2` is pasta's mapping of the host,
`172.16.50.51` is the host's LAN address, `10.0.2.2` is slirp's host, `127.0.0.1` is
already allowed by the loopback rule. A prompt-injected config line plus a reflexive "y"
opens a host service to the box. Fix: refuse (or annotate in red) grants in
`169.254.0.0/16`, `10.0.2.0/24`, loopback, and any address currently on a host interface.
No functional cost; an operator who really wants it can use `AIRLOCK_EXTRA_EGRESS`.

### F8. Second layer for the host mapping: `--map-guest-addr none` works — **Low**, effort **T**

Podman already runs pasta as
`--config-net --dns-forward 169.254.1.1 -t none -u none -T none -U none --no-map-gw --quiet --map-guest-addr 169.254.1.2`
(from the real argv of your live box). So `--no-map-gw` is already on: the gateway
address does not reach the host. What `169.254.1.2` reaches is the host's *non-loopback*
sockets:

```
firewall OFF, default pasta:  169.254.1.2:18081 (host listener on 0.0.0.0)   OPEN
                              169.254.1.2:18082 (host listener on 127.0.0.1) Connection refused
firewall OFF, pasta:--map-guest-addr,none:  both TIMEOUT
firewall ON,  default pasta:  both "No route to host" (REJECT)
firewall ON,  pasta:--map-guest-addr,none:  firewall inits, DNS resolves, api.anthropic.com 404
```
So today only the in-box firewall stands between the box and any host service bound to
`0.0.0.0` (a dev server, Postgres, an MCP server, `podman system service`). Adding
`--network=pasta:--map-guest-addr,none` in the launcher removes that address entirely
and costs only `host.containers.internal`, which nothing in airlock uses. The host's
loopback-only services were never reachable (pasta does not map loopback). ICMP needs no
second layer: `dev` cannot create ICMP sockets. IPv6: pasta copies the host's global
addresses into the box, and the in-box `ip6tables` handles them; no v6 equivalent of the
host mapping exists.

### F9. `airlock mount` guards — **Low** overall, effort **T–S**

The design is sound (host-only store, re-check at launch, canonical path, owner check,
hard-link scan). What I could and could not get past:

| Guard | Result | Evidence |
|---|---|---|
| Deny list | **Incomplete, by nature** | Accepted on first try: `.config/rclone .config/helm .terraform.d .config/hcloud .config/Code .local/share/pass .config/op .config/git .cache .config/systemd .ansible .config/pip .m2 .config/tailscale .config/argocd .config/k9s` (bats). rclone.conf, helm registry creds, `credentials.tfrc.json`, `.config/git/credentials`, k9s/argocd tokens are all bearer secrets. |
| Ancestor check | Holds | `~/.config` refused ("contains protected"). |
| Symlink resolution | Holds at check time | `readlink -e`; swapped-for-symlink dirs are skipped at launch (existing tests). |
| TOCTOU check→mount | **Window exists, narrow** | Stub engine swapped the dir for a symlink to `~/.ssh` *after* the check; the launcher still passed `-v ~/.kube-claude:~/.kube-claude:ro` and the runtime would resolve the symlink. Exploiting it needs a writer on an ancestor of the mount path during the launch window; no ancestor of `~/.kube-claude` is ever mounted rw, so a *box* cannot do it. Only relevant if someone runs airlock with `$HOME` or a parent as the workspace/`share_rw`. |
| Hard-link scan | **Blind to nested mounts** | `find -xdev` stops at filesystem boundaries; podman's `-v` is `rbind`, so a FUSE/bind mount inside the dir *is* exposed but *not* scanned. Add `findmnt -R "$c"` and refuse if anything but the top is a mountpoint. T. |
| Owner / mode | Holds | `-perm /022`; an ACL-granted group write is caught because setfacl raises the mask bits (tested, refused). |
| `mount rm` | Fine | Non-canonical spellings normalise via `readlink -f`; nothing else matches. |
| Box influence over its mounts | None found | No config key; store is host-only; the check reads only host paths. |
| Propagation | Fine | rprivate; a mount made on the host after launch does not appear in the box, and `mv`-replaced tokens do (same inode namespace). |

The deeper point: a deny list protects against *you* mounting the wrong thing by habit,
not against a complete inventory of where credentials live. A cheap improvement is to make
`mount add` print the file list and ask "these N files will be readable by every box on
this project; continue?", so the operator sees what they are granting.

**On the kube token itself** (not inspected): the box can exfiltrate it for its 12h life
through any allowed shared IP or DNS. Confirm the bound ClusterRole excludes `secrets`,
`serviceaccounts/token`, `pods/exec`, `pods/portforward`, `nodes/proxy`; "read-only"
that includes `get secrets` is not read-only.

### F10. Root's PATH during firewall init starts with a `dev`-owned directory — **Low**, effort **T**

```
$ cat /proc/1/environ | tr '\0' '\n' | grep ^PATH
PATH=/home/dev/.local/bin:/home/dev/.local/bin:/usr/local/sbin:...
$ ls -ld /home/dev/.local/bin
drwxr-xr-x 1 dev dev ...
```
`init-firewall.sh` runs as root and calls `iptables`, `ipset`, `dig`, `curl`, `jq`,
`aggregate` by name. Not exploitable today because that directory lives in the ephemeral
overlay and `dev` never runs before the firewall. It becomes exploitable the day anything
under `/home/dev` outside `.claude` is persisted. Set an explicit root PATH in
`entrypoint.sh`; no functional cost. Also noted: root can rewrite `/etc/resolv.conf`
before the drop (harmless, the port-53 rules are already fixed) and `dev` cannot.

### F11. `.airlock/config` values are glob-expanded on the host — **Low**, effort **T**

`for _d in $_val` and `for _s in $_val` are unquoted, so `artifact_dirs = *` expands
against the workspace listing:
```
artifact_dirs = *   ->  4 artifact mounts, including .../artifacts/zzz-dir:.../zzz-dir:rw
share = *           ->  one "Share ... ?" prompt per matching name under AIRLOCK_SHARE_BASE
```
A box can make its own next launch shadow arbitrary workspace directories with empty
stores (self-harm, but confusing), and spam share prompts with plausible sibling names.
`mkdir -p "$host_path"` also follows a box-planted symlink in the workspace and creates
a directory outside it on the host (it is `rmdir`'d again by the last-one-out cleanup, so
the lasting effect is nil). Fix: `set -f` around the parser or split with `read -ra`.

### F12. Supply chain of the non-Debian layers — **Low**, effort **S**

| Layer | Trust today | Note |
|---|---|---|
| Debian packages | apt signatures | fine, but stale (F5) |
| Claude Code | `curl https://claude.ai/install.sh \| bash`, version pinned by arg | the installer itself is unverified; upstream publishes no checksum for the script. Accept, or vendor the script and diff on change. |
| Node 24 | TLS only, "newest v24.x" | `SHASUMS256.txt` (+ `.sig`) is published; verify it. S. |
| kubectl, helm, sops, tea, promtool, terraform, tflint, vector, alloy, pwsh, PSScriptAnalyzer | version + sha256 per arch | good; a re-tag fails the build. Bumps are manual (three bump commits since July). |
| ansible-lint venv | `ansible-lint==26.8.0`, **transitive deps unpinned** | 30 packages resolved at build time; `pip list --outdated` shows only pip today, but a rebuild can pull a different tree. Use `pip install --require-hashes -r constraints.txt` (`pip-compile --generate-hashes`). S. |

None of this is urgent; the firewall means a poisoned tool mostly hurts the box. It
matters most for the tools that run **as root before the drop**: `dig`, `curl`, `jq`,
`aggregate`, `iptables`, `ipset` are all Debian, which is the right place for them.

### F13. The OAuth token is readable by the agent — **Medium** (documented), effort **M** to change

Documented honestly. Two options beyond rotation:
- `airlock login persist` per project bounds exposure to that project's credential
  (already there; the credential is still readable in `~/.claude/.credentials.json`).
- Keep the token in a root-owned process: run a tiny reverse proxy as root in the box
  before the drop, listening on `127.0.0.1`, that adds `Authorization` and forwards to
  `api.anthropic.com`; point Claude at it with `ANTHROPIC_BASE_URL` and give `dev` no
  token at all. `dev` cannot read root's `/proc/<pid>/environ` (verified: `/proc/1/environ`
  is `-r--------`). The box can still *use* the credential but not *take* it. Compatibility
  with the OAuth-token auth path is the open question; prototype before committing.

### F14. Claims to fix in the docs — **Info**, effort **T**

Listed in §1.1. Also: the box's `CLAUDE.md` tells the agent "This is a Docker sandbox";
it is podman by default, and the agent will reason about its environment from that line.

## 3. New code since the last review

**`ce7e94f` airlock mount** — see F9. Nothing wrong with the shape. Add the nested-mount
refusal and the content preview; keep the deny list but stop treating it as the guard.

**`9853d3b` DNS** — correct and verified: the box's `resolv.conf` is exactly
`nameserver 169.254.1.1`, the firewall pins that one address, `dig @8.8.8.8` is
unreachable, and `AIRLOCK_HOST_DNS` is `::1 127.0.0.1` on this host so no public
resolver could ever be pinned. Paths I checked for a way around it:
- *IPv6 resolver*: pasta offers no v6 forwarder here, `resolv.conf` has none, and the v6
  OUTPUT chain has no port-53 rule. Closed.
- *Docker*: with a loopback-only host resolver docker substitutes `8.8.8.8`; the firewall
  now refuses to pin it and dies with a clear message asking for `AIRLOCK_DNS`. Correct
  fail-closed behaviour.
- *slirp4netns*: `10.0.2.3` is RFC1918 and always pinned; the same forwarder-to-host
  semantics. Fine.
- *Box root rewriting resolv.conf*: only root can (`dev` gets EACCES), and root exists
  only before the drop; the port-53 rules are by IP, so a rewritten file changes nothing.
- *`AIRLOCK_HOST_DNS` unset*: pins everything in `resolv.conf`, which is the old
  behaviour and only reachable by running the firewall by hand. Acceptable; the doctor
  and the launcher both set it. Consider making unset a hard error instead, since there
  is no longer a caller that legitimately omits it.

**`4afb4c8` infra clients** — pins are correct (build fails on mismatch). `sops` and
`kubectl` are exactly the tools that turn a mounted credential into cluster access, which
is the point; they add no attack surface of their own. `SOPS_DISABLE_VERSION_CHECK` and
`CHECKPOINT_DISABLE` are good hygiene. `tea` stores tokens under `~/.config/tea` (denied
for mount, good).

## 4. Network layer

- **Host mapping.** F8. Adopt `--map-guest-addr none`. `--no-map-gw` is already in
  effect; `-t none -u none -T none -U none` means no port forwarding either way.
- **IPv6.** The box carries the host's global and ULA addresses. `ip6tables` works
  (`filtering=yes`), the positive control passes. Link-local (`fe80::`) to LAN neighbours
  is blocked by the v6 OUTPUT policy; only ND types are allowed and pasta has no L2 to
  carry them anyway.
- **ICMP.** `dev` cannot open ICMP sockets (`ping_group_range 0 0`, no `NET_RAW`); root
  could before the drop. No `ping` binary in the image. Nothing to do.
- **Host loopback.** Unreachable by construction (pasta never maps loopback). Host
  `0.0.0.0` listeners are reachable only via `169.254.1.2`, which the firewall REJECTs
  and F8 removes.
- **Root bringing the firewall down.** Root holds `NET_ADMIN` only until `gosu dev`.
  `dev` has no path back: no `sudo`, `su` needs a password and NNP blocks the setuid
  anyway, `gosu root` → "operation not permitted", file capabilities: none
  (`getcap -r /` empty), the entrypoint trusts nothing `dev` can write (F10 is the one
  soft spot). `iptables -L` as dev: permission denied. Nested userns (F6) gives a *new*
  empty netns, not the box's.

## 5. Observations from the first launch

**5.1 WebSearch works, WebFetch is blocked.** Consistent with the design: WebSearch runs on
Anthropic's side, WebFetch is a client-side fetch. Note that WebFetch is therefore an
exfil client the moment a domain is allowed, exactly like `curl`.

**5.2 TCP to 169.254.1.2 on 22/53/55435 blocked only by the firewall.** Confirmed, and
F8 is the second layer.

**5.3 TCP 53 to 169.254.1.1 "fails".** Did not reproduce. With the firewall up, as `dev`:
```
dig +tcp @169.254.1.1 example.com A      -> 172.66.147.243 / 104.20.23.154
drill -t @169.254.1.1 example.com A      -> ANSWER: 2
python raw TCP DNS query to 169.254.1.1  -> TCP answered 63 bytes
bash: exec 3<>/dev/tcp/169.254.1.1/53    -> OPEN
```
pasta 2026_07_28 forwards TCP DNS to the host resolver, which listens on TCP 53
(`ss -lnt` shows `127.0.0.1:53` and `[::1]:53`). The likely explanation for the original
observation: the tool used is not in the image. `nc` is absent (`failed to run command
'nc'`), and a `timeout`-wrapped probe that produces no output can read as "failed". If it
was a different tool, tell me which and I will chase it.

## 6. Base image

Debian trixie versus Arch on the host: for this use the stable base is the right call.
Security fixes reach `stable-security` typically within a day or two of disclosure for
the packages that matter here (openssl, glibc, curl, bind, util-linux), backports are
unnecessary because nothing in the image needs a newer distro package, and a stable base
means a rebuild changes as little as possible, which is what keeps the validators pinned
and the smoke test meaningful. Arch would give newer userland with no security benefit
inside a firewalled box and a rebuild that can change anything at any time.

The layers that are not Debian are listed in F12; Claude Code and Node are the two that
float. Staleness is F5: the fix is cadence plus `--pull`, not digest pins. Suggested:
`make refresh` weekly (cron or a reminder), `make install` after every pull, and print
the apt-layer date in `airlock doctor` so a stale image is visible.

## 7. Hardening options

Each row: what it adds on top of what you already have, what it breaks, verdict.

| Option | Adds | Breaks | Verdict |
|---|---|---|---|
| Custom seccomp (deny userns) | removes the main kernel-exploit precondition (F6) | Claude Code's bwrap sandbox in-box (not needed); anything using `unshare` | **Do**, after a functional check |
| `--read-only` rootfs + tmpfs | prevents writes to the overlay | `apt`, `pip --user`, `npm -g`, Postgres under `$HOME`, Playwright caches; needs tmpfs for `/tmp`, `/home/dev`, `/run`, `/var/tmp` | Skip: `--rm` already discards the overlay; low gain, high friction |
| mask/unmask | podman already masks `/proc/kcore`, `/proc/keys`, `/sys/firmware`, `/proc/sys` ro (verified) | nothing | Nothing to add |
| userns size | keep-id maps 1000→1000 and the rest to 100000+; 65536 ids | a smaller range changes nothing security-wise | Leave |
| AppArmor | a modest profile (mount, ptrace, `/proc/sys` writes), all already blocked by caps/seccomp/userns | needs kernel `lsm=` change and reboot on titan | Skip |
| Landlock | in-box, from the entrypoint: fs scoping (little gain: the container already scopes) and, on ABI v4+, per-process TCP connect port rules as a second egress layer independent of iptables | needs a Landlock wrapper binary; Debian has none packaged; would need to allow 443/53/22 | Maybe later; the CONNECT proxy is the better second layer |
| cgroup limits | `pids` 4096 set; `memory`/`cpu` controllers are delegated (`cgroup.controllers: cpu memory pids`), so `--memory`/`--cpus` work rootless | too-low memory breaks builds (documented) | Set `AIRLOCK_MEMORY` to something generous on titan; add `--cpus` opt-in |
| Host sysctls | `unprivileged_bpf_disabled=1`, `ptrace_scope=2`, `dmesg_restrict=1`, `kptr_restrict=2` already; `io_uring_disabled=0` but seccomp blocks it in the box | `ptrace_scope=2` means no `strace`/`gdb` in a box (host choice) | Already good; `io_uring_disabled=2` is optional belt-and-braces |
| podman defaults | seccomp, masked paths, rprivate, no port forwarding, `--no-map-gw`, pids 2048, rootless userns | | Doing most of the work already |
| gVisor | see below | | **Not viable as-is** |
| nftables | see below | | Optional, small |

**gVisor (`runsc release-20260316.0`, rootless).** Tested with the launcher's exact
arguments. Plain `--runtime=runsc` fails under both cgroup managers
(`systemd error: Access denied ... interactive authentication` / `cgroup.subtree_control:
permission denied`). With a wrapper adding `--ignore-cgroups` it starts, and pasta
networking works (the box gets the host's addresses). But:
```
iptables -P OUTPUT DROP     -> iptables: Failed to initialize nft: Protocol not supported
ipset create t hash:net     -> ipset v7.22: Cannot open session to kernel.
iptables-legacy -P OUTPUT DROP -> can't initialize iptables table `filter': Table does not exist
init-firewall.sh            -> ERROR: this box has global IPv6 but ip6tables is unusable ... Refusing to start
```
So the firewall cannot come up at all, and with no cgroups there is no pids/memory cap.
Inside, `Seccomp: 0` (the sentry does its own filtering) and `unshare -Ur` gives an
emulated root. The gain would be the sentry between the agent and the host kernel, which
is exactly what F6 is about; the cost is rewriting egress enforcement to live *outside*
the box (host-side or a proxy). If you ever do the CONNECT-proxy design with the proxy
outside the sandbox, gVisor becomes viable again; until then, no.

**nftables (your mid-review question).** The image has no `nft` binary; `iptables` is
`iptables-nft`, so every rule already lands in nftables. Moving to native `nft` would let
you drop `ipset` and the `ip_set*`/`xt_set` modules (nft sets are native, fewer
prerequisites in `modules-load.d`), load the whole ruleset atomically with `nft -f`
(no window where the OUTPUT policy is DROP but the allow rules are not yet in), and
express v4+v6 once in an `inet` table. It buys no new containment on its own and does
not help gVisor (netstack supports neither). Worth doing when you next rewrite the
firewall, for example as part of §9; not worth a standalone change. S.

## 8. Functional check

Nothing recommended above changes Claude Code, git, python/node builds, kubectl,
validators or `airlock paste`, with two exceptions to test first: the seccomp change
(Claude Code's own sandbox feature) and, if adopted, the CONNECT proxy (any tool that
ignores `HTTPS_PROXY`). `--map-guest-addr none` only removes `host.containers.internal`.

## 9. The design answer for IP-based egress

Today the allowlist says "these IPs on 443". The Traefik VIP shows why that is the wrong
unit: names are what you approve, IPs are what you enforce, and the two only coincide for
single-tenant hosts. Options:

1. **Infra-side, no airlock change (S).** Give agent-reachable services their own ingress
   IP (a second Traefik entrypoint or MetalLB address for `metrics`/`logs`). The grant then
   really is one service. Fragile: the next shared VIP reintroduces the problem.
2. **CONNECT proxy in the box (L, recommended).** As root, before the drop, start an HTTP
   CONNECT proxy (tinyproxy, or a 100-line Go/Python one) on `127.0.0.1` with the
   *hostname* allowlist derived from the same `firewall.conf`/groups/`egress =` inputs.
   Firewall: `OUTPUT -m owner --uid-owner proxy -p tcp --dport 443 -j ACCEPT`, everything
   else for `dev` dropped, **including port 53**. Export `HTTPS_PROXY`/`HTTP_PROXY`/
   `NO_PROXY` for `dev`. The proxy sees the requested host in the CONNECT line, so no TLS
   interception and no CA. Effects: closes CDN co-tenancy, closes the shared-VIP problem,
   closes DNS exfiltration (the box has no resolver at all; the proxy resolves), keeps
   `IPv4:port` grants working as `CONNECT ip:port`. Cost: any tool that bypasses the
   proxy env breaks loudly (not silently), git-over-ssh to GitHub needs either the
   existing port-22 rule kept or `ProxyCommand`; kubectl, curl, git, pip, npm, node,
   Claude Code all honour `HTTPS_PROXY`. Test matrix is the same as `make image-smoke`.
3. **SNI-sniffing without a proxy** (nft cannot, an sniproxy-style userspace filter can)
   gives the name check without changing client config, but it is trivially bypassed by
   a client that sends a false SNI, so it is not a containment boundary. Skip.

Option 2 is also what makes gVisor and a root-held API credential (F13) natural later.

## 10. Proposed README wording (replaces the two "Known limitation" sections)

> **Known limitation: files the box writes run, or are read, on the host.** The firewall
> contains the network, not files. Three things you already trust on the host live in
> directories the box can write:
> - **The project.** Mounted read-write at its real path. Git runs `.git/config` keys
>   (`core.fsmonitor` on every `git status`, `core.pager`, `core.hooksPath`,
>   `core.sshCommand`, filters) and `.git/hooks`; Claude Code runs `.claude/settings.json`
>   hooks and `.mcp.json` servers **without asking** and follows `CLAUDE.md`; build tools
>   run `Makefile`, `package.json` scripts, `conftest.py`; direnv runs `.envrc` once you
>   re-`allow` it. Treat a repo a box has worked in like a PR from a stranger: diff those
>   files before you `git status`, build, or open host `claude` in it.
> - **This project's memory** (`AIRLOCK_SHARE_MEMORY=rw`, the default). Host Claude
>   auto-loads `memory/` every session, and follows symlinks, so a box can both plant
>   instructions and make the host read any file you can read. `ro` stops the box
>   authoring memories; it does not stop the next channel.
> - **This project's transcripts.** Always read-write, because a box must record its own
>   session. A box can rewrite what a host `--resume` sees as history, and anything the
>   host says in that session is readable by the next box.
> `AIRLOCK_SHARE_HISTORY=0` shares nothing; the cost is no `--resume` across the boundary.

And in the egress bullet, replace "CDN co-tenancy" with "any IP shared by more than one
name: a CDN edge, a reverse proxy, an ingress VIP. Granting `metrics.example` on a shared
ingress grants every service behind it."

## Start here (ordered by value per hour)

1. **Docs** (T): §1.1 corrections, §10 wording, SECURITY.md rebuild sentence. Fixes the
   only misleading statements and costs nothing.
2. **`--map-guest-addr none`** (T, F8): one launcher line plus a bats assertion.
3. **Symlink check on the shared project dir** (T–S, F1): in the host `claude` wrapper
   and in the launcher before mounting. Closes the read-back path with no UX change.
4. **Egress grant sanity check** (T, F7): refuse/annotate host and pasta addresses.
5. **Image refresh** (S, F5): `--pull`, cache-bust the apt layer, `make refresh`, print
   the apt date in `doctor`. This is the one that is silently getting worse every week.
6. **Entrypoint PATH + `set -f` in the config parser** (T, F10, F11).
7. **Mount: nested-mount refusal + content preview + deny-list additions** (T–S, F9).
8. **Change detection for `.claude/`, `.mcp.json`, `.git/config`, `CLAUDE.md`** in the
   host wrapper (S, F2/F3).
9. **Custom seccomp denying user namespaces** (S, F6), after checking Claude Code in a
   box still runs tools normally.
10. **Verify the kube ClusterRole** cannot read secrets or exec (T, F9 note).
11. **Node SHASUMS and hashed pip constraints** (S, F12).
12. **Dedicated ingress IP for agent-facing services on titan** (S, infra, §9.1) as the
    stopgap for the VIP problem.
13. **CONNECT-proxy egress** (L, §9.2): the one change that turns "we allow IPs" into
    "we allow names" and removes DNS from the box. Highest total value; do it after the
    cheap items above are in.
14. **Root-held API credential** (M, F13) and **nft rewrite** (S), both natural
    follow-ons to 13.
