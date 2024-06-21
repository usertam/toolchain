#!/usr/bin/env bash

base=$(dirname "$(readlink -f "$0")")
install=$base/install
src=$base/src

set -eu

function parse_parameters() {
    while (($#)); do
        case $1 in
            all | binutils | deps | kernel | llvm | fixup | dist) action=$1 ;;
            *) exit 33 ;;
        esac
        shift
    done
}

function do_all() {
    do_deps
    do_llvm
    do_binutils
    do_kernel
}

function do_binutils() {
    "$base"/build-binutils.py \
        --install-folder "$install" \
        --show-build-commands \
        --targets aarch64 arm x86_64
}

function do_deps() {
    # We only run this when running on GitHub Actions
    [[ -z ${GITHUB_ACTIONS:-} ]] && return 0

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
    extra_args=()
    [[ -n ${GITHUB_ACTIONS:-} ]] && extra_args+=(--no-ccache)

    "$base"/build-llvm.py \
        --assertions \
        --bolt \
        --build-targets distribution \
        --install-folder "$install" \
        --install-targets distribution \
        --lto thin \
        --pgo kernel-defconfig \
        --projects clang lld \
        --quiet-cmake \
        --shallow-clone \
        --show-build-commands \
        --targets AArch64 ARM X86 \
        --vendor-string usertam \
        "${extra_args[@]}"
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

function do_dist() {
    tar --sort=name \
        --mtime='1970-01-01' \
        --owner=0 --group=0 --numeric-owner \
        -I pixz -cf tc-build-install.tar.xz \
        -C "$install" $(ls -A "$install")
}

parse_parameters "$@"
do_"${action:=all}"
