# claude-airlock base image (layer 0)
#
# Debian trixie-slim (current Debian stable) is the minimal base. Ubuntu / Arch
# variants are a FROM + package-list swap away — the firewall, entrypoint, and
# launcher are all OS-agnostic, so they carry over unchanged.
FROM debian:trixie-slim

ARG TZ=UTC
ENV TZ="$TZ"
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      gh \
      jq \
      make \
      ripgrep \
      iptables \
      ipset \
      iproute2 \
      dnsutils \
      aggregate \
      gosu \
      less \
      vim \
      zsh \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Optional internal/corporate CA chain. Drop your org's CA certs (public certs
# only — never private keys) into image/certs/ and they are trusted by external
# tooling in the box (curl, git, the Python HTTP stack), so it can reach internal
# HTTPS services whose leaf certs chain to a private PKI. The directory is empty
# by default and the build is a no-op without it.
#
# update-ca-certificates folds them into the system store, which curl/git and
# Python's ssl module use by default; REQUESTS_CA_BUNDLE/SSL_CERT_FILE extend that
# to requests/httpx (which otherwise use their own certifi bundle). Deliberately
# NOT added to Node's trust: Claude Code talks to api.anthropic.com over Node TLS,
# and we keep that on its vetted built-in Mozilla roots rather than widening it with
# a private PKI it doesn't need.
#
# COPY of the directory (not a *.crt glob) so an empty certs/ still builds;
# update-ca-certificates ignores the non-.crt placeholder.
COPY certs/ /usr/local/share/ca-certificates/
RUN update-ca-certificates
ENV REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

# Unprivileged user the agent runs as. UID 1000 matches a typical host user, so
# bind-mounted files line up without chown gymnastics.
ARG USERNAME=dev
RUN groupadd -g 1000 ${USERNAME} \
    && useradd -m -u 1000 -g ${USERNAME} -s /bin/bash ${USERNAME} \
    && mkdir -p /home/${USERNAME}/.claude /workspace \
    && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME} /workspace

# Egress policy + init script: root-owned, NOT writable by the agent.
RUN mkdir -p /etc/airlock
COPY firewall.conf /etc/airlock/firewall.conf
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY entrypoint.sh /usr/local/bin/airlock-entrypoint
RUN chmod 0444 /etc/airlock/firewall.conf \
    && chmod 0555 /usr/local/bin/init-firewall.sh /usr/local/bin/airlock-entrypoint

# Install Claude Code as the agent user (native, self-contained installer).
USER ${USERNAME}
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/${USERNAME}/.local/bin:${PATH}"

# Container starts as root so the entrypoint can raise the firewall, then drops
# to the agent user before exec'ing Claude.
USER root
ENV PATH="/home/${USERNAME}/.local/bin:${PATH}"
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/airlock-entrypoint"]
CMD ["claude"]
