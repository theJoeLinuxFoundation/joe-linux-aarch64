# Not in the book: the newest upstream release, built as its README says.
build() {
    # No stack traces (-k): elfutils' libdw and the standalone libunwind
    # are not packaged on ARM. There is no 32-bit toolchain, so no decoding
    # of 32-bit processes (mpers). No SELinux. The terminal width comes from
    # ncurses' terminfo, which configure picks up without a switch.
    ./configure --prefix=/usr \
        --enable-stacktrace=no \
        --without-libdw \
        --without-libunwind \
        --without-libiberty \
        --without-libselinux \
        --enable-mpers=no
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
