#!/bin/bash
# Tools the bootstrap needs on the build machine that a stock installation
# may lack, built from source into build/host-tools. Nothing here ships and
# nothing needs root.
#
#   ninja, cmake    LLVM's build (bootstrap/stage1.sh)
#   mtools          images' EFI system partitions (dave image build)
#   xorriso         the live medium's ISO 9660 file system
#   mksquashfs      the live medium's compressed root, with the xz
#                   compressor and its arm64 filter
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
source "$top/bootstrap/lib.sh"
export PATH=$hosttools/bin:$PATH
mkdir -p "$hosttools/bin"
jobs=$(nproc)

ninja() {
    unpack ninja-1.13.2.tar.gz
    python3 configure.py --bootstrap
    install -m755 ninja "$hosttools/bin/ninja"
}

cmake() {
    unpack cmake-4.4.5.tar.gz
    # Its bundled libraries: none of the host's are needed, and cmake never
    # downloads anything for the bootstrap, so it needs no TLS either.
    ./bootstrap --prefix="$hosttools" --parallel="$jobs" --no-qt-gui -- \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_USE_OPENSSL=OFF -DBUILD_TESTING=OFF
    make -j"$jobs"
    make install
}

mtools() {
    unpack mtools-4.0.49.tar.bz2
    ./configure --prefix="$hosttools" --disable-floppyd
    make -j"$jobs"
    make install
}

xorriso() {
    unpack xorriso-1.5.8.pl02.tar.gz
    ./configure --prefix="$hosttools"
    make -j"$jobs"
    make install
}

# The xz and zstd compressors only: they need this machine's xz and zstd
# libraries and headers, and nothing else.
squashfs() {
    unpack squashfs-tools-4.7.5.tar.gz
    make -C squashfs-tools -j"$jobs" GZIP_SUPPORT=0 LZO_SUPPORT=0 LZ4_SUPPORT=0 \
        XZ_SUPPORT=1 ZSTD_SUPPORT=1 COMP_DEFAULT=xz \
        INSTALL_DIR="$hosttools/bin" INSTALL_MANPAGES_DIR= install
}

step host-ninja ninja
step host-cmake cmake
step host-mtools mtools
step host-xorriso xorriso
step host-squashfs squashfs
