#!/usr/bin/env bash

base=$(dirname "$(readlink -f "$0")")
install=$base/install
src=$base/src

set -eu

function do_binutils() {
    "$base"/build-binutils.py \
        --install-folder "$install" \
        --show-build-commands \
        --targets aarch64 arm x86_64
}

function do_deps() {
    # We only run this when running on GitHub Actions
    [[ -z ${GITHUB_ACTIONS:-} ]] && return 0

    # Refresh mirrorlist to avoid dead mirrors
    sudo apt-get update -y

    sudo apt-get install -y --no-install-recommends \
        bc \
        bison \
        ca-certificates \
        clang \
        cmake \
        curl \
        file \
        flex \
        gcc \
        g++ \
        git \
        libelf-dev \
        libssl-dev \
        lld \
        make \
        ninja-build \
        patchelf \
        pkg-config \
        python3 \
        texinfo \
        xz-utils \
        zlib1g-dev \
        zstd
}

function do_kernel() {
    local branch=linux-rolling-stable
    local linux=$src/$branch

    if [[ -d $linux ]]; then
        git -C "$linux" fetch --depth=1 origin $branch
        git -C "$linux" reset --hard FETCH_HEAD
    else
        git clone \
            --branch "$branch" \
            --depth=1 \
            --single-branch \
            https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git \
            "$linux"
    fi

    cat <<EOF | env PYTHONPATH="$base"/tc_build python3 -
from pathlib import Path

from kernel import LLVMKernelBuilder

builder = LLVMKernelBuilder()
builder.folders.build = Path('$base/build/linux')
builder.folders.source = Path('$linux')
builder.matrix = {'defconfig': ['X86']}
builder.toolchain_prefix = Path('$install')
builder.silent = False

builder.build()
EOF
}

function do_llvm() {
    # On GitHub Actions, llvm-bolt needs more memory to instrument clang than
    # a runner has, so give it more swap to fall back on, and let zswap keep
    # what is swapped out compressed in memory before any of it goes to disk
    if [[ -n ${GITHUB_ACTIONS:-} ]]; then
        sudo fallocate -l 8G /swap-llvm
        sudo chmod 600 /swap-llvm
        sudo mkswap /swap-llvm
        sudo swapon /swap-llvm
        echo Y | sudo tee /sys/module/zswap/parameters/enabled
    fi

    "$base"/build-llvm.py \
        --projects clang lld \
        --targets AArch64 ARM X86 \
        --bolt \
        --lto thin \
        --pgo kernel-defconfig \
        --cspgo \
        --build-targets distribution \
        --install-targets distribution \
        --vendor-string usertam \
        --install-folder "$install" \
        --quiet-cmake \
        --shallow-clone \
        --show-build-commands \
        --no-ccache \
        --no-update \
        "$@"
}

# build-llvm.py can only shallow clone a branch, so fetch the exact commit to
# build first, which build-llvm.py then uses as is
function do_fetch() {
    local llvm=$src/llvm-project
    git init -q "$llvm"
    git -C "$llvm" remote add origin https://github.com/llvm/llvm-project.git
    git -C "$llvm" fetch --depth=1 origin "$1"
    git -C "$llvm" checkout -q FETCH_HEAD
}

function do_rust() {
    "$base"/build-rust.py \
        --debug \
        --llvm-install-folder "$install" \
        --install-folder "$install" \
        --show-build-commands
}

function do_fixup() {
    echo "Removing unused products..."
    rm -rf "$install"/include "$install"/lib/*.a "$install"/lib/*.la

    # GNU strip before 2.44, which is what the host has, breaks a binary whose
    # program header table llvm-bolt has moved, so strip with the llvm-strip
    # that was just built. It replaces the file it strips, which leaves the
    # other hard links of a binutils tool as they were, so link those again
    echo "Stripping remaining products..."
    find "$install" -type f \( -executable -o -name '*.so*' \) -printf '%i %p\0' | sort -zn |
        while read -r -d '' inode bin; do
            if [[ $inode = "${last:-}" ]]; then
                ln -f "$stripped" "$bin"
            else
                "$install"/bin/llvm-strip "$bin"
                last=$inode stripped=$bin
            fi
        done

    echo "Patching rpaths for portability..."
    find "$install" -mindepth 2 -maxdepth 3 -type f -print0 | while IFS= read -r -d '' bin; do
        file -b "$bin" | grep -q 'ELF .* interpreter' || continue
        echo "- $bin"
        # shellcheck disable=SC2016
        patchelf --set-rpath '$ORIGIN/../lib' "$bin"
    done
}

# Carry the source, build, and install folders over to the next CI job, in the
# .tar.zst file named by the argument
function do_pack() {
    local dirs=()
    for dir in build install src; do
        [[ -d $base/$dir ]] && dirs+=("$dir")
    done
    tar -C "$base" -I 'zstd -T0' -cf "$base/$1" "${dirs[@]}"
}

function do_unpack() {
    tar -C "$base" -I zstd -xf "$base/$1"
    rm -f "$base/$1"
}

function do_dist() {
    local commit linux xz
    commit=$(git -C "$src"/llvm-project rev-parse HEAD)

    # build-llvm.py downloads the Linux source for PGO into src/linux-<version>
    linux=$(find "$src" -mindepth 1 -maxdepth 1 -type d -name 'linux-*' -printf '%f' -quit)

    # One thread makes a single block, which is smaller than several. On
    # x86_64, the filter for x86 code adds to that, and every xz can undo it;
    # the one for arm64 code needs xz 5.4, so aarch64 goes without
    xz='xz -T1 -9e'
    [[ $(uname -m) = x86_64 ]] && xz='xz -T1 --x86 --lzma2=preset=9e'

    # shellcheck disable=SC2046
    tar --sort=name \
        --mtime='1970-01-01' \
        --owner=0 --group=0 --numeric-owner \
        -I "$xz" -cf "$base/toolchain-$(uname -m).tar.xz" \
        -C "$install" $(ls "$install")

    cat <<EOF >"$base"/notes.md
Built against the tip of llvm-project at commit [\`${commit:0:7}\`](https://github.com/llvm/llvm-project/commit/$commit).
- Projects: clang, lld
- Targets: aarch64, arm, x86
- PGO: IR and CSIR instrumentation, arm64 virtconfig, arm multi_v5/aspeed_g5/multi_v7 and x86_64 defconfig on $linux
- PLO: BOLT, instrumentation, host kernel (arm64 virtconfig or x86_64 defconfig) on $linux
- LTO: ThinLTO
EOF
}

# Publish the distributions of every arch, downloaded into distribution-<arch>
function do_release() {
    local asset assets=() month note notes rel tag
    month=$(date +%y.%m)

    # Releases are numbered within each month (YY.MM-1, YY.MM-2, ...), so
    # find the highest number tagged so far
    rel=$(gh api "repos/{owner}/{repo}/git/matching-refs/tags/$month-" \
        --jq '[.[].ref | split("-")[1] | tonumber?] | max // 0')
    tag=$month-$((rel + 1))

    # Every arch must have been built from the same sources
    notes=("$base"/distribution-*/notes.md)
    for note in "${notes[@]}"; do
        cmp "${notes[0]}" "$note"
    done

    # Add the tag to each asset name, as in toolchain-YY.MM-N-x86_64.tar.xz
    for asset in "$base"/distribution-*/toolchain-*.tar.xz; do
        assets+=("${asset%/*}/toolchain-$tag-${asset##*/toolchain-}")
        mv "$asset" "${assets[-1]}"
    done

    gh release create "$tag" "${assets[@]}" \
        --notes-file "${notes[0]}" \
        --target "$(git -C "$base" rev-parse HEAD)"
}

# Run the requested action with any extra arguments (e.g. 'ci.sh llvm --actions-stage final')
declare -F do_"${1:-}" >/dev/null || exit 33
do_"$1" "${@:2}"
