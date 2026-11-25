#!/usr/bin/env bash
# TEST: where a kernel build with the static toolchain leaves the cpus idle. In
# the comparison of run.sh it takes less cpu time than the release and yet as
# long or longer, on every runner. Build the kernel of run.sh with $1 and $2 in
# turn: as run.sh does, then with every tool of the toolchain run through twrap,
# which notes its times, then with the time the tools are off the cpus traced by
# bpftrace, where that is to be had. probe.py says after each build what the
# machine did meanwhile.

set -euo pipefail

base=$(dirname "$(readlink -f "$0")")
work=$PWD/bench-work
names=("$1" "$2")
arch=$(uname -m)
jobs=$(nproc)
linux='linux-7.3'
target=${TARGET:-all}

mkdir -p "$work"/{dl,tc,src,log,build,wrap}
cd "$work"

echo "machine: $arch, $jobs cpus, $(lscpu | sed -n 's/^Model name: *//p' | head -1), linux $(uname -r), root on $(findmnt -no SOURCE /)"
free -m | sed -n 2,3p
echo "transparent huge pages: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
echo "$(make --version | head -1), sh is $(readlink -f /bin/sh)"

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

# One twrap under the name of every tool the kernel is built with
gcc -O2 -Wall -o wrap/twrap "$base"/twrap.c
for tool in clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readelf llvm-strip; do
    ln -sf twrap wrap/"$tool"
done

function kbuild() {
    # kbuild <name> <label> <directory make takes the tools from>
    local name=$1 label=$2 t=$3 out=$work/build/linux klog=$work/log/kernel-$2.log tsv=$work/log/tools-$2.tsv
    local vars=(-C "$work/src/$linux" -s -j"$jobs" ARCH=x86_64 KCFLAGS=-Wno-error O="$out"
        CC="$t/clang" LD="$t/ld.lld" AR="$t/llvm-ar" NM="$t/llvm-nm" OBJCOPY="$t/llvm-objcopy"
        OBJDUMP="$t/llvm-objdump" READELF="$t/llvm-readelf" STRIP="$t/llvm-strip")
    export TWRAP_BIN=$work/tc/$name/bin TWRAP_LOG=/dev/null
    rm -rf "$out"
    make "${vars[@]}" defconfig >"$klog" 2>&1
    sync
    TWRAP_LOG=$tsv python3 -I "$base"/probe.py "$label" "$klog" "$tsv" -- make "${vars[@]}" "$target" || {
        tail -40 "$klog"
        exit 1
    }
    rm -rf "$out"
}

function traced() {
    local name=$1 txt=$work/log/offcpu-$1.txt pid
    sudo env BPFTRACE_MAP_KEYS_MAX=65536 BPFTRACE_MAX_MAP_KEYS=65536 bpftrace -o "$txt" "$base"/offcpu.bt &
    pid=$!
    for _ in $(seq 60); do
        grep -qs attached "$txt" && break
        sleep 1
    done
    # Without the trace the build would say nothing new
    if grep -qs attached "$txt"; then
        kbuild "$name" "traced-$name" "$work/tc/$name/bin"
    fi
    sudo pkill -INT -x bpftrace || true
    wait "$pid" || true
    echo "== off the cpus with $name, ns"
    head -600 "$txt" || true
}

echo "== make -j$jobs $target as run.sh builds it (the first build warms the machine up)"
kbuild "${names[0]}" warmup "$work/tc/${names[0]}/bin"
kbuild "${names[0]}" "plain-${names[0]}" "$work/tc/${names[0]}/bin"
kbuild "${names[1]}" "plain-${names[1]}" "$work/tc/${names[1]}/bin"

echo "== with every tool of the toolchain through twrap"
kbuild "${names[1]}" "wrapped-${names[1]}" "$work/wrap"
kbuild "${names[0]}" "wrapped-${names[0]}" "$work/wrap"

# The image is without bpftrace, and not every kernel takes the one of the distribution
sudo apt-get install -y bpftrace >/dev/null 2>&1 || true
if sudo bpftrace -e 'BEGIN { exit(); }' >/dev/null 2>&1; then
    traced "${names[0]}"
    traced "${names[1]}"
else
    echo "== no bpftrace that works here"
fi
echo "end $(date -Is)"
