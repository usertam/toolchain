#!/usr/bin/env bash

set -eo pipefail

# Function to show an informational message
function msg() {
    echo -e "\e[1;32m$@\e[0m"
}

# cd to script dir
cd "${0%/*}"

# Build LLVM
msg "Building LLVM..."
./build-llvm.py \
	--clang-vendor "usertam" \
	--targets "ARM;AArch64;X86" \
	--shallow-clone \
	--pgo kernel-defconfig \
	--lto thin

# Build binutils
msg "Building binutils..."
./build-binutils.py --targets arm aarch64 x86_64

# Remove unused products
msg "Removing unused products..."
rm -fr install/include
rm -f install/lib/*.a install/lib/*.la

# Strip remaining products
msg "Stripping remaining products..."
for f in $(find install -type f -exec file {} \; | grep 'not stripped' | awk '{print $1}'); do
	strip ${f: : -1}
done

# Set executable rpaths so setting LD_LIBRARY_PATH isn't necessary
msg "Setting library load paths for portability..."
for bin in $(find install -mindepth 2 -maxdepth 3 -type f -exec file {} \; | grep 'ELF .* interpreter' | awk '{print $1}'); do
	# Remove last character from file output (':')
	bin="${bin: : -1}"

	echo "$bin"
	patchelf --set-rpath '$ORIGIN/../lib' "$bin"
done

# Create tar.xz archive of built toolchain
msg "Creating toolchain archive..."
XZ_OPT="-9 -T0" tar --sort=name \
    --mtime='1970-01-01' \
    --owner=0 --group=0 --numeric-owner \
    -cJf tc-build-install.tar.xz \
    -C install $(ls -A install)
