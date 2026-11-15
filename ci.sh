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
        pixz \
        pkg-config \
        python3 \
        texinfo \
        xz-utils \
        zlib1g-dev
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
    "$base"/build-llvm.py \
        --projects clang lld \
        --targets AArch64 ARM X86 \
        --lto thin \
        --pgo kernel-defconfig \
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

    echo "Stripping remaining products..."
    find "$install" -type f -executable -exec strip {} \;

    echo "Patching rpaths for portability..."
    find "$install" -mindepth 2 -maxdepth 3 -type f -print0 | while IFS= read -r -d '' bin; do
        file -b "$bin" | grep -q 'ELF .* interpreter' || continue
        echo "- $bin"
        # shellcheck disable=SC2016
        patchelf --set-rpath '$ORIGIN/../lib' "$bin"
    done
}

# Carry the source, build, and install folders over to the next CI job
function do_pack() {
    local dirs=()
    for dir in build install src; do
        [[ -d $base/$dir ]] && dirs+=("$dir")
    done
    tar -C "$base" -cf "$base"/artifact.tar "${dirs[@]}"
}

function do_unpack() {
    tar -C "$base" -xf "$base"/artifact.tar
    rm -f "$base"/artifact.tar
}

function do_dist() {
    # shellcheck disable=SC2046
    tar --sort=name \
        --mtime='1970-01-01' \
        --owner=0 --group=0 --numeric-owner \
        -I pixz -cf "$base"/toolchain-build.tar.xz \
        -C "$install" $(ls "$install")
}

function do_release() {
    local asset=$base/toolchain-build.tar.xz commit linux month rel
    commit=$(git -C "$src"/llvm-project rev-parse HEAD)
    month=$(date +%y.%m)

    # build-llvm.py downloads the Linux source for PGO into src/linux-<version>
    linux=$(find "$src" -mindepth 1 -maxdepth 1 -type d -name 'linux-*' -printf '%f' -quit)

    # Releases are numbered within each month (YY.MM-1, YY.MM-2, ...), so
    # find the highest number tagged so far
    rel=$(gh api "repos/{owner}/{repo}/git/matching-refs/tags/$month-" \
        --jq '[.[].ref | split("-")[1] | tonumber?] | max // 0')

    gh release create "$month-$((rel + 1))" "$asset" \
        --notes-file - \
        --target "$(git -C "$base" rev-parse HEAD)" <<EOF
Built against the tip of llvm-project at commit [\`${commit:0:7}\`](https://github.com/llvm/llvm-project/commit/$commit).
- Projects: clang, lld
- Targets: aarch64, arm, x86
- BOLT: None
- LTO: ThinLTO
- PGO: kernel-defconfig on $linux
EOF
}

# Run the requested action with any extra arguments (e.g. 'ci.sh llvm --actions-stage final')
declare -F do_"${1:-}" >/dev/null || exit 33
do_"$1" "${@:2}"
