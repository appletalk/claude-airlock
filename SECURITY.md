# Security policy

claude-airlock exists to contain a coding agent that may misbehave, so its security is the
whole product. We want to hear about weaknesses in it.

## Reporting a vulnerability

**Report privately. Do not open a public issue for a security bug.**

- Use GitHub's private vulnerability reporting: the repository's **Security** tab, then
  **Report a vulnerability**. (If the tab is not visible, the maintainer needs to enable
  "Private vulnerability reporting" in the repo settings; ask them to.)
- Include what an attacker can do, which containment property it breaks, and a proof of
  concept if you have one.

Please allow a reasonable window to fix and release before any public disclosure. We aim to
acknowledge a report within a few days.

## Threat model in one paragraph

Assume the agent may be adversarial (prompt injection, a bad tool call). The container and
egress firewall bound **escape and exfiltration** (Class A). They do **not** bound
authorized-but-destructive actions (Class B) or **influence** channels (files and memory
the host later trusts). Run untrusted code in the box, keep real credentials scoped and out
of it, and review what the box wrote before the host acts on it. The full model is in
[docs/security-model.md](docs/security-model.md).

## In scope

Anything that lets a box exceed its intended authority. For example:

- **Egress escape:** reaching a network destination the allowlist should have blocked,
  over any protocol or address family (an IPv6 leak, a firewall-init bypass, an ipset gap).
- **Sandbox escape or privilege gain:** the agent user (`dev`) obtaining capabilities,
  writing the firewall rules, or reaching the host, other projects or the engine socket.
- **Grant tampering:** a box approving its own egress, share or secret grant, or reading a
  host-side store it should not (the state dir, another project's data).
- **Credential exposure:** the OAuth token or an injected secret leaking somewhere it
  should not be (other host users, logs, the process table).
- **Host code trusting box-writable files.** The launcher (and `airlock paste`) runs on the
  host as the box's user, and the box decides what every name in its read-write mounts is:
  a file, a folder, a FIFO, a link to anywhere that user can reach. Host code never opens a
  path there by name. It builds content in a private temp file outside the mounts and
  renames it in, reads only through a private copy of a regular file, and stops on a folder
  where a file should be. A write or read through such a path is in scope.

## Known limitations, not vulnerabilities

These are documented, deliberate trade-offs; see
[docs/security-model.md](docs/security-model.md) and
[docs/SECURITY-REVIEW.md](docs/SECURITY-REVIEW.md). A report that only restates one is not
a finding. A way to *worsen* one, or a practical exploit that changes our risk assessment,
is very welcome.

- **DNS is a low-bandwidth exfiltration channel.** DNS is pinned to the configured
  resolvers, which removes the choice of destination but not tunnelling data through query
  names. The OAuth token is in scope for this channel; rotate it if you believe a box was
  compromised.
- **IP-based allowlisting inherits CDN co-tenancy.** The firewall matches destination IPs,
  not TLS SNI, so a site sharing an allowlisted IP (common behind shared CDNs once a
  registry group is enabled) is reachable. Closing this needs an L7 proxy, such as the
  `airlock egress proxy` posture with an SNI-aware proxy.
- **The shared workspace and `memory/` are influence channels.** Files a box writes into
  your project can later be run or read by the *unsandboxed* host. Some run with no build
  step and no prompt: `.git/config` keys such as `core.fsmonitor` on a plain host `git
  status`, hooks in `.claude/settings.json` and servers in `.mcp.json` when you open host
  `claude` there, plus git hooks, `.envrc` and build scripts. Shared memory is read by the
  host agent every session. The firewall cannot see a file write.
  - **Mitigated for git config:** every config file host git reads for a repo in a
    read-write root, and its hooks, are read-only in the box (`AIRLOCK_GIT_RO=1`, the
    default). Repos a box creates while it runs (submodules, worktrees, nested `.git`) are
    not covered by that; set the host git environment shown in
    [Git config and hooks are read-only in the box](docs/security-model.md#git-config-and-hooks-are-read-only-in-the-box),
    which also lists exactly what is bound, what is refused, and what it breaks in the box.
  - **Still open:** `.claude/`, `.mcp.json`, `.envrc`, build scripts, and any script you
    later run by hand. Review a touched repo before host tooling runs in it.
  - **Memory:** tighten with `AIRLOCK_SHARE_MEMORY=ro`. Symlinks in the shared session
    directory are refused.
  - **This repo:** the gitignored `.tooling/` shellcheck and bats are what `make check` and
    the pre-commit hook fall back to when no system copy is installed. A box can write
    them. `make bootstrap` re-verifies them; run it with no box open on the checkout.
- **Class B: destructive but authorized actions** (a bad `terraform destroy`, a
  force-push) are not solved by isolation. Keep write credentials out of the box.

## Supported versions

This is a single-branch project; fixes land on `main`. Rebuild the images after pulling
with `make install-airlock`:

- It picks up a new Claude Code release immediately.
- It refreshes the Debian packages (base tag and `stable-security`) once a week. `make
  refresh` does the package refresh today, and `airlock doctor` reports when the packages
  were last refreshed.
- The pinned upstream tools (kubectl, terraform and the rest in `image/dev/Dockerfile`)
  move only when their pins are bumped.
