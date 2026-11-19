#!/usr/bin/env bash
# TEST: compare two releases of this repository, $1 and $2, on the machine this
# runs on: kernel builds, single files and startup. The two take turns in an
# order that changes every round, so that drift of the machine hits both alike,
# and a result is the ratio of the second to the first within a round.

set -euo pipefail

base=$(dirname "$(readlink -f "$0")")
work=$PWD/bench-work
names=("$1" "$2")
arch=$(uname -m)
jobs=$(nproc)
linux='linux-7.3'
sqlite='sqlite-amalgamation-3460000'
export BENCH=$work NAMES="${names[*]}"

case $arch in
    x86_64) karch=x86_64 ktarget=all ;;
    aarch64) karch=arm64 ktarget=Image ;;
esac

mkdir -p "$work"/{dl,tc,src/json/nlohmann,log,build}
cd "$work"

echo "machine: $arch, $jobs cpus, $(lscpu | sed -n 's/^Model name: *//p' | head -1), linux $(uname -r), root on $(findmnt -no SOURCE /)"
free -m | sed -n 2,3p
echo "transparent huge pages: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"

for name in "${names[@]}"; do
    tar=toolchain-$name-$arch.tar.xz
    curl -fsSL -o dl/"$tar" https://github.com/"${GITHUB_REPOSITORY:-usertam/toolchain}"/releases/download/"$name"/"$tar"
    mkdir tc/"$name"
    tar -C tc/"$name" -xf dl/"$tar"
    echo "$name: $(tc/"$name"/bin/clang --version | head -1), tarball sha256 $(sha256sum <dl/"$tar" | cut -c1-16)"
    # A clang that llvm-bolt went over has one more segment of code, aligned to 2 MiB
    tc/"$name"/bin/llvm-readelf -lW tc/"$name"/bin/clang | grep LOAD
done

curl -fsSL -o dl/$linux.tar.xz https://cdn.kernel.org/pub/linux/kernel/v7.x/$linux.tar.xz
curl -fsSL -o dl/$sqlite.zip https://www.sqlite.org/2024/$sqlite.zip
curl -fsSL -o src/json/nlohmann/json.hpp https://github.com/nlohmann/json/releases/download/v3.11.3/json.hpp
sha256sum -c <<EOF
87363c24f10e06321eb362765521094e94471f6bff8bce2d6b3e40f39f004953  dl/$linux.tar.xz
712a7d09d2a22652fb06a49af516e051979a3984adb067da86760e60ed51a7f5  dl/$sqlite.zip
9bea4c8066ef4a1c206b2be5a36302f8926f7fdc6087af5d20b417d0cf103ea6  src/json/nlohmann/json.hpp
EOF
tar -C src -xf dl/$linux.tar.xz
python3 -I -m zipfile -e dl/$sqlite.zip src

# Both get the C++ headers of the system's g++, whichever they would pick
cxxinc=(-nostdinc++)
while read -r dir; do
    cxxinc+=(-isystem "$dir")
done < <(g++ -E -v -x c++ /dev/null 2>&1 | sed -n '/^#include <...> search starts here:/,/^End of search list/p' | grep 'c++')

sqlite_o2=(clang -w -O2 -c "src/$sqlite/sqlite3.c" -o /dev/null)
sqlite_o0=(clang -w -O0 -g -c "src/$sqlite/sqlite3.c" -o /dev/null)
cxx_o2=(clang++ -w -std=c++20 -O2 "${cxxinc[@]}" -I src/json -c "$base"/json_regex.cpp -o /dev/null)
startup=(clang -c -x c /dev/null -o /dev/null)

function once() {
    local name
    for name in "${names[@]}"; do
        tc/"$name"/bin/"$1" "${@:2}"
    done
}

function pcache() {
    # Put the programs of both in the same state of the page cache: "seq" reads
    # them from start to end, "fault" leaves them to be read in as they run
    state=$1
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
    if [[ $state = seq ]]; then
        find -L tc/*/bin -maxdepth 1 -type f -exec cat {} + >/dev/null
    fi
    once "${sqlite_o2[@]}"
    once "${sqlite_o0[@]}"
    once "${cxx_o2[@]}"
    echo "== page cache: $state, $(grep FileHugePages /proc/meminfo | tr -s ' ')"
    python3 -I "$base"/stat.py maps -- "${sqlite_o2[@]}"
}

function kbuild() {
    local name=$1 round=$2 out=$work/build/linux-$1 t=$work/tc/$1/bin klog=$work/log/kernel-$TAG-$1-$2.log
    local vars=(-C "$work/src/$linux" -s -j"$jobs" ARCH="$karch" KCFLAGS=-Wno-error O="$out"
        CC="$t/clang" LD="$t/ld.lld" AR="$t/llvm-ar" NM="$t/llvm-nm" OBJCOPY="$t/llvm-objcopy"
        OBJDUMP="$t/llvm-objdump" READELF="$t/llvm-readelf" STRIP="$t/llvm-strip")
    rm -rf "$out"
    make "${vars[@]}" defconfig >"$klog" 2>&1
    sync
    python3 -I "$base"/stat.py run "$name" "$round" "$tsv" -- make "${vars[@]}" "$3" >>"$klog" 2>&1 || {
        tail -40 "$klog"
        exit 1
    }
    echo "$(date +%T) $name round $round: $(tail -1 "$tsv" | cut -f3-6 | tr '\t' ' ') objs=$(find "$out" -name '*.o' | wc -l)"
    rm -rf "$out"
}

function tu() {
    local label=$1 turns=$(($2 / scale))
    python3 -I "$base"/stat.py time "$label" "$state" "$((turns > 2 ? turns : 2))" -- "${@:3}"
}

function measure() {
    # measure <tag of the result lines> <kernel rounds> <kernel target> <turns divided by>
    export TAG=$1
    local rounds=$2 target=$3 round i
    scale=$4
    tsv=$work/log/kernel-$TAG.tsv

    pcache seq
    echo "== kernel: $linux $karch defconfig, make -j$jobs $target (round 0 warms the machine up)"
    printf 'name\tround\twall_s\tuser_s\tsys_s\tmaxrss_mib\n' >"$tsv"
    kbuild "${names[0]}" 0 "$target"
    for round in $(seq 1 "$rounds"); do
        for i in 0 1; do
            kbuild "${names[(i ^ (round - 1)) % 2]}" "$round" "$target"
        done
    done
    python3 -I "$base"/stat.py kernel "$tsv"

    for state in seq fault; do
        pcache "$state"
        tu sqlite-O2 12 "${sqlite_o2[@]}"
        tu sqlite-O0-g 40 "${sqlite_o0[@]}"
        tu cxx-O2 24 "${cxx_o2[@]}"
        tu startup 400 "${startup[@]}"
    done
}

# A short pass over everything first, for a mistake to show in minutes
echo "::group::Smoke test"
measure smoke 1 init/ 10
echo "::endgroup::"

measure result "${ROUNDS:-2}" "$ktarget" 1
echo "end $(date -Is)"
