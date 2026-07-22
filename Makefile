# claude-airlock dev tooling — shellcheck lint + bats tests.
#
# Prefers system-installed shellcheck/bats (e.g. `pacman -S shellcheck bats`,
# `apt install shellcheck bats`); falls back to tools vendored by `make bootstrap`
# into .tooling/ (no sudo, cross-distro).
SHELL := /usr/bin/env bash

SHELLCHECK ?= $(shell command -v shellcheck 2>/dev/null || echo .tooling/bin/shellcheck)
BATS       ?= $(shell command -v bats 2>/dev/null || echo .tooling/bin/bats)

# Shell we lint. The zsh integration is excluded — shellcheck doesn't parse zsh.
SHELL_SCRIPTS := bin/claude-airlock bin/install.sh \
                 image/init-firewall.sh image/entrypoint.sh \
                 config/airlock-statusline.sh \
                 hooks/pre-commit scripts/bootstrap-tools.sh \
                 scripts/airlock-doctor.sh \
                 scripts/image-smoke.sh scripts/validator-checks.sh

.DEFAULT_GOAL := help

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n",$$1,$$2}'

install: ## install the launcher + build base/dev images (see bin/install.sh)
	@bash bin/install.sh

lint: ## shellcheck the launcher + firewall + helper scripts
	@command -v "$(SHELLCHECK)" >/dev/null 2>&1 \
	  || { echo "shellcheck not found — 'make bootstrap' or install it"; exit 1; }
	"$(SHELLCHECK)" $(SHELL_SCRIPTS)

test: ## run the bats suite against BOTH engines (podman + docker)
	@command -v "$(BATS)" >/dev/null 2>&1 \
	  || { echo "bats not found — 'make bootstrap' or install it"; exit 1; }
	@# Both engines are stubbed, so this needs neither installed. Run the whole suite
	@# twice: whichever engine you stop using day to day is the one that silently rots.
	@for e in podman docker; do \
	  echo "==> bats (ENGINE=$$e)"; \
	  ENGINE=$$e "$(BATS)" test/ || exit 1; \
	done

doctor: ## verify THIS host can actually contain a box (live containment test)
	@bash scripts/airlock-doctor.sh

image-smoke: ## prove the dev image's validators work offline (needs a built :dev)
	@bash scripts/image-smoke.sh

check: lint test ## lint + test (what the pre-commit hook runs)

hooks: ## install the git pre-commit hook (symlink)
	@ln -sf ../../hooks/pre-commit .git/hooks/pre-commit \
	  && echo "installed .git/hooks/pre-commit -> hooks/pre-commit"

bootstrap: ## vendor shellcheck + bats into .tooling/ (no sudo)
	@bash scripts/bootstrap-tools.sh

.PHONY: help install lint test doctor image-smoke check hooks bootstrap
