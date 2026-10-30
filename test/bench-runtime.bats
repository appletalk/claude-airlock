#!/usr/bin/env bats
# scripts/bench-runtime.sh --list: which variants a host gets and the runtime arguments each box
# runs with. Runs nothing (no engine needed).

setup() {
    B="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts/bench-runtime.sh"
    T="$BATS_TEST_TMPDIR"
    printf '#!/bin/sh\n' > "$T/runsc"; chmod +x "$T/runsc"
    : > "$T/kvm"; echo 6.18.2-arch1-1 > "$T/osrelease"
    export BENCH_RUNSC="$T/runsc" BENCH_KVM="$T/kvm" BENCH_OSRELEASE="$T/osrelease"
}

@test "no runsc: crun alone" {
    BENCH_RUNSC="$T/none" run "$B" --list
    [ "$status" -eq 0 ]
    [ "$output" = $'crun\tpodman --runtime crun run ...' ]
}

@test "runsc and a usable /dev/kvm: systrap, systrap without directfs, kvm; every runsc box has ignore-cgroups, host-uds=open and network=none" {
    run "$B" --list
    [ "$status" -eq 0 ]
    [ "$(cut -f1 <<< "$output" | tr '\n' ' ')" = "crun runsc-systrap runsc-systrap-nodirectfs runsc-kvm " ]
    grep -qx $'runsc-systrap\tpodman --runtime '"$T"'/runsc --runtime-flag ignore-cgroups --runtime-flag host-uds=open --runtime-flag network=none run ...' <<< "$output"
    grep -q $'^runsc-systrap-nodirectfs\t.* --runtime-flag directfs=false run' <<< "$output"
    grep -q $'^runsc-kvm\t.*network=none --runtime-flag platform=kvm run' <<< "$output"
}

@test "no usable /dev/kvm: no kvm variant, and asking for it is refused" {
    BENCH_KVM="$T/none" run "$B" --list
    [[ "$output" != *runsc-kvm* ]]
    BENCH_KVM="$T/none" run "$B" --list --variants runsc-kvm
    [ "$status" -ne 0 ]; [[ "$output" == *"needs runsc at"*"usable"* ]]
}

@test "WSL: the ptrace variant too" {
    echo 6.6.87.2-microsoft-standard-WSL2 > "$T/osrelease"
    run "$B" --list
    grep -q $'^runsc-ptrace\t.*--runtime-flag platform=ptrace run' <<< "$output"
}

@test "--variants picks; unknown ones and runsc ones without runsc are refused" {
    run "$B" --list --variants crun,runsc-systrap
    [ "$(cut -f1 <<< "$output" | tr '\n' ' ')" = "crun runsc-systrap " ]
    run "$B" --list --variants crun,gvisor
    [ "$status" -ne 0 ]; [[ "$output" == *"unknown variant gvisor"* ]]
    BENCH_RUNSC="$T/none" run "$B" --list --variants runsc-systrap
    [ "$status" -ne 0 ]; [[ "$output" == *"no runsc at"* ]]
}

@test "a /dev/kvm this user can't open: present is not enough" {
    [ "$(id -u)" != 0 ] || skip "root opens anything"
    chmod 000 "$T/kvm"
    run "$B" --list
    [[ "$output" != *runsc-kvm* ]] || { echo "$output"; return 1; }
}

# --summarize: the summary of a results file (the part of a real run that turns runs into numbers)
results() { printf 'variant\tworkload\trun\tvalue\tstatus\n'; printf '%b' "$1"; }

@test "summary: medians per variant and the ratio to crun; pgbench by its rate; checks pass/fail" {
    results 'crun\tgit-gc\t1\t1.0\tok\ncrun\tgit-gc\t2\t3.0\tok\ncrun\tgit-gc\t3\t2.0\tok\nrunsc-systrap\tgit-gc\t1\t4.0\tok\nrunsc-systrap\tgit-gc\t2\t5.0\tok\nrunsc-systrap\tgit-gc\t3\t3.0\tok\ncrun\tpgbench-tps\t1\t1000\tok\nrunsc-systrap\tpgbench-tps\t1\t500\tok\ncrun\tcheck-proxy\t1\t404\tok\nrunsc-systrap\tcheck-proxy\t1\t000\tfail\n' > "$T/r.tsv"
    run "$B" --summarize "$T/r.tsv"
    [ "$status" -eq 0 ]
    grep -qx $'workload\tcrun\trunsc-systrap' <<< "$output"
    grep -qx $'git-gc\t2\t4 (2.00x)' <<< "$output"
    grep -qx $'pgbench-tps\t1000\t500 (2.00x)' <<< "$output"
    grep -qx $'check-proxy\tok (404)\tFAIL (000)' <<< "$output"
}

@test "summary: a failed pgbench (rate 0) is FAIL with no ratio, and the rows after it still print" {
    results 'crun\tpgbench-tps\t1\t1000\tok\nrunsc-systrap\tpgbench-tps\t1\t0\tfail\ncrun\tgit-gc\t1\t1.0\tok\nrunsc-systrap\tgit-gc\t1\t2.0\tok\n' > "$T/r.tsv"
    run "$B" --summarize "$T/r.tsv"
    [ "$status" -eq 0 ]
    grep -qx $'pgbench-tps\t1000\t0 FAIL' <<< "$output"
    grep -qx $'git-gc\t1\t2 (2.00x)' <<< "$output"
}

@test "summary: workloads a variant never ran because its box died are FAIL, not blank" {
    results 'crun\tgit-gc\t1\t1.0\tok\ncrun\tcheck-inner-run\t1\t-\tok\nrunsc-systrap\tcheck-inner-run\t1\texit 137\tfail\nrunsc-ptrace\tcheck-inner-run\t1\t-\tok\n' > "$T/r.tsv"
    run "$B" --summarize "$T/r.tsv"
    grep -qx $'git-gc\t1\tFAIL\t-' <<< "$output"
    grep -qx $'check-inner-run\tok\tFAIL (exit 137)\tok' <<< "$output"
}

@test "summary: a variant whose boxes never start is FAIL on every workload, with no blank cell" {
    results 'crun\tgit-gc\t1\t1.0\tok\ncrun\tcheck-inner-run\t1\t-\tok\nrunsc-ptrace\tstart-true\t1\t0.5\tfail\nrunsc-ptrace\tcheck-inner-run\t1\tboxes do not start\tfail\n' > "$T/r.tsv"
    run "$B" --summarize "$T/r.tsv"
    grep -qx $'git-gc\t1\tFAIL' <<< "$output"
    grep -qx $'check-inner-run\tok\tFAIL (boxes do not start)' <<< "$output"
    ! grep -q $'\t\t' <<< "$output" || { echo "$output"; return 1; }
}

@test "summary: no ratio against a crun value that failed" {
    results 'crun\tgit-gc\t1\t0.05\tfail\nrunsc-systrap\tgit-gc\t1\t1.0\tok\n' > "$T/r.tsv"
    run "$B" --summarize "$T/r.tsv"
    grep -qx $'git-gc\t0.05 FAIL\t1' <<< "$output"
}

@test "in the box, a workload whose pipeline fails partway (tar of an unreadable file) is a failure, not a fast success" {
    [ "$(id -u)" != 0 ] || skip "root reads anything"
    # the box script's settings and workload functions, as the bench writes them
    sed -n "/<<'INNER'$/,/^INNER$/p" "$B" | sed '1d;$d' > "$T/inner.sh"
    { grep -m1 '^set -' "$T/inner.sh"; sed -n '/^t() {/,/^pyc() {/p' "$T/inner.sh"; } > "$T/fns.sh"
    grep -qx 'set -uo pipefail' "$T/fns.sh"
    W="$T/w"; mkdir -p "$W/src"; echo a > "$W/src/a"; echo b > "$W/src/b"; chmod 000 "$W/src/b"
    run bash -c 'source "$1"; W=$2; t files-tar-stat 1 files' _ "$T/fns.sh" "$W"
    chmod 600 "$W/src/b"
    [[ "$output" == $'files-tar-stat\t1\t'*$'\tfail' ]] || { echo "$output"; return 1; }
    run bash -c 'source "$1"; W=$2; t files-tar-stat 1 files' _ "$T/fns.sh" "$W"
    [[ "$output" == $'files-tar-stat\t1\t'*$'\tok' ]] || { echo "$output"; return 1; }
}

@test "run from an installed copy (no checkout, reached through a current -> versions/<rev> symlink): the work tree is that copy's files" {
    # an install laid out as the installer does it
    mkdir -p "$T/install/versions"
    mkdir -p "$T/install/versions/abc123"
    cp -a "$BATS_TEST_DIRNAME/../scripts" "$BATS_TEST_DIRNAME/../image" "$T/install/versions/abc123/"
    ln -s versions/abc123 "$T/install/current"
    # an engine whose boxes never start: the bench prepares its work tree, then records the failure
    mkdir -p "$T/bin"
    cat > "$T/bin/podman" <<'S'
#!/bin/bash
case " $* " in *" --version "*) echo "podman version 5 (fake)" ;; *" image exists "*|*" rm "*) ;; *" image inspect "*) echo sha256:0 ;; *) exit 1 ;; esac
S
    chmod +x "$T/bin/podman"
    python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$T/s.sock"
    PATH="$T/bin:$PATH" BENCH_RUNSC="$T/none" AIRLOCK_EGRESS_PROXY="$T/s.sock" XDG_CACHE_HOME="$T/cache" \
        run bash "$T/install/current/scripts/bench-runtime.sh" --quick
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    d="$(ls -d "$T"/cache/airlock-bench/*/)"
    grep -q '^work tree   1 commit (not a checkout)$' "$d/facts.txt"
    [ -f "$d/work/src/scripts/bench-runtime.sh" ] && [ ! -L "$d/work/src" ]
    grep -qx $'crun\tcheck-inner-run\t1\tboxes do not start\tfail' "$d/results.tsv"
}
