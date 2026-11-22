# joe Linux ARM's own compiler: clang, lld and LLVM's binary tools, built for
# and on the target. The bootstrap's compiler (bootstrap/stage1.sh, "llvm"
# and "builtins") is a program for the build machine in /usr/lib/joe-cross,
# which builds every package; this one is the installed system's, and is
# configured as that one is: for aarch64-unknown-linux-android37 (bionic,
# whose name clang and configure scripts know), writing joe's dynamic linker
# into programs, and linking with lld, compiler-rt, libunwind and libc++.
#
# clang, lld and the tools share libLLVM and libclang-cpp rather than each
# carrying LLVM, which keeps the package, and the installation medium that
# carries it in joe-base, smaller.

target=aarch64-unknown-linux-android37
interp=/usr/lib/ld-bionic-aarch64.so.1
cross=/usr/lib/joe-cross/bin

prepare() {
    # clang's Android driver hardcodes Android's interpreter; joe's is
    # $interp. Fail loudly if an LLVM update moved the line (as stage1.sh).
    local f=clang/lib/Driver/ToolChains/Linux.cpp
    grep -q 'return Triple.isArch64Bit() ? "/system/bin/linker64" : "/system/bin/linker";' "$f"
    sed -i "s|return Triple.isArch64Bit() ? \"/system/bin/linker64\" : \"/system/bin/linker\";|return Triple.isArch64Bit() ? \"$interp\" : \"/usr/lib/ld-bionic-arm.so.1\";|" "$f"
    grep -q "\"$interp\"" "$f"
}

build() {
    # Compile jobs are limited: at ten, a 12 GB builder runs out of memory on
    # clang's largest files. No tests, examples, benchmarks, docs, ARCMT or
    # static analyzer (whose scan-build needs perl), as in stage1.sh.
    cmake -G Ninja -S llvm -B build -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_SKIP_INSTALL_RPATH=ON \
        -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
        -DCMAKE_AR="$cross/llvm-ar" -DCMAKE_RANLIB="$cross/llvm-ranlib" -DCMAKE_NM="$cross/llvm-nm" \
        -DLLVM_ENABLE_PROJECTS="clang;lld" \
        -DLLVM_TARGETS_TO_BUILD="AArch64;BPF" \
        -DLLVM_HOST_TRIPLE="$target" -DLLVM_DEFAULT_TARGET_TRIPLE="$target" \
        -DLLVM_BUILD_LLVM_DYLIB=ON -DLLVM_LINK_LLVM_DYLIB=ON -DCLANG_LINK_CLANG_DYLIB=ON \
        -DLLVM_ENABLE_RTTI=ON \
        -DLLVM_INSTALL_BINUTILS_SYMLINKS=ON \
        -DCLANG_DEFAULT_LINKER=lld \
        -DCLANG_DEFAULT_OBJCOPY=llvm-objcopy \
        -DCLANG_DEFAULT_RTLIB=compiler-rt \
        -DCLANG_DEFAULT_UNWINDLIB=libunwind \
        -DCLANG_DEFAULT_CXX_STDLIB=libc++ \
        -DLLVM_ENABLE_ZLIB=FORCE_ON -DLLVM_ENABLE_ZSTD=FORCE_ON \
        -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_LIBPFM=OFF \
        -DLLVM_ENABLE_FFI=OFF -DLLVM_ENABLE_Z3_SOLVER=OFF -DLLVM_ENABLE_ASSERTIONS=OFF \
        -DLLVM_PARALLEL_COMPILE_JOBS=7 -DLLVM_PARALLEL_LINK_JOBS=2 \
        -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF \
        -DCLANG_ENABLE_ARCMT=OFF -DCLANG_ENABLE_STATIC_ANALYZER=OFF
    ninja -C build

    # compiler-rt's builtins (clang's libgcc, linked into every program),
    # built as stage1.sh builds the cross compiler's. bionic supplies the
    # startup files, so not compiler-rt's crt.
    cmake -G Ninja -S runtimes -B builtins -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_ASM_COMPILER=clang \
        -DCMAKE_AR="$cross/llvm-ar" -DCMAKE_RANLIB="$cross/llvm-ranlib" -DCMAKE_NM="$cross/llvm-nm" \
        -DCMAKE_C_COMPILER_TARGET="$target" -DCMAKE_CXX_COMPILER_TARGET="$target" \
        -DCMAKE_ASM_COMPILER_TARGET="$target" \
        -DLLVM_ENABLE_RUNTIMES=compiler-rt -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON \
        -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON -DCOMPILER_RT_BUILD_BUILTINS=ON -DCOMPILER_RT_BUILD_CRT=OFF \
        -DCOMPILER_RT_BUILD_SANITIZERS=OFF -DCOMPILER_RT_BUILD_XRAY=OFF -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
        -DCOMPILER_RT_BUILD_PROFILE=OFF -DCOMPILER_RT_BUILD_MEMPROF=OFF -DCOMPILER_RT_BUILD_ORC=OFF \
        -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF -DCOMPILER_RT_BUILD_GWP_ASAN=OFF -DCOMPILER_RT_INCLUDE_TESTS=OFF
    ninja -C builtins
}

package() {
    DESTDIR="$DESTDIR" ninja -C build install

    # What only building against LLVM needs, and LLVM's own development
    # tools, stay out: the base system carries this package, and they were
    # three quarters of its 650 MB. That is the headers, the static
    # component libraries (364 MB), the CMake files, the libclang C API that
    # nothing installed links, llvm-config, TableGen and llvm-exegesis. An
    # llvm-dev package can carry them when something builds against LLVM.
    rm -rf "$DESTDIR"/usr/include/{llvm,llvm-c,clang,clang-c,lld} \
        "$DESTDIR"/usr/lib/cmake/{llvm,clang,lld}
    find "$DESTDIR/usr/lib" -maxdepth 1 -name 'lib*.a' -delete
    rm -f "$DESTDIR"/usr/lib/libclang.so* \
        "$DESTDIR"/usr/bin/{llvm-tblgen,clang-tblgen,llvm-exegesis,llvm-config}
    rmdir "$DESTDIR/usr/include" "$DESTDIR/usr/lib/cmake" 2>/dev/null || true

    # The builtins where this clang looks for them (its resource directory),
    # and compiler-rt's public headers, which bionic's headers include.
    local resource="$DESTDIR/usr/lib/clang/23"
    install -Dm644 "builtins/compiler-rt/lib/$target/libclang_rt.builtins.a" \
        "$resource/lib/$target/libclang_rt.builtins.a"
    cp -a compiler-rt/include/sanitizer "$resource/include/"

    # The names build systems call without asking, as the cross toolchain
    # has them: LLVM_INSTALL_BINUTILS_SYMLINKS made ar, nm, objcopy, strip,
    # readelf and the rest; clang picks its mode from the name it is run by.
    ln -s clang "$DESTDIR/usr/bin/cc"
    ln -s clang++ "$DESTDIR/usr/bin/c++"
    ln -s clang "$DESTDIR/usr/bin/cpp"
    ln -s ld.lld "$DESTDIR/usr/bin/ld"
}
