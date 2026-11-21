# Not in the book: the newest upstream release, built as its README says.
build() {
    # libnl supplies task delay accounting. Temperatures (lm-sensors), hwloc
    # and backtraces of other processes (libunwind) lack their libraries.
    ./configure --prefix=/usr \
        --sysconfdir=/etc \
        --enable-unicode \
        --enable-affinity \
        --enable-capabilities \
        --enable-delayacct \
        --disable-sensors \
        --disable-hwloc \
        --disable-backtrace \
        --without-libunwind \
        --disable-pcp \
        --disable-static
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
