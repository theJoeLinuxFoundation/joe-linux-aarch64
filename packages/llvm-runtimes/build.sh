# libc++ with libc++abi merged into it and a static libunwind inside, and
# libunwind.a with hidden symbols, which clang links into every program
# (-l:libunwind.a), so it is needed in the build root and shipped.
# compiler-rt's builtins belong to the cross toolchain, not to this package.
#
# libc++ is built as Android's, with __ANDROID__, which the cross toolchain
# leaves undefined for joe's own programs.
#
# The configuration is the one packages/bionic/bionic.sh gives the
# bootstrap's libc++ (bionic_libcxx_args, bionic_unwind_args); keep the two
# the same. (A recipe sees only its own directory, so it cannot read that
# file.)

unpack() {
    tar -xf "$SOURCES/$PKG_SOURCE" --strip-components=1 --no-same-owner \
        llvm-project-23.1.0.src/{cmake,libc,libunwind,libcxx,libcxxabi,runtimes,llvm/cmake,llvm/utils,third-party}
}

runtimes() {
    local dir=$1
    shift
    cmake -G Ninja -S runtimes -B "$dir" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_ASM_COMPILER=clang \
        -DCMAKE_AR=/usr/lib/joe-cross/bin/llvm-ar -DCMAKE_RANLIB=/usr/lib/joe-cross/bin/llvm-ranlib \
        -DCMAKE_NM=/usr/lib/joe-cross/bin/llvm-nm \
        -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF "$@"
}

build() {
    runtimes build -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_C_COMPILER_WORKS=ON -DCMAKE_CXX_COMPILER_WORKS=ON \
        "-DLLVM_ENABLE_RUNTIMES=libunwind;libcxxabi;libcxx" \
        -DLIBUNWIND_ENABLE_SHARED=OFF -DLIBUNWIND_USE_COMPILER_RT=ON \
        -DLIBUNWIND_HAS_DL_LIB=OFF -DLIBUNWIND_HAS_PTHREAD_LIB=OFF \
        -DLIBCXXABI_USE_COMPILER_RT=ON -DLIBCXXABI_USE_LLVM_UNWINDER=ON -DLIBCXXABI_ENABLE_STATIC_UNWINDER=ON \
        -DLIBCXX_USE_COMPILER_RT=ON -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON -DLIBCXX_INSTALL_MODULES=OFF \
        -DLIBUNWIND_INSTALL_LIBRARY=OFF -DLIBCXXABI_INSTALL_LIBRARY=OFF \
        -DLIBCXX_INCLUDE_TESTS=OFF -DLIBCXX_INCLUDE_BENCHMARKS=OFF -DLIBCXXABI_INCLUDE_TESTS=OFF \
        -DLIBUNWIND_INCLUDE_TESTS=OFF -DLIBCXX_INCLUDE_DOCS=OFF -DLIBUNWIND_INCLUDE_DOCS=OFF
    ninja -C build
    runtimes unwind -DLLVM_ENABLE_RUNTIMES=libunwind -DLIBUNWIND_HIDE_SYMBOLS=ON \
        -DLIBUNWIND_HAS_DL_LIB=OFF -DLIBUNWIND_HAS_PTHREAD_LIB=OFF \
        -DLIBUNWIND_ENABLE_SHARED=OFF -DLIBUNWIND_ENABLE_STATIC=ON -DLIBUNWIND_USE_COMPILER_RT=ON \
        -DLIBUNWIND_INCLUDE_TESTS=OFF -DLIBUNWIND_INCLUDE_DOCS=OFF
    ninja -C unwind
}

package() {
    DESTDIR="$DESTDIR" ninja -C build install
    install -m644 unwind/lib/libunwind.a "$DESTDIR/usr/lib/libunwind.a"
}
