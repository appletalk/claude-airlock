# claude-airlock Playwright stack — dev base + headless Chromium for browser E2E.
#
# Opt in per project via .airlock/config:   image = claude-airlock:playwright
#
# Local-app E2E (driving your app on localhost) is fully contained — no egress.
# If a project needs its EXACT playwright version's browser, allowlist the
# Playwright CDN (cdn.playwright.dev) via .airlock/config and run `playwright
# install chromium`.
FROM claude-airlock:dev

USER root
ENV DEBIAN_FRONTEND=noninteractive

# Shared, world-readable browser cache (baked at build time) so both the dev user
# and a project's own @playwright/test resolve the browser here.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright

RUN npm install -g playwright @playwright/mcp \
    && playwright install --with-deps chromium \
    && chmod -R a+rX /opt/ms-playwright \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# @playwright/mcp defaults to the Chrome channel at /opt/google/chrome/chrome,
# which we don't ship. Point that path at the bundled Chromium so the MCP's
# default browser resolves to our browser (no per-project config needed). The
# glob resolves the installed revision at build time, so it survives version bumps.
RUN mkdir -p /opt/google/chrome \
    && ln -sf "$(ls -d /opt/ms-playwright/chromium-*/chrome-linux64/chrome | head -1)" /opt/google/chrome/chrome

# Chromium's own sandbox is redundant here (the airlock container IS the sandbox)
# and needs caps we don't grant, so projects should launch Chromium with
# --no-sandbox. ENTRYPOINT / USER(root) / WORKDIR are inherited from dev.

# No setuid or setgid file in the box. None is needed at runtime: the entrypoint drops to dev with
# gosu (not setuid), and su, mount, passwd and the rest only matter to a box that could gain
# privileges, which no_new_privs already stops. Without the bit each one is an ordinary program
# run as dev. The packages behind them are Debian's required base (util-linux is Essential), so
# they stay installed and lose only the bit. Each image does this after its last package
# install, so none can bring a bit back unnoticed; the image smoke test checks the running box.
RUN find / -xdev -type f -perm /6000 -exec chmod ug-s {} + \
    && ! find / -xdev -type f -perm /6000 | grep .
