#!/bin/bash
# Stage 1 of the joe Linux ARM bootstrap: the cross toolchain and the C
# library, built by this machine's compiler.
#
#   1. LLVM (clang, lld and the binary tools) for this machine, targeting
#      aarch64-unknown-linux-android37 by default.
#   2. bionic's headers, then compiler-rt's builtins, then bionic itself,
#      then libunwind, libc++abi and libc++, all for the target.
#
# Unlike Linux From Scratch there is no GCC and no binutils: bionic is built
# with clang and expects LLVM's runtimes.
#
# The toolchain is installed inside the build root, in /usr/lib/joe-cross,
# with a `sysroot` link pointing three levels up. From this machine that is
# build/bootstrap/root; inside the build root (entered with bwrap) it is /.
# The same clang therefore builds the temporary tools from outside and every
# package from inside. It is a program for this machine (x86_64 or aarch64),
# linked against its C library, so the libraries it needs from this machine
# are copied beside it (lib/, its $ORIGIN/../lib rpath) and the machine's
# loader into the build root, where its programs look for it (/lib64 on
# x86_64, /lib on aarch64). None of this is packaged.
#
# On an x86_64 machine the build root's own programs run under qemu-user, so
# the compiler being this machine's is what makes builds fast; on an aarch64
# machine everything runs natively.
#
# Runs as an ordinary user. Each step leaves a marker, so the script can be
# re-run after a failure and continues where it stopped.
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
source "$top/bootstrap/lib.sh"
export PATH=$hosttools/bin:/usr/bin
jobs=$(nproc)

root=$top/build/bootstrap/root
cross=$root/usr/lib/joe-cross
interp=$JOE_INTERP

mkdir -p "$root"/usr/{bin,lib,sbin,include} "$root/etc"
for d in bin lib sbin; do [[ -e $root/$d ]] || ln -s "usr/$d" "$root/$d"; done

# --- 1. LLVM for this machine ---------------------------------------------

llvm() {
    unpack llvm-project-23.1.0.src.tar.xz
    # clang's Android driver hardcodes Android's interpreter; joe's is $interp.
    # Fail loudly if an LLVM update moved the line.
    local f=clang/lib/Driver/ToolChains/Linux.cpp
    grep -q 'return Triple.isArch64Bit() ? "/system/bin/linker64" : "/system/bin/linker";' "$f"
    sed -i "s|return Triple.isArch64Bit() ? \"/system/bin/linker64\" : \"/system/bin/linker\";|return Triple.isArch64Bit() ? \"$interp\" : \"/usr/lib/ld-bionic-arm.so.1\";|" "$f"
    grep -q "\"$interp\"" "$f"

    cmake -G Ninja -S llvm -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$cross" \
        -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ \
        -DLLVM_ENABLE_PROJECTS="clang;lld" \
        -DLLVM_TARGETS_TO_BUILD="AArch64;BPF" \
        -DLLVM_DEFAULT_TARGET_TRIPLE="$JOE_TARGET" \
        -DLLVM_INSTALL_TOOLCHAIN_ONLY=ON \
        -DLLVM_INSTALL_BINUTILS_SYMLINKS=ON \
        -DLLVM_TOOLCHAIN_TOOLS="llvm-ar;llvm-ranlib;llvm-nm;llvm-objcopy;llvm-strip;llvm-readobj;llvm-readelf;llvm-objdump;llvm-size;llvm-strings;llvm-cxxfilt;llvm-symbolizer;llvm-addr2line;llvm-dwarfdump;llvm-as;llvm-dis;llvm-link;llvm-profdata;llvm-cov" \
        -DCLANG_DEFAULT_LINKER=lld \
        -DCLANG_DEFAULT_OBJCOPY=llvm-objcopy \
        -DCLANG_DEFAULT_RTLIB=compiler-rt \
        -DCLANG_DEFAULT_UNWINDLIB=libunwind \
        -DCLANG_DEFAULT_CXX_STDLIB=libc++ \
        -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF \
        -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_LIBPFM=OFF -DLLVM_ENABLE_FFI=OFF \
        -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_PARALLEL_LINK_JOBS=4 \
        -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF \
        -DCLANG_ENABLE_ARCMT=OFF -DCLANG_ENABLE_STATIC_ANALYZER=OFF
    ninja -C build -j"$jobs"
    ninja -C build install

    # The libraries the toolchain needs from this machine, beside it, and the
    # loader where this machine's programs look for it.
    local lib loader
    for lib in $(ldd "$cross/bin/clang" "$cross/bin/lld" | awk '$3 ~ /^\// { print $3 }' | sort -u); do
        cp -L "$lib" "$cross/lib/"
    done
    loader=$(readelf -l "$cross/bin/clang" | sed -n 's/.*interpreter: \(.*\)]/\1/p')
    mkdir -p "$root$(dirname "$loader")"
    cp -L "$loader" "$root$loader"

    # clang picks its mode from the name it is run by: cpp preprocesses.
    ln -sfn ../../.. "$cross/sysroot"
    ln -sf clang "$cross/bin/cc"
    ln -sf clang++ "$cross/bin/c++"
    ln -sf clang "$cross/bin/cpp"
    ln -sf ld.lld "$cross/bin/ld"
    # The binutils names, which build systems call without asking: an
    # install with LLVM_INSTALL_TOOLCHAIN_ONLY does not make these.
    local t
    for t in ar ranlib nm strip objcopy objdump readelf size strings addr2line; do
        ln -sf "llvm-$t" "$cross/bin/$t"
    done
    ln -sf llvm-cxxfilt "$cross/bin/c++filt"

    # The interpreter path must be what clang writes into executables.
    echo 'int main(void){return 0;}' > t.c
    "$cross/bin/clang" -### t.c 2>&1 | grep -q -- "-dynamic-linker\" \"$interp\""
}

step llvm llvm

# --- 2. The C library and LLVM's runtimes, for the target -----------------

source "$top/packages/bionic/bionic.sh"
llvm_src=$top/build/bootstrap/llvm-src
aosp=$top/build/bootstrap/aosp
bionic_out=$top/build/bootstrap/bionic-out
runtimes=$top/build/bootstrap/runtimes
resource=$cross/lib/clang/23
export JOE_CROSS=$cross JOE_SYSROOT=$root JOE_TARGET JOE_RUNTIMES=$runtimes JOBS=$jobs
export JOE_BUILTINS=$resource/lib/$JOE_TARGET/libclang_rt.builtins.a

llvm_source() {
    rm -rf "$llvm_src"
    mkdir -p "$llvm_src"
    fetch llvm-project-23.1.0.src.tar.xz
    tar -xf "$src/llvm-project-23.1.0.src.tar.xz" -C "$llvm_src" --strip-components=1
}

# runtimes_cmake DIR [CMAKE ARGS...]: LLVM's runtimes, for the target.
runtimes_cmake() {
    local dir=$1
    shift
    bionic_runtimes_cmake "$dir" "$llvm_src" "$@"
}

aosp_tree() {
    local f
    for f in $(bionic_sources); do fetch "$f"; done
    bionic_tree "$src" "$aosp"
}

headers() {
    bionic_headers "$aosp" "$root"
}

# compiler-rt's builtins (clang's libgcc), where clang looks for them, and
# its public headers, which bionic's memory tagging code includes. Nothing
# can be linked yet, so the configure checks only compile.
builtins() {
    runtimes_cmake build -DLLVM_ENABLE_RUNTIMES=compiler-rt \
        -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON -DCOMPILER_RT_BUILD_BUILTINS=ON -DCOMPILER_RT_BUILD_CRT=OFF \
        -DCOMPILER_RT_BUILD_SANITIZERS=OFF -DCOMPILER_RT_BUILD_XRAY=OFF -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
        -DCOMPILER_RT_BUILD_PROFILE=OFF -DCOMPILER_RT_BUILD_MEMPROF=OFF -DCOMPILER_RT_BUILD_ORC=OFF \
        -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF -DCOMPILER_RT_BUILD_GWP_ASAN=OFF -DCOMPILER_RT_INCLUDE_TESTS=OFF
    ninja -C build
    install -Dm644 "build/compiler-rt/lib/$JOE_TARGET/libclang_rt.builtins.a" "$JOE_BUILTINS"
    mkdir -p "$resource/include"
    cp -a "$llvm_src/compiler-rt/include/sanitizer" "$resource/include/"
}

unwind() {
    bionic_unwind "$llvm_src" "$PWD" "$runtimes"
    install -m644 "$runtimes/libunwind.a" "$root/usr/lib/libunwind.a"
}

libc() {
    bionic_build "$aosp" "$bionic_out" "${bionic_libc_products[@]}"
    bionic_install_libc "$bionic_out" "$root"
}

# libc++, with libc++abi in it and a static libunwind, as joe's C++ standard
# library; then libc++ without exceptions, which the dynamic linker links.
libcxx() {
    runtimes_cmake build "${bionic_libcxx_args[@]}" -DCMAKE_INSTALL_PREFIX="$root/usr"
    ninja -C build
    ninja -C build install
    bionic_cxx_noexcept "$llvm_src" "$PWD" "$runtimes"
}

linker() {
    bionic_build "$aosp" "$bionic_out" "${bionic_libc_products[@]}" "${bionic_linker_products[@]}" \
        "${bionic_liblog_products[@]}"
    bionic_install_linker "$bionic_out" "$root"
    bionic_install_liblog "$aosp" "$bionic_out" "$root"
}

# A C++ program that throws, starts a thread and loads a library, run with
# the build root as its file system (run_target: by qemu-user, or natively
# on an aarch64 machine): the toolchain, the C library, libc++ and the
# dynamic linker together.
check() {
    cat > t.cpp <<'EOT'
#include <dlfcn.h>
#include <pwd.h>
#include <stdexcept>
#include <string>
#include <thread>
int main() {
  std::string s;
  try { throw std::runtime_error("ok"); } catch (const std::exception& e) { s = e.what(); }
  std::thread t([&] { s += " thread"; });
  t.join();
  if (dlopen("libm.so", RTLD_NOW) == nullptr) return 2;
  return s == "ok thread" ? 0 : 1;
}
EOT
    "$cross/bin/clang++" -O2 t.cpp -o t
    readelf -l t | grep -q "interpreter: $interp]"
    run_target "$root" ./t
}

# --- 3. Rust, for this machine, with a standard library for the target ----
#
# dynamod's service manager is Rust. Like dave and dynamod-init (Zig), it is
# compiled on this machine for the target, so this is a cross compiler kept
# here, not in the build root. x.py builds its own LLVM (AArch64, and this
# machine's architecture): the cross toolchain above is installed without
# LLVM's libraries. The
# standard library for aarch64-linux-android is compiled against bionic in
# the build root, and programs are linked by the cross toolchain's clang.

rust_prefix=$top/build/bootstrap/rust

rust() {
    local stage0_date=2026-08-20 stage0_version=1.98.0 c targets=AArch64
    [[ $JOE_HOST_ARCH == x86_64 ]] && targets="AArch64;X86"
    unpack rustc-1.99.0-src.tar.xz
    mkdir -p "build/cache/$stage0_date"
    for c in rustc rust-std cargo; do
        fetch "$c-$stage0_version-$JOE_HOST.tar.xz"
        cp "$src/$c-$stage0_version-$JOE_HOST.tar.xz" "build/cache/$stage0_date/"
    done
    cat > bootstrap.toml <<EOT
change-id = "ignore"

[llvm]
targets = "$targets"
download-ci-llvm = false

[build]
description = "joe Linux ARM cross compiler"
build = "$JOE_HOST"
host = ["$JOE_HOST"]
target = ["$JOE_HOST", "aarch64-linux-android"]
docs = false
extended = true
tools = ["cargo"]
vendor = true

[install]
prefix = "$rust_prefix"
# Under the prefix: the default is the build machine's /etc.
sysconfdir = "etc"

[rust]
channel = "stable"
llvm-bitcode-linker = false
# The cross toolchain's lld is built without zlib.
compress-debuginfo = "off"

[target.aarch64-linux-android]
cc = "$cross/bin/clang"
cxx = "$cross/bin/clang++"
ar = "$cross/bin/llvm-ar"
ranlib = "$cross/bin/llvm-ranlib"
linker = "$cross/bin/clang"
EOT
    export CARGO_HOME=$PWD/build/cargo-home
    ./x.py build --jobs "$jobs"
    rm -rf "$rust_prefix"
    ./x.py install
    # A Rust program for the target, linked and run like the C++ one in
    # stage1-check. The linker is the cross toolchain's, given each time as
    # cargo users give it (CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER).
    printf 'fn main() { let v: Vec<u32> = (1..=4).collect(); std::thread::spawn(move || assert_eq!(v.iter().sum::<u32>(), 10)).join().unwrap(); }\n' > t.rs
    "$rust_prefix/bin/rustc" -O --target aarch64-linux-android -C linker="$cross/bin/clang" t.rs -o t
    readelf -l t | grep -q "interpreter: $interp]"
    run_target "$root" ./t
}

step llvm-source llvm_source
step aosp-tree aosp_tree
step bionic-headers headers
step compiler-rt-builtins builtins
step libunwind unwind
step bionic-libc libc
step libcxx libcxx
step bionic-linker linker
step stage1-check check
step rust rust
