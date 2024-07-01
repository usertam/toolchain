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
        pixz \
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

function do_fixup() {
    echo "Removing unused products..."
    rm -rf "$install"/include "$install"/lib/*.a "$install"/lib/*.la

    echo "Stripping remaining products..."
    find "$install" -type f -executable -exec strip {} \;

    echo "Patching rpaths for portability..."
    for bin in $(find "$install" -mindepth 2 -maxdepth 3 -type f -exec file {} \; | grep 'ELF .* interpreter' | awk '{print $1}'); do
        # Remove last character from file output (':')
        bin="${bin: : -1}"
        echo "- $bin"
        patchelf --set-rpath '$ORIGIN/../lib' "$bin"
    done
}

function do_bootstrap() {
    do_llvm --actions-stage bootstrap
}

function do_instrumented() {
    do_llvm --actions-stage instrumented
}

function do_profiling() {
    do_llvm --actions-stage profiling
}

function do_final() {
    do_llvm --actions-stage final
}

function do_pack() {
    tar -cf artifact.tar \
        $(ls -d src build install)
}

function do_unpack() {
    tar -xf artifact.tar
    rm -rf artifact.tar
}

function do_dist() {
    tar --sort=name \
        --mtime='1970-01-01' \
        --owner=0 --group=0 --numeric-owner \
        -I pixz -cf toolchain-build.tar.xz \
        -C "$install" $(ls "$install")
}

function do_revision() {
    hash=$(git -C src/llvm-project rev-parse HEAD | cut -c -7)
    date=$(date +%y%m%d)
    cat <<EOF > revision-notes.md
Built against the main branch of [llvm-project](https://github.com/llvm/llvm-project) on commit \`$hash\`.
- Projects: clang, lld
- Targets: aarch64, arm, x86
- Bolt: None
- LTO: ThinLTO (thin)
- PGO: kernel-defconfig
EOF
    echo "r$date.$hash"
}

eval "$@"
