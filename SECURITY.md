# Security policy

claude-airlock exists to contain a possibly-misbehaving coding agent. Its security posture
is therefore the whole product, and we want to hear about weaknesses in it.

## Reporting a vulnerability

**Please report privately — do not open a public issue for a security bug.**

- Preferred: GitHub's private vulnerability reporting — the repository's **Security** tab →
  **Report a vulnerability**. (If the tab is not visible, the maintainer needs to enable
  "Private vulnerability reporting" in repo settings; ping them to do so.)
- Include: what an attacker can do, the containment property it breaks, and a proof of
  concept if you have one.

Please give us a reasonable window to fix and release before any public disclosure. We aim
to acknowledge a report within a few days.

## What is in scope

Anything that lets a contained box exceed its intended authority, for example:

- **Egress escape** — reaching a network destination the allowlist should have blocked,
  over any protocol or address family (a v6 leak, a firewall-init bypass, an ipset gap).
- **Sandbox escape / privilege gain** — the agent user (`dev`) obtaining capabilities,
  writing the firewall rules, or reaching the host / other projects / the engine socket.
- **Grant tampering** — a box approving its own egress/share/secret grant, or reading a
  host-side store it should not (the state dir, another project's data).
- **Credential exposure** — the OAuth token or an injected secret leaking to a place it
  shouldn't be (other host users, logs, the process table).

## What is a known limitation, not a vulnerability

These are documented, deliberate trade-offs — see the README's "Security model" and
[`docs/SECURITY-REVIEW.md`](docs/SECURITY-REVIEW.md). A report that simply restates one of
these is not a finding (though a way to *worsen* one, or a practical exploit that changes
our risk assessment, is very welcome):

- **DNS is a low-bandwidth exfil channel.** DNS is pinned to the configured resolvers,
  which removes destination choice but not tunnelling data through query names. The OAuth
  token is in scope for this channel; rotate it if a box is believed compromised.
- **IP-based allowlisting inherits CDN co-tenancy.** The firewall matches destination IPs,
  not TLS SNI, so a site sharing an allowlisted IP (common behind shared CDNs when a
  registry group is enabled) is reachable. Closing this needs an L7 proxy.
- **The shared workspace and `memory/` are influence channels.** Files a box writes into
  your project can later be run or read by the *unsandboxed* host, and some run with no
  build step and no prompt: `.git/config` keys such as `core.fsmonitor` on a plain host
  `git status`, hooks in `.claude/settings.json` and servers in `.mcp.json` when you open
  host `claude` there, plus git hooks, `.envrc` and build scripts. Shared memory is read
  by the host agent every session. The firewall cannot see a file write, and there is no
  wrapper policing host `git` by design. Review a touched repo, including `.git/config`
  and `.claude/`, before host tooling runs in it; tighten memory with
  `AIRLOCK_SHARE_MEMORY=ro`. Symlinks in the shared session directory are refused.
- **Class B — destructive but *authorized* actions** (a bad `terraform destroy`, a
  force-push) are not solved by isolation. Keep write credentials out of the box.

## Threat model in one line

Assume the agent may be adversarial (prompt injection, a bad tool call). The container +
egress firewall bound **escape and exfiltration** (Class A). They do **not** bound
authorized-but-destructive actions (Class B) or **influence** channels (files/memory the
host later trusts). Run untrusted code in the box; keep real credentials scoped and out of
it; review what the box wrote before the host acts on it.

## Supported versions

This is a single-branch project; fixes land on `main`. Rebuild the images after pulling:
`make install` picks up a new Claude Code release immediately and refreshes the Debian
packages (base tag and `stable-security`) once a week; `make refresh` does the package
refresh today. `airlock doctor` reports when the packages were last refreshed. The pinned
upstream tools (kubectl, terraform, and the rest in `image/dev/Dockerfile`) move only when
their pins are bumped.
