# Not in the book: the newest upstream release, built as its README says.
build() {
    # utf8proc supplies Unicode width data. Use the allocator in bionic.
    # utempter (utmp records for panes) remains unavailable.
    ./configure --prefix=/usr \
        --disable-systemd \
        --enable-sixel \
        --enable-utf8proc \
        --disable-utempter \
        --disable-jemalloc
    make
}

package() {
    make DESTDIR="$DESTDIR" install
}
