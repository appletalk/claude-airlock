# claude-airlock dev base (layer 1) — the base plus the language runtimes most
# projects need to actually run: Python, Node.js, and a C build toolchain.
#
# This is the default image for real work. Heavy/specialized toolchains
# (Playwright browsers, Terraform, Ansible, ...) go in opt-in stacks layered on
# top of THIS image, not here.
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

# ENTRYPOINT / CMD / USID(root) / WORKDIR are all inherited from the base image:
# the entrypoint still raises the firewall as root, then drops to the dev user.
