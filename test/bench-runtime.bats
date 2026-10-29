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
