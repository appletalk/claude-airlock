# Images

`make install-airlock` builds the images in layers.

| Image | What it is |
| --- | --- |
| `claude-airlock:base` | Debian + Claude Code + the egress firewall and proxy bridge, and little else: curl, jq and a bare `python3` (no pip or venv). No git, gh or editor; those are in `:dev`. |
| `claude-airlock:os` | The base without Claude Code (its `os` build stage). Not a box image: `:dev` builds on it and copies Claude Code from `:base` as its last layer. |
| `claude-airlock:dev` *(default)* | Base + git, gh, make, less, vim, zsh, ripgrep, Python (pip, venv), Node, PowerShell, build tools, PostgreSQL, YAML tooling, infra clients (kubectl, helm, sops, tea, drill; no credentials baked in), and the [offline config validators](#config-validators). |
| `claude-airlock:playwright` | Dev + headless Chromium + the Playwright MCP. Not built by the install. |

- **Choose an image** with `AIRLOCK_IMAGE` in the host config, or per project with
  `image = claude-airlock:playwright` in `.airlock/config` (it must be a `claude-airlock:*`
  tag).
- **Build `:playwright` on demand:** `docker build -t claude-airlock:playwright
  image/playwright` (with podman, `podman build`).
- **Build `:dev` by hand:** build `:base` and `:os` first, e.g. `podman build --target os
  -t claude-airlock:os image`.
- **PostgreSQL in a box:** start it with `airlock-pg-start` (`localhost:5432`, ephemeral).

## Config validators

Infrastructure-as-code tooling in `:dev` that runs to completion at **minimal egress**: no
provider downloads, no collection resolution, no plugin fetches. Syntax and lint only.

| Tool | What works offline |
| --- | --- |
| `promtool check config\|rules`, `promtool test rules` | Prometheus config, alerting and recording rules, rule unit tests |
| `terraform fmt -check` | HCL syntax and formatting (exit 3 = drift, 2 = syntax error) |
| `tflint` | the `terraform` ruleset bundled inside the binary |
| `ansible-lint` | playbook and role lint (`ANSIBLE_LINT_NODEPS=1` is set image-wide, see below) |
| `vector validate --no-environment` | config parse and topology, no component or health checks |
| `alloy fmt -t`, `alloy validate` | Alloy syntax and formatting, component references and argument schemas |
| `Invoke-ScriptAnalyzer` (pwsh) | PowerShell lint. Bundles the Windows PowerShell 5.1 **compatibility profiles**, so `PSUseCompatibleSyntax` / `PSUseCompatibleCommands` can catch 7.x-only syntax that would fail on a 5.1 guest. |
| `shellcheck` | shell lint; also what this repo's `make lint` and pre-commit hook run |
| `bats` | shell test runner; this repo's `make test` |
| `magick` (ImageMagick), Pillow (`python3-pil`) | image conversion and inspection; backs `airlock paste` where the clipboard offers BMP |

**Deliberately out of scope**, because they need the network and would otherwise degrade to
a no-op in a box: `terraform init` / `validate`, `tflint --init` (external rulesets),
`ansible-galaxy collection install`, bare `vector validate`, and `alloy run` (which starts
the components and reports usage upstream). They fail rather than lie. A project that
really needs one opens a narrow `egress =` in `.airlock/config` for a one-time fetch, and
caches the result with `artifact_dirs` (e.g. `.terraform`), which persists across sessions.

**Two settings are load-bearing:**

- `ANSIBLE_LINT_NODEPS=1` forces ansible-lint's offline mode. By default it installs
  `requirements.yml` collections and refreshes JSON schemas over the network. The firewall
  **drops** rather than rejects, so that would stall instead of failing.
- `POWERSHELL_UPDATECHECK=Off` and `POWERSHELL_TELEMETRY_OPTOUT=1` do the same for pwsh's
  startup update check.

**`make image-smoke` proves the table.** It runs each validator inside a real box at
minimal egress against a **known-bad** fixture, and fails if the tool accepts it. Checking
only that valid input passes would not catch a validator that has quietly stopped
validating. It also covers the offline halves of the infra clients (`kubectl kustomize`,
`helm lint|template`, `sops filestatus`), plus node, pwsh and `airlock-pg-start`.

## What is pinned

In `:base` and `:dev`, the validators and infra clients (except `drill`, which is a Debian
package) are pinned by version and sha256 in `image/dev/Dockerfile`, and so is everything
else those images download. `:playwright` is not pinned: it installs Playwright and Chromium
with npm and Playwright's own installer, at whatever version is current.

- Node, by tarball checksum;
- the ansible-lint venv, by a hash for every package (`image/dev/ansible-requirements.txt`);
- Claude Code, through a vendored copy of its installer (`image/claude-install.sh`), which
  checks the binary against the release manifest. `make claude-installer-diff` shows what
  upstream has changed; see [install.md](install.md#the-claude-code-installer-is-vendored).
- shellcheck and bats too (not apt), at the same versions `make bootstrap` vendors and CI
  runs, so lint results cannot differ between CI and a box. (A host with its own system
  shellcheck uses that one: `.tooling/` sits in a directory boxes can write to.)

Only the Debian packages float, on the weekly refresh.

## Corporate or internal CA certificates

If you sit behind a TLS-inspecting proxy, or need to reach internal HTTPS services whose
certificates chain to a private PKI, give the images your CA chain. Put it in the host's own
directory, root's, kept with the rest of the host's config, and rebuild:

```sh
sudo install -d -m 0755 /etc/claude-airlock/ca
sudo install -m 0644 /path/to/your-root-ca.crt /etc/claude-airlock/ca/
make install-airlock          # rebuild the images
```

- `make install-airlock` checks every `.crt` there and lists each certificate's subject and
  fingerprint. It refuses the directory or a file that is a link, isn't root's, or is writable
  by group or others: every image trusts what is there, so whoever can write it can get into
  every box's trust. Each file must hold PEM CA certificates (`CA:TRUE`) and nothing else: no
  leaf certificates, **never private keys**.
- `AIRLOCK_CA_REQUIRED=1` in the host config makes an install with no CA certificate an error,
  for hosts that can't work without one. `AIRLOCK_CA_DIR` names another directory (same rules).
- Without the host directory, the install takes `image/certs/` in the clone instead (untracked
  by design; the same certificate checks, but not the ownership ones). Use it only where you
  have no root.
- Nothing here is needed on a normal home network; with no certificates the CA layer is a no-op.
- The chain is trusted by curl, git and Python only, never by Node, so Claude's own TLS
  stays on its built-in roots (see [security-model.md](security-model.md#a-private-ca-chain-stays-out-of-claudes-own-tls)).
