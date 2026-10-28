# claude-airlock dev base (layer 1) - the base plus the developer tools (git, gh, make,
# an editor and pager, ripgrep), the language runtimes most projects need to actually run
# (Python, Node.js, PowerShell, a C build toolchain), and the config validators that lint
# infrastructure-as-code offline.
#
# This is the default image for real work. Toolchains that need to DOWNLOAD a
# per-project dependency graph before they can do anything (Terraform providers,
# Ansible collections, tflint ruleset plugins) are deliberately NOT enabled here:
# see the "config validators" section below for exactly what is and is not in
# scope. Genuinely heavy, specialized stacks (Playwright browsers) still go in
# opt-in images layered on top of THIS one.
# install.sh builds each commit under its own tags and retags only when both builds succeed.
#
# Built FROM the base's `os` stage (everything but Claude Code), with the base's Claude
# Code install copied in as the very last layer. A Claude Code release then rebuilds one
# small layer here instead of every toolchain layer, and the dev image carries exactly
# the binary the base image shipped (and doctor tested), not a second, separate install.
ARG BASE_IMAGE=claude-airlock:base
ARG OS_IMAGE=claude-airlock:os
FROM ${BASE_IMAGE} AS claude

# Envoy, fetched and verified in a throwaway stage so gpg and the key never reach the image
# (only the binary is copied in, in the validators section below). Verified as airlock-envoy's
# install-envoy.sh does it: the release's checksum list must carry a good signature from the
# pinned Envoy maintainers key (envoy-release-key.asc, the same file as airlock-envoy's), and
# the binary must match its line in that list. A re-signed or re-tagged release fails the
# build. Bump: ENVOY_VERSION, and the key only if the maintainers rotate it.
FROM ${OS_IMAGE} AS envoy
USER root
ARG ENVOY_VERSION=1.40.2
ARG ENVOY_KEY_FPR=0AFCE836BA4D1D35763C8523D8CDC3750181F31F
COPY envoy-release-key.asc /tmp/envoy-release-key.asc
RUN set -eux; \
    apt-get update; apt-get install -y --no-install-recommends gnupg; apt-get clean; \
    case "$(dpkg --print-architecture)" in \
      amd64) earch=x86_64 ;; \
      arm64) earch=aarch_64 ;; \
      *) echo "unsupported arch" >&2; exit 1 ;; \
    esac; \
    bin="envoy-${ENVOY_VERSION}-linux-${earch}"; \
    url="https://github.com/envoyproxy/envoy/releases/download/v${ENVOY_VERSION}"; \
    export GNUPGHOME="$(mktemp -d)"; \
    gpg --batch --quiet --import /tmp/envoy-release-key.asc; \
    gpg --batch --with-colons --fingerprint | awk -F: '$1 == "fpr" { print $10; exit }' | grep -qx "$ENVOY_KEY_FPR"; \
    mkdir /out; cd /out; \
    curl -fsSL -o checksums.txt.asc "$url/checksums.txt.asc"; \
    curl -fsSL -o "$bin" "$url/$bin"; \
    gpg --batch --status-fd 1 --verify checksums.txt.asc 2>/dev/null > status; \
    awk -v f="$ENVOY_KEY_FPR" '$2 == "VALIDSIG" && $NF == f { ok = 1 } \
      $2 ~ /^(REVKEYSIG|EXPKEYSIG|EXPSIG|BADSIG|ERRSIG|ERROR|FAILURE|NODATA)$/ { bad = 1 } \
      END { exit !(ok && !bad) }' status; \
    gpg --batch --quiet --decrypt checksums.txt.asc 2>/dev/null > list; \
    awk -v f="$bin" '{ n = $2; sub(/.*\//, "", n) } n == f && !done { print $1 "  " f; done = 1 }' list > sum; \
    test -s sum; \
    sha256sum -c sum; \
    install -m 0555 "$bin" /out/envoy; \
    /out/envoy --version | grep -F "/${ENVOY_VERSION}/"

FROM ${OS_IMAGE}

USER root
ENV DEBIAN_FRONTEND=noninteractive

# Every Debian package the dev image adds, in ONE layer (one index fetch, one snapshot of
# the archive). What each group is for:
#
# Developer tools: git, gh, make, less, vim, zsh, ripgrep. The base keeps only what runs
# Claude Code and the airlock machinery, so these come in here. git must stay in this
# layer: the bats install below clones with it.
#
# Python + a C/C++ build toolchain (many pip packages compile native extensions).
# python3-yaml + yamllint are the DISTRO packages (not pip), so they need no PyPI
# egress and match the system python — they cover the near-universal "parse/lint
# YAML" need (pre-commit hooks, config/registry scripts) that would otherwise force
# a project to open PyPI just to `import yaml`. cryptography, requests and openpyxl
# are here for the same reason: ad-hoc scripts reach for them constantly, and a box
# with minimal egress cannot pip install them (an ad-hoc venv sees them with
# `python3 -m venv --system-site-packages`). This is for ubiquitous system-level
# tooling only; project-specific deps still go in the project's own venv (which,
# being isolated, won't see these unless it needs `airlock egress pypi`).
#
# ImageMagick and Pillow back `airlock paste`: WSLg offers BMP, the Claude API takes
# PNG/JPEG/GIF/WebP, so without a converter a paste on that platform fails. They also
# let an agent generate image fixtures and VERIFY what it produced (real format, real
# dimensions) rather than trusting a file it just wrote.
#
# PostgreSQL (server + client) for projects with DB-backed tests. Present but NOT
# running — it costs only disk until a project starts it on demand with
# `airlock-pg-start` (localhost:5432). Postgres is the only DB in the stack, so it
# lives in the dev base rather than a separate opt-in image.
#
# unzip: terraform, tflint, alloy and the PSScriptAnalyzer .nupkg ship as zips.
# drill (ldnsutils) sits beside dnsutils' dig for hosts whose tooling standardizes on ldns.
# luajit runs Lua written for Envoy's Lua filter (LuaJIT, Lua 5.1) outside Envoy: unit tests.
# acl (setfacl, getfacl): tools that render or check socket ACLs (airlock-envoy's parser suite)
# need it on PATH. It grants nothing chmod can't: only a file's owner may change its ACL.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      gh \
      make \
      less \
      vim \
      zsh \
      ripgrep \
      python3 \
      python3-pip \
      python3-venv \
      python3-dev \
      python-is-python3 \
      python3-yaml \
      yamllint \
      python3-cryptography \
      python3-requests \
      python3-openpyxl \
      build-essential \
      pkg-config \
      imagemagick \
      python3-pil \
      postgresql \
      postgresql-client \
      unzip \
      ldnsutils \
      luajit \
      acl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
COPY airlock-pg-start /usr/local/bin/airlock-pg-start
RUN chmod 0555 /usr/local/bin/airlock-pg-start

# Shell lint + test: shellcheck and bats are what this repo's OWN gates run (`make lint`,
# `make test`, hooks/pre-commit). Without them in the image, developing claude-airlock
# from inside a box means the pre-commit hook takes its lenient "tool not found —
# skipping" branch and exits 0 having checked NOTHING.
#
# Pinned, NOT apt: lint findings depend on the shellcheck version (0.11 added checks
# 0.10 does not have), and Debian's, Ubuntu's and Arch's packages all differ, so an apt
# install let the box, CI and a host disagree about whether the tree is clean. The same
# versions are pinned in scripts/bootstrap-tools.sh, which is what CI and `make
# bootstrap` use; test/install.bats fails if the two drift. shellcheck is a release
# tarball checked by sha256; bats is a git checkout of the release tag verified against
# its commit id (bats publishes no release artifact, and GitHub's generated tag archives
# are not guaranteed byte-stable).
ARG SHELLCHECK_VERSION=0.11.0
ARG BATS_VERSION=1.14.0
ARG BATS_COMMIT=eb7f42f8d608ac693d7a4b67474f6714ea68cfc5
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) scarch=x86_64;  sha=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 ;; \
      arm64) scarch=aarch64; sha=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.${scarch}.tar.xz" -o /tmp/sc.txz; \
    echo "${sha}  /tmp/sc.txz" | sha256sum -c -; \
    tar -xJf /tmp/sc.txz -C /tmp --no-same-owner "shellcheck-v${SHELLCHECK_VERSION}/shellcheck"; \
    install -m 0555 "/tmp/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck; \
    rm -rf /tmp/sc.txz "/tmp/shellcheck-v${SHELLCHECK_VERSION}"; \
    git -c advice.detachedHead=false clone -q --depth 1 --branch "v${BATS_VERSION}" \
      https://github.com/bats-core/bats-core.git /tmp/bats; \
    test "$(git -C /tmp/bats rev-parse HEAD)" = "$BATS_COMMIT"; \
    /tmp/bats/install.sh /usr/local >/dev/null; \
    rm -rf /tmp/bats; \
    shellcheck --version; bats --version

# Node.js 24 from the official multi-distro binary tarball (nodejs.org), NOT apt
# or NodeSource. This keeps the layer distro-agnostic: the exact same step ports
# to Ubuntu / Arch base variants unchanged. Pinned by version + sha256 per arch like
# every other upstream binary below (the checksums are nodejs.org's SHASUMS256.txt for
# the release); it used to float to "newest v24.x at build time" on TLS alone, the one
# download in the image a re-tag or a bad mirror could change silently. Bump with the
# other pins.
ARG NODE_VERSION=24.22.1
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) narch=x64;   sha=6c172a9ab6718f7b801fb5a7bd486af2ee5e32758086a04b84fcce2aa77095e6 ;; \
      arm64) narch=arm64; sha=dbabf7a1cbf947e6059ffad2c27b80041db97dea1e553b62afdee7f13fca336e ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${narch}.tar.xz" -o /tmp/node.tar.xz; \
    echo "${sha}  /tmp/node.tar.xz" | sha256sum -c -; \
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
#   alloy fmt -t / alloy validate    Alloy syntax + component/argument schema check
#   Invoke-ScriptAnalyzer            PowerShell script lint
#
# OUT OF SCOPE - these need the network and are expected to FAIL LOUDLY in a box:
#   terraform init / validate        pulls providers from registry.terraform.io
#   tflint --init                    pulls external rulesets (aws, azurerm, ...) from GitHub
#   ansible-galaxy collection install pulls from galaxy.ansible.com
#   vector validate (no flag)        opens sinks and runs health checks
#   alloy run                        starts the components and reports usage upstream
# A project that needs those opens a narrow `egress =` in .airlock/config for a
# one-time fetch and caches the result via `artifact_dirs` (e.g. `.terraform`),
# which persists across sessions. It is not this image's job to guess a provider
# or collection set.
#
# Downloads are pinned by version AND sha256 (per arch). Unlike the Node layer
# above, which trusts TLS alone, these pins also detect an upstream re-tag: a
# rebuild either produces the same validator or fails.

# promtool from the Prometheus release tarball. Only the promtool binary is
# extracted; the prometheus server itself is ~half the tarball and we never run it.
ARG PROMETHEUS_VERSION=3.15.1
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) parch=amd64; sha=6a726885328ad9efebbf36e876ce2fb6225468a71fd1e7ce3ba666d5f4d97a84 ;; \
      arm64) parch=arm64; sha=ceb6d21493c37ca0b4513b147642797c68cf39a0f50a444d50e1e80c74f21b26 ;; \
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
ARG TERRAFORM_VERSION=1.17.0
ARG TFLINT_VERSION=0.65.0
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) tfsha=c168cab7c637a8769fdb90089ddd19de701bc6ff8aca64dc2e2185fe46f59f67; \
             tlsha=d4c545ed2e29d6338604b586f34f544f380f70f243aa72f7b484713835eaec61 ;; \
      arm64) tfsha=f32478134ffc6d710eec474bbd316652cdddc0f4e336973a3745e8d3a3309cdf; \
             tlsha=843017c47a98be1de4d88fa038daa293770fe25cd01656c4f08b2e30d1d3b3a0 ;; \
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
ARG VECTOR_VERSION=0.60.0
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) varch=x86_64;  sha=9584f402e67fea7ff2dd846f0a8bbb56fa32951bded11749093ff3780e1513cf ;; \
      arm64) varch=aarch64; sha=e2984f826aa61bf3ea98fba4cccde2437f645794b2f8a3d45c97df9594dcfbd1 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/vectordotdev/vector/releases/download/v${VECTOR_VERSION}/vector-${VECTOR_VERSION}-${varch}-unknown-linux-musl.tar.gz" -o /tmp/vector.tgz; \
    echo "${sha}  /tmp/vector.tgz" | sha256sum -c -; \
    mkdir -p /tmp/vector-x; \
    tar -xzf /tmp/vector.tgz -C /tmp/vector-x --no-same-owner; \
    install -m 0555 "$(find /tmp/vector-x -type f -name vector -perm -u+x | head -1)" /usr/local/bin/vector; \
    rm -rf /tmp/vector.tgz /tmp/vector-x; \
    vector --version

# Grafana Alloy: `fmt` and `validate` only. Both are pure config-graph work -- they
# parse the river/Alloy syntax, resolve component references and check every
# argument against the component's schema without starting a single component, so
# they complete at minimal egress. `alloy run` is the out-of-scope half: it opens
# the UI port, starts the components, and reports usage to Grafana.
#
# Note the size: this is a ~450MB binary (every component plus the embedded UI are
# linked in, and Go binaries don't strip usefully). It is the single largest tool
# in the image -- roughly promtool + terraform + vector combined.
ARG ALLOY_VERSION=1.21.2
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) sha=1eadb46a0640127184250173acd9b4145e4d590680db37ffe66fa8afd07f04cf ;; \
      arm64) sha=3722a7494bce5ff100c18f0051e63799ad9e89546ca75022cb1dc8dc676af401 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/grafana/alloy/releases/download/v${ALLOY_VERSION}/alloy-linux-${arch}.zip" -o /tmp/alloy.zip; \
    echo "${sha}  /tmp/alloy.zip" | sha256sum -c -; \
    unzip -q -o /tmp/alloy.zip -d /tmp "alloy-linux-${arch}"; \
    install -m 0555 "/tmp/alloy-linux-${arch}" /usr/local/bin/alloy; \
    rm -f /tmp/alloy.zip "/tmp/alloy-linux-${arch}"; \
    alloy --version

# Envoy: `envoy --mode validate -c <config>` checks a config (schema, references, filters)
# without opening a listener or an upstream connection. The binary also runs a whole proxy
# in a box, against local upstreams only (minimal egress), to test a config end to end; give
# it --disable-hot-restart (no shared memory segment) and a writable --base-id-path if any.
# Fetched and verified in the envoy stage at the top of this file.
COPY --from=envoy /out/envoy /usr/local/bin/envoy
RUN envoy --version

# PowerShell from the upstream tarball (Microsoft publishes no trixie apt repo,
# and the tarball keeps this layer distro-agnostic like the Node one above).
# PSScriptAnalyzer is installed from its PSGallery .nupkg (a zip) into the
# AllUsers module path: the box's $HOME is a fresh mount every session, so a
# CurrentUser install would vanish. Baking it here is also what makes the linter
# work with zero egress.
ARG POWERSHELL_VERSION=7.6.9
ARG PSSCRIPTANALYZER_VERSION=1.25.0
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) parch=x64;   sha=1da6d6d6035d651f20e70ddee7c4c15ac6ab8b9fb40ee92240d91263f28a884b ;; \
      arm64) parch=arm64; sha=02eb9991af447c7e7fe881acde195961afd397c40b8eb1c2b3856b84ec2d85f2 ;; \
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
#
# Every package in the venv is pinned by version AND sha256 in ansible-requirements.txt
# (pip-compile --generate-hashes from `ansible-lint==<version>`), installed with
# --require-hashes. Pinning only the top package left its ~30 dependencies to resolve
# fresh at every build, so a rebuild could pull a different tree - or a poisoned one -
# without anything in the repo changing. To bump: edit the version in the .in line at
# the top of that file's header, regenerate with pip-compile in a box, review the diff.
#
# Set BEFORE the install so the build-time `ansible-lint --version` runs the way every
# box will: offline, with no PyPI version check.
#
# ansible-lint is exposed through a wrapper rather than a symlink: it expects its own
# venv's bin dir on PATH (to find ansible-playbook and friends) and, when it is not,
# prepends it itself with a "PATH altered ... broken local setup" WARNING on every run.
# The wrapper puts the venv first for that one process only; putting /opt/ansible/bin on
# the box's global PATH would also expose the venv's python, pip and yamllint.
ENV ANSIBLE_LINT_NODEPS=1
COPY ansible-requirements.txt /tmp/ansible-requirements.txt
RUN set -eux; \
    python3 -m venv /opt/ansible; \
    /opt/ansible/bin/pip install --no-cache-dir --require-hashes -r /tmp/ansible-requirements.txt; \
    rm -f /tmp/ansible-requirements.txt; \
    for b in ansible ansible-playbook ansible-galaxy ansible-doc; do \
      ln -s "/opt/ansible/bin/$b" "/usr/local/bin/$b"; \
    done; \
    printf '%s\n' '#!/bin/sh' 'PATH="/opt/ansible/bin:$PATH" exec /opt/ansible/bin/ansible-lint "$@"' \
      > /usr/local/bin/ansible-lint; \
    chmod 0555 /usr/local/bin/ansible-lint; \
    ansible-lint --version

# ============================================================================
# Infra clients - kubectl, helm, sops, tea, drill.
# ============================================================================
# Unlike the validators above these are clients: they are only useful against an
# endpoint the project grants via `egress =` (an apiserver `IPv4:port`, a Forgejo
# host), and they ship with NO credentials. A kubeconfig, token or age key is a
# host-side grant, never baked in. The offline halves still work at minimal egress:
# `helm lint|template` on a local chart, `kubectl kustomize`, `sops filestatus`.
# Pinned by version + sha256 per arch, same as the validators. drill comes from the apt
# layer at the top.
ARG KUBECTL_VERSION=1.37.2
ARG HELM_VERSION=4.3.1
ARG SOPS_VERSION=3.13.3
ARG TEA_VERSION=0.16.0
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) kcsha=c04487523e7aa7d1493f7808174c899db93d7a9cf57531420cd76b9bd415f8f4; \
             hmsha=0403a88ae20913d11b10a2467b50087721fea7581736da6b9d3992f5357fe54b; \
             spsha=e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b; \
             tesha=9c142c8a0b31485eea2387031c1c404f12b7141075eb4ffbd7ced49441590636 ;; \
      arm64) kcsha=fcc16f63186659d9722014b7e02d5fdd2d4e669cb8c0ab66365d7d3b8ba03509; \
             hmsha=8cf8f66ecbc252ac8f7f06cca68aba88508ddfde3a6a34feb1678ad1694b4f88; \
             spsha=53b0abacd38ef1b12a66d6c100956691b9cefce018d91f81e73ddf7438b94d77; \
             tesha=0e14a036322eeb1fc55e266acafeb8490e523ed99f9232034ae74861e2339879 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" -o /tmp/kubectl; \
    echo "${kcsha}  /tmp/kubectl" | sha256sum -c -; \
    install -m 0555 /tmp/kubectl /usr/local/bin/kubectl; \
    curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${arch}.tar.gz" -o /tmp/helm.tgz; \
    echo "${hmsha}  /tmp/helm.tgz" | sha256sum -c -; \
    tar -xzf /tmp/helm.tgz -C /usr/local/bin --strip-components=1 --no-same-owner "linux-${arch}/helm"; \
    chmod 0555 /usr/local/bin/helm; \
    curl -fsSL "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${arch}" -o /tmp/sops; \
    echo "${spsha}  /tmp/sops" | sha256sum -c -; \
    install -m 0555 /tmp/sops /usr/local/bin/sops; \
    curl -fsSL "https://dl.gitea.com/tea/${TEA_VERSION}/tea-${TEA_VERSION}-linux-${arch}" -o /tmp/tea; \
    echo "${tesha}  /tmp/tea" | sha256sum -c -; \
    install -m 0555 /tmp/tea /usr/local/bin/tea; \
    rm -f /tmp/kubectl /tmp/helm.tgz /tmp/sops /tmp/tea; \
    kubectl version --client; helm version --short; sops --version --disable-version-check; tea --version; drill -v
# sops checks GitHub for a newer release; blocked in a box, that is a stall per call.
ENV SOPS_DISABLE_VERSION_CHECK=1

# Claude Code LAST: copied from the base image built alongside this one (see the top of
# this file). Only ~/.local: the rest of the base's $HOME is installer residue that the
# launcher's mounts (~/.claude, ~/.claude.json) cover at runtime anyway.
COPY --from=claude --chown=dev:dev /home/dev/.local /home/dev/.local
RUN gosu dev claude --version

# ENTRYPOINT / CMD / USER(root) / WORKDIR / PATH are all inherited from the base's `os`
# stage: the entrypoint still raises the firewall as root, then drops to the dev user.
