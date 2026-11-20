build() {
    # ARMv8.0 rather than native: the package must run on any 64-bit Arm CPU
    # (and "native" in the build root would be the build machine's).
    # Without --disable-multi-os-directory the library can land in lib64.
    ./configure --prefix=/usr \
        --disable-static \
        --disable-multi-os-directory \
        --with-gcc-arch=armv8-a
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
