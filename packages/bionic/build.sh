# bionic is built as the bootstrap builds it (bootstrap/stage1.sh), with the
# functions of bionic.sh: an AOSP tree assembled from the sources, joe's
# patches and overlay, and bp/, which reads its Android.bp files.
#
# The cross toolchain in /usr/lib/joe-cross compiles; the build root is the
# sysroot. libc++'s configure checks link against the build root's C library,
# so the libc++ without exceptions is built after libunwind and before
# bionic's own libraries replace that C library in this package.

source /recipe/bionic.sh

# Nothing to unpack: the first source is one of several AOSP trees.
unpack() { :; }

build() {
    export JOE_CROSS=/usr/lib/joe-cross JOE_SYSROOT=/ JOE_TARGET=aarch64-unknown-linux-android37
    export JOE_RUNTIMES=/build/runtimes
    export JOE_BUILTINS=$JOE_CROSS/lib/clang/23/lib/$JOE_TARGET/libclang_rt.builtins.a

    bionic_tree "$SOURCES" /build/aosp

    mkdir -p /build/llvm
    tar -xf "$SOURCES/llvm-project-23.1.0.src.tar.xz" -C /build/llvm --strip-components=1 \
        llvm-project-23.1.0.src/{cmake,libc,libunwind,libcxx,libcxxabi,runtimes,llvm/cmake,llvm/utils,third-party}
    bionic_unwind /build/llvm /build/runtimes-work "$JOE_RUNTIMES"
    bionic_cxx_noexcept /build/llvm /build/runtimes-work "$JOE_RUNTIMES"

    bionic_build /build/aosp /build/out "${bionic_libc_products[@]}" "${bionic_linker_products[@]}" \
        "${bionic_liblog_products[@]}"
}

package() {
    bionic_headers /build/aosp "$DESTDIR"
    bionic_install_libc /build/out "$DESTDIR"
    bionic_install_linker /build/out "$DESTDIR"
    bionic_install_liblog /build/aosp /build/out "$DESTDIR"
}
