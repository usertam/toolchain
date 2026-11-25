#!/usr/bin/env bash
# TEST: what of the static toolchain keeps provjobd busy. On the hosted runners
# a kernel build with the static toolchain takes less cpu time than with the
# release and yet as long or longer, as provjobd, a process of the runner, takes
# two cpu-minutes of the four cpus meanwhile, against two seconds with the
# release (idle.sh).
#
# The first round of this script (run 45542098097) read the cpu time of
# provjobd around single workloads: it takes 1 to 9 ms for every run of a
# static LLVM tool, even one that only says its version, and about 7% of the
# cpu time of a compile on top, whatever the huge pages and the purging of the
# tool's mimalloc are set to, and nothing for the static binutils, which have
# the malloc of musl. The second (run 45544235316) found the arena: mimalloc
# maps 1 GiB as its first one, and with 64 MiB at a time, or without arenas,
# provjobd keeps as quiet as with the release, and the static toolchain is 6%
# to 11% faster than the release where it was level. The clang of the release
# with a mimalloc loaded into it keeps provjobd as busy as the static one. A
# program that only maps 1 GiB and computes does not.
#
# This round: from what size of the arena on, and whether a program that
# writes to a large mapping and gives parts of it back, as mimalloc does, is
# enough.

set -euo pipefail

base=$(dirname "$(readlink -f "$0")")
work=$PWD/bench-work
names=("$1" "$2")
arch=$(uname -m)
linux='linux-7.3'

mkdir -p "$work"/{dl,tc,src,build,trigger}
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
release=$work/tc/${names[0]}/bin
static=$work/tc/${names[1]}/bin

if [[ ! -d src/$linux ]]; then
    curl -fsSL --retry 5 --retry-all-errors -o dl/$linux.tar.xz https://cdn.kernel.org/pub/linux/kernel/v7.x/$linux.tar.xz
    sha256sum -c <<<"87363c24f10e06321eb362765521094e94471f6bff8bce2d6b3e40f39f004953  dl/$linux.tar.xz"
    tar -C src -xf dl/$linux.tar.xz
fi

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

function kernel() {
    # kernel <label> <directory of the tools> <variables for the tools>...
    local t=$2 out=$work/build/linux
    local vars=(-C "$work/src/$linux" -s ARCH=x86_64 KCFLAGS=-Wno-error O="$out"
        CC="$t/clang" LD="$t/ld.lld" AR="$t/llvm-ar" NM="$t/llvm-nm" OBJCOPY="$t/llvm-objcopy"
        OBJDUMP="$t/llvm-objdump" READELF="$t/llvm-readelf" STRIP="$t/llvm-strip")
    rm -rf "$out"
    make "${vars[@]}" defconfig >/dev/null
    make "${vars[@]}" -j"$(nproc)" prepare >/dev/null 2>&1
    probe "$1" 1 env "${@:3}" make "${vars[@]}" -j"$(nproc)" kernel/ mm/
    echo "  $(find "$out"/kernel "$out"/mm -name '*.o' | wc -l) objects"
}

cd trigger
printf 'int main(void) { return 0; }\n' >small.c
gcc -O2 -Wall -o spin "$base"/spin.c

sizes=(64MiB 128MiB 256MiB 512MiB 1GiB)

echo "== a program that maps memory, writes to 4 MiB of it and ends, 500 times: MiB mapped"
for mapped in 64 1024; do
    probe "touch-$mapped" 500 ./spin 0 "$mapped" 4
done

echo "== one that takes 10 s of cpu time and keeps giving back and writing to 32 MiB: MiB mapped"
for mapped in 64 1024; do
    probe "churn-$mapped" 1 ./spin 10 "$mapped" 32 churn
done

echo "== clang of ${names[1]}, a short compile 500 times: the size of an arena"
for size in "${sizes[@]}"; do
    probe "short-$size" 500 env MIMALLOC_ARENA_RESERVE="$size" "$static"/clang -O2 -c -o small.o small.c
done

echo "== kernel/ and mm/ of the kernel of idle.sh"
kernel "${names[0]}" "$release"
for size in "${sizes[@]}"; do
    kernel "${names[1]}-$size" "$static" MIMALLOC_ARENA_RESERVE="$size"
done
echo "end $(date -Is)"
