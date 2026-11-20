# How joe Linux builds bionic, shared by the bootstrap (bootstrap/stage1.sh)
# and the bionic package's recipe; sourced, so it only defines functions.
#
# bionic is built from AOSP's sources with AOSP's own build descriptions:
# bp/ evaluates the Android.bp files the way Soong does for an arm64 device
# and writes a ninja file. joe's changes are the patches in patches/ (what a
# Linux system needs of its C library) and the modules in overlay/ (stand-ins
# for the parts of AOSP joe does not build).
#
# The functions take their toolchain from the environment, as bp/joe.py
# describes: JOE_CROSS, JOE_SYSROOT, JOE_TARGET, JOE_BUILTINS, JOE_RUNTIMES.

bionic_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# The files of SOURCES that bionic_tree unpacks, one per line.
bionic_sources() {
    local path commit
    while read -r path commit; do
        [[ -z $path || $path == \#* ]] && continue
        echo "aosp-${path//\//-}-$commit.tar"
    done <"$bionic_dir/aosp.list"
    echo UCD-17.0.0.zip
}

# bionic_tree SOURCES TREE: an AOSP tree with what joe builds bionic from,
# patched, with joe's overlay in TREE/joe.
bionic_tree() {
    local sources=$1 tree=$2 path commit p
    rm -rf "$tree"
    mkdir -p "$tree"
    while read -r path commit; do
        [[ -z $path || $path == \#* ]] && continue
        mkdir -p "$tree/$path"
        tar -xf "$sources/aosp-${path//\//-}-$commit.tar" -C "$tree/$path" --strip-components=1
    done <"$bionic_dir/aosp.list"
    # patches/*.patch are bionic's; patches/PATH/*.patch those of the
    # repository at PATH in the tree (patches/system/logging: liblog).
    for p in "$bionic_dir"/patches/*.patch; do
        patch -d "$tree/bionic" -p1 -s -N --no-backup-if-mismatch <"$p"
    done
    local dir
    while read -r dir; do
        for p in "$dir"/*.patch; do
            patch -d "$tree/${dir#"$bionic_dir/patches/"}" -p1 -s -N --no-backup-if-mismatch <"$p"
        done
    done < <(find "$bionic_dir/patches" -mindepth 2 -name '*.patch' -printf '%h\n' | sort -u)
    cp -a "$bionic_dir/overlay" "$tree/joe"
    python3 -I "$bionic_dir/overlay/unicode/gen.py" "$sources/UCD-17.0.0.zip" >"$tree/joe/unicode/icu4x.c"
}

# bionic_headers TREE DEST: the C library's headers, and the kernel's as
# bionic ships them, in DEST/usr/include, laid out as libc_headers exports
# them: the kernel's uapi (with arm64's asm), Android's additions to it, then
# libc's own.
bionic_headers() {
    local libc=$1/bionic/libc dest=$2/usr/include
    mkdir -p "$dest"
    cp -a "$libc/kernel/uapi/." "$dest/"
    rm -rf "$dest"/asm-{arm,arm64,riscv,x86}
    cp -a "$libc/kernel/uapi/asm-arm64/asm" "$dest/asm"
    cp -a "$libc/kernel/android/scsi/." "$libc/kernel/android/uapi/." "$dest/"
    cp -a "$libc/include/." "$dest/"
}

# bionic_build TREE OUT PRODUCT...: build the named products (see
# bp/bpbuild.py) in OUT.
bionic_build() {
    local tree=$1 out=$2
    shift 2
    python3 -I "$bionic_dir/bp/bpbuild.py" --tree "$tree" --out "$out" \
        --overlay "$tree/joe/Android.bp" "$@"
    ninja -C "$out" ${JOBS:+-j"$JOBS"}
}

# The products of the C library proper, and of the dynamic linker, which
# links libc++ and so is built after it.
bionic_libc_products=(
    libc:shared libc:static libm:shared libm:static libdl:shared libdl:static
    ld-android:shared crtbegin_dynamic crtbegin_so crtbegin_static crtend_android crtend_so
)
bionic_linker_products=(linker)

# Android's logging library, which Rust's standard library for Android
# links (-llog); joe's writes to standard error (patches/system/logging).
bionic_liblog_products=(liblog:shared)

# The parts of LLVM's runtimes bionic's build needs, from LLVM's source:
#
#   libunwind.a           with hidden symbols, which clang links into every
#                         program (-l:libunwind.a), and which the dynamic
#                         linker links;
#   libunwind-exported.a  with visible symbols, which libc.so links whole
#                         and exports, as Android's does;
#   libc++_noexcept.a     libc++ (with libc++abi) without exceptions, which
#                         the dynamic linker links (Android's
#                         libc++_static_noexcept).
#
# bionic_runtimes_cmake DIR LLVM_SRC [ARGS...] configures LLVM's runtimes in
# DIR for the target, as Android's own: with __ANDROID__, which the cross
# toolchain otherwise leaves undefined. libunwind can be built before there is a C library:
# its configure checks then only compile, and would find a -ldl and a
# -lpthread that bionic does not have (both are in libc), so they are
# overridden. libc++ needs a C library to configure against; its compiler
# checks are skipped because they would link -lc++, which it builds.
bionic_runtimes_cmake() {
    local dir=$1 llvm=$2
    shift 2
    cmake -G Ninja -S "$llvm/runtimes" -B "$dir" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER="$JOE_CROSS/bin/clang" -DCMAKE_CXX_COMPILER="$JOE_CROSS/bin/clang++" \
        -DCMAKE_ASM_COMPILER="$JOE_CROSS/bin/clang" \
        -DCMAKE_AR="$JOE_CROSS/bin/llvm-ar" -DCMAKE_RANLIB="$JOE_CROSS/bin/llvm-ranlib" \
        -DCMAKE_NM="$JOE_CROSS/bin/llvm-nm" \
        -DCMAKE_C_COMPILER_TARGET="$JOE_TARGET" -DCMAKE_CXX_COMPILER_TARGET="$JOE_TARGET" \
        -DCMAKE_ASM_COMPILER_TARGET="$JOE_TARGET" \
        -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 -DCMAKE_SYSROOT="$JOE_SYSROOT" \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
        -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF "$@"
}

bionic_unwind_args=(
    -DLIBUNWIND_HAS_DL_LIB=OFF -DLIBUNWIND_HAS_PTHREAD_LIB=OFF
    -DLIBUNWIND_ENABLE_SHARED=OFF -DLIBUNWIND_ENABLE_STATIC=ON -DLIBUNWIND_USE_COMPILER_RT=ON
    -DLIBUNWIND_INCLUDE_TESTS=OFF -DLIBUNWIND_INCLUDE_DOCS=OFF
)

# libc++ as joe's C++ standard library (installed by llvm-runtimes and by
# the bootstrap): with libc++abi merged in and a static libunwind.
bionic_libcxx_args=(
    -DCMAKE_C_COMPILER_WORKS=ON -DCMAKE_CXX_COMPILER_WORKS=ON
    "-DLLVM_ENABLE_RUNTIMES=libunwind;libcxxabi;libcxx"
    -DLIBUNWIND_ENABLE_SHARED=OFF -DLIBUNWIND_USE_COMPILER_RT=ON
    -DLIBUNWIND_HAS_DL_LIB=OFF -DLIBUNWIND_HAS_PTHREAD_LIB=OFF
    -DLIBCXXABI_USE_COMPILER_RT=ON -DLIBCXXABI_USE_LLVM_UNWINDER=ON -DLIBCXXABI_ENABLE_STATIC_UNWINDER=ON
    -DLIBCXX_USE_COMPILER_RT=ON -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON -DLIBCXX_INSTALL_MODULES=OFF
    -DLIBUNWIND_INSTALL_LIBRARY=OFF -DLIBCXXABI_INSTALL_LIBRARY=OFF
    -DLIBCXX_INCLUDE_TESTS=OFF -DLIBCXX_INCLUDE_BENCHMARKS=OFF -DLIBCXXABI_INCLUDE_TESTS=OFF
    -DLIBUNWIND_INCLUDE_TESTS=OFF -DLIBCXX_INCLUDE_DOCS=OFF -DLIBUNWIND_INCLUDE_DOCS=OFF
)

# bionic_unwind LLVM_SRC WORK RUNTIMES: both libunwinds in RUNTIMES.
bionic_unwind() {
    local llvm=$1 work=$2 runtimes=$3 variant hide
    mkdir -p "$runtimes"
    for variant in hidden exported; do
        hide=ON
        [[ $variant == exported ]] && hide=OFF
        bionic_runtimes_cmake "$work/unwind-$variant" "$llvm" -DLLVM_ENABLE_RUNTIMES=libunwind \
            -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY -DLIBUNWIND_HIDE_SYMBOLS=$hide \
            "${bionic_unwind_args[@]}"
        ninja -C "$work/unwind-$variant"
    done
    install -m644 "$work/unwind-hidden/lib/libunwind.a" "$runtimes/libunwind.a"
    install -m644 "$work/unwind-exported/lib/libunwind.a" "$runtimes/libunwind-exported.a"
}

# bionic_cxx_noexcept LLVM_SRC WORK RUNTIMES: libc++_noexcept.a in RUNTIMES.
bionic_cxx_noexcept() {
    local llvm=$1 work=$2 runtimes=$3
    bionic_runtimes_cmake "$work/cxx-noexcept" "$llvm" "${bionic_libcxx_args[@]}" \
        -DCMAKE_INSTALL_PREFIX="$work/unused" \
        -DLIBCXX_ENABLE_SHARED=OFF -DLIBCXXABI_ENABLE_SHARED=OFF \
        -DLIBCXX_ENABLE_EXCEPTIONS=OFF -DLIBCXXABI_ENABLE_EXCEPTIONS=OFF
    ninja -C "$work/cxx-noexcept" cxx_static
    install -m644 "$work/cxx-noexcept/lib/libc++.a" "$runtimes/libc++_noexcept.a"
}

# bionic_install_libc OUT DEST: the libraries and startup files in
# DEST/usr/lib. ld-android.so is not installed: the dynamic linker provides
# it from within itself to the libraries that name it.
bionic_install_libc() {
    local out=$1 dest=$2/usr/lib f
    mkdir -p "$dest"
    for f in libc.so libc.a libm.so libm.a libdl.so libdl.a; do
        install -m644 "$out/lib/$f" "$dest/$f"
    done
    chmod 755 "$dest"/*.so
    for f in crtbegin_dynamic crtbegin_so crtbegin_static crtend_android crtend_so; do
        install -m644 "$out/obj/$f.o" "$dest/$f.o"
    done
    # The libraries a Linux C library is split into elsewhere, whose
    # functions bionic has in libc: empty, as musl's are, so that the -lrt or
    # -lpthread of a build (cmake's, for one) links.
    for f in libpthread librt libutil libresolv libxnet; do
        printf '!<arch>\n' >"$dest/$f.a"
        chmod 644 "$dest/$f.a"
    done
}

# bionic_install_liblog TREE OUT DEST: liblog.so and <android/log.h>.
bionic_install_liblog() {
    install -Dm755 "$2/lib/liblog.so" "$3/usr/lib/liblog.so"
    install -Dm644 "$1/system/logging/liblog/include/android/log.h" "$3/usr/include/android/log.h"
}

# bionic_install_linker OUT DEST: the dynamic linker, at the path clang
# writes into every executable.
bionic_install_linker() {
    install -Dm755 "$1/bin/linker64" "$2/usr/lib/ld-bionic-aarch64.so.1"
}
