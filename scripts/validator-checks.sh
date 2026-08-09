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
#
# 127 is treated as a FAILURE of the check, not a pass. An absent tool "fails" every
# known-bad fixture for the wrong reason, so without this an uninstalled validator
# reports ok on every negative check it has -- the assertion that cannot fail.
expect_fail() {
  local label="$1"; shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "$label -- the tool ACCEPTED a known-bad fixture (no-op or degraded)"
    printf '%s\n' "$out" | sed 's/^/        /'
  elif [ "$rc" -eq 127 ]; then
    bad "$label -- the tool is NOT INSTALLED (exit 127); a missing tool must not read as a pass"
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

hdr "alloy fmt / validate (Alloy syntax + component schema)"
expect_ok   "fmt -t accepts formatted config"             alloy fmt -t alloy/good.alloy
expect_fail "fmt -t rejects misformatted config"          alloy fmt -t alloy/bad-fmt.alloy
expect_ok   "validate accepts a valid component graph"    alloy validate alloy/good.alloy
expect_fail "validate rejects an unknown attribute"       alloy validate alloy/bad.alloy

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

hdr "shellcheck (shell lint)"
expect_ok   "accepts a clean script"                shellcheck shell/good.sh
expect_fail "rejects an unquoted expansion"         shellcheck shell/bad.sh

# bats is checked against a suite that MUST fail. A runner reporting a failing suite
# as green would make every other green result in this repo worthless.
hdr "bats (shell test runner)"
expect_ok   "a passing suite passes"                bats bats/good.bats
expect_fail "a FAILING suite is reported as failed" bats bats/bad.bats

# Image conversion backs `airlock paste`: WSLg offers BMP only, and the Claude API
# takes PNG/JPEG/GIF/WebP. Exit status alone is not enough -- a converter that exits
# 0 having written garbage is exactly the failure that matters -- so each check also
# asserts the PNG magic bytes of what was actually produced.
hdr "image conversion (BMP -> PNG, for airlock paste)"
# Asserting the OUTPUT's magic bytes, not just the exit status: a converter that
# exits 0 having written garbage is the failure mode that matters here.
# Invoked indirectly through expect_ok/expect_fail's "$@", which shellcheck cannot see.
# pil_* return 127 when Pillow is absent so expect_fail's not-installed guard fires:
# a bare ImportError is exit 1, indistinguishable from a correct rejection.
# shellcheck disable=SC2317
{
png_magic()     { [ "$(head -c4 "$1" | od -An -tx1 | tr -d ' \n')" = "89504e47" ]; }
magick_to_png() { magick "$1" png:"$2" && png_magic "$2"; }
have_pil()      { python3 -c 'import PIL' 2>/dev/null; }
pil_to_png()    { have_pil || return 127
                  python3 -c 'import sys
from PIL import Image
Image.open(sys.argv[1]).save(sys.argv[2], "PNG")' "$1" "$2" && png_magic "$2"; }
pil_open()      { have_pil || return 127
                  python3 -c 'import sys
from PIL import Image
Image.open(sys.argv[1])' "$1"; }
}

expect_ok   "ImageMagick produces a real PNG"  magick_to_png image/sample.bmp out-magick.png
expect_fail "ImageMagick rejects a non-image"  magick_to_png image/not-an-image.bmp out-bad.png
# Pillow's absence is an ImportError (exit 1), not 127, so expect_fail's guard cannot
# see it -- assert the module is importable explicitly.
expect_ok   "Pillow is importable"             python3 -c 'import PIL'
expect_ok   "Pillow produces a real PNG"       pil_to_png image/sample.bmp out-pil.png
expect_fail "Pillow rejects a non-image"       pil_open image/not-an-image.bmp

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
