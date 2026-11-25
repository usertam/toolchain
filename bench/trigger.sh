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
# cpu time of a compile on top, with one job as with four, and whatever the
# huge pages and the purging of the tool's mimalloc are set to. It takes
# nothing for the static binutils, which have the malloc of musl, for small or
# large static programs, or for 300000 calls of mmap, madvise, mprotect, open
# or fcntl in a row. And it takes the same 7% with the release during a
# compile that takes 20 s and much memory.
#
# So is it the address space? mimalloc maps 1 GiB as its first arena, however
# little of it gets used. This round: a program that maps memory and then
# computes, the static clang with a small arena, and part of the kernel of
# idle.sh with the arenas of the static clang set otherwise, and with the
# mimalloc of the distribution loaded into the clang of the release.

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

# 64 MiB at a time in place of 1 GiB
small_arena='MIMALLOC_ARENA_RESERVE=64MiB'
echo "the mimalloc of ${names[1]} with $small_arena:"
env MIMALLOC_VERBOSE=1 "$small_arena" "$static"/clang --version 2>&1 | grep -E 'arena_reserve|arena_eager_commit|disallow_arena_alloc|allow_thp' || true

echo "== a program that maps memory and takes 10 s of cpu time: MiB mapped, MiB of them written to"
probe spin-0-0 1 ./spin 10 0 0
for mapped in 128 1024 16384; do
    probe "spin-$mapped-0" 1 ./spin 10 "$mapped" 0
done
probe spin-1024-0-without-access 1 ./spin 10 1024 0 none
probe spin-1024-512 1 ./spin 10 1024 512
probe spin-512-512 1 ./spin 10 512 512

echo "== the same without the 10 s, 500 times each"
probe map-0 500 ./spin 0 0 0
probe map-1024 500 ./spin 0 1024 0

echo "== clang of ${names[1]}, 500 times each: its version, a short compile"
probe version 500 "$static"/clang --version
probe version-small-arena 500 env "$small_arena" "$static"/clang --version
probe short 500 "$static"/clang -O2 -c -o small.o small.c
probe short-small-arena 500 env "$small_arena" "$static"/clang -O2 -c -o small.o small.c

echo "== kernel/ and mm/ of the kernel of idle.sh"
kernel "${names[0]}" "$release"
kernel "${names[1]}" "$static"
kernel "${names[1]}-small-arena" "$static" "$small_arena"
kernel "${names[1]}-arena-not-committed" "$static" MIMALLOC_ARENA_EAGER_COMMIT=0
kernel "${names[1]}-no-arena" "$static" MIMALLOC_DISALLOW_ARENA_ALLOC=1

# The release with a mimalloc in its clang, where the distribution has one
sudo apt-get install -y libmimalloc2.0 >/dev/null 2>&1 || true
lib=$(dpkg -L libmimalloc2.0 2>/dev/null | grep -m1 '/libmimalloc\.so\.[0-9.]*$' || true)
if [[ -n $lib ]]; then
    mkdir -p "$work"/preload
    ln -sf "$release"/* "$work"/preload/
    rm "$work"/preload/clang
    printf '#!/bin/sh\nLD_PRELOAD=%s exec %s "$@"\n' "$lib" "$release"/clang >"$work"/preload/clang
    chmod +x "$work"/preload/clang
    echo "$lib in the clang of ${names[0]}:"
    env MIMALLOC_VERBOSE=1 "$work"/preload/clang --version 2>&1 | grep -E 'mimalloc: (v|option .arena_reserve)|clang version' || true
    kernel "${names[0]}-mimalloc" "$work"/preload
else
    echo "== no mimalloc to load here"
fi
echo "end $(date -Is)"
