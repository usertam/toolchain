#!/usr/bin/env bash
# TEST: what keeps provjobd busy. On the hosted runners a kernel build with the
# static toolchain takes less cpu time than with the release and yet as long or
# longer, as provjobd, a process of the runner, takes two cpu-minutes of the
# four cpus meanwhile, against two seconds with the release (idle.sh).
#
# Earlier rounds of this script (runs 45542098097, 45544235316, 45546186988)
# read the cpu time of provjobd around single workloads. It is busy when a tool
# runs whose mimalloc has its first arena of 1 GiB: 1 to 9 ms for every run,
# and about 7% of the cpu time of a compile on top. With arenas of up to
# 512 MiB, or without arenas, it keeps quiet, and the static toolchain is 6%
# to 11% faster than the release in a part of the kernel, where it was level.
# A program without mimalloc that maps 1 GiB, writes to 4 MiB of it and ends
# costs 2 to 4 ms as well, one that maps 64 MiB nothing. But a compile of 20 s
# with the release keeps provjobd as busy as one with the static clang, and
# that maps no more than 285 MiB in all.
#
# This round, with a program that maps memory and writes to it (spin.c): what
# of the mapping counts, and whether provjobd is busy for as long as the memory
# of a process grows. Then compiles of three sizes with both toolchains: from
# what size on is it busy.

set -euo pipefail

base=$(dirname "$(readlink -f "$0")")
work=$PWD/bench-work
names=("$1" "$2")
arch=$(uname -m)

mkdir -p "$work"/{dl,tc,trigger}
cd "$work"

echo "machine: $arch, $(nproc) cpus, $(lscpu | sed -n 's/^Model name: *//p' | head -1), linux $(uname -r), root on $(findmnt -no SOURCE /)"
for name in "${names[@]}"; do
    if [[ ! -d tc/$name ]]; then
        tar=toolchain-$name-$arch.tar.xz
        curl -fsSL --retry 5 --retry-all-errors -o dl/"$tar" https://github.com/"${GITHUB_REPOSITORY:-usertam/toolchain}"/releases/download/"$name"/"$tar"
        mkdir tc/"$name"
        tar -C tc/"$name" -xf dl/"$tar"
    fi
    echo "$name: $(tc/"$name"/bin/clang --version | head -1)"
done

function probe() {
    # probe <label> <times> <command>: the command that often, then the time
    # provjobd is still busy with what has ended
    # shellcheck disable=SC2016
    python3 -I "$base"/probe.py "$1" /dev/null - -- bash -c '
        for ((i = 0; i < $0; i++)); do
            "$@"
        done >/dev/null 2>&1
        last=-1
        while now=$(cat /proc/[0-9]*/stat 2>/dev/null | awk '\''$2 ~ /^\(provjobd/ { t += $14 + $15 } END { print t + 0 }'\'') && ((now - last > 2)); do
            last=$now
            sleep 1
        done' "${@:2}" | grep -E '^==|provjobd|its children|busy with' | sed -E 's/^  the machine.*; (busy with)/  \1/'
}


cd trigger
gcc -O2 -Wall -o spin "$base"/spin.c

echo "== a program that maps memory, writes to some of it and ends, 500 times: MiB mapped, MiB written to"
for sizes in '1024 0' '1024 1' '1024 4' '1024 32' '1023 4'; do
    # shellcheck disable=SC2086
    probe "touch-${sizes/ /-}" 500 ./spin 0 $sizes
done
probe touch-1024-4-in-two-mappings 500 ./spin 0 1024 4 split

echo "== one that takes 10 s of cpu time and writes to its memory bit by bit: MiB mapped, MiB written to"
for sizes in '512 64' '512 256' '1024 64' '1024 256'; do
    # shellcheck disable=SC2086
    probe "grow-${sizes/ /-}" 1 ./spin 10 $sizes grow
done
probe at-once-1024-256 1 ./spin 10 1024 256

echo "== one that maps and unmaps 64 KiB 20000 times after the writing: MiB mapped, MiB written to"
probe calls-64-4 1 ./spin 0 64 4 calls
probe calls-1024-4 1 ./spin 0 1024 4 calls

# The command, and its peak memory into the file peak
peak=(python3 -I -c 'import resource, subprocess, sys
subprocess.run(sys.argv[1:], check=True)
open("peak", "w").write(f"{resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss >> 10} MiB")')

function compile() {
    # compile <label> <name> <variables>...: long.c with the clang of that name
    probe "$1" 1 env "${@:3}" "${peak[@]}" "$work/tc/$2/bin/clang" -O2 -c -o long.o long.c
    echo "  peak memory: $(cat peak)"
}

echo "== compiles of 3000, 6000 and 12000 functions: ${names[0]}, ${names[1]}, ${names[1]} with arenas of 64 MiB"
for count in 3000 6000 12000; do
    for i in $(seq $count); do
        echo "int f$i(int n, int *p) { for (int i = 0; i < n; i++) p[i] += n * $i; return p[n / 2] + $i; }"
    done >long.c
    for name in "${names[@]}"; do
        compile "$name-$count" "$name"
    done
    compile "${names[1]}-64MiB-$count" "${names[1]}" MIMALLOC_ARENA_RESERVE=64MiB
done
echo "end $(date -Is)"
