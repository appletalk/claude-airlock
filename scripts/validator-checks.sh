#!/usr/bin/env bash
#
# Runs INSIDE the box, behind the raised firewall, as the unprivileged dev user.
# Launched by scripts/image-smoke.sh -- see that file for the why.
#
# Every validator is checked in BOTH directions. Asserting only that a good
# fixture passes is the trap this whole file exists to avoid: a tool that has
# silently degraded to a no-op passes the good fixture too. The bad fixture is
# the real test, so each tool must also REJECT input it is supposed to reject.
set -uo pipefail

FIXTURES="${1:-/fixtures}"
fail=0
ran=0

pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; ran=$((ran + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; ran=$((ran + 1)); }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

# expect_ok <label> <cmd...>   : the command must succeed
expect_ok() {
  local label="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then
    pass "$label"
  else
    bad "$label (exit $?) -- a VALID fixture was rejected"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
}

# expect_fail <label> <cmd...> : the command must FAIL (this is the no-op detector)
expect_fail() {
  local label="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then
    bad "$label -- the tool ACCEPTED a known-bad fixture (no-op or degraded)"
    printf '%s\n' "$out" | sed 's/^/        /'
  else
    pass "$label"
  fi
}

# Work on a writable copy: the fixtures are mounted read-only, and some linters
# want to write a cache next to the files they read.
work="$(mktemp -d)"
cp -r "$FIXTURES"/. "$work"/
cd "$work" || exit 1

hdr "promtool (Prometheus config + rules)"
expect_ok   "check config accepts a valid scrape config"  promtool check config prometheus/good.prometheus.yml
expect_fail "check config rejects a bad duration"         promtool check config prometheus/bad.prometheus.yml
expect_ok   "check rules accepts valid alerting rules"    promtool check rules prometheus/good.rules.yml
expect_fail "check rules rejects invalid PromQL"          promtool check rules prometheus/bad.rules.yml

hdr "terraform fmt (HCL syntax + formatting)"
expect_ok   "fmt -check accepts formatted HCL"            terraform fmt -check -recursive terraform/good
expect_fail "fmt -check rejects misformatted HCL"         terraform fmt -check terraform/bad-fmt.tf

hdr "tflint (bundled terraform ruleset, no plugin download)"
expect_ok   "accepts a clean module"                      tflint --chdir=terraform/good
expect_fail "flags unused declarations / deprecated interpolation" tflint --chdir=terraform/bad-lint

hdr "vector validate --no-environment"
expect_ok   "accepts a valid topology"                    vector validate --no-environment vector/good.yaml
expect_fail "rejects an unknown sink field"               vector validate --no-environment vector/bad.yaml

hdr "ansible-lint (offline, ANSIBLE_LINT_NODEPS=1)"
expect_ok   "accepts a clean play"                        ansible-lint --offline ansible/good.yml
expect_fail "flags an unnamed, non-FQCN task"             ansible-lint --offline ansible/bad.yml

# PSScriptAnalyzer reports findings as OBJECTS and still exits 0, so exit status
# is meaningless here -- assert on the finding count instead.
hdr "PSScriptAnalyzer"
pssa() { pwsh -NoProfile -NonInteractive -Command "@(Invoke-ScriptAnalyzer -Path '$1').Count"; }
if n="$(pssa powershell/good.ps1 2>&1)" && [ "$n" = "0" ]; then
  pass "clean script yields 0 findings"
else
  bad "clean script yielded '$n' (expected 0)"
fi
if n="$(pssa powershell/bad.ps1 2>&1)" && [ "${n:-0}" -gt 0 ] 2>/dev/null; then
  pass "aliased/unused-variable script yields $n findings"
else
  bad "known-bad script yielded '$n' findings (expected > 0) -- rules not loaded?"
fi

# The scope claim in image/dev/Dockerfile cuts both ways: the network-dependent
# commands must NOT quietly appear to work. The firewall DROPs (does not reject),
# so these hang rather than fail fast -- hence the timeout, which is also why
# ANSIBLE_LINT_NODEPS is set in the image rather than left to each project.
hdr "out-of-scope commands do not succeed offline"
expect_fail "terraform init cannot reach the provider registry" \
  timeout 20 terraform init -backend=false -input=false terraform/good

hdr ""
if [ "$fail" -eq 0 ]; then
  printf '\033[32mall %d validator checks passed\033[0m -- offline, at minimal egress.\n' "$ran"
else
  printf '\033[31mvalidator checks failed\033[0m -- see above.\n'
fi
exit "$fail"
