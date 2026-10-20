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
- **Host code trusting box-writable files** — the launcher (or `airlock paste`) runs on the
  host as the box's user, and the box decides what every name in its read-write mounts is
  (a file, a folder, a FIFO, a link to anywhere that user can reach). Host code never opens
  a path there by name: it builds content in a private temp file outside the mounts and
  renames it in, reads only through a private copy of a regular file, and stops on a folder
  where a file should be. A write or read through such a path is in scope.

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
  host `claude` there, plus git hooks, `.envrc` and build scripts. In this repo that
  includes the gitignored `.tooling/` shellcheck/bats that `make check` and the
  pre-commit hook fall back to when no system copy is installed: `make bootstrap`
  re-verifies them, run with no box open on the checkout. Shared memory is read
  by the host agent every session. The firewall cannot see a file write.
  **Every config file host git reads for a repo in a read-write root is read-only in the box**
  (`AIRLOCK_GIT_RO=1`, the default). That covers what a config can name: `credential.helper`,
  `core.editor`, `core.fsmonitor`, `diff.external`, filter and merge drivers,
  `remote.*.uploadpack`, aliases, hooks. In the workspace and every `share_rw`, read-only:
  - `.git/config`, and its includes that lie in a read-write root (followed by hand, 10 deep)
  - `config.worktree`, for the repo and each worktree when `extensions.worktreeConfig` is on
  - `commondir`: created as `.` where git would look for one, so a box can't add one that
    points git at a config it wrote
  - the `.git` pointer files of in-root linked worktrees and submodule checkouts, and
    submodule gitdirs' configs, nested ones included
  - the hooks, an in-root `core.hooksPath` (resolved per worktree), and the in-root target of
    a hook that is a symlink

  Each git directory is bound onto itself, so it can't be renamed away and replaced. The
  checks run on canonical paths and the binds land where the box sees them, so a symlinked
  parent or share base changes nothing. A symlink, a hard link, an unreadable git directory or
  a `commondir` pointing elsewhere stops the launch: a box may have planted it. Config is read
  hermetically (no repository discovery, no system or global config), and a read error
  refuses instead of reading as empty.

  Linked worktrees must check out: each `worktrees/*/commondir` has to lead back to the
  repo, and each `gitdir` file has to name a `.git` file that points back to it. A bare repo
  shared read-write is guarded as a git directory. A hook symlink whose target doesn't
  exist yet in a read-write root refuses (the box could create it).

  **Not closed by binding, so also neutralise git on the host.** While a box runs it can
  create a repo that host git then enters: a `.git` file or directory in a submodule path
  (upstream's or one it adds, populated or not), a new submodule, a new worktree. Its config
  is the box's, so hooks, `core.fsmonitor`, filter and diff drivers in it can all run on a
  plain host `git status` or `diff` (the next launch guards what exists by then). Paused
  rebase, `am` and cherry-pick state can hold `exec` lines that `--continue` runs. Hook
  managers (husky, pre-commit, lefthook) read tracked files. Global or system config that
  points into a share, and independent repos nested in the workspace, aren't checked. Host
  environment config outranks every config file, so set it in your shell (child processes
  inherit it), keeping host git out of submodules and hooks:

  ```
  GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
  GIT_CONFIG_KEY_1=core.fsmonitor GIT_CONFIG_VALUE_1=false
  GIT_CONFIG_KEY_2=diff.ignoreSubmodules GIT_CONFIG_VALUE_2=all
  ```

  Run a repo's hooks by hand when you want them, and look into submodules with explicit
  `git -C <sub>` commands. Abort, rather than continue, a rebase or `am` a box left paused.

  **What this costs in the box:** commit, branch, checkout, stash, rebase, `gc` and new
  worktrees work. Anything that writes config fails, sometimes after doing half its work:
  `remote add`, `branch --set-upstream`/`push -u`, `switch -c x origin/x` (the branch is
  made, its tracking isn't), `branch -D` (deleted, config error), `submodule add` and
  `submodule update` (even a no-op on an initialised one), `config --worktree`, `maintenance
  register`. Removing or pruning a worktree that existed at launch fails on its bound gitdir.
  Edit a tracked hooks directory on the host. An include that goes through a symlink into a
  read-write root refuses the launch: point it at the real path. With a workspace reached
  through a symlinked path, in-root worktrees don't work in the box (git records the real
  path, which the box doesn't see).

  Also open: `.claude/`, `.mcp.json`, `.envrc`, build scripts, and any script you later run
  by hand. Review a touched repo before host tooling runs in it. Tighten memory with
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
