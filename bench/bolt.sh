#!/usr/bin/env bash
# TEST: run llvm-bolt over the clang of a release again, from what the run that
# made the release left in build/llvm: once the way the release had it, "lite",
# and once the way of $1. Each goes into a copy of the release in place of its
# clang, is weighed there, and run.sh then compares the two.
#
#   trap: as lite, but the old bodies of the functions that moved are filled
#         with traps, which take next to no room once compressed
#   full: every function is laid out again, in the place of the old code

set -euo pipefail

base=$(dirname "$(readlink -f "$0")")
top=$PWD
work=$top/bench-work
build=$top/build/llvm
release=26.11-2
variant=$1
export BENCH=$work NAMES="lite $variant"

declare -A flags=(
    [lite]=''
    [trap]='--trap-old-code'
    [full]='--lite=0 --use-old-text'
)

mkdir -p "$work"/{dl,tc,log,out,release}
cd "$work"

# llvm-bolt needs more memory than a runner has to instrument clang with, and
# may do so here, see ci.sh
if [[ -n ${GITHUB_ACTIONS:-} ]]; then
    sudo fallocate -l 8G /swap-llvm
    sudo chmod 600 /swap-llvm
    sudo mkswap /swap-llvm
    sudo swapon /swap-llvm
    echo Y | sudo tee /sys/module/zswap/parameters/enabled
fi

tar=toolchain-$release-$(uname -m).tar.xz
curl -fsSL -o dl/"$tar" https://github.com/"${GITHUB_REPOSITORY:-usertam/toolchain}"/releases/download/"$release"/"$tar"
tar -C release -xf dl/"$tar"
echo "$release: tarball $(stat -c %s dl/"$tar") bytes, clang-24 $(stat -c %s release/bin/clang-24) bytes"
ldd "$build"/bootstrap/bin/llvm-bolt || true

function weigh() {
    # The tarball of 'ci.sh dist' with the compressor in $2
    # shellcheck disable=SC2046
    tar --sort=name \
        --mtime='1970-01-01' \
        --owner=0 --group=0 --numeric-owner \
        -I "$2" -cf - \
        -C "$1" $(ls "$1") | wc -c
}

printf 'name\tround\twall_s\tuser_s\tsys_s\tmaxrss_mib\n' >log/bolt.tsv
for name in lite "$variant"; do
    echo "::group::llvm-bolt, $name"
    # The command of the release, from the log of its BOLT job
    # shellcheck disable=SC2086
    python3 -I "$base"/stat.py run "$name" 0 log/bolt.tsv -- "$build"/bootstrap/bin/llvm-bolt \
        --data="$build"/final/clang.fdata \
        --dyno-stats \
        --icf=all \
        -o out/clang-24."$name" \
        --reorder-blocks=ext-tsp \
        --reorder-functions=cdsort \
        --split-all-cold \
        --split-functions \
        --use-gnu-stack \
        ${flags[$name]} \
        "$build"/final/bin/clang-24 2>&1 | tee log/bolt-"$name".log
    echo "::endgroup::"

    # What 'ci.sh fixup' does to it once it is installed
    cp -a release tc/"$name"
    cp out/clang-24."$name" tc/"$name"/bin/clang-24
    strip tc/"$name"/bin/clang-24
    # shellcheck disable=SC2016
    patchelf --set-rpath '$ORIGIN/../lib' tc/"$name"/bin/clang-24

    echo "$name: clang-24 is $(stat -c %s out/clang-24."$name") bytes from llvm-bolt, $(stat -c %s tc/"$name"/bin/clang-24) stripped," \
        "$(pixz -t <tc/"$name"/bin/clang-24 | wc -c) through pixz, $(pixz -t -9 <tc/"$name"/bin/clang-24 | wc -c) through pixz -9"
    echo "$name: tarball is $(weigh tc/"$name" pixz) bytes with pixz, $(weigh tc/"$name" 'pixz -9') with pixz -9"
    release/bin/llvm-readelf -SW tc/"$name"/bin/clang-24 | grep -E ' \.(bolt\.org\.)?(text|text\.cold|eh_frame|eh_frame_hdr) ' || true
done
cat log/bolt.tsv

if cmp -s tc/lite/bin/clang-24 release/bin/clang-24; then
    echo "lite: the clang-24 of $release, byte for byte"
else
    echo "lite: not the clang-24 of $release"
fi
rm -r out release

cd "$top"
exec bash "$base"/run.sh lite "$variant"
