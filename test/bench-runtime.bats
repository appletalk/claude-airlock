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

@test "runsc and a usable /dev/kvm: systrap, systrap without directfs, kvm; every runsc box has ignore-cgroups and host-uds=open" {
    run "$B" --list
    [ "$status" -eq 0 ]
    [ "$(cut -f1 <<< "$output" | tr '\n' ' ')" = "crun runsc-systrap runsc-systrap-nodirectfs runsc-kvm " ]
    grep -qx $'runsc-systrap\tpodman --runtime '"$T"'/runsc --runtime-flag ignore-cgroups --runtime-flag host-uds=open run ...' <<< "$output"
    grep -q $'^runsc-systrap-nodirectfs\t.* --runtime-flag directfs=false run' <<< "$output"
    grep -q $'^runsc-kvm\t.*host-uds=open --runtime-flag platform=kvm run' <<< "$output"
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
