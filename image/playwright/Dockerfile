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
