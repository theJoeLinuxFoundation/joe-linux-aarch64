build() {
    ./configure --prefix=/usr \
        --mandir=/usr/share/man \
        --with-shared \
        --without-debug \
        --without-normal \
        --with-cxx-shared \
        --enable-pc-files \
        --with-pkg-config-libdir=/usr/lib/pkgconfig
    make
}

package() {
    make DESTDIR="$DESTDIR" install

    # Always use the wide-character ABI, which is what makes the non-wide
    # library names below safe to link against.
    sed -e 's/^#if.*XOPEN.*$/#if 1/' -i "$DESTDIR/usr/include/curses.h"

    # Applications asking for the non-wide libraries get the wide ones.
    local lib
    for lib in ncurses form panel menu; do
        ln -sf "lib${lib}w.so" "$DESTDIR/usr/lib/lib${lib}.so"
        ln -sf "${lib}w.pc" "$DESTDIR/usr/lib/pkgconfig/${lib}.pc"
    done

    # Old build systems look for -lcurses.
    ln -sf libncursesw.so "$DESTDIR/usr/lib/libcurses.so"
}
