# claude-airlock dev tooling — shellcheck lint + bats tests.
#
# Prefers system-installed shellcheck/bats (e.g. `pacman -S shellcheck bats`,
# `apt install shellcheck bats`); falls back to tools vendored by `make bootstrap`
# into .tooling/ (no sudo, cross-distro).
#
# System first is deliberate: .tooling/ is gitignored and lives inside the project dir a
# box mounts read-write, so a binary there is one a box could have replaced, invisibly to
# `git status`, before the host's next `make check` or commit runs it. CI pins the
# version instead by passing SHELLCHECK/BATS explicitly after bootstrapping.
SHELL := /usr/bin/env bash

SHELLCHECK ?= $(shell command -v shellcheck 2>/dev/null || echo .tooling/bin/shellcheck)
BATS       ?= $(shell command -v bats 2>/dev/null || echo .tooling/bin/bats)

# Shell we lint. The zsh integration is excluded — shellcheck doesn't parse zsh.
SHELL_SCRIPTS := bin/claude-airlock bin/install.sh bin/bundle.sh bin/install-bundle.sh bin/update-runsc \
                 image/init-firewall.sh image/entrypoint.sh \
                 config/airlock-statusline.sh \
                 hooks/pre-commit hooks/pre-merge-commit hooks/commit-msg scripts/private-names-check test/private-names-check-test.sh \
                 scripts/bootstrap-tools.sh \
                 scripts/airlock-doctor.sh lib/host-dns.sh lib/clipboard-image.sh \
                 scripts/image-smoke.sh scripts/validator-checks.sh scripts/bench-runtime.sh \
                 scripts/run-tests.sh \
                 agents/install.sh agents/airlock-agents-apply agents/operator agents/share/completion.bash \
                 agents/lib/session-run agents/lib/session-stop agents/lib/web-session-run \
                 agents/lib/web-worker agents/lib/guard-worker agents/lib/worker-common.sh \
                 agents/lib/nodump-refresh agents/host-test.sh

.DEFAULT_GOAL := help

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n",$$1,$$2}'

install-airlock: ## install the launcher + build base/dev images for you (packages refreshed weekly; see bin/install.sh)
	@bash bin/install.sh

install-agents: ## (root, optional) agent users with their own sessions; needs airlock-envoy running (docs/setup.md)
	@bash agents/install.sh

bundle: ## write the installed version (launcher + images) to DIR= for another account or an offline host
	@test -n "$(DIR)" || { echo "usage: make bundle DIR=<directory the other account can read>"; exit 1; }
	@bash bin/bundle.sh "$(DIR)"

bundle-clean: ## remove the bundle in DIR= once every reader has installed it
	@test -n "$(DIR)" || { echo "usage: make bundle-clean DIR=<directory>"; exit 1; }
	@bash bin/bundle.sh --clean "$(DIR)"

install-bundle: ## install from the bundle in DIR= (no build, no network); or: bash DIR/install-bundle.sh
	@test -n "$(DIR)" || { echo "usage: make install-bundle DIR=<directory>"; exit 1; }
	@bash bin/install-bundle.sh "$(DIR)"

refresh: ## rebuild the images with today's Debian security updates (forces the weekly refresh now)
	@AIRLOCK_APT_REFRESH="$$(date +%G-W%V).$$(date +%F-%H%M)" bash bin/install.sh

claude-installer-diff: ## show how upstream's Claude Code installer differs from the vendored copy
	@curl -fsSL https://claude.ai/install.sh | diff -u image/claude-install.sh - \
	  && echo "image/claude-install.sh matches upstream"

claude-installer-update: ## replace the vendored Claude Code installer with upstream's (read the diff first)
	@curl -fsSL https://claude.ai/install.sh -o image/claude-install.sh.new \
	  && mv image/claude-install.sh.new image/claude-install.sh \
	  && sha256sum image/claude-install.sh \
	  && echo "updated image/claude-install.sh - review 'git diff', then commit and 'make install-airlock'"

lint: ## shellcheck the launcher + firewall + helper scripts (+ zsh -n on the integration)
	@command -v "$(SHELLCHECK)" >/dev/null 2>&1 \
	  || { echo "shellcheck not found — 'make bootstrap' or install it"; exit 1; }
	"$(SHELLCHECK)" $(SHELL_SCRIPTS)
	@# shellcheck cannot parse zsh, so the shell integration had NO gate at all.
	@# `zsh -n` at least catches a syntax error before it breaks everyone's rc file.
	@if command -v zsh >/dev/null 2>&1; then \
	  echo "==> zsh -n shell/claude-airlock.zsh"; \
	  zsh -n shell/claude-airlock.zsh; \
	else \
	  echo "!! zsh not found — shell/claude-airlock.zsh not syntax-checked"; \
	fi

test: ## run the bats suite against BOTH engines (podman + docker)
	@command -v "$(BATS)" >/dev/null 2>&1 \
	  || { echo "bats not found — 'make bootstrap' or install it"; exit 1; }
	@# Both engines are stubbed, so this needs neither installed. Run the whole suite
	@# twice: whichever engine you stop using day to day is the one that silently rots.
	@# Every (engine, file) pair runs in parallel (JOBS=n to limit); see the script.
	@BATS="$(BATS)" bash scripts/run-tests.sh

doctor: ## verify THIS host can actually contain a box (live containment test)
	@bash scripts/airlock-doctor.sh

image-smoke: ## prove the dev image's validators work offline (needs a built :dev)
	@bash scripts/image-smoke.sh

bench-runtime: ## time box work under crun and gVisor on this host (docs/gvisor.md; ARGS=--quick)
	@bash scripts/bench-runtime.sh $(ARGS)

check: lint test ## lint + test (what the pre-commit hook runs)

hooks: ## install the git pre-commit, pre-merge-commit and commit-msg hooks (symlinks)
	@ln -sf ../../hooks/pre-commit .git/hooks/pre-commit \
	  && ln -sf ../../hooks/pre-merge-commit .git/hooks/pre-merge-commit \
	  && ln -sf ../../hooks/commit-msg .git/hooks/commit-msg \
	  && echo "installed .git/hooks/pre-commit, pre-merge-commit and commit-msg -> hooks/"

bootstrap: ## vendor shellcheck + bats into .tooling/ (no sudo)
	@bash scripts/bootstrap-tools.sh

.PHONY: help install-airlock install-agents bundle bundle-clean install-bundle refresh claude-installer-diff claude-installer-update lint test doctor image-smoke bench-runtime check hooks bootstrap
