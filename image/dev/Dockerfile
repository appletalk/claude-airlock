# claude-airlock dev base (layer 1) - the base plus the language runtimes most
# projects need to actually run: Python, Node.js, PowerShell, a C build toolchain,
# and the config validators that lint infrastructure-as-code offline.
#
# This is the default image for real work. Toolchains that need to DOWNLOAD a
# per-project dependency graph before they can do anything (Terraform providers,
# Ansible collections, tflint ruleset plugins) are deliberately NOT enabled here:
# see the "config validators" section below for exactly what is and is not in
# scope. Genuinely heavy, specialized stacks (Playwright browsers) still go in
# opt-in images layered on top of THIS one.
FROM claude-airlock:base

USER root
ENV DEBIAN_FRONTEND=noninteractive

# Python + a C/C++ build toolchain (many pip packages compile native extensions).
# python3-yaml + yamllint are the DISTRO packages (not pip), so they need no PyPI
# egress and match the system python — they cover the near-universal "parse/lint
# YAML" need (pre-commit hooks, config/registry scripts) that would otherwise force
# a project to open PyPI just to `import yaml`. This is for ubiquitous system-level
# tooling only; project-specific deps still go in the project's own venv (which,
# being isolated, won't see these unless it needs `airlock egress pypi`).
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 \
      python3-pip \
      python3-venv \
      python3-dev \
      python-is-python3 \
      python3-yaml \
      yamllint \
      build-essential \
      pkg-config \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# PostgreSQL (server + client) for projects with DB-backed tests. Present but
# NOT running — it costs only disk until a project starts it on demand with
# `airlock-pg-start` (localhost:5432). Postgres is the only DB in the stack, so
# it lives in the dev base rather than a separate opt-in image.
RUN apt-get update && apt-get install -y --no-install-recommends \
      postgresql postgresql-client \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
COPY airlock-pg-start /usr/local/bin/airlock-pg-start
RUN chmod 0555 /usr/local/bin/airlock-pg-start

# Node.js 24 from the official multi-distro binary tarball (nodejs.org), NOT apt
# or NodeSource. This keeps the layer distro-agnostic: the exact same step ports
# to Ubuntu / Arch base variants unchanged. Picks the newest v24.x at build time.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) narch=x64 ;; \
      arm64) narch=arm64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    ver="$(curl -fsSL https://nodejs.org/dist/index.json \
             | jq -r '[.[] | select(.version | startswith("v24."))][0].version')"; \
    test -n "$ver" && test "$ver" != null; \
    curl -fsSL "https://nodejs.org/dist/${ver}/node-${ver}-linux-${narch}.tar.xz" -o /tmp/node.tar.xz; \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 --no-same-owner; \
    rm /tmp/node.tar.xz; \
    node --version; npm --version

# ============================================================================
# Config validators - SYNTAX AND LINT ONLY, and offline by construction.
# ============================================================================
# Every tool below runs to completion with the firewall at its default minimal
# egress. That is the whole design rule: a validator that needs the network is a
# validator that silently degrades to a no-op inside a box, and a no-op that
# reports success is worse than an absent tool.
#
# IN SCOPE (verified by scripts/image-smoke.sh, which runs each of these against
# a known-bad fixture at minimal egress and fails if the tool passes it):
#   promtool check config|rules      Prometheus config + alerting/recording rules
#   promtool test rules              rule unit tests
#   terraform fmt -check             HCL syntax + formatting (exit 3 = drift, 2 = syntax error)
#   tflint                           the terraform ruleset bundled INSIDE the binary
#   ansible-lint                     playbook/role lint, offline (see ANSIBLE_LINT_NODEPS)
#   vector validate --no-environment config parse + topology, no component/health checks
#   Invoke-ScriptAnalyzer            PowerShell script lint
#
# OUT OF SCOPE - these need the network and are expected to FAIL LOUDLY in a box:
#   terraform init / validate        pulls providers from registry.terraform.io
#   tflint --init                    pulls external rulesets (aws, azurerm, ...) from GitHub
#   ansible-galaxy collection install pulls from galaxy.ansible.com
#   vector validate (no flag)        opens sinks and runs health checks
# A project that needs those opens a narrow `egress =` in .airlock/config for a
# one-time fetch and caches the result via `artifact_dirs` (e.g. `.terraform`),
# which persists across sessions. It is not this image's job to guess a provider
# or collection set.
#
# Downloads are pinned by version AND sha256 (per arch). Unlike the Node layer
# above, which trusts TLS alone, these pins also detect an upstream re-tag: a
# rebuild either produces the same validator or fails.

# unzip: terraform and tflint ship zips, and nothing else in the image needs it.
RUN apt-get update && apt-get install -y --no-install-recommends unzip \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# promtool from the Prometheus release tarball. Only the promtool binary is
# extracted; the prometheus server itself is ~half the tarball and we never run it.
ARG PROMETHEUS_VERSION=3.13.1
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) parch=amd64; sha=962b812371aff838d152b6ff2d56fdb7a6396f5542f48ebf73421b9721f0d103 ;; \
      arm64) parch=arm64; sha=fbd8e5e0f6ad2e7d053e717739186caee4fd0cab2cf9335bfc86c292fe2a2bfe ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    d="prometheus-${PROMETHEUS_VERSION}.linux-${parch}"; \
    curl -fsSL "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/${d}.tar.gz" -o /tmp/prom.tgz; \
    echo "${sha}  /tmp/prom.tgz" | sha256sum -c -; \
    tar -xzf /tmp/prom.tgz -C /usr/local/bin --strip-components=1 --no-same-owner "${d}/promtool"; \
    rm /tmp/prom.tgz; \
    chmod 0555 /usr/local/bin/promtool; \
    promtool --version

# terraform: `fmt` only (see scope note above). tflint carries its terraform
# ruleset inside the binary, so it lints with no plugin download.
ARG TERRAFORM_VERSION=1.15.8
ARG TFLINT_VERSION=0.64.0
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) tfsha=d25ce7b6902013ad905db3d2eab0be4cd905887fe88b81a6171b8d5503c31f3d; \
             tlsha=cca9d13e2e1d7a2c627af60ff899a3c9b74212899416aeb96ec764d2ef954537 ;; \
      arm64) tfsha=8891e9dcedc9e3b8950bc6af9d4d8af1f4cfade3062f53b9dc403a89f6ce8c9c; \
             tlsha=560da89aacf59389d4eb029730dd5b109b7288096c32f2726a0d9e783a5ea8eb ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${arch}.zip" -o /tmp/tf.zip; \
    echo "${tfsha}  /tmp/tf.zip" | sha256sum -c -; \
    unzip -q /tmp/tf.zip -d /usr/local/bin terraform; \
    curl -fsSL "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_linux_${arch}.zip" -o /tmp/tflint.zip; \
    echo "${tlsha}  /tmp/tflint.zip" | sha256sum -c -; \
    unzip -q /tmp/tflint.zip -d /usr/local/bin tflint; \
    rm /tmp/tf.zip /tmp/tflint.zip; \
    chmod 0555 /usr/local/bin/terraform /usr/local/bin/tflint; \
    terraform version; tflint --version
# Terraform phones home for version checks on some commands; CHECKPOINT_DISABLE
# turns that off so `fmt` never waits on a blocked domain.
ENV CHECKPOINT_DISABLE=1

# vector: the musl static build, so the binary carries its own libc and stays
# decoupled from the Debian base.
ARG VECTOR_VERSION=0.57.0
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) varch=x86_64;  sha=b04fafcffcbeb3d43cbba587583dbe3338b24dd34256b3967fb15d137aff75f2 ;; \
      arm64) varch=aarch64; sha=81cec5343e49985351e13f76ae3d550d7b0f0ac64fd4d88c07e3873bdfdf100a ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/vectordotdev/vector/releases/download/v${VECTOR_VERSION}/vector-${VECTOR_VERSION}-${varch}-unknown-linux-musl.tar.gz" -o /tmp/vector.tgz; \
    echo "${sha}  /tmp/vector.tgz" | sha256sum -c -; \
    mkdir -p /tmp/vector-x; \
    tar -xzf /tmp/vector.tgz -C /tmp/vector-x --no-same-owner; \
    install -m 0555 "$(find /tmp/vector-x -type f -name vector -perm -u+x | head -1)" /usr/local/bin/vector; \
    rm -rf /tmp/vector.tgz /tmp/vector-x; \
    vector --version

# PowerShell from the upstream tarball (Microsoft publishes no trixie apt repo,
# and the tarball keeps this layer distro-agnostic like the Node one above).
# PSScriptAnalyzer is installed from its PSGallery .nupkg (a zip) into the
# AllUsers module path: the box's $HOME is a fresh mount every session, so a
# CurrentUser install would vanish. Baking it here is also what makes the linter
# work with zero egress.
ARG POWERSHELL_VERSION=7.6.4
ARG PSSCRIPTANALYZER_VERSION=1.25.0
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) parch=x64;   sha=4471b5a36bfe86ec7af8525d36bb1cacba0128e7aac22d05cc064bc00e604721 ;; \
      arm64) parch=arm64; sha=d4ef2382fa452f2ccbdb48a01adbbce9ed64954872123970c16be6d086d1224b ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/powershell-${POWERSHELL_VERSION}-linux-${parch}.tar.gz" -o /tmp/pwsh.tgz; \
    echo "${sha}  /tmp/pwsh.tgz" | sha256sum -c -; \
    mkdir -p /opt/microsoft/powershell/7; \
    tar -xzf /tmp/pwsh.tgz -C /opt/microsoft/powershell/7 --no-same-owner; \
    chmod 0555 /opt/microsoft/powershell/7/pwsh; \
    ln -s /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh; \
    rm /tmp/pwsh.tgz; \
    mod=/usr/local/share/powershell/Modules/PSScriptAnalyzer; \
    mkdir -p "$mod"; \
    curl -fsSL "https://www.powershellgallery.com/api/v2/package/PSScriptAnalyzer/${PSSCRIPTANALYZER_VERSION}" -o /tmp/pssa.nupkg; \
    echo "14e634c828eb98efb9f40b2918ba90f139ed5eccdf663a2a747736d996995d60  /tmp/pssa.nupkg" | sha256sum -c -; \
    unzip -q /tmp/pssa.nupkg -d "$mod"; \
    rm -rf /tmp/pssa.nupkg "$mod/_rels" "$mod/package" "$mod/[Content_Types].xml"; \
    chmod -R a+rX /usr/local/share/powershell
# pwsh phones home on startup (update check) and ships usage telemetry. In a box
# those domains are blocked, so leaving them on buys a DNS/connect stall on every
# single invocation and nothing else.
ENV POWERSHELL_TELEMETRY_OPTOUT=1 \
    POWERSHELL_UPDATECHECK=Off \
    DOTNET_CLI_TELEMETRY_OPTOUT=1

# ansible-lint in its own venv: trixie's system python is externally-managed
# (PEP 668), and the isolation also keeps ansible-core's dependency tree from
# ever colliding with a project's own .venv. Only the entry points are exposed.
#
# ANSIBLE_LINT_NODEPS is the load-bearing line. By default ansible-lint installs
# requirements.yml collections and refreshes its JSON schemas over the network at
# runtime; against a DROP rule those HANG rather than fail. The env var forces
# offline mode (src/ansiblelint/config.py: nodeps -> offline -> no schema refresh),
# which is the difference between a linter and a stall.
ARG ANSIBLE_LINT_VERSION=26.6.0
RUN set -eux; \
    python3 -m venv /opt/ansible; \
    /opt/ansible/bin/pip install --no-cache-dir "ansible-lint==${ANSIBLE_LINT_VERSION}"; \
    for b in ansible ansible-playbook ansible-galaxy ansible-doc ansible-lint; do \
      ln -s "/opt/ansible/bin/$b" "/usr/local/bin/$b"; \
    done; \
    ansible-lint --version
ENV ANSIBLE_LINT_NODEPS=1

# ENTRYPOINT / CMD / USID(root) / WORKDIR are all inherited from the base image:
# the entrypoint still raises the firewall as root, then drops to the dev user.
