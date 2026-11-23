#!/usr/bin/env bash
# TEST: what becomes of the toolchain when 'ci.sh fixup' strips it with
# llvm-strip, and when llvm-bolt goes without --use-gnu-stack, so that it moves
# the program header table of clang instead of taking the PT_GNU_STACK header
# for its new segment. The workflow runs the parts of this around ci.sh:
#
#      bolt: run llvm-bolt over the clang of the final stage again (prebolt/),
#            without --use-gnu-stack, and install that in place of the clang
#            of the release
#      host: what the strip of the host makes of the installed clang
#   compare: the distribution against the release

set -euo pipefail

top=$PWD
install=$top/install
build=$top/build/llvm
release=26.11-3
work=$top/strip-work

mkdir -p "$work"

# The program header table of $1, and where the ELF header has it
function headers() {
    readelf -hW "$1" | grep -E 'Start of program headers|Number of program headers'
    readelf -lW "$1" | grep -E '^ +(PHDR|LOAD|GNU_STACK)'
    readelf -dW "$1" | grep -E 'R(UN)?PATH' || echo "  no rpath"
}

# Whether the clang in $1/bin runs: it compiles and links C++ that throws
function runs() {
    cat >"$work"/throw.cc <<'CC'
#include <cstdio>
#include <stdexcept>
int main(int argc, char **) {
    try {
        if (argc)
            throw std::runtime_error("clang runs, and what it compiled does");
    } catch (const std::exception &e) {
        return puts(e.what()) < 0;
    }
    return 1;
}
CC
    "$1"/bin/clang --version | head -1 || return
    "$1"/bin/clang++ -O2 "${@:2}" "$work"/throw.cc -o "$work"/throw || return
    "$work"/throw
}

function do_bolt() {
    # llvm-bolt may need more memory than a runner has, see ci.sh
    if [[ -n ${GITHUB_ACTIONS:-} ]]; then
        sudo fallocate -l 8G /swap-llvm
        sudo chmod 600 /swap-llvm
        sudo mkswap /swap-llvm
        sudo swapon /swap-llvm
        echo Y | sudo tee /sys/module/zswap/parameters/enabled
    fi

    echo "The clang of the release, as installed:"
    headers "$install"/bin/clang-24

    # The command of the release, from the log of its BOLT job, without
    # --use-gnu-stack
    "$build"/bootstrap/bin/llvm-bolt \
        --data="$build"/final/clang.fdata \
        --dyno-stats \
        --icf=all \
        --lite=0 \
        -o "$work"/clang.bolt \
        --reorder-blocks=ext-tsp \
        --reorder-functions=cdsort \
        --split-all-cold \
        --split-functions \
        --use-old-text \
        "$top"/prebolt/clang-24

    echo "The clang without --use-gnu-stack:"
    headers "$work"/clang.bolt
    echo "$(stat -c %s "$install"/bin/clang-24) bytes with --use-gnu-stack, $(stat -c %s "$work"/clang.bolt) without"

    # In place of the one of the build, which keeps its mode, and installed
    # from there as 'ninja install-distribution' does it, where CMake changes
    # the rpath
    cat "$work"/clang.bolt >"$build"/final/bin/clang-24
    rm "$work"/clang.bolt
    if cmake -DCMAKE_INSTALL_COMPONENT=clang -P "$build"/final/cmake_install.cmake; then
        echo "RESULT: CMake installs the clang without --use-gnu-stack"
    else
        echo "RESULT: CMake does NOT install the clang without --use-gnu-stack (exit $?), so copy it"
        cat "$build"/final/bin/clang-24 >"$install"/bin/clang-24
    fi
    echo "As installed:"
    headers "$install"/bin/clang-24
    cmp "$build"/final/bin/clang-24 "$install"/bin/clang-24 || true
}

function do_host() {
    strip --version | head -1
    patchelf --version
    mkdir -p "$work"/host/bin "$work"/host/lib
    cp "$install"/bin/clang-24 "$work"/host/bin/
    ln -s clang-24 "$work"/host/bin/clang
    ln -s clang-24 "$work"/host/bin/clang++
    cp -a "$install"/lib/clang "$work"/host/lib/

    echo "Before:"
    headers "$work"/host/bin/clang-24
    runs "$work"/host || echo "RESULT: clang does not run before strip (exit $?)"

    strip "$work"/host/bin/clang-24 && echo "strip: exit 0" || echo "strip: exit $?"
    echo "After the strip of the host:"
    headers "$work"/host/bin/clang-24
    if runs "$work"/host; then
        echo "RESULT: the strip of the host leaves a clang that runs"
    else
        echo "RESULT: the strip of the host leaves a clang that does not run (exit $?)"
    fi
    rm -r "$work"/host
}

# Every file under $1 with its link count, its size, and the first name of
# its inode
function links() {
    find "$1" -type f -printf '%i %n %s %P\n' | sort -k1,1n -k4 |
        awk '{ if ($1 != last) { first = $4; last = $1 } print $4, $2, $3, first }' | sort
}

function do_compare() {
    local arch bin differ=0 file kind ours tar theirs tools=0
    arch=$(uname -m)
    tar=toolchain-$release-$arch.tar.xz
    theirs=$work/release
    ours=$work/ours

    mkdir -p "$theirs" "$ours"
    curl -fsSL --retry 5 --retry-all-errors -o "$work/$tar" \
        https://github.com/"${GITHUB_REPOSITORY:-usertam/toolchain}"/releases/download/"$release"/"$tar"
    tar -C "$theirs" -xf "$work/$tar"
    tar -C "$ours" -xf "$top"/toolchain-"$arch".tar.xz
    echo "RESULT: tarball: $(stat -c %s "$work/$tar") bytes in the release, $(stat -c %s "$top"/toolchain-"$arch".tar.xz) here"

    links "$theirs" >"$work"/theirs.txt
    links "$ours" >"$work"/ours.txt
    echo "RESULT: files: $(wc -l <"$work"/theirs.txt) in the release, $(wc -l <"$work"/ours.txt) here;" \
        "with more than one link: $(awk '$2 > 1' "$work"/theirs.txt | wc -l) in the release, $(awk '$2 > 1' "$work"/ours.txt | wc -l) here"
    if cmp -s <(awk '{ print $1, $2, $4 }' "$work"/theirs.txt) <(awk '{ print $1, $2, $4 }' "$work"/ours.txt); then
        echo "RESULT: the same names, linked to each other the same way"
    else
        echo "RESULT: NOT the same names or links:"
        diff <(awk '{ print $1, $2, $4 }' "$work"/theirs.txt) <(awk '{ print $1, $2, $4 }' "$work"/ours.txt) | head -40
    fi
    echo "RESULT: unpacked: $(awk '{ s += $3 / $2 } END { printf "%d", s }' "$work"/theirs.txt) bytes in the release," \
        "$(awk '{ s += $3 / $2 } END { printf "%d", s }' "$work"/ours.txt) here"

    # How each file compares: the same, the same once llvm-strip has been over
    # the one of the release as well, or neither
    while read -r file _; do
        kind=other
        if cmp -s "$theirs/$file" "$ours/$file"; then
            kind=same
        elif "$ours"/bin/llvm-strip -o "$work"/stripped "$theirs/$file" 2>/dev/null && cmp -s "$work"/stripped "$ours/$file"; then
            kind=same-stripped
        fi
        echo "$kind $(stat -c %s "$theirs/$file") $(stat -c %s "$ours/$file") $file"
    done < <(join "$work"/theirs.txt "$work"/ours.txt) >"$work"/kinds.txt
    echo "RESULT: files that are the same: $(grep -c '^same ' "$work"/kinds.txt)," \
        "the same once llvm-strip has been over the release's: $(grep -c '^same-stripped ' "$work"/kinds.txt)," \
        "neither: $(grep -c '^other ' "$work"/kinds.txt)"
    echo "Neither (release bytes, bytes here, name):"
    grep '^other ' "$work"/kinds.txt | head -150 || true
    echo "The same once stripped:"
    grep '^same-stripped ' "$work"/kinds.txt | head -150 || true

    echo "clang-24 of the release:"
    headers "$theirs"/bin/clang-24
    echo "clang-24 here:"
    headers "$ours"/bin/clang-24

    # Every tool says what it said in the release
    for bin in "$ours"/bin/* "$ours"/*-linux-gnu*/bin/*; do
        tools=$((tools + 1))
        if [[ $("$bin" --version 2>&1 | head -3) != "$("$theirs/${bin#"$ours"/}" --version 2>&1 | head -3)" ]]; then
            echo "$bin --version differs:"
            "$bin" --version 2>&1 | head -3 || true
            differ=$((differ + 1))
        fi
    done
    echo "RESULT: $tools tools asked for their version, $differ answer other than in the release"

    # clang with lld, and with the as and ld of binutils
    if runs "$ours" -fuse-ld=lld; then
        echo "RESULT: with lld: runs"
    else
        echo "RESULT: with lld: does NOT run (exit $?)"
    fi
    if runs "$ours" -fuse-ld=bfd -fno-integrated-as -v >"$work"/bfd.log 2>&1; then
        echo "RESULT: with as and ld.bfd: runs"
    else
        echo "RESULT: with as and ld.bfd: does NOT run (exit $?)"
    fi
    grep -E '^ "|runs|rror' "$work"/bfd.log | cut -c1-150 || true
    rm -r "$theirs" "$ours"
}

declare -F do_"${1:-}" >/dev/null || exit 33
do_"$1" "${@:2}"
