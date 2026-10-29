#!/usr/bin/env bash
#
# bench-runtime: time the same box work under crun and under gVisor (runsc), on this host, to
# decide whether boxes run under gVisor by default here (docs/gvisor.md). Run it as the user
# whose boxes it is about (an agent user: its podman, its image, its proxy socket).
#
#   make bench-runtime                      every variant this host can run, 5 runs each
#   scripts/bench-runtime.sh --quick        1 run each, no full test suite
#   scripts/bench-runtime.sh --list         the variants and their engine arguments; runs nothing
#   scripts/bench-runtime.sh --variants crun,runsc-kvm
#
# Variants: crun (today's runtime); runsc-systrap and runsc-systrap-nodirectfs when runsc is
# installed; runsc-kvm when /dev/kvm is usable; runsc-ptrace on WSL (where systrap is reported
# to fail). Each box is started the way the launcher starts a proxy-mode box: no network but
# loopback, the proxy socket bridged in, the same capabilities, seccomp profile and user mapping.
#
# Output: a results directory (printed at the end) with facts.txt (the host), results.tsv (one
# line per variant, workload and run) and summary.tsv (medians and the ratio to crun), plus a
# log per variant. Paste facts.txt and summary.tsv.
#
# The proxy socket: AIRLOCK_EGRESS_PROXY, else the AIRLOCK_EGRESS_PROXY line of this user's
# claude-airlock config. One request goes through it (a CONNECT to api.anthropic.com, which any
# listener allows), so it shows in the proxy's log.
set -uo pipefail
export LC_ALL=C

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE=podman
IMAGE="${AIRLOCK_IMAGE:-claude-airlock:dev}"
RUNSC="${BENCH_RUNSC:-/usr/local/bin/runsc}"          # test hooks: never set in use
KVM="${BENCH_KVM:-/dev/kvm}"
OSRELEASE="${BENCH_OSRELEASE:-/proc/sys/kernel/osrelease}"
die() { echo "bench-runtime: $*" >&2; exit 1; }

# The summary of a results file: per workload, each variant's median, and how many times slower
# than crun (pgbench-tps is a rate: by its rate). check-* rows are pass/fail.
summarize() {
  awk -F'\t' '
    NR == 1 { next }
    $2 ~ /^check-/ { chk[$1 SUBSEP $2] = ($5 == "ok" ? "ok" : "FAIL") ($4 != "-" ? " (" $4 ")" : ""); }
    $2 !~ /^check-/ && $4 ~ /^[0-9.]+$/ { k = $1 SUBSEP $2; n[k]++; v[k, n[k]] = $4 }
    $5 != "ok" { bad[$1 SUBSEP $2] = 1 }
    $4 == "n/a" { na[$1 SUBSEP $2] = 1 }
    { if (!($2 in seen)) { seen[$2] = 1; order[++w] = $2 } if (!($1 in vs)) { vs[$1] = 1; vo[++nv] = $1 } }
    function median(k,   i, j, t, m) {
      m = n[k]; for (i = 1; i <= m; i++) a[i] = v[k, i] + 0
      for (i = 2; i <= m; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]; a[j + 1] = t }
      return (m % 2) ? a[(m + 1) / 2] : (a[m / 2] + a[m / 2 + 1]) / 2
    }
    END {
      printf "workload"; for (i = 1; i <= nv; i++) printf "\t%s", vo[i]; printf "\n"
      for (x = 1; x <= w; x++) {
        wl = order[x]; printf "%s", wl
        base = ((("crun" SUBSEP wl) in n)) ? median("crun" SUBSEP wl) : 0
        for (i = 1; i <= nv; i++) {
          k = vo[i] SUBSEP wl
          if (k in chk) { printf "\t%s", chk[k]; continue }
          # nothing measured: failed, not measurable here (n/a), its box died (FAIL), or not run
          if (!(k in n)) { printf "\t%s", ((k in bad) ? "FAIL" : (k in na) ? "n/a" : (chk[vo[i] SUBSEP "check-inner-run"] ~ /^FAIL/) ? "FAIL" : "-"); continue }
          m = median(k); cell = sprintf("%g", m)
          if (vo[i] != "crun" && base > 0 && m > 0 && !(k in bad) && wl != "idle-pss-mib") cell = cell sprintf(" (%.2fx)", (wl == "pgbench-tps") ? base / m : m / base)
          if (k in bad) cell = cell " FAIL"
          printf "\t%s", cell
        }
        printf "\n"
      }
    }' "$1"
}

reps=5 quick=0 list=0 want=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) quick=1; reps=1 ;;
    --list) list=1 ;;
    --summarize) [ $# -ge 2 ] || die "--summarize needs a results.tsv"; summarize "$2"; exit ;;
    --variants) [ $# -ge 2 ] || die "--variants needs a list"; want=$2; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1 (see --help)" ;;
  esac
  shift
done

on_wsl() { grep -qsiE 'microsoft|wsl' "$OSRELEASE"; }

# ---- variants ----------------------------------------------------------------------------------
all=(crun)
if [ -x "$RUNSC" ]; then
  all+=(runsc-systrap runsc-systrap-nodirectfs)
  [ -r "$KVM" ] && [ -w "$KVM" ] && all+=(runsc-kvm)
  on_wsl && all+=(runsc-ptrace)
fi
if [ -n "$want" ]; then
  variants=()
  IFS=, read -ra asked <<< "$want"
  for v in "${asked[@]}"; do
    case "$v" in
      crun) ;;
      runsc-systrap|runsc-systrap-nodirectfs|runsc-ptrace) [ -x "$RUNSC" ] || die "$v: no runsc at $RUNSC (sudo update-runsc)" ;;
      runsc-kvm) [ -x "$RUNSC" ] && [ -r "$KVM" ] && [ -w "$KVM" ] || die "$v: needs runsc at $RUNSC and a usable $KVM" ;;
      *) die "unknown variant $v (crun, runsc-systrap, runsc-systrap-nodirectfs, runsc-kvm, runsc-ptrace)" ;;
    esac
    variants+=("$v")
  done
else
  variants=("${all[@]}")
fi

# The engine's global arguments for a variant: the runtime and its flags. runsc can't apply
# cgroups under rootless podman yet (it asks the system manager), so ignore-cgroups; the box
# reaches the proxy through a host Unix socket, which gVisor refuses unless host-uds=open.
runtime_args() {
  case "$1" in
    crun) echo "--runtime crun" ;;
    runsc-*)
      local a="--runtime $RUNSC --runtime-flag ignore-cgroups --runtime-flag host-uds=open"
      case "$1" in
        runsc-systrap-nodirectfs) a="$a --runtime-flag directfs=false" ;;
        runsc-kvm) a="$a --runtime-flag platform=kvm" ;;
        runsc-ptrace) a="$a --runtime-flag platform=ptrace" ;;
      esac
      echo "$a" ;;
  esac
}

if [ "$list" = 1 ]; then
  for v in "${variants[@]}"; do printf '%s\t%s %s run ...\n' "$v" "$ENGINE" "$(runtime_args "$v")"; done
  exit 0
fi

# ---- preconditions -----------------------------------------------------------------------------
command -v "$ENGINE" >/dev/null || die "$ENGINE not on PATH"
"$ENGINE" image exists "$IMAGE" 2>/dev/null || die "image $IMAGE not found (make install-airlock)"
sock="${AIRLOCK_EGRESS_PROXY:-}"
if [ -z "$sock" ]; then
  for c in "${AIRLOCK_CONFIG:-}" "${XDG_CONFIG_HOME:-$HOME/.config}/claude-airlock/config"; do
    [ -n "$c" ] && [ -r "$c" ] || continue
    sock="$(sed -n 's/^AIRLOCK_EGRESS_PROXY=["'\'']\{0,1\}\([^"'\'']*\).*/\1/p' "$c" | tail -n 1)"
    [ -z "$sock" ] || break
  done
fi
[ -n "$sock" ] && [ -S "$sock" ] || die "no proxy socket (set AIRLOCK_EGRESS_PROXY to this user's airlock-envoy socket)"

out="${XDG_CACHE_HOME:-$HOME/.cache}/airlock-bench/$(date +%Y%m%d-%H%M%S)"
W="$out/work"
mkdir -p "$W" || die "can't create $W"
# The work tree: this repository, with its history when it is a checkout (an installed copy has
# none: then one commit, and facts.txt says so).
if git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  git clone -q --no-hardlinks "$REPO_DIR" "$W/src" || die "can't copy the repository into $W"
  history="$(git -C "$W/src" rev-list --count HEAD) commits"
else
  if ! { cp -a "$REPO_DIR" "$W/src" && git -C "$W/src" init -q && git -C "$W/src" add -A \
      && git -C "$W/src" -c user.name=bench -c user.email=bench@localhost commit -qm bench; }; then
    die "can't copy the repository into $W"
  fi
  history="1 commit (not a checkout)"
fi

# ---- facts -------------------------------------------------------------------------------------
{
  echo "date        $(date -Is)"
  echo "kernel      $(uname -r)"
  echo "os          $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"')"
  echo "wsl         $(on_wsl && echo yes || echo no)"
  echo "cpu         $(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -n 1) x $(nproc)"
  echo "memory      $(awk '/^MemTotal/ { printf "%.1f GiB", $2 / 1048576 }' /proc/meminfo)"
  if [ -r "$KVM" ] && [ -w "$KVM" ]; then k=usable; elif [ -e "$KVM" ]; then k="present, not usable by $(id -un)"; else k=absent; fi
  echo "kvm         $k"
  echo "user        $(id -un)"
  echo "podman      $("$ENGINE" --version 2>/dev/null)"
  echo "crun        $(crun --version 2>/dev/null | head -n 1)"
  echo "runsc       $( { [ -x "$RUNSC" ] && "$RUNSC" --version 2>/dev/null | head -n 1; } || echo none)"
  echo "work tree   $history"
  echo "image       $IMAGE $("$ENGINE" image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null | cut -c1-19)"
  echo "variants    ${variants[*]}"
  echo "runs        $reps$([ "$quick" = 1 ] && echo ' (quick)')"
} > "$out/facts.txt"
cat "$out/facts.txt"

# ---- the work inside a box ---------------------------------------------------------------------
# One box per variant runs every workload; each line: workload, run, seconds (or a value), status.
cat > "$W/inner.sh" <<'INNER'
#!/usr/bin/env bash
set -u
W=$1 REPS=$2 QUICK=$3
cd "$W" || exit 1
t() {  # t <workload> <run> <command...>: time it
  local name=$1 run=$2 s e st=ok; shift 2
  s=$(date +%s.%N)
  "$@" >/dev/null 2>>"$W/inner.err" || st=fail
  e=$(date +%s.%N)
  printf '%s\t%s\t%s\t%s\n' "$name" "$run" "$(awk -v s="$s" -v e="$e" 'BEGIN { printf "%.3f", e - s }')" "$st"
}
burst() { local i; for i in $(seq 2000); do /bin/true || return 1; done; }
gstatus() { local i; for i in $(seq 20); do git -C "$W/src" status --porcelain >/dev/null || return 1; done; }
nodes() { local i; for i in $(seq 50); do node -e 0 || return 1; done; }
claudev() { local i; for i in $(seq 10); do claude --version >/dev/null || return 1; done; }
files() { rm -rf "$W/x" && mkdir "$W/x" && tar -C "$W/src" -cf - . | tar -C "$W/x" -xf - && find "$W/x" -type f -exec stat {} + >/dev/null; }
pyc() { rm -rf "$W/py" && cp -r "$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["stdlib"])')" "$W/py" && python3 -m compileall -q "$W/py"; }

# Function first: the proxy bridge and one request through it (any HTTP status is a pass).
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 https://api.anthropic.com/ 2>>"$W/inner.err")
printf 'check-proxy\t1\t%s\t%s\n' "$code" "$([ "${code:-000}" != 000 ] && echo ok || echo fail)"

for r in $(seq "$REPS"); do
  t exec-burst-2000 "$r" burst
  t git-status-x20 "$r" gstatus
  t git-log-p "$r" git -C "$W/src" log -p
  rm -rf "$W/clone"; t git-clone "$r" git clone -q --no-local "$W/src" "$W/clone"
  t git-gc "$r" git -C "$W/clone" gc -q
  t files-tar-stat "$r" files
  t node-x50 "$r" nodes
  t claude-version-x10 "$r" claudev
  rm -rf "$W/venv"; t python-venv "$r" python3 -m venv "$W/venv"
  t python-compileall "$r" pyc
  if [ -d "$W/src/test" ]; then
    t bats-config-parse "$r" bats "$W/src/test/config_parse.bats"
    t bats-agents-site "$r" bats "$W/src/test/agents-site.bats"
  fi
done
[ "$QUICK" = 1 ] || [ ! -d "$W/src/test" ] || t bats-full 1 bats "$W/src/test"

# Postgres: transactions a second over 20 s (a rate: higher is better).
if airlock-pg-start >/dev/null 2>>"$W/inner.err"; then
  pgbench -i -q -s 10 -h 127.0.0.1 -U postgres postgres >/dev/null 2>>"$W/inner.err"
  tps=$(pgbench -T 20 -c 4 -h 127.0.0.1 -U postgres postgres 2>>"$W/inner.err" | awk '/^tps/ { print $3; exit }')
  printf 'pgbench-tps\t1\t%s\t%s\n' "${tps:-0}" "$([ -n "$tps" ] && echo ok || echo fail)"
else
  printf 'pgbench-tps\t1\t0\tfail\n'
fi
INNER

box() {  # box <variant> <run args...> -- <command...>: a box as the launcher starts one
  local v=$1; shift
  # shellcheck disable=SC2046  # runtime_args is word-split on purpose
  "$ENGINE" $(runtime_args "$v") run --rm \
    --cap-drop=ALL --cap-add=SETUID --cap-add=SETGID \
    --security-opt=no-new-privileges --security-opt "seccomp=$REPO_DIR/image/seccomp.json" \
    --userns=keep-id:uid=1000,gid=1000 --network=none --pids-limit 4096 \
    -v "$sock:$sock:ro" -e "AIRLOCK_EGRESS_PROXY=$sock" \
    -v "$W:$W:rw" -w "$W" "$@"
}

# Memory of an idle box: the PSS of every process in its cgroups (conmon's included, the same
# for every variant). Best effort: a sandboxed user manager may hide the box's processes.
idle_pss() {
  local v=$1 name="airlock-bench-$$" id pss
  box "$v" -d --name "$name" "$IMAGE" sleep 60 >/dev/null 2>&1 || { echo n/a; return; }
  sleep 5
  id="$("$ENGINE" inspect -f '{{.Id}}' "$name" 2>/dev/null)"
  pss="$(grep -l -- "$id" /proc/[0-9]*/cgroup 2>/dev/null | while read -r f; do
           awk '/^Pss:/ { print $2 }' "${f%/cgroup}/smaps_rollup" 2>/dev/null; done | awk '{ s += $1 } END { if (s) printf "%.1f", s / 1024 }')"
  "$ENGINE" rm -f "$name" >/dev/null 2>&1
  echo "${pss:-n/a}"
}

# A file the host changes while the box runs is seen in it (new files and new contents).
host_change() {
  local v=$1 pid st _
  rm -f "$W/flag" "$W/ready"; echo old > "$W/content"
  # shellcheck disable=SC2016  # expanded by the box's shell
  box "$v" "$IMAGE" bash -c 'W=$1; touch "$W/ready"; for i in $(seq 200); do
      [ -f "$W/flag" ] && [ "$(cat "$W/content")" = new ] && exit 0; sleep 0.1; done; exit 1' _ "$W" >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 300); do [ -f "$W/ready" ] && break; sleep 0.1; done
  echo new > "$W/content"; touch "$W/flag"
  wait "$pid"; st=$?
  [ "$st" = 0 ] && echo ok || echo fail
}

# The idle-memory box, if a run stops while it is up.
trap '"$ENGINE" rm -f "airlock-bench-$$" >/dev/null 2>&1 || true' EXIT

# Warm-up, untimed, every variant before any is timed: the image layers, the work tree and the
# tools in the page cache, so the first variant timed (crun) doesn't carry the cold start.
echo "==> warm-up"
for v in "${variants[@]}"; do
  # shellcheck disable=SC2016  # expanded by the box's shell
  box "$v" "$IMAGE" bash -c 'node -e 0; claude --version; git -C "$1/src" log -p | tail -n 1; tar -C "$1/src" -cf - . | wc -c' _ "$W" >/dev/null 2>&1 || true
done

echo -e "variant\tworkload\trun\tvalue\tstatus" > "$out/results.tsv"
for v in "${variants[@]}"; do
  echo "==> $v"
  log="$out/$v.log"
  # start-up: a box that does nothing, from the host
  for r in $(seq $(( reps * 2 ))); do
    s=$(date +%s.%N)
    if box "$v" "$IMAGE" true >>"$log" 2>&1; then st=ok; else st=fail; fi
    e=$(date +%s.%N)
    printf '%s\tstart-true\t%s\t%s\t%s\n' "$v" "$r" "$(awk -v s="$s" -v e="$e" 'BEGIN { printf "%.3f", e - s }')" "$st" >> "$out/results.tsv"
  done
  if ! grep -q "^$v"$'\tstart-true\t.*\tok$' "$out/results.tsv"; then
    echo "    $v: boxes don't start (see $log); skipped"
    continue
  fi
  printf '%s\tcheck-host-change\t1\t-\t%s\n' "$v" "$(host_change "$v")" >> "$out/results.tsv"
  printf '%s\tidle-pss-mib\t1\t%s\t%s\n' "$v" "$(idle_pss "$v")" ok >> "$out/results.tsv"
  : > "$W/inner.err"
  box "$v" "$IMAGE" bash "$W/inner.sh" "$W" "$reps" "$quick" 2>>"$log" | sed "s/^/$v\t/" >> "$out/results.tsv"
  st="${PIPESTATUS[0]}"
  printf '%s\tcheck-inner-run\t1\t%s\t%s\n' "$v" "$([ "$st" = 0 ] && echo - || echo "exit $st")" "$([ "$st" = 0 ] && echo ok || echo fail)" >> "$out/results.tsv"
  cat "$W/inner.err" >> "$log"
done

summarize "$out/results.tsv" > "$out/summary.tsv"
echo
column -t -s $'\t' "$out/summary.tsv" 2>/dev/null || cat "$out/summary.tsv"
echo
echo "Medians: seconds, except idle-pss-mib (MiB) and pgbench-tps (transactions a second). (Nx): how"
echo "many times slower than crun (for pgbench, by its rate). check-*: pass/fail, nothing timed."
echo "FAIL: failed, or never ran because its box died (check-inner-run). n/a: not measurable here."
echo "-: not run for this variant."
echo "results: $out  (paste facts.txt and summary.tsv)"
