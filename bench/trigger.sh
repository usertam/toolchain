#!/usr/bin/env bash
# TEST: what of the static toolchain keeps provjobd busy. On the hosted runners
# a kernel build with the static toolchain takes less cpu time than with the
# release and yet as long or longer, as provjobd, a process of the runner, takes
# two cpu-minutes of the four cpus meanwhile, against two seconds with the
# release (idle.sh). Run tools of $1 and $2 and some small programs, one at a
# time, so that a cpu is free for provjobd, and let probe.py say how much cpu
# time it took for each: is it what is run, how often, or what it does. Then
# part of the kernel of idle.sh, where it is known to be busy, with the
# allocator of $2 set otherwise and with one job.

set -euo pipefail

base=$(dirname "$(readlink -f "$0")")
work=$PWD/bench-work
names=("$1" "$2")
arch=$(uname -m)
linux='linux-7.3'

mkdir -p "$work"/{dl,tc,src,log,build,trigger}
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
    # kernel <label> <name> <jobs> <variables for the tools>...
    local t=$work/tc/$2/bin out=$work/build/linux
    local vars=(-C "$work/src/$linux" -s ARCH=x86_64 KCFLAGS=-Wno-error O="$out"
        CC="$t/clang" LD="$t/ld.lld" AR="$t/llvm-ar" NM="$t/llvm-nm" OBJCOPY="$t/llvm-objcopy"
        OBJDUMP="$t/llvm-objdump" READELF="$t/llvm-readelf" STRIP="$t/llvm-strip")
    rm -rf "$out"
    make "${vars[@]}" defconfig >/dev/null
    make "${vars[@]}" -j"$(nproc)" prepare >/dev/null 2>&1
    probe "$1" 1 env "${@:4}" make "${vars[@]}" -j"$3" kernel/ mm/
    echo "  $(find "$out"/kernel "$out"/mm -name '*.o' | wc -l) objects"
}

cd trigger
printf 'int main(void) { return 0; }\n' >small.c
printf 'const char pad[128 << 20] = {1};\nint main(int argc, char **argv) { return pad[argc]; }\n' >large.c
gcc -O2 -o small small.c
gcc -O2 -static -o small-static small.c
gcc -O2 -static-pie -o small-static-pie small.c
gcc -O2 -o large large.c
gcc -O2 -static -o large-static large.c
gcc -O2 -Wall -o calls "$base"/calls.c
# A source that takes a compiler some seconds
for i in $(seq 12000); do
    echo "int f$i(int n, int *p) { for (int i = 0; i < n; i++) p[i] += n * $i; return p[n / 2] + $i; }"
done >long.c
stat -c '%s bytes: %n' small small-static small-static-pie large large-static

echo "== nothing but a sleep"
probe sleep 1 sleep 20

echo "== programs that do nothing, 500 times each"
for program in small small-static small-static-pie large large-static; do
    probe "$program" 500 ./"$program"
done

echo "== tools that say their version, 500 times each"
for name in "${names[@]}"; do
    for tool in clang ld.lld llvm-ar ld; do
        echo "$(stat -Lc %s "$work/tc/$name/bin/$tool") bytes, $(file -bL "$work/tc/$name/bin/$tool" | cut -d, -f1-2,4 | cut -c1-90)"
        probe "$name-$tool" 500 "$work/tc/$name/bin/$tool" --version
    done
done

echo "== compiles: one that takes long twice, a short one 500 times"
for name in "${names[@]}"; do
    probe "$name-long" 2 "$work/tc/$name/bin/clang" -O2 -c -o long.o long.c
    probe "$name-short" 500 "$work/tc/$name/bin/clang" -O2 -c -o small.o small.c
done

echo "== system calls, 300000 of a kind"
for call in mmap madvise mprotect open fcntl; do
    probe "$call" 1 ./calls "$call" 300000
done

echo "== kernel/ and mm/ of the kernel of idle.sh"
kernel "${names[0]}" "${names[0]}" "$(nproc)"
kernel "${names[1]}" "${names[1]}" "$(nproc)"
kernel "${names[1]}-no-purge" "${names[1]}" "$(nproc)" MIMALLOC_PURGE_DELAY=-1
kernel "${names[1]}-huge-pages" "${names[1]}" "$(nproc)" MIMALLOC_ALLOW_THP=1
kernel "${names[1]}-one-job" "${names[1]}" 1
echo "end $(date -Is)"
